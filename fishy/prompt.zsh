# fishy prompt: fish draws the prompt. The server runs fish's own machinery
# (fish_prompt and friends, the fish_prompt/preexec/postexec events, the
# title, OSC 133 marks, PROMPT_SP) and hands back the bytes fish would have
# written; zsh writes them at the same points of the command lifecycle.
#
#   fish (read_i / readline)            zsh
#   ----------------------------------  ------------------------------------
#   command done: CMD_DURATION, 133 D,  first precmd hook   (postexec)
#     fish_postexec, show cursor
#   abandon line (⏎), fish_prompt event first precmd hook   (prompt-event)
#   ... other fish_prompt handlers      the other precmd hooks (direnv, ...)
#   exec_prompt: prompts + title        last precmd hook    (prompt -> PS1)
#   transient re-render on Enter        line-finish
#   133 C, fish_preexec, title          last preexec hook   (exec)
#   OSC 7 on PWD change                 chpwd               (capture)
#
# The prompt arrives in zsh prompt syntax with fish's widths baked in (%G), so
# zsh lays out the command line exactly where fish would.

typeset -gi _fp_first=1      # fish's first prompt only writes \r (no ⏎)
typeset -gi _fp_ran=0        # a command ran since the last prompt
typeset -gF _fp_t0=0         # when it started (fish: right before eval)
typeset -g  _fp_cmd=''       # the accepted command line
typeset -gi _fp_status=0
typeset -ga _fp_pipestatus=()
typeset -g  _fp_ps1='' _fp_rps1=''
typeset -gi _fp_lastw=-1 _fp_lines=1 _fp_rw=0 _fp_transient=0

