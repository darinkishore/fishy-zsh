# fishy suggest: fish's autosuggestion state machine (src/reader/reader.rs:
# Autosuggestion, try_apply_edit_to_autosuggestion, push_edit_internal,
# update_autosuggestion, autosuggest_completed, accept_autosuggestion).
#
# The suggestion itself is computed by fish's own performer in the async
# server (history search with path validation, then completion fallback).

zmodload zsh/zselect 2>/dev/null

# Current autosuggestion (empty _fs_text = none).
typeset -g _fs_text=''
typeset -gi _fs_start=0 _fs_end=0 _fs_icase=-1 _fs_whole=0
# Saved autosuggestion (RemoveAndSave / Restore).
typeset -gi _fs_has_saved=0
typeset -g _fs_saved_text=''
typeset -gi _fs_saved_start=0 _fs_saved_end=0 _fs_saved_icase=-1 _fs_saved_whole=0
typeset -gi _fs_suppress=0
typeset -g _fs_inflight='' _fs_req_id=''
typeset -gi _fs_handler_fd=-1

fishy-suggest-clear() { _fs_text='' _fs_start=0 _fs_end=0 _fs_icase=-1 _fs_whole=0 }

fishy-suggest-reset() {
  fishy-suggest-clear
  _fs_has_saved=0 _fs_suppress=0 _fs_inflight='' _fs_req_id=''
}

# Is $1 a prefix of $2, case-sensitively or (icase) case-insensitively?
_fs_prefixes() {
  local icase=$1 a=$2 b=$3
  if (( icase )); then
    [[ ${(L)b} == "${(L)a}"* ]]
  else
    [[ $b == "$a"* ]]
  fi
}

