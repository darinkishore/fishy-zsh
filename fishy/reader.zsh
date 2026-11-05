# fishy reader: fish's readline dispatch and commands (src/reader/reader.rs
# handle_char_event / handle_readline_command) on top of zle.
#
# Every key is bound to a widget that calls `_fishy_run <fish readline command>`
# (or `_fishy_insert <text>` for self-inserting keys). Rendering happens in
# zle-line-pre-redraw (fishy-render).

zmodload zsh/zselect 2>/dev/null

typeset -g  _fishy_last_cmd='' _fishy_current_cmd=''
typeset -ga _fishy_kill_ring
typeset -g  _fishy_kill_item=''
typeset -gi _fishy_yank_len=0
typeset -gi FISHY_AUTOSUGGEST=1

# History search state, mirrored from the server's ReaderHistorySearch.
typeset -gi _fh_active=0 _fh_at_present=1 _fh_match_start=-1 _fh_match_len=0
typeset -gi _fh_res_start=0 _fh_res_end=0
typeset -g  _fh_mode='' _fh_result='' _fh_search_string=''

# Flash state (fish: Reader::flash).
typeset -gi _fishy_flash_start=-1 _fishy_flash_end=-1 _fishy_flash_suggestion=0

# ---------------------------------------------------------------- line lifecycle

fishy-reader-line-init() {
  fishy-editline-reset
  fishy-highlight-reset
  fishy-suggest-reset
  fishy-pager-clear
  _fishy_last_cmd='' _fishy_completion_action='' _fishy_transient='' _fishy_yank_len=0
  _fh_active=0 _fh_at_present=1 _fh_mode=''
}

# ---------------------------------------------------------------- history search

fishy-hsearch-at-present() { (( ! _fh_active || _fh_at_present )) }

_fh_parse() {
  local -a f=("${(@ps:\x1f:)fishy_reply[1]}")
  [[ $f[1] == H ]] || return 1
  REPLY_FOUND=$f[2]
  _fh_at_present=$f[3] _fh_result=$f[4] _fh_res_start=$f[5] _fh_res_end=$f[6]
  _fh_match_start=$f[7] _fh_match_len=$f[8]
}

fishy-hsearch-reset() {
  (( _fh_active )) || return 0
  _fh_active=0 _fh_at_present=1 _fh_mode='' _fh_match_start=-1 _fh_match_len=0
  fishy-call sync hsearch-end
}