# Append the O payload of every reply record (raw terminal bytes, last
# field) to $_fp_buf; _fishy_prompt_flush writes it.
typeset -g _fp_buf=''
_fishy_prompt_out() {
  local rec
  for rec in "$fishy_reply[@]"; do
    [[ $rec == O$'\x1f'* ]] && _fp_buf+=${rec#O$'\x1f'}
  done
  return 0
}
_fishy_prompt_flush() {
  [[ -n $_fp_buf ]] && print -rn -- "$_fp_buf"
  _fp_buf=''
}

_fishy_prompt_first() {
  # One command: any command (even `local`) resets $pipestatus.
  local -a ps=("${pipestatus[@]}" $? $EPOCHREALTIME)
  local -F t1=$ps[-1]
  local -i st=$ps[-2]
  ps[-2,-1]=()
  emulate -L zsh
  _fp_status=$st _fp_pipestatus=("${ps[@]}")
  # Stay around the other hooks: first here, render last (plugins may have
  # added hooks since the previous prompt).
  precmd_functions=(_fishy_prompt_first ${precmd_functions:#_fishy_prompt_(first|last)} _fishy_prompt_last)

  if (( _fp_ran )); then
    local -i ms=$(( (t1 - _fp_t0) * 1000 ))   # truncated, like as_millis()
    fishy-call sync postexec $st $ms "$_fp_cmd" "${ps[@]}" && _fishy_prompt_out
  fi
  # resolve_pending: the line becomes searchable and is saved (the async
  # server's copy, for suggestions, only in memory). Also for lines zsh runs
  # no preexec for, e.g. a comment.
  if (( _fishy_history_pending )); then
    fishy-tell sync history-resolve
    fishy-tell async history-resolve nosave
    _fishy_history_pending=0
  fi
  fishy-call sync prompt-event $_fp_first ${COLUMNS:-80} ${LINES:-24} $st "${ps[@]}" \
    && _fishy_prompt_out
  _fishy_prompt_flush
  _fp_first=0 _fp_ran=0
}

# Ask fish for the prompt ($1: 1 = transient final rendering) and install it.
_fishy_prompt_render() {
  emulate -L zsh
  fishy-call sync prompt ${1:-0} ${COLUMNS:-80} ${LINES:-24} $_fp_status "${_fp_pipestatus[@]}" || return
  local rec
  local -a f
  for rec in "$fishy_reply[@]"; do
    case $rec in
      O$'\x1f'*) _fp_buf+=${rec#O$'\x1f'} ;;
      L$'\x1f'*)
        f=("${(@ps:\x1f:)rec}")
        _fp_lastw=$f[2] _fp_lines=$f[3]
        _fp_ps1=${rec#L$'\x1f'*$'\x1f'*$'\x1f'} ;;
      R$'\x1f'*)
        f=("${(@ps:\x1f:)rec}")
        _fp_rw=$f[2]
        _fp_rps1=${rec#R$'\x1f'*$'\x1f'} ;;
      X$'\x1f'*) _fp_transient=${rec#X$'\x1f'} ;;
    esac
  done
  _fishy_prompt_flush
  _fishy_prompt_apply
}

# The prompt strings only need PROMPT_PERCENT. Under PROMPT_SUBST they are
# reached through a parameter (substituted text is not substituted again);
# under PROMPT_BANG a literal ! is doubled.
_fishy_prompt_apply() {
  local l=$_fp_ps1 r=$_fp_rps1
  if [[ -o prompt_bang ]]; then l=${l//!/!!} r=${r//!/!!}; fi
  typeset -g _fp_ps1_out=$l _fp_rps1_out=$r
  if [[ -o prompt_subst ]]; then
    PS1='${_fp_ps1_out}' RPS1='${_fp_rps1_out}'
  else
    PS1=$l RPS1=$r
  fi
  # fish draws the right prompt ending in the last column.
  ZLE_RPROMPT_INDENT=0
}

_fishy_prompt_last() {
  emulate -L zsh
  # Environment first (the prompt reads it), the prompt, and only then the
  # command stubs: thousands of names must not queue in front of the prompt.
  _fishy_sync_env sync
  _fishy_sync_env async
  _fishy_prompt_render 0
  _fishy_sync_commands
}

# zle-line-finish (before the final repaint): fish's transient prompt.
_fishy_prompt_line_finish() {
  _fp_cmd=$BUFFER
  (( _fp_transient )) || return 0
  _fishy_prompt_render 1
  zle .reset-prompt
}

_fishy_prompt_preexec() {
  emulate -L zsh
  # Always last, so the measured time is the command's, like fish's.
  preexec_functions=(${preexec_functions:#_fishy_prompt_preexec} _fishy_prompt_preexec)
  fishy-call sync exec "$_fp_cmd" && _fishy_prompt_out
  _fishy_prompt_flush
  _fp_ran=1
  _fp_t0=$EPOCHREALTIME
}

# fish's __fish_update_cwd_osc runs --on-variable PWD (OSC 7).
_fishy_prompt_chpwd() {
  fishy-call sync capture __fish_update_cwd_osc && _fishy_prompt_out
  _fishy_prompt_flush
}

# Window size changes: fish re-runs the prompt ($COLUMNS) and repaints
# (__fish_winch_handler, when fish_handle_reflow is 1 - it is for Ghostty).
functions[_fishy_prev_trapwinch]=${functions[TRAPWINCH]-}
TRAPWINCH() {
  if zle; then
    _fishy_prompt_render 0
    zle .reset-prompt
  fi
  [[ -n ${functions[_fishy_prev_trapwinch]} ]] && _fishy_prev_trapwinch "$@"
  return 0
}

fishy-prompt-install() {
  # fishy writes fish's PROMPT_SP itself, which also covers the line an
  # interrupted command leaves behind ("^C⏎"): no extra newline from zsh
  # (SIGINT_NEWLINE is fishy's zsh patch).
  setopt no_prompt_sp prompt_cr prompt_percent
  [[ -n ${options[sigintnewline]-} ]] && setopt no_sigint_newline
  precmd_functions=(_fishy_prompt_first ${precmd_functions:#_fishy_prompt_(first|last)} _fishy_prompt_last)
  preexec_functions=(${preexec_functions:#_fishy_prompt_preexec} _fishy_prompt_preexec)
  chpwd_functions=(${chpwd_functions:#_fishy_prompt_chpwd} _fishy_prompt_chpwd)
}

# Width of the prompt's last line, as fish measured it (fish's
# commandline_indent: a prompt that fills the line indents nothing).
_fishy_prompt_width() {
  local -i w=$_fp_lastw
  if (( w < 0 )); then
    # No prompt from fish (server unavailable): measure PS1.
    local p=${(%)PS1}
    p=${p//$'\e'\[[0-9;:?]#[a-zA-Z]/}
    p=${p//$'\e'\][^$'\a']#$'\a'/}
    p=${p##*$'\n'}
    w=${(m)#p}
  fi
  (( w >= ${COLUMNS:-80} )) && w=0
  REPLY=$w
}
