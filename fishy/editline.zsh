# fishy editline: a port of fish's EditableLine + UndoHistory (src/editable_line.rs)
# operating on zle's $BUFFER / $CURSOR.
#
# Every modification of the command line goes through fishy-push-edit so that
# undo/redo, edit coalescing and autosuggestion bookkeeping behave like fish.
# Offsets are 0-based character offsets with half-open ranges, exactly as in
# fish; zsh's 1-based subscripts are only used at the BUFFER boundary.

# Undo history: parallel arrays, one entry per edit.
typeset -ga _fe_start _fe_end _fe_old _fe_rep _fe_cpos _fe_cpos_undo _fe_group
typeset -gi _fe_applied=0 _fe_may_coalesce=0 _fe_try_coalesce=0
typeset -gi _fe_group_level=0 _fe_group_id=0 _fe_pending_pos=-1

fishy-editline-reset() {
  _fe_start=() _fe_end=() _fe_old=() _fe_rep=() _fe_cpos=() _fe_cpos_undo=() _fe_group=()
  _fe_applied=0 _fe_may_coalesce=0 _fe_try_coalesce=0
  _fe_group_level=0 _fe_pending_pos=-1
}

# Replace [start,end) of BUFFER with rep (no bookkeeping).
_fe_apply() {
  local -i start=$1 end=$2
  _fhl_check
  BUFFER="${BUFFER[1,start]}${3}${BUFFER[end+1,-1]}"
  _fhl_splice $start $end ${#3}
}

# fish: cursor_position_after_edit
_fe_cursor_after() {
  local -i cpos=$1 start=$2 end=$3 replen=$4 removed=0
  if (( cpos > start )); then
    removed=$(( (end - start) < (cpos - start) ? (end - start) : (cpos - start) ))
  fi
  REPLY=$(( cpos + replen - removed ))
  (( REPLY < 0 )) && REPLY=0
}

# fish: want_to_coalesce_insertion_of
_fe_want_coalesce() {
  local s=$1
  (( _fe_may_coalesce )) || return 1
  (( ${#s} == 1 )) || return 1
  [[ $s == ' ' ]] && (( ! _fe_try_coalesce )) && return 1
  local -i n=${#_fe_start}
  (( _fe_start[n] == _fe_end[n] )) || return 1
  _fe_cursor_after $_fe_cpos[n] $_fe_start[n] $_fe_end[n] ${#_fe_rep[n]}
  (( REPLY == CURSOR )) || return 1
  return 0
}

# fishy-edit-line-push START END REPLACEMENT ALLOW_COALESCE
# The raw EditableLine::push_edit (callers use fishy-push-edit, which also
# handles the autosuggestion).
_fe_push() {
  local -i start=$1 end=$2 coalesce=$4
  local rep=$3
  local -i is_insertion=$(( start == end ))
  if (( coalesce && is_insertion )) && _fe_want_coalesce "$rep"; then
    local -i n=${#_fe_start}
    _fe_rep[n]+=$rep
    _fe_apply $start $end "$rep"
    CURSOR=$(( CURSOR + ${#rep} ))
    return 0
  fi
  (( is_insertion )) && [[ -z $rep ]] && return 0  # nop
  local group=''
  (( _fe_group_level > 0 )) && group=$_fe_group_id
  if (( _fe_applied != ${#_fe_start} )); then
    local -i keep=$_fe_applied
    _fe_start=("${(@)_fe_start[1,keep]}") _fe_end=("${(@)_fe_end[1,keep]}")
    _fe_old=("${(@)_fe_old[1,keep]}") _fe_rep=("${(@)_fe_rep[1,keep]}")
    _fe_cpos=("${(@)_fe_cpos[1,keep]}") _fe_cpos_undo=("${(@)_fe_cpos_undo[1,keep]}")
    _fe_group=("${(@)_fe_group[1,keep]}")
  fi
  local -i cpos=$CURSOR
  if (( _fe_pending_pos >= 0 )); then cpos=$_fe_pending_pos; _fe_pending_pos=-1; fi
  local old=${BUFFER[start+1,end]}
  _fe_apply $start $end "$rep"
  _fe_cursor_after $cpos $start $end ${#rep}
  CURSOR=$REPLY
  _fe_may_coalesce=$(( is_insertion && (_fe_try_coalesce || ${#rep} == 1) ))
  _fe_start+=($start) _fe_end+=($end) _fe_old+=("$old") _fe_rep+=("$rep")
  _fe_cpos+=($cpos) _fe_cpos_undo+=('') _fe_group+=("$group")
  (( _fe_applied++ ))
  return 0
}

fishy-editline-begin-group() {
  (( _fe_group_level > 0 )) && return 0
  _fe_group_level=1 _fe_may_coalesce=0 _fe_try_coalesce=1
  (( _fe_group_id++ ))
}

fishy-editline-end-group() {
  (( _fe_group_level > 0 )) || return 0
  (( --_fe_group_level > 0 )) && return 0
  _fe_try_coalesce=0 _fe_may_coalesce=0
}

# Returns 0 if something was undone.
_fe_undo() {
  local -i did=0 end=$_fe_applied pos_before=$CURSOR
  local last_group='' first=1
  while (( _fe_applied > 0 )); do
    local -i i=$_fe_applied
    if (( did )) && { [[ -z $_fe_group[i] ]] || [[ $_fe_group[i] != "$last_group" ]] }; then
      break
    fi
    last_group=$_fe_group[i]
    (( _fe_applied-- ))
    _fe_apply $_fe_start[i] $(( _fe_start[i] + ${#_fe_rep[i]} )) "$_fe_old[i]"
    CURSOR=$_fe_cpos[i]
    did=1
  done
  (( did )) && _fe_cpos_undo[end]=$pos_before
  fishy-editline-end-group
  _fe_may_coalesce=0
  (( did ))
}

_fe_redo() {
  local -i did=0
  local last_group=''
  while (( _fe_applied < ${#_fe_start} )); do
    local -i i=$(( _fe_applied + 1 ))
    if (( did )) && { [[ -z $_fe_group[i] ]] || [[ $_fe_group[i] != "$last_group" ]] }; then
      break
    fi
    last_group=$_fe_group[i]
    (( _fe_applied++ ))
    _fe_apply $_fe_start[i] $_fe_end[i] "$_fe_rep[i]"
    [[ -n $_fe_cpos_undo[i] ]] && CURSOR=$_fe_cpos_undo[i]
    did=1
  done
  fishy-editline-end-group
  (( did ))
}

# fish: range_of_line_at_cursor -> REPLY_START REPLY_END
fishy-line-range() {
  local buf=$1
  local -i cursor=$2 start=0 end
  local before=${buf[1,cursor]} after=${buf[cursor+1,-1]}
  if [[ $before == *$'\n'* ]]; then
    local tail=${before##*$'\n'}
    start=$(( cursor - ${#tail} ))
  fi
  if [[ $after == *$'\n'* ]]; then
    local head=${after%%$'\n'*}
    end=$(( cursor + ${#head} ))
  else
    end=${#buf}
  fi
  if (( end != start )) && [[ ${buf[end]} == $'\n' ]]; then
    (( end-- ))
  fi
  REPLY_START=$start REPLY_END=$end
}