# fish: Reader::update_command_line_from_history_search
_fishy_update_from_hsearch() {
  if [[ $_fishy_transient == history ]]; then
    _fishy_transient=''
    _fishy_undo_internal
  fi
  _fishy_transient=''
  if (( ! _fh_at_present )); then
    if [[ $_fh_mode == (token|last-token) ]]; then
      # fish: replace_current_token
      fishy-call sync token-extent $CURSOR "$BUFFER" || return
      local -a e=("${(@ps:\x1f:)fishy_reply[1]}")
      fishy-push-edit $e[2] $e[3] "$_fh_result"
    else
      fishy-push-edit 0 ${#BUFFER} "$_fh_result"
      if [[ $_fh_mode == prefix && -n $_fh_search_string ]]; then
        CURSOR=${#_fh_search_string}
      fi
    fi
    _fishy_transient=history
  fi
}

# fish: the history-search-* readline commands.
_fishy_history_search() {
  local mode=$1 dir=$2
  local -i was_active=$_fh_active
  if fishy-hsearch-at-present && [[ $mode != "$_fh_mode" ]]; then
    local text offset=0 skip=''
    if [[ $mode == (token|last-token) ]]; then
      fishy-call sync token-extent $CURSOR "$BUFFER" || return
      local -a e=("${(@ps:\x1f:)fishy_reply[1]}")
      text=${BUFFER[e[2]+1,e[3]]} offset=$e[2]
    else
      text=$BUFFER
      # Skip the autosuggestion in the history unless it was truncated.
      if [[ -n $_fs_text && $mode != prefix ]] && (( ! _fishy_suggestion_truncated )); then
        skip=$_fs_text
      fi
    fi
    fishy-call sync hsearch-reset $mode $offset "$text" "$skip" || return
    _fh_parse
    _fh_active=1 _fh_mode=$mode _fh_search_string=$text
  fi
  fishy-call sync hsearch-move $dir || return
  _fh_parse
  if (( ! REPLY_FOUND )); then
    if (( _fh_res_end > _fh_res_start )); then
      fishy-flash $_fh_res_start $_fh_res_end
    else
      fishy-flash 0 ${#BUFFER}
    fi
  fi
  if (( REPLY_FOUND )); then
    _fishy_update_from_hsearch
  elif (( ! was_active )); then
    fishy-hsearch-reset
  fi
}

# ---------------------------------------------------------------- helpers

_fishy_undo_internal() {
  _fe_undo && _fishy_command_line_changed remove
}

# fish: ReaderData::clear_transient_edit
_fishy_clear_transient() {
  [[ -n $_fishy_transient ]] || return 0
  _fishy_undo_internal
  _fishy_transient=''
}

# fish: Reader::flash. Paint [start,end) in search_match for 100ms.
fishy-flash() {
  local -i start=$1 end=$2
  (( start == end && ! _fishy_flash_suggestion )) && return
  _fishy_flash_start=$start _fishy_flash_end=$end
  fishy-render
  zle -R
  zselect -t 10 2>/dev/null
  _fishy_flash_start=-1 _fishy_flash_end=-1 _fishy_flash_suggestion=0
  fishy-render
  zle -R
}

# fish: ReaderData::kill (with the global kill ring).
_fishy_kill() {
  local -i start=$1 end=$2 newv=$4
  local mode=$3 piece=${BUFFER[start+1,end]}
  if (( newv )); then
    _fishy_kill_item=$piece
    [[ -n $piece ]] && _fishy_kill_ring=("$piece" "$_fishy_kill_ring[@]")
  else
    local old=$_fishy_kill_item
    if [[ $mode == append ]]; then _fishy_kill_item+=$piece; else _fishy_kill_item=$piece$old; fi
    local -i idx=${_fishy_kill_ring[(ie)$old]}
    (( idx <= ${#_fishy_kill_ring} )) && _fishy_kill_ring[idx]=()
    [[ -n $_fishy_kill_item ]] && _fishy_kill_ring=("$_fishy_kill_item" "$_fishy_kill_ring[@]")
  fi
  fishy-push-edit $start $end ''
}

# fish: delete_char(backward). Handles zero-width combining characters.
_fishy_delete_char() {
  local -i backward=$1 pos=$CURSOR
  (( backward )) || (( pos++ ))
  local -i pos_end=$pos
  (( CURSOR == 0 && backward )) && return
  while :; do
    (( pos-- ))
    local c=${BUFFER[pos+1]}
    (( ${(m)#c} != 0 || pos == 0 )) && break
  done
  _fs_suppress=1
  fishy-push-edit $pos $pos_end ''
}

# fish: move_word via the server's word motion. Sets REPLY to the new position.
_fishy_word_pos() {
  local dir=$1 style=$2
  local -i to_end=$3
  fishy-call sync word $dir $style $to_end $CURSOR "$BUFFER" || return 1
  REPLY=${fishy_reply[1]#P$'\x1f'}
}

# fish: Reader::move_word(elt, dir, erase, style, newv, to_word_end)
_fishy_move_word() {
  local dir=$1 style=$4
  local -i erase=$2 newv=$3 to_end=$5 start=$CURSOR
  _fishy_word_pos $dir $style $to_end || return
  local -i pos=$REPLY
  if (( erase )); then
    _fs_suppress=1
    if [[ $dir == r ]]; then
      _fishy_kill $start $(( pos + to_end )) append $newv
    else
      _fishy_kill $pos $(( start + to_end )) prepend $newv
    fi
  else
    CURSOR=$pos
  fi
}

# fish: WordCharClass::from_char / bigword_class, for is_at_word_end.
_fishy_word_class() {
  local style=$1 c=$2
  case $c in
    ''|[$' \t']) REPLY=blank; return ;;
    $'\n') REPLY=newline; return ;;
  esac
  if [[ $style == w ]]; then REPLY=word; return; fi
  [[ $c == [[:alnum:]] ]] && { REPLY=word; return }
  REPLY=punct
}

# ---------------------------------------------------------------- dispatch tables

# fish: command_ends_paging
_fishy_ends_paging() {
  local cmd=$1
  local -i focused=$2
  case $cmd in
    history-*-search-*|history-search-*|accept-autosuggestion|delete-or-exit|cancel-commandline|clear-commandline|cancel)
      return 0 ;;
    complete|complete-and-search|history-pager|backward-char|backward-char-passive|forward-char|forward-char-passive|forward-single-char|up-line|down-line|repaint|suppress-autosuggestion|beginning-of-history|end-of-history|execute)
      return 1 ;;
    beginning-of-line|end-of-line|forward-*word*|kill-*word*|backward-*word*|forward-token|backward-token|nextd-or-forward-word|prevd-or-backward-word|delete-char|backward-delete-char|kill-line|yank|yank-pop|backward-kill-line|kill-whole-line|kill-inner-line|kill-token|backward-kill-path-component|backward-kill-token|self-insert|transpose-chars|transpose-words|upcase-word|downcase-word|capitalize-word|beginning-of-buffer|end-of-buffer|undo|redo)
      (( ! focused )) ;;
    *) return 1 ;;
  esac
}

# fish: command_ends_history_search
_fishy_ends_hsearch() {
  case $1 in
    history-search-*|history-prefix-search-*|history-token-search-*|history-last-token-search-*|history-delete|history-pager-delete|beginning-of-history|end-of-history|repaint|force-repaint|clear-screen)
      return 1 ;;
  esac
  return 0
}

# fish: command_only_affects_rendering (for last_cmd bookkeeping)
_fishy_only_rendering() {
  [[ $1 == (repaint|force-repaint|repaint-mode|clear-screen) ]]
}

# fish: handle_char_event for a Readline event.
_fishy_run() {
  fishy-unswap
  local cmd=$1
  [[ $_fishy_last_cmd == (yank|yank-pop) ]] || _fishy_yank_len=0
  if [[ $cmd == cancel ]] && fishy-pager-navigating; then
    _fishy_clear_transient
  fi
  local -i focused=$(( _fp_search_shown && _fp_selected >= 0 ))
  if (( ! _fh_active )) && _fishy_ends_paging $cmd $focused; then
    fishy-pager-clear
  fi
  _fishy_current_cmd=$cmd
  "_fishy_cmd_$cmd"
  if (( _fh_active )) && _fishy_ends_hsearch $cmd; then
    [[ $cmd == cancel ]] && _fishy_clear_transient
    fishy-hsearch-reset
    _fishy_transient=''
  fi
  _fishy_only_rendering $cmd || _fishy_last_cmd=$cmd
  fishy-suggest-update
  fishy-highlight-update
}

# fish: read_normal_chars' accumulated insertion (note: unlike the Key event
# path it does not reset the history search). $2=1: the event that ended the
# batch follows in the same loop iteration, so no highlight/suggest update yet.
_fishy_insert_batch() {
  fishy-unswap
  local text=$1
  local -i deferred=${2:-0}
  [[ $_fishy_last_cmd == (yank|yank-pop) ]] || _fishy_yank_len=0
  if fishy-search-focused; then
    _fp_search_text+=$text
    fishy-pager-refilter
    fishy-pager-selection-changed
  else
    fishy-push-edit $CURSOR $CURSOR "$text" $(( ! _fh_active ))
    _fishy_transient='' _fs_suppress=0
    fishy-pager-clear
  fi
  _fishy_last_cmd=''
  (( deferred )) && return
  fishy-suggest-update
  fishy-highlight-update
}

# fish: handle_char_event for a Key event (self-insert). $1 = text to insert.
_fishy_insert() {
  fishy-unswap
  local text=$1
  [[ $_fishy_last_cmd == (yank|yank-pop) ]] || _fishy_yank_len=0
  if (( _fp_search_shown && _fp_selected >= 0 )); then
    # Focus is on the pager search field.
    _fp_search_text+=$text
    fishy-pager-refilter
    fishy-pager-selection-changed
  else
    fishy-push-edit $CURSOR $CURSOR "$text" $(( ! _fh_active ))
    _fishy_transient='' _fs_suppress=0
    fishy-pager-clear
    fishy-hsearch-reset
  fi
  _fishy_last_cmd=''
  fishy-suggest-update
  fishy-highlight-update
}

# ---------------------------------------------------------------- commands

_fishy_cmd_beginning-of-line() {
  local -i pos=$CURSOR
  while (( pos > 0 )) && [[ ${BUFFER[pos]} != $'\n' ]]; do (( pos-- )); done
  CURSOR=$pos
}

_fishy_cmd_end-of-line() {
  if fishy-suggest-at-end; then
    fishy-suggest-accept line
  else
    local -i pos=$CURSOR
    while (( pos < ${#BUFFER} )) && [[ ${BUFFER[pos+1]} != $'\n' ]]; do (( pos++ )); done
    CURSOR=$pos
  fi
}

_fishy_cmd_beginning-of-buffer() { CURSOR=0 }

_fishy_cmd_end-of-buffer() {
  if fishy-suggest-at-end; then fishy-suggest-accept all; else CURSOR=${#BUFFER}; fi
}

_fishy_cmd_clear-commandline() {
  [[ -z $BUFFER ]] && return
  fishy-push-edit 0 ${#BUFFER} ''
}

_fishy_cmd_cancel-commandline() {
  [[ -z $BUFFER ]] && return
  CURSOR=${#BUFFER}
  fishy-suggest-clear
  fishy-render
  # fish prints ^C in fish_color_cancel and starts a fresh line.
  zle -I
  print -rn -- "${_fishy_face[cancel]:+}"'^C'
  fishy-push-edit 0 ${#BUFFER} ''
}

_fishy_cmd_cancel() {
  if [[ $_fishy_completion_action == unique && $_fishy_last_cmd == (complete|complete-and-search) ]]; then
    _fishy_undo_internal
  fi
}

_fishy_cmd_complete() { _fishy_complete_cmd complete }
_fishy_cmd_complete-and-search() { _fishy_complete_cmd complete-and-search }
_fishy_complete_cmd() {
  local c=$1
  if fishy-pager-navigating || [[ $_fishy_completion_action == ambiguous && $_fishy_last_cmd == complete ]]; then
    _fishy_render_pager
    if (( _fpr_remaining != 0 )); then
      _fp_fully_disclosed=1
    else
      if [[ $c == complete ]]; then fishy-select-completion next; else fishy-select-completion prev; fi
    fi
  else
    fishy-compute-and-apply-completions $c
  fi
}

_fishy_cmd_pager-toggle-search() {
  fishy-pager-is-empty && return
  _fp_search_shown=$(( ! _fp_search_shown ))
  _fp_fully_disclosed=1
  if (( _fp_search_shown )) && ! fishy-pager-navigating; then
    fishy-select-completion south
  fi
}

_fishy_cmd_backward-delete-char() {
  if (( _fp_search_shown && _fp_selected >= 0 )); then
    _fp_search_text=${_fp_search_text[1,-2]}
    fishy-pager-refilter
    fishy-pager-selection-changed
    return
  fi
  _fishy_delete_char 1
}

_fishy_cmd_delete-char() {
  (( CURSOR < ${#BUFFER} )) && _fishy_delete_char 0
}

_fishy_cmd_delete-or-exit() {
  if (( CURSOR < ${#BUFFER} )); then
    _fishy_delete_char 0
  elif [[ -z $BUFFER ]]; then
    exit
  fi
}

_fishy_cmd_backward-char() {
  if fishy-pager-navigating; then
    fishy-select-completion west
  elif (( CURSOR != 0 )); then
    (( CURSOR-- ))
  fi
}

_fishy_cmd_forward-char() {
  if fishy-pager-navigating; then
    fishy-select-completion east
  elif fishy-suggest-at-end; then
    fishy-suggest-accept all
  elif (( CURSOR < ${#BUFFER} )); then
    (( CURSOR++ ))
  fi
}

_fishy_cmd_forward-single-char() {
  if fishy-pager-navigating; then
    fishy-select-completion east
  elif fishy-suggest-at-end; then
    fishy-suggest-accept count 1
  elif (( CURSOR < ${#BUFFER} )); then
    (( CURSOR++ ))
  fi
}

# fish: up-line / down-line
_fishy_cmd_up-line() { _fishy_updown up }
_fishy_cmd_down-line() { _fishy_updown down }
_fishy_updown() {
  local d=$1
  if fishy-pager-navigating; then
    local dir
    if [[ $d == down ]]; then dir=south
    else
      _fishy_render_pager
      local -i rows=$_fpr_rows row=-1 col=-1
      (( rows )) && row=$(( _fpr_selected % rows )) col=$(( _fpr_selected / rows ))
      if (( row <= 0 && col <= 0 )); then dir=deselect; else dir=north; fi
    fi
    fishy-select-completion $dir
  elif ! fishy-pager-is-empty; then
    if [[ $d == down ]]; then fishy-select-completion south; else fishy-select-completion north; fi
  else
    # Move between lines of a multi-line buffer. fish adjusts the column for
    # its continuation-line indent; zsh draws no indent, so columns map 1:1.
    local -a all=("${(@ps:\n:)BUFFER}")
    local before=${BUFFER[1,CURSOR]}
    local nl=${before//[^$'\n']/}
    local -i line_old=$(( ${#nl} + 1 )) line_new
    if [[ $d == up ]]; then line_new=$(( line_old - 1 )); else line_new=$(( line_old + 1 )); fi
    (( line_new >= 1 && line_new <= ${#all} )) || return
    local -i col=${#${before##*$'\n'}} base=0 i
    for (( i = 1; i < line_new; i++ )); do (( base += ${#all[i]} + 1 )); done
    (( col > ${#all[line_new]} )) && col=${#all[line_new]}
    CURSOR=$(( base + col ))
  fi
}

# fish: up-or-search / down-or-search (share/functions/*.fish)
_fishy_cmd_up-or-search() {
  if (( _fh_active )); then _fishy_run_inner history-search-backward; return; fi
  if ! fishy-pager-is-empty; then _fishy_run_inner up-line; return; fi
  local before=${BUFFER[1,CURSOR]}
  if [[ $before != *$'\n'* ]]; then _fishy_run_inner history-search-backward
  else _fishy_run_inner up-line; fi
}
_fishy_cmd_down-or-search() {
  if (( _fh_active )); then _fishy_run_inner history-search-forward; return; fi
  if ! fishy-pager-is-empty; then _fishy_run_inner down-line; return; fi
  local after=${BUFFER[CURSOR+1,-1]}
  if [[ $after != *$'\n'* ]]; then _fishy_run_inner history-search-forward
  else _fishy_run_inner down-line; fi
}
# `commandline -f X` from a fish function: a nested readline command.
_fishy_run_inner() { _fishy_run "$1" }

_fishy_cmd_history-search-backward() { _fishy_history_search line b }
_fishy_cmd_history-search-forward() { _fishy_history_search line f }
_fishy_cmd_history-prefix-search-backward() { _fishy_history_search prefix b }
_fishy_cmd_history-prefix-search-forward() { _fishy_history_search prefix f }
_fishy_cmd_history-token-search-backward() { _fishy_history_search token b }
_fishy_cmd_history-token-search-forward() { _fishy_history_search token f }
_fishy_cmd_history-last-token-search-backward() { _fishy_history_search last-token b }
_fishy_cmd_history-last-token-search-forward() { _fishy_history_search last-token f }

_fishy_cmd_beginning-of-history() { _fishy_history_ends up }
_fishy_cmd_end-of-history() { _fishy_history_ends down }
_fishy_history_ends() {
  if fishy-pager-navigating; then
    [[ $1 == up ]] && fishy-select-completion page-north || fishy-select-completion page-south
  elif (( _fh_active )); then
    if [[ $1 == up ]]; then fishy-call sync hsearch-move oldest; else fishy-call sync hsearch-move present; fi
    _fh_parse && _fishy_update_from_hsearch
  fi
}

# Word motions (fish 4.9 emacs bindings).
_fishy_cmd_prevd-or-backward-word() {
  if [[ -z $BUFFER ]]; then _fishy_dirhist prev; return; fi
  _fishy_move_word l 0 0 p 0
}
_fishy_cmd_backward-word() { _fishy_move_word l 0 0 p 0 }
_fishy_cmd_backward-bigword() { _fishy_move_word l 0 0 w 0 }
_fishy_cmd_nextd-or-forward-word() {
  if [[ -z $BUFFER ]]; then _fishy_dirhist next; return; fi
  _fishy_forward_word_emacs p 0
}
_fishy_cmd_forward-word() { _fishy_forward_word_emacs p 0 }
_fishy_cmd_forward-bigword() { _fishy_forward_word_emacs w 0 }
_fishy_cmd_kill-word() { _fishy_forward_word_emacs p 1 }
_fishy_cmd_kill-bigword() { _fishy_forward_word_emacs w 1 }

# fish: ForwardWordEmacs | ForwardBigwordEmacs | KillWordEmacs | KillBigwordEmacs
_fishy_forward_word_emacs() {
  local style=$1
  local -i is_kill=$2 at_word_end=0
  if (( CURSOR + 1 < ${#BUFFER} )); then
    _fishy_word_class $style "${BUFFER[CURSOR+1]}"; local cur=$REPLY
    _fishy_word_class $style "${BUFFER[CURSOR+2]}"; local nxt=$REPLY
    [[ $cur != (blank|newline) && $nxt != $cur ]] && at_word_end=1
  fi
  if fishy-suggest-at-end; then
    fishy-suggest-accept word $style 1
  elif (( at_word_end )); then
    if (( is_kill )); then _fishy_delete_char 0; else (( CURSOR++ )); fi
  else
    local -i newv=1
    [[ $_fishy_last_cmd == $_fishy_current_cmd ]] && newv=0
    _fishy_move_word r $is_kill $newv $style 1
    if (( ! is_kill )) && (( CURSOR < ${#BUFFER} )); then (( CURSOR++ )); fi
  fi
}

_fishy_cmd_backward-kill-word() {
  local -i newv=1
  [[ $_fishy_last_cmd == (backward-kill-word|backward-kill-bigword) ]] && newv=0
  _fishy_move_word l 1 $newv p 0
}
_fishy_cmd_backward-kill-bigword() {
  local -i newv=1
  [[ $_fishy_last_cmd == (backward-kill-word|backward-kill-bigword) ]] && newv=0
  _fishy_move_word l 1 $newv w 0
}
_fishy_cmd_backward-kill-path-component() {
  local -i newv=1
  [[ $_fishy_last_cmd == (backward-kill-word|backward-kill-bigword) ]] && newv=0
  _fishy_move_word l 1 $newv c 0
}

_fishy_cmd_backward-token() {
  fishy-call sync backward-token $CURSOR "$BUFFER" || return
  [[ ${fishy_reply[1]} == P* ]] && CURSOR=${fishy_reply[1]#P$'\x1f'}
}
_fishy_cmd_forward-token() {
  if fishy-suggest-at-end; then
    # fish: forward_token(autosuggest=true) on the combined line.
    local combined=$BUFFER${_fs_text[_fs_end-_fs_start+1,-1]}
    fishy-call sync forward-token $CURSOR "$combined" || return
    [[ ${fishy_reply[1]} == P* ]] || return
    local -i np=${fishy_reply[1]#P$'\x1f'}
    fishy-line-range "$BUFFER" $CURSOR
    fishy-suggest-accept count $(( np - REPLY_END ))
  elif (( CURSOR < ${#BUFFER} )); then
    fishy-call sync forward-token $CURSOR "$BUFFER" || return
    [[ ${fishy_reply[1]} == P* ]] && CURSOR=${fishy_reply[1]#P$'\x1f'}
  fi
}
_fishy_cmd_backward-kill-token() {
  fishy-call sync backward-token $CURSOR "$BUFFER" || return
  [[ ${fishy_reply[1]} == P* ]] || return
  local -i np=${fishy_reply[1]#P$'\x1f'} newv=1
  _fs_suppress=1
  [[ $_fishy_last_cmd == backward-kill-token ]] && newv=0
  _fishy_kill $np $CURSOR prepend $newv
}
_fishy_cmd_kill-token() {
  fishy-call sync forward-token $CURSOR "$BUFFER" || return
  [[ ${fishy_reply[1]} == P* ]] || return
  local -i np=${fishy_reply[1]#P$'\x1f'} newv=1
  _fs_suppress=1
  [[ $_fishy_last_cmd == kill-token ]] && newv=0
  _fishy_kill $CURSOR $np append $newv
}

_fishy_cmd_kill-line() {
  local -i begin=$CURSOR end=$CURSOR newv=1
  while (( end < ${#BUFFER} )) && [[ ${BUFFER[end+1]} != $'\n' ]]; do (( end++ )); done
  (( end == begin && end < ${#BUFFER} )) && (( end++ ))
  [[ $_fishy_last_cmd == kill-line ]] && newv=0
  (( end > begin )) && _fishy_kill $begin $end append $newv
}

_fishy_cmd_backward-kill-line() {
  (( CURSOR == 0 )) && return
  local -i end=$CURSOR begin=$(( CURSOR - 1 )) newv=1
  while (( begin != 0 )) && [[ ${BUFFER[begin+1]} != $'\n' ]]; do (( begin-- )); done
  [[ ${BUFFER[begin+1]} == $'\n' ]] && (( begin++ ))
  local -i len=$(( end - begin > 1 ? end - begin : 1 ))
  _fs_suppress=1
  [[ $_fishy_last_cmd == backward-kill-line ]] && newv=0
  _fishy_kill $(( end - len )) $end prepend $newv
}

_fishy_cmd_yank() {
  local s=$_fishy_kill_ring[1]
  fishy-push-edit $CURSOR $CURSOR "$s"
  _fishy_transient='' _fs_suppress=0
  _fishy_yank_len=${#s}
}

_fishy_cmd_yank-pop() {
  (( _fishy_yank_len != 0 )) || return
  (( ${#_fishy_kill_ring} )) && _fishy_kill_ring=("${(@)_fishy_kill_ring[2,-1]}" "$_fishy_kill_ring[1]")
  local s=$_fishy_kill_ring[1]
  local -i begin=$(( CURSOR - _fishy_yank_len )) end=$CURSOR
  _fs_suppress=1
  fishy-push-edit $begin $end "$s"
  _fishy_yank_len=${#s}
}

_fishy_cmd_transpose-chars() {
  (( ${#BUFFER} < 2 )) && return
  (( CURSOR == ${#BUFFER} )) && (( CURSOR-- ))
  (( CURSOR > 0 )) || return
  local -i p=$CURSOR
  local new=${BUFFER[1,p-1]}${BUFFER[p+1]}${BUFFER[p]}${BUFFER[p+2,-1]}
  fishy-push-edit 0 ${#BUFFER} "$new"
  CURSOR=$(( p + 1 ))
}

_fishy_cmd_transpose-words() {
  local rest=${BUFFER[CURSOR+1,-1]}
  local skip=${rest%%[[:alnum:]]*}
  [[ $rest != *[[:alnum:]]* ]] && skip=$rest
  CURSOR=$(( CURSOR + ${#skip} ))
  fishy-call sync token-extent $CURSOR "$BUFFER" || return
  local -a e=("${(@ps:\x1f:)fishy_reply[1]}")
  local -i ts=$e[2] te=$e[3] ps=$e[4] pe=$e[5]
  if (( ts == ${#BUFFER} )); then
    fishy-call sync token-extent $pe "$BUFFER" || return
    e=("${(@ps:\x1f:)fishy_reply[1]}"); ts=$e[2] te=$e[3] ps=$e[4] pe=$e[5]
  fi
  if (( pe > ps && te > ts && ts > ps )); then
    local new=${BUFFER[1,ps]}${BUFFER[ts+1,te]}${BUFFER[pe+1,ts]}${BUFFER[ps+1,pe]}${BUFFER[te+1,-1]}
    fishy-push-edit 0 ${#BUFFER} "$new"
    CURSOR=$te
  fi
}

_fishy_case_word() {
  local mode=$1
  local -i init=$CURSOR pos=$CURSOR cap=0
  _fishy_move_word r 0 0 p 0
  local repl='' ch
  while (( pos < CURSOR )); do
    ch=${BUFFER[pos+1]}
    local -i up=0
    case $mode in
      capitalize) (( ! cap )) && [[ $ch == [[:alnum:]] ]] && up=1 ;;
      upcase) up=1 ;;
    esac
    if (( up )); then repl+=${(U)ch}; else repl+=${(L)ch}; fi
    (( cap = cap || up ))
    (( pos++ ))
  done
  fishy-push-edit $init $pos "$repl"
}
_fishy_cmd_upcase-word() { _fishy_case_word upcase }
_fishy_cmd_downcase-word() { _fishy_case_word downcase }
_fishy_cmd_capitalize-word() { _fishy_case_word capitalize }

_fishy_cmd_undo() { _fishy_undo_redo undo }
_fishy_cmd_redo() { _fishy_undo_redo redo }
_fishy_undo_redo() {
  local ok=1
  if [[ $1 == undo ]]; then _fe_undo || ok=0; else _fe_redo || ok=0; fi
  if (( ! ok )); then fishy-flash 0 ${#BUFFER}; return; fi
  _fishy_command_line_changed remove
  _fs_suppress=0
  fishy-pager-clear
}

_fishy_cmd_expand-abbr() {
  _fishy_expand_abbr 1
}
# fish: expand_abbreviation_at_cursor(cursor_backtrack)
_fishy_expand_abbr() {
  local -i back=$1 pos=$(( CURSOR - $1 ))
  (( pos < 0 )) && pos=0
  fishy-call sync expand-abbr $pos "$BUFFER" || return 1
  [[ -n ${fishy_reply[1]} ]] || return 1
  local -a r=("${(@ps:\x1f:)fishy_reply[1]}")
  fishy-push-edit $r[2] $r[3] "$r[4]"
  (( r[5] >= 0 )) && CURSOR=$r[5]
  return 0
}

_fishy_cmd_suppress-autosuggestion() {
  _fs_suppress=1
  fishy-suggest-clear
}

_fishy_cmd_accept-autosuggestion() {
  fishy-suggest-at-line && fishy-suggest-accept all
}

_fishy_cmd_clear-screen() {
  zle .clear-screen
}

_fishy_cmd_repaint() { zle .reset-prompt }

# fish: Reader::handle_execute
_fishy_cmd_execute() {
  if fishy-pager-navigating; then
    if ! fishy-pager-selected; then
      fishy-push-edit $CURSOR $CURSOR "$_fp_search_text"
      _fishy_transient='' _fs_suppress=0
    fi
    fishy-pager-clear
    return
  fi
  fishy-pager-clear

  # Backslash-escaped newline continuation.
  local -i cont=0
  if (( CURSOR >= ${#BUFFER} )); then
    _fishy_is_backslashed $CURSOR && cont=1
  else
    if _fishy_is_backslashed $CURSOR && [[ ${BUFFER[CURSOR+1]} == [[:space:]] ]]; then
      cont=1
    elif _fishy_is_backslashed ${#BUFFER}; then
      CURSOR=${#BUFFER}
      cont=1
    fi
  fi
  if (( cont )); then
    fishy-push-edit $CURSOR $CURSOR $'\n' 1
    return
  fi

  # Abbreviation expansion at the cursor, then a zsh syntax check: an
  # incomplete command gets a newline instead of executing (fish semantics,
  # with zsh's grammar deciding what is incomplete).
  _fishy_expand_abbr 0
  _fishy_syntax_status "$BUFFER"
  case $REPLY in
    incomplete) fishy-push-edit $CURSOR $CURSOR $'\n' 1; return ;;
    error)
      # fish: print the error below the line, keep the line for editing.
      zle -I
      print -ru2 -- "$REPLY_ERR"
      return ;;
  esac
  fishy-suggest-clear
  fishy-highlight-finish
  _fishy_accept=1
}

_fishy_is_backslashed() {
  local -i pos=$1 count=0
  while (( pos > 0 )) && [[ ${BUFFER[pos]} == \\ ]]; do (( count++, pos-- )); done
  (( count % 2 == 1 ))
}

# REPLY = ok | incomplete | error, judged by zsh's own parser; REPLY_ERR holds
# zsh's message for errors. Parse-only: nothing is ever executed.
#  1. Fast path, no fork: let zsh parse the text as a function body.
#  2. Otherwise classify with `zsh -fn` (noexec): an unterminated quote, ${,
#     $( / $(( / ` / <( / >( / =(, or a parser that ran out of input at
#     end-of-line is incomplete; anything else is an error.
#  3. Lines ending in && || | |& are accepted by non-interactive parsing at
#     EOF but continue in interactive zsh, so they are incomplete too.
_fishy_syntax_status() {
  local code=$1 err
  REPLY_ERR=''
  err=$( { functions[__fishy_syntax_probe]=$code } 2>&1 )
  if [[ -z $err ]]; then
    local -a toks=(${(z)code})
    if [[ ${toks[-1]} == ('&&'|'||'|'|'|'|&') ]]; then REPLY=incomplete; else REPLY=ok; fi
    return
  fi
  err=$(print -r -- "$code" | command zsh -fn 2>&1)
  if [[ -z $err ]]; then REPLY=ok; return; fi
  if [[ $err == *'unmatched '* || $err == *'closing brace expected'* \
     || $err == *'parse error near `\n'"'"* \
     || $err == *'parse error near `'('$('|'`'|'<('|'>('|'=(')* ]]; then
    REPLY=incomplete
  else
    REPLY=error REPLY_ERR=$err
  fi
}

# Directory history (prevd/nextd) on alt-left/right with an empty line.
_fishy_dirhist() {
  # Implemented in dirhist.zsh (fish's dirprev/dirnext semantics).
  (( $+functions[fishy-dirhist] )) && fishy-dirhist $1
}

# ---------------------------------------------------------------- rendering

typeset -gi _fishy_suggestion_truncated=0
typeset -gi _fishy_accept=0

# Number of screen lines used by prompt + command line (+ suggestion).
_fishy_screen_lines() {
  local text=$1
  local -i cols=${COLUMNS:-80} lines=1 col=0 w
  # The prompt as fish laid it out (prompt.zsh).
  (( lines = _fp_lines > 0 ? _fp_lines : 1 ))
  _fishy_prompt_width; col=$REPLY
  # A prompt that fills its line puts the command line on the next one.
  (( _fp_lastw >= cols && cols > 0 )) && (( lines++ ))
  (( cols > 0 )) || cols=80
  while (( col > cols )); do (( col -= cols, lines++ )); done
  local c
  for c in "${(@s::)text}"; do
    if [[ $c == $'\n' ]]; then (( lines++ )); col=0; continue; fi
    w=${(m)#c}
    if (( col + w > cols )); then (( lines++ )); col=0; fi
    (( col += w ))
  done
  REPLY=$lines
}

_fishy_render_pager() {
  local disp=$_fishy_sugg_disp
  _fishy_screen_lines "$BUFFER$disp"
  local -i h=$(( ${LINES:-24} - REPLY ))
  (( h < 1 )) && h=1
  fishy-pager-render ${COLUMNS:-80} $h
}

typeset -g _fishy_sugg_disp=''

# Pager search-field focus: zle can only put the cursor inside BUFFER, but fish
# puts it on the "search:" line below the command line. While the field has
# focus, each redraw shows the command line as PREDISPLAY, the field text as
# BUFFER and the rest of the pager as POSTDISPLAY; every widget swaps back first.
typeset -gi _fcl_swapped=0 _fcl_cursor=0
typeset -g  _fcl_buffer=''
fishy-unswap() {
  (( _fcl_swapped )) || return 0
  BUFFER=$_fcl_buffer CURSOR=$_fcl_cursor PREDISPLAY=''
  _fcl_swapped=0
}

# Display-only edits (patched zle's `zle_display`): fish's continuation-line
# indent, and the suggestion-case display of combine_command_and_autosuggestion.
typeset -gi _fishy_has_zle_display=-1
_fishy_display_edits() {
  reply=()
  if (( _fishy_has_zle_display < 0 )); then
    [[ ${(t)zle_display} == *special* ]] && _fishy_has_zle_display=1 || _fishy_has_zle_display=0
  fi
  (( _fishy_has_zle_display )) || return
  local -a edits=()
  # Case flip: an icase suggestion whose case differs from the typed line is
  # drawn in the suggestion's case unless the last token has uppercase.
  if [[ -n $_fishy_sugg_disp ]]; then
    local -i ss=$_fs_start se=$_fs_end
    local line=${BUFFER[ss+1,se]}
    if [[ $_fs_text != "$line"* ]] && (( ${#line} < ${#_fs_text} )); then
      fishy-call sync token-extent $(( ${#BUFFER} > 0 ? ${#BUFFER} - 1 : 0 )) "$BUFFER"
      local -a e=("${(@ps:\x1f:)fishy_reply[1]}")
      local lasttok=${BUFFER[e[2]+1,e[3]]}
      if [[ $lasttok != *[[:upper:]]* ]]; then
        edits+=("$ss $se ${_fs_text[1,se-ss]}")
      fi
    fi
  fi
  # Continuation-line indent.
  if [[ $BUFFER == *$'\n'* ]]; then
    _fishy_prompt_width; local -i pw=$REPLY
    fishy-indents "$BUFFER"
    local r
    for r in "$reply[@]"; do
      local -a f=(${=r})
      local -i cols=$(( pw + 4 * f[2] ))
      (( cols > 0 )) && edits+=("$f[1] $f[1] ${(l:cols:: :)}")
    done
  fi
  reply=("$edits[@]")
}

# zle-line-pre-redraw: compose POSTDISPLAY and region_highlight.
# The command line as last drawn (fish: rendered_layout.text).
typeset -g _fishy_rendered_text=''

fishy-render() {
  emulate -L zsh -o extendedglob
  fishy-unswap
  _fishy_rendered_text=$BUFFER
  region_highlight=("${(@)region_highlight:#*memo=fishy}")
  # Syntax colors first; suggestion/pager/search-match/flash entries follow and
  # take precedence where they overlap.
  fishy-highlight-entries
  local -a syntax=("$reply[@]")
  fishy-suggest-display
  _fishy_sugg_disp=$REPLY
  local post=$REPLY
  local -a extra=()
  local -i base=$(( ${#PREDISPLAY} + ${#BUFFER} ))
  if [[ -n $_fishy_sugg_disp ]]; then
    local spec=${_fishy_face[autosuggestion]:-fg=8}
    (( _fishy_flash_suggestion )) && spec=$_fishy_face[search_match]
    extra+=("P$base $(( base + ${#post} )) $spec memo=fishy")
  fi
  local -a plines=() starts=()
  if ! fishy-pager-is-empty; then
    _fishy_render_pager
    plines=("$_fpr_lines[@]")
  fi
  _fishy_display_edits
  (( _fishy_has_zle_display )) && zle_display=("$reply[@]")
  if (( ${#plines} )) && fishy-search-focused; then
    # Swapped layout: PREDISPLAY = command line + "\nsearch: ", BUFFER = field.
    local cl=$BUFFER field=$_fp_search_text
    _fcl_buffer=$BUFFER _fcl_cursor=$CURSOR _fcl_swapped=1
    local pre=$cl$post$'\n'"search: "
    local -i fieldw=$(( ${#field} < FISHY_PAGER_SEARCH_FIELD_WIDTH ? FISHY_PAGER_SEARCH_FIELD_WIDTH : ${#field} ))
    local pad=${(l:fieldw-${#field}:: :)}
    PREDISPLAY=$pre
    BUFFER=$field CURSOR=${#field}
    (( _fishy_has_zle_display )) && zle_display=()
    # Command-line syntax colors move into the PREDISPLAY region.
    local e
    for e in "$syntax[@]"; do region_highlight+=("P$e"); done
    region_highlight+=("$extra[@]")
    local -i fstart=${#pre}
    local ul=${_fishy_face[search]:-underline}
    region_highlight+=("P$fstart $(( fstart + fieldw )) $ul memo=fishy")
    # Remaining pager lines (line 0 was the search field itself).
    local -i off=$(( fstart + fieldw + 1 )) li
    for (( li = 2; li <= ${#plines}; li++ )); do starts[li]=$off; (( off += ${#plines[li]} + 1 )); done
    POSTDISPLAY=$pad
    (( ${#plines} > 1 )) && POSTDISPLAY+=$'\n'${(pj:\n:)plines[2,-1]}
    _fishy_pager_spans_to_rh 2
    return
  fi
  region_highlight+=("$syntax[@]" "$extra[@]")
  if (( ${#plines} )); then
    local -i off=$(( base + ${#post} + 1 )) li
    for (( li = 1; li <= ${#plines}; li++ )); do starts[li]=$off; (( off += ${#plines[li]} + 1 )); done
    post+=$'\n'${(pj:\n:)plines}
    _fishy_pager_spans_to_rh 1
  fi
  POSTDISPLAY=$post
  # History search match and flash highlight the command line itself.
  if (( _fh_active && ! _fh_at_present && _fh_match_start >= 0 )); then
    region_highlight+=("$(( _fh_match_start )) $(( _fh_match_start + _fh_match_len )) ${_fishy_face[search_match_bg]:-${_fishy_face[search_match]}} memo=fishy")
  fi
  if (( _fishy_flash_start >= 0 )); then
    region_highlight+=("$_fishy_flash_start $_fishy_flash_end $_fishy_face[search_match] memo=fishy")
  fi
}

# Pager spans -> region_highlight, for pager lines from index $1 (1-based;
# uses `starts` from the caller).
_fishy_pager_spans_to_rh() {
  local -i first=$1
  local sp
  for sp in "$_fpr_spans[@]"; do
    local -a sv=(${=sp})
    local -i ln=$(( sv[1] + 1 ))
    (( ln < first )) && continue
    local face=${_fishy_face[$sv[4]]}
    [[ -z $face || $face == none ]] && continue
    region_highlight+=("P$(( starts[ln] + sv[2] )) $(( starts[ln] + sv[3] )) $face memo=fishy")
  done
}