# fish: try_apply_edit_to_autosuggestion. Uses BUFFER *before* the edit.
_fs_try_apply_edit() {
  local -i start=$1 end=$2
  local rep=$3
  [[ -n $_fs_text ]] || return 1
  local -i ss=$_fs_start se=$_fs_end delta=0 unchanged
  (( start < ss || end != se )) && return 1
  local rest
  if (( _fs_icase < 0 )); then
    unchanged=$(( (se - ss) - (end - start) ))
    (( unchanged < 0 )) && return 1
    rest=${_fs_text[unchanged+1,-1]}
    # is_prefix(...) must be a *strict* prefix (IsPrefix::Prefix).
    [[ $rest == "$rep"?* ]] || return 1
  else
    local removed=${BUFFER[start+1,end]}
    local -i unmatched=${#${(L)removed}}
    delta=$(( -unmatched ))
    unchanged=$(( _fs_icase - unmatched ))
    (( unchanged < 0 )) && return 1
    delta+=${#${(L)rep}}
    rest=${${(L)_fs_text}[unchanged+1,-1]}
    [[ $rest == "${(L)rep}"?* ]] || return 1
  fi
  _fs_end=$(( se - ( (end - start) < se ? (end - start) : se ) + ${#rep} ))
  (( _fs_icase >= 0 )) && _fs_icase=$(( _fs_icase + delta ))
  return 0
}

# fish: push_edit_internal + command_line_changed for the command line.
# fishy-push-edit START END REPLACEMENT [COALESCE]
fishy-push-edit() {
  local -i start=$1 end=$2 coalesce=${4:-0}
  local rep=$3
  local update=remove
  if _fs_try_apply_edit $start $end "$rep"; then
    update=preserve
  elif [[ -n $_fs_text ]] && (( start == _fs_end && start == end )) && [[ -n $rep ]]; then
    update=save
  elif (( _fs_has_saved && FISHY_AUTOSUGGEST )) && fishy-hsearch-at-present \
      && [[ -z $rep ]] && (( start == _fs_saved_end && start != end )); then
    update=restore
  fi
  _fe_push $start $end "$rep" $coalesce
  _fishy_command_line_changed $update
}

# fish: command_line_changed (command line part).
_fishy_command_line_changed() {
  local had_saved=$_fs_has_saved
  _fs_has_saved=0
  case $1 in
    preserve) ;;
    remove) fishy-suggest-clear ;;
    save)
      _fs_saved_text=$_fs_text _fs_saved_start=$_fs_start _fs_saved_end=$_fs_end
      _fs_saved_icase=$_fs_icase _fs_saved_whole=$_fs_whole _fs_has_saved=1
      fishy-suggest-clear
      ;;
    restore)
      if (( had_saved )); then
        _fs_text=$_fs_saved_text _fs_start=$_fs_saved_start _fs_end=$_fs_saved_end
        _fs_icase=$_fs_saved_icase _fs_whole=$_fs_saved_whole
      fi
      _fs_suppress=0
      ;;
  esac
}

# fish: Reader::can_autosuggest
_fishy_can_autosuggest() {
  (( FISHY_AUTOSUGGEST && ! _fs_suppress )) || return 1
  fishy-hsearch-at-present || return 1
  (( ! _fp_search_focused )) || return 1
  [[ $BUFFER == *[^$' \t\r\n\v']* ]]
}

# fish: is_at_line_with_autosuggestion
fishy-suggest-at-line() {
  [[ -n $_fs_text ]] || return 1
  (( ! _fp_search_focused )) || return 1
  fishy-line-range "$BUFFER" $CURSOR
  (( REPLY_START == _fs_start && REPLY_END == _fs_end )) && return 0
  (( _fs_start == 0 && CURSOR <= _fs_end ))
}

# fish: is_at_autosuggestion (cursor_end_mode is Exclusive in emacs mode)
fishy-suggest-at-end() {
  [[ -n $_fs_text ]] || return 1
  (( ! _fp_search_focused )) || return 1
  (( CURSOR == _fs_end ))
}

# fish: update_autosuggestion
fishy-suggest-update() {
  fishy-log "suggest-update buf=[$BUFFER] can=$(_fishy_can_autosuggest && echo 1)"
  if ! _fishy_can_autosuggest; then
    _fs_inflight=''
    fishy-suggest-clear
    return
  fi
  fishy-suggest-at-line && return
  [[ $BUFFER == "$_fs_inflight" && -n $_fs_req_id ]] && return
  _fs_inflight=$BUFFER
  fishy-suggest-clear
  fishy-send async suggest $CURSOR "$BUFFER" || { _fs_inflight=''; return }
  _fs_req_id=$REPLY
  _fs_watch
}

# Watch the async server's reply fd with zle -F (once per fd).
_fs_watch() {
  local fd=$_fishy_rfd[async]
  [[ -n $fd ]] || return
  (( fd == _fs_handler_fd )) && return
  (( _fs_handler_fd >= 0 )) && zle -F $_fs_handler_fd 2>/dev/null
  zle -F -w $fd fishy-suggest-ready
  _fs_handler_fd=$fd
}

# zle -F handler: consume every complete reply that is available.
_fishy_w_suggest_ready() {
  local fd=$_fishy_rfd[async] rec
  [[ -n $fd ]] || return
  while :; do
    local -a records=()
    local id=''
    while IFS= read -r -d $'\0' -u $fd rec; do
      if [[ $rec == $'\x1e'* ]]; then id=${rec#$'\x1e'}; break; fi
      records+=("$rec")
    done
    if [[ -z $id ]]; then
      # EOF: server died. Forget the watch; next request restarts it.
      zle -F $fd 2>/dev/null; _fs_handler_fd=-1; _fishy_stop async
      _fs_inflight='' _fs_req_id=''
      return
    fi
    [[ $id == "$_fs_req_id" ]] && _fs_completed "${records[@]}"
    zselect -t 0 -r $fd 2>/dev/null || break
  done
  fishy-render
  zle -R
}

# fish: autosuggest_completed
_fs_completed() {
  fishy-log "suggest-reply id=$_fs_req_id: ${1//$'\x1f'/|}"
  local rec=$1
  local -a f=("${(@ps:\x1f:)rec}")
  [[ $f[1] == S ]] || return
  local cmdline=$_fs_inflight
  [[ $_fs_inflight == "$BUFFER" ]] && _fs_inflight=''
  _fs_req_id=''
  [[ $cmdline == "$BUFFER" ]] || return     # stale
  local text=$f[2]
  local -i start=$f[3] end=$f[4] icase=$f[5] whole=$f[6]
  [[ -n $text ]] || return
  _fishy_can_autosuggest || return
  _fs_prefixes $(( icase >= 0 )) "${BUFFER[start+1,end]}" "$text" || return
  _fs_text=$text _fs_start=$start _fs_end=$end _fs_icase=$icase _fs_whole=$whole
  fishy-log "suggest-set [$_fs_text] $_fs_start-$_fs_end"
}

# fish: accept_autosuggestion. Kind: all | line | word STYLE TO_END | count N
fishy-suggest-accept() {
  fishy-suggest-at-line || return 1
  fishy-pager-clear
  local kind=$1
  local -i ss=$_fs_start se=$_fs_end
  local text=$_fs_text
  case $kind in
    all)
      fishy-push-edit $ss $se "$text"
      ;;
    count)
      local -i n=$2 avail=$(( ${#text} - (se - ss) ))
      (( n > avail )) && n=avail
      (( n == 0 )) && return 0
      local -i from=$(( ${#text} - avail ))
      fishy-push-edit $se $se "${text[from+1,from+n]}"
      ;;
    line)
      local suggested=${text[se-ss+1,-1]}
      local piece=${suggested%%$'\n'*}
      [[ -n $piece ]] || return 0
      fishy-push-edit $se $se "$piece"
      ;;
    word)
      local -i have=$(( se - ss ))
      fishy-call sync accept-word $2 $3 $have "$text" || return 1
      local -a f=("${(@ps:\x1f:)fishy_reply[1]}")
      local -i want=$f[2]
      fishy-push-edit $se $se "${text[have+1,want]}"
      ;;
  esac
  return 0
}

# What zle should draw after the buffer: the not-yet-typed suggestion part.
# fish: paint_layout / combine_command_and_autosuggestion (see AGENTS.md for
# the icase display-case limitation).
fishy-suggest-display() {
  REPLY=''
  fishy-suggest-at-line || return
  local -i ss=$_fs_start se=$_fs_end
  # fish inserts the suggestion at the end of the searched line. zsh can only
  # draw after the whole buffer, which is the same place unless a later line
  # follows (multi-line buffer with the suggestion on an earlier line).
  (( ${#BUFFER} == se )) || return
  REPLY=${_fs_text[se-ss+1,-1]}
}
