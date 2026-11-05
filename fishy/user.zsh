# fishy user bindings: the user's own fish bindings (plugins, config.fish),
# taken from fish's binding table rather than written down here.
#
# After the sync server's first prompt event (when fish runs its interactive
# setup, which sets fish_key_bindings and so lets plugins such as autopair
# install theirs), `__fishy user-bindings` lists the default mode's user
# bindings in the order fish tries them. Each becomes an entry of fishy's
# table (input.zsh) whose widget runs the binding's commands as fish's
# binding_execute does: readline functions as fishy's readline commands, and
# fish code
#   - as fishy's zsh port, for functions fishy ports (atuin, fzf's fish
#     bindings, fish's own share/functions bindings),
#   - in the server (`__fishy bind-run`), for code that only edits the command
#     line (autopair),
#   - otherwise in a one-shot fish on the terminal, with the command line,
#     cursor and reader state passed in and its edits sent back: anything that
#     runs a full-screen program (fzf.fish) works as in fish.

# Fish functions fishy has ports of (a binding whose code is just the name).
typeset -gA _fishy_user_ports=(
  fzf-file-widget fishy-fzf-file
  fzf-cd-widget fishy-fzf-cd
  fzf_complete fishy-fzf-complete
  _atuin_search fishy-atuin-search
  _atuin_bind_up fishy-atuin-up
  _atuin_ai_question_mark fishy-atuin-question
  fish_clipboard_copy fishy-clipboard-copy
  fish_clipboard_paste fishy-clipboard-paste
  __fish_man_page fishy-man-page
  __fish_list_current_token fishy-list-token
  __fish_preview_current_file fishy-preview
  __fish_whatis_current_token fishy-whatis
  __fish_paginate fishy-paginate
  __fish_toggle_comment_commandline fishy-toggle-comment
  edit_command_buffer fishy-edit-command-buffer
  up-or-search fishy-up-or-search
  down-or-search fishy-down-or-search
)

# Fish functions that only edit the command line: they run in the server
# (no process start, so as fast as a readline command).
typeset -ga _fishy_user_server_fns=(
  _autopair_insert_left _autopair_insert_right _autopair_insert_same
  _autopair_backspace _autopair_tab
)

typeset -ga _fishy_user_cmds   # per binding: its commands, \x1f-joined
typeset -gA _fishy_readline_names
typeset -gi _fishy_user_loaded=0

# fish: a binding command is a readline function if it names one.
_fishy_readline_names_load() {
  (( ${#_fishy_readline_names} )) && return
  _fishy_bind_eval 'bind --function-names' || return
  local n
  for n in ${(f)_fishy_bind_out}; do _fishy_readline_names[$n]=1; done
}

# Import the user bindings (once, at the first line-init: the prompt event
# that runs fish's interactive setup is queued before this request).
fishy-user-bindings-load() {
  (( _fishy_user_loaded )) && return
  _fishy_user_loaded=1
  fishy-call sync user-bindings || return
  local rec style keys c
  local -a f cmds opts
  local -i n=0 script
  _fishy_user_binds=() _fishy_user_cmds=()
  for rec in "$fishy_reply[@]"; do
    [[ $rec == U$'\x1f'* ]] || continue
    f=("${(@ps:\x1f:)rec}")
    style=$f[2] keys=$f[3]
    [[ -n $f[4] ]] && continue        # switches bind mode: fishy has one mode
    cmds=("${(@)f[5,-1]}")
    (( n++ ))
    _fishy_user_cmds[n]=${(pj:\x1f:)cmds}
    # One function per binding: zle keeps $WIDGET at the outer widget
    # (fishy-key) when a widget calls another.
    functions[_fishy_w_user_$n]="_fishy_user_binding_run $n"
    zle -N fishy-user-$n _fishy_w_user_$n
    _fishy_readline_names_load
    script=0
    for c in "$cmds[@]"; do
      [[ -n ${_fishy_readline_names[$c]} ]] || script=1
    done
    opts=(-u -K)
    [[ $style == R ]] && opts+=(-R)
    (( script )) && opts+=(-s)
    fishy-bind "$opts[@]" "$keys" fishy-user-$n
  done
  fishy-keys-install
}

# fish's binding_execute for user binding $1.
_fishy_user_binding_run() {
  fishy-unswap
  local -a cmds=("${(@ps:\x1f:)_fishy_user_cmds[$1]}")
  local c skip=''
  for c in "$cmds[@]"; do
    if [[ -n $skip ]]; then
      # and/or: a failed (or succeeded) function skips the following ones.
      [[ -n ${_fishy_readline_names[$c]} ]] && continue
      skip=''
    fi
    if [[ -n ${_fishy_readline_names[$c]} ]]; then
      case $c in
        (and) (( _fishy_function_status )) || skip=1 ;;
        (or) (( _fishy_function_status )) && skip=1 ;;
        (execute) _fishy_w_execute ;;
        (self-insert|self-insert-notfirst) _fishy_key_insert "$_fishy_cur_event" ;;
        (*)
          if (( $+functions[_fishy_cmd_$c] )); then
            _fishy_run $c
          else
            fishy-log "bind: no readline function $c"
          fi ;;
      esac
    elif [[ -n ${_fishy_user_ports[$c]} ]]; then
      zle ${_fishy_user_ports[$c]}
    elif (( ${_fishy_user_server_fns[(Ie)${c%% *}]} )); then
      _fishy_bind_run "$c"
    else
      _fishy_bind_run_tty "$c"
    fi
    (( _fishy_accept )) && return
  done
}

# The reader state `commandline` reports, for bind-run: FLAGS [FIELD CURSOR].
_fishy_bind_state() {
  reply=('')
  fishy-pager-is-empty || reply[1]+=p
  fishy-pager-is-empty || (( _fpr_remaining )) || reply[1]+=d
  (( _fh_active )) && reply[1]+=s
  if (( _fp_search_shown )); then
    reply[1]+=f
    reply+=("$_fp_search_text" ${#_fp_search_text})
  fi
}

# A binding's fish code in a one-shot fish on the terminal (user config
# loaded as interactive fish loads it), then its edits applied like bind-run's.
# What it writes lands where the cursor is, as in fish; afterwards fish's
# screen sees the terminal was written to (check_status) and repaints from the
# line the cursor is on, after a \r (reset_line). zle redraws relative to where
# it left the cursor, so the same \r and a redraw do the same.
_fishy_bind_run_tty() {
  local code=$1 out
  _fishy_bind_state
  local -a state=("$reply[@]")
  state[1]+=t
  out=$(__fishy_no_exit_event=1 __fishy_interactive_config=1 $FISHY_FISH -c 'builtin __fishy reply 0 bind-run $argv' \
          $CURSOR "$BUFFER" "$code" "$state[@]" 3>&1 1>/dev/tty 2>/dev/tty </dev/tty)
  print -rn -- $'\r' >/dev/tty
  # Records are NUL-terminated; the last one is the \x1e terminator.
  local -a recs=("${(@ps:\0:)out}")
  _fishy_bind_apply "${(@)recs:#$'\x1e'*}"
  local -a fns=("$_fishy_bind_fns[@]")
  local fn
  local -i repainted=0
  for fn in "$fns[@]"; do
    if [[ $fn == execute ]]; then
      _fishy_w_execute
    elif (( $+functions[_fishy_cmd_$fn] )); then
      _fishy_run $fn
      [[ $fn == repaint ]] && repainted=1
    else
      fishy-log "bind: no readline function $fn"
    fi
    (( _fishy_accept )) && return
  done
  (( repainted )) || zle .reset-prompt
  fishy-suggest-update
  fishy-highlight-update
}
