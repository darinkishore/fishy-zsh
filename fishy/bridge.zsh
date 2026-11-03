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

zmodload zsh/system 2>/dev/null

typeset -gA _fishy_wfd _fishy_rfd _fishy_pid _fishy_envsig
typeset -gi _fishy_seq=0
typeset -ga fishy_reply

: ${FISHY_FISH:=fishy-fish}

_fishy_start() {
  emulate -L zsh
  local name=$1 dir wfd rfd
  dir=$(command mktemp -d "${TMPDIR:-/tmp}/fishy.XXXXXX") || return 1
  command mkfifo -m 600 $dir/req $dir/resp || { command rm -rf $dir; return 1 }
  # The child opens req (read) then resp (write); we open in the same order,
  # so neither side can deadlock on the other's open().
  $FISHY_FISH -c "source ${(q)FISHY_DIR}/server.fish" <$dir/req >$dir/resp 2>/dev/null &!
  _fishy_pid[$name]="$!"
  exec {wfd}>$dir/req {rfd}<$dir/resp
  command rm -rf $dir
  _fishy_wfd[$name]=$wfd _fishy_rfd[$name]=$rfd _fishy_envsig[$name]=''
}

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
  _fishy_write $name env "${kv[@]}" || return 1
  fishy-recv $name $REPLY || return 1
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
  _fishy_sync_env $name || return 1
  _fishy_write $name "$@"
}

fishy-call() {
  emulate -L zsh
  local name=$1; shift
  fishy-send $name "$@" || return 1
  fishy-recv $name $REPLY
}
