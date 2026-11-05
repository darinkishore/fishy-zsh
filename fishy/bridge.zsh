# fishy bridge: persistent patched-fish servers that make fish's decisions for zsh.
#
# Two independent servers so that slow work never blocks typing:
#   sync  - Tab completion, history, word motion (we wait for the answer)
#   async - autosuggestions (answer arrives via `zle -F`, stale ones dropped)
#
#   fishy-call SERVER SUBCOMMAND ARGS...
#       synchronous; reply records land in $fishy_reply (fields \x1f-separated)
#   fishy-send SERVER SUBCOMMAND ARGS...   -> prints request id
#   fishy-recv SERVER ID                   -> collect reply for ID into $fishy_reply
#
# Every request carries an id; records belonging to an older (abandoned) request
# are discarded, so ^C in the middle of a reply can never desynchronize us.

zmodload zsh/system zsh/datetime 2>/dev/null  # sysread/zselect, $EPOCHREALTIME

typeset -gA _fishy_wfd _fishy_rfd _fishy_pid _fishy_envsig
typeset -gi _fishy_seq=0
typeset -ga fishy_reply

: ${FISHY_FISH:=fishy-fish}

# Debug log: export FISHY_LOG=/path/to/file to trace bridge and reader events.
fishy-log() { [[ -n $FISHY_LOG ]] && print -r -- "$EPOCHREALTIME $*" >>$FISHY_LOG; return 0 }

_fishy_start() {
  emulate -L zsh
  local name=$1 wfd rfd
  # A detached coproc gives us a pipe pair without forking helpers (mktemp,
  # mkfifo, rm). Its fds are duplicated and the job disowned, so the next
  # coproc can start and nothing shows up in `jobs`.
  # __fishy_interactive_config: fish loads its config as an interactive fish
  # does (`status is-interactive` is true during config only), so the server
  # has interactive fish's abbreviations, functions, completions and default
  # theme (share/config.fish). See the patch in src/bin/fish.rs.
  # No job control here: no "[n] pid" notice. The server then shares zsh's
  # process group, so it ignores terminal-generated signals itself
  # (`__fishy serve-init` in server.fish).
  setopt local_options no_monitor no_notify no_multios
  # Replies travel on fd 3: fish writes event handler output, titles and the
  # like straight to fds 1/2 (no redirection catches them), so the protocol
  # pipe must not be one of those. The prompt requests capture them.
  coproc __fishy_interactive_config=1 $FISHY_FISH -c "source ${(q)FISHY_DIR}/server.fish" 3>&1 >/dev/null 2>/dev/null
  _fishy_pid[$name]="$!"
  exec {wfd}>&p {rfd}<&p
  # Out of the job table (even without job control a coproc is a job): else
  # `exit` and ctrl-d stop at "you have running jobs". _fishy_shutdown ends
  # the servers instead.
  disown
  _fishy_wfd[$name]=$wfd _fishy_rfd[$name]=$rfd _fishy_envsig[$name]=''
}

# zsh is exiting: stop the servers. Being disowned they get no SIGHUP, and a
# background command started from this shell may hold their pipe open.
_fishy_shutdown() {
  local name
  for name in ${(k)_fishy_pid}; do _fishy_stop $name; done
}
zshexit_functions+=(_fishy_shutdown)

_fishy_stop() {
  emulate -L zsh
  local name=$1 fd
  if [[ -n $_fishy_wfd[$name] ]]; then fd=$_fishy_wfd[$name]; exec {fd}>&-; fi
  if [[ -n $_fishy_rfd[$name] ]]; then fd=$_fishy_rfd[$name]; exec {fd}<&-; fi
  [[ -n $_fishy_pid[$name] ]] && kill $_fishy_pid[$name] 2>/dev/null
  unset "_fishy_wfd[$name]" "_fishy_rfd[$name]" "_fishy_pid[$name]" "_fishy_envsig[$name]"
}

_fishy_ensure() {
  emulate -L zsh
  local name=$1
  [[ -n $_fishy_pid[$name] ]] && kill -0 $_fishy_pid[$name] 2>/dev/null && return 0
  _fishy_stop $name
  _fishy_start $name
}

