# fishy highlight: fish's syntax highlighting (highlight_shell, colors resolved by
# fish) with fish's update model (src/reader/reader.rs super_highlight_me_plenty,
# highlight_completed, editable_line.rs apply_edit):
#   - one color per character, kept in _fhl_colors (zle highlight specs);
#   - an edit splices in copies of the color just before the edit;
#   - an async highlight (with I/O) is requested whenever the text changes and
#     applied only if the text still matches when it arrives.

typeset -ga _fhl_colors
typeset -g  _fhl_inflight=''
typeset -g  _fhl_req_id=''

fishy-highlight-reset() { _fhl_colors=() _fhl_inflight='' _fhl_req_id='' }

# fish: apply_edit's color splice. Called for every BUFFER change by _fe_apply.
_fhl_splice() {
  local -i start=$1 end=$2 n=$3 i
  local fill=none
  (( start > 0 )) && fill=${_fhl_colors[start]:-none}
  local -a ins=()
  for (( i = 0; i < n; i++ )); do ins+=($fill); done
  _fhl_colors=("${(@)_fhl_colors[1,start]}" "${ins[@]}" "${(@)_fhl_colors[end+1,-1]}")
}

# Keep the color array in sync if something else rewrote BUFFER.
_fhl_check() {
  (( ${#_fhl_colors} == ${#BUFFER} )) && return
  local -i i
  _fhl_colors=()
  for (( i = 0; i < ${#BUFFER}; i++ )); do _fhl_colors+=(none); done
}

# fish: super_highlight_me_plenty
fishy-highlight-update() {
  _fhl_check
  [[ $BUFFER == "$_fhl_inflight" && -n $_fhl_req_id ]] && return
  _fhl_inflight=$BUFFER
  fishy-async-send highlight highlight 1 $CURSOR "$BUFFER" || return
  _fhl_req_id=$REPLY
}

# Fill _fhl_colors from H records for text of length $1.
_fhl_apply_records() {
  local -i len=$1 i
  shift
  _fhl_colors=()
  for (( i = 0; i < len; i++ )); do _fhl_colors+=(none); done
  local rec
  for rec in "$@"; do
    local -a f=("${(@ps:\x1f:)rec}")
    [[ $f[1] == H ]] || continue
    for (( i = f[2] + 1; i <= f[3]; i++ )); do _fhl_colors[i]=$f[4]; done
  done
}

# fish: highlight_completed
_fishy_async_done_highlight() {
  local id=$1; shift
  [[ $id == "$_fhl_req_id" ]] || return
  local text=$_fhl_inflight
  _fhl_inflight='' _fhl_req_id=''
  [[ $text == "$BUFFER" ]] || return
  _fhl_apply_records ${#BUFFER} "$@"
}

# fish: finish_highlighting_before_exec: if the current colors are stale, do a
# quick highlight without I/O so the final rendering is right.
fishy-highlight-finish() {
  [[ -z $_fhl_req_id ]] && return
  fishy-call sync highlight 0 $CURSOR "$BUFFER" || return
  _fhl_apply_records ${#BUFFER} "$fishy_reply[@]"
  _fhl_inflight='' _fhl_req_id=''
}

# region_highlight entries for the command line (runs of equal color).
fishy-highlight-entries() {
  reply=()
  _fhl_check
  local -i i=1 n=${#_fhl_colors} j
  while (( i <= n )); do
    local c=$_fhl_colors[i]
    j=$i
    while (( j < n )) && [[ $_fhl_colors[j+1] == "$c" ]]; do (( j++ )); done
    [[ $c != none ]] && reply+=("$(( i - 1 )) $j $c memo=fishy")
    i=$(( j + 1 ))
  done
}