# Write one request; prints nothing, sets REPLY to the id.
_fishy_write() {
  emulate -L zsh
  local name=$1; shift
  local id=$(( ++_fishy_seq ))
  local -a fields=($id $PWD "$@")
  print -rnu $_fishy_wfd[$name] -- "${(pj:\x1f:)fields}"$'\0' 2>/dev/null || {
    _fishy_stop $name
    return 1
  }
  REPLY=$id
}

# Exported environment changed since this server last saw it? Send it first.
_fishy_sync_env() {
  emulate -L zsh
  local name=$1 k
  local -a kv
  for k in ${(k)parameters[(R)*export*]}; do
    kv+=("$k=${(P)k}")
  done
  kv=(${(o)kv})
  local sig=${(pj:\x1f:)kv}
  [[ $sig == "$_fishy_envsig[$name]" ]] && return 0
  # Fire-and-forget: requests are processed in order, and the reply is
  # discarded by the next fishy-recv (or the async handler) by its id.
  _fishy_ensure $name || return 1
  _fishy_write $name env "${kv[@]}" || return 1
  _fishy_envsig[$name]=$sig
}

fishy-recv() {
  emulate -L zsh
  local name=$1 id=$2 rec
  fishy_reply=()
  while IFS= read -r -d $'\0' -u $_fishy_rfd[$name] rec; do
    if [[ $rec == $'\x1e'* ]]; then
      [[ ${rec#$'\x1e'} == "$id" ]] && return 0
      fishy_reply=()  # terminator of an abandoned request: drop its records
      continue
    fi
    fishy_reply+=("$rec")
  done
  _fishy_stop $name  # EOF: the server died mid-reply
  return 1
}

fishy-send() {
  emulate -L zsh
  local name=$1; shift
  _fishy_ensure $name || return 1
  _fishy_write $name "$@"
  fishy-log "send[$name] id=$REPLY $1"
}

# Send without waiting for the reply (ordering still holds per server).
fishy-tell() {
  emulate -L zsh
  local name=$1; shift
  fishy-send $name "$@"
}

fishy-call() {
  emulate -L zsh
  local name=$1; shift
  local -F t0=${FISHY_LOG:+$EPOCHREALTIME}
  fishy-send $name "$@" || return 1
  fishy-recv $name $REPLY || return 1
  [[ -n $FISHY_LOG ]] && fishy-log "recv[$name] $1 $(( (EPOCHREALTIME - t0) * 1000 ))ms"
  return 0
}

# ---------------------------------------------------------------- async server
# Requests on the async server are tagged with a kind; replies are dispatched to
# _fishy_async_done_<kind> ID RECORDS... from a zle -F handler.

typeset -gA _fa_kind
typeset -gi _fa_handler_fd=-1

fishy-async-send() {
  local kind=$1; shift
  fishy-send async "$@" || return 1
  _fa_kind[$REPLY]=$kind
  local fd=$_fishy_rfd[async]
  if [[ -n $fd ]] && (( fd != _fa_handler_fd )); then
    (( _fa_handler_fd >= 0 )) && zle -F $_fa_handler_fd 2>/dev/null
    zle -F -w $fd fishy-async-ready
    _fa_handler_fd=$fd
  fi
  return 0
}

# zle -F widget: consume every complete reply that is available.
_fishy_w_async_ready() {
  fishy-unswap
  _fishy_async_consume || return
  fishy-render
  zle -R
}

# Read and dispatch every complete async reply that is available (at least
# one: call it when the fd is readable). Returns 1 if the server died.
_fishy_async_consume() {
  local fd=$_fishy_rfd[async] rec
  [[ -n $fd ]] || return 1
  while :; do
    local -a records=()
    local id=''
    while IFS= read -r -d $'\0' -u $fd rec; do
      if [[ $rec == $'\x1e'* ]]; then id=${rec#$'\x1e'}; break; fi
      records+=("$rec")
    done
    if [[ -z $id ]]; then
      # EOF: the server died; forget pending requests, the next one restarts it.
      zle -F $fd 2>/dev/null; _fa_handler_fd=-1; _fa_kind=()
      _fishy_stop async
      _fs_inflight='' _fs_req_id='' _fhl_inflight='' _fhl_req_id=''
      return 1
    fi
    local kind=${_fa_kind[$id]}
    unset "_fa_kind[$id]"
    [[ -n $kind ]] && "_fishy_async_done_$kind" $id "${records[@]}"
    zselect -t 0 -r $fd 2>/dev/null || break
  done
  return 0
}
