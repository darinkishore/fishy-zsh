# fishy-zsh: fish 4.9's interactive UX for zsh.
#
#   source /path/to/fishy/fishy.zsh
#
# Needs the patched fish (`fishy-fish`, with the __fishy builtin) on PATH or in
# $FISHY_FISH. See AGENTS.md for the architecture.

[[ -o interactive && -o zle ]] || return 0

typeset -g FISHY_DIR=${${(%):-%x}:A:h}

# Boot the fish servers first (unless start.zsh already did, earlier in the
# startup files), so fish starts while the rest of fishy loads.
(( ${_fishy_started_early:-0} )) || source $FISHY_DIR/start.zsh
autoload -Uz add-zle-hook-widget

source $FISHY_DIR/editline.zsh
source $FISHY_DIR/highlight.zsh
source $FISHY_DIR/indent.zsh
source $FISHY_DIR/suggest.zsh
source $FISHY_DIR/pager.zsh
source $FISHY_DIR/complete.zsh
source $FISHY_DIR/theme.zsh
source $FISHY_DIR/reader.zsh
source $FISHY_DIR/keys.zsh
source $FISHY_DIR/paste.zsh
source $FISHY_DIR/integrations.zsh
source $FISHY_DIR/prompt.zsh

# fishy owns POSTDISPLAY, region_highlight and every widget. Detach the usual
# plugins that would fight over them if they were loaded before us.
autoload -Uz add-zsh-hook add-zle-hook-widget
if (( $+functions[_zsh_autosuggest_start] )); then
  add-zsh-hook -d precmd _zsh_autosuggest_start
  add-zsh-hook -d precmd _zsh_autosuggest_bind_widgets 2>/dev/null
fi
if (( $+functions[_zsh_highlight__zle-line-pre-redraw] )); then
  add-zle-hook-widget -d line-pre-redraw _zsh_highlight__zle-line-pre-redraw
  add-zle-hook-widget -d line-finish _zsh_highlight__zle-line-finish
fi

# Ghostty's shell integration: under nix-darwin it never loads for fish (fish
# builds its vendor_conf.d list from the Nix profiles, not XDG_DATA_DIRS), so
# what Ghostty sees from fish is fish's own OSC 133 marks, OSC 7, titles and
# the default block cursor. fishy writes exactly those (prompt.zsh), so the zsh
# integration, which would add its own marks, title, cwd reports, bar cursor
# and sudo/ssh wrappers, is dropped before its deferred init (first precmd).
precmd_functions=(${precmd_functions:#_ghostty_deferred_init})

# fish reads ctrl-s (pager-toggle-search) and ctrl-q; don't let the tty eat
# them as XOFF/XON flow control.
setopt no_flow_control

# fish_escape_delay_ms defaults to 30ms; zsh's KEYTIMEOUT is in 1/100 s.
KEYTIMEOUT=3

# Shared history: commands run here are added to fish's history (with fish's
# path detection), so autosuggestions and history search match fish exactly.
fishy-history-add() {
  fishy-call sync history-add "$PWD" "$1"
}

# Commands zsh can run that fish doesn't know (aliases, functions, builtins,
# reserved words) become stub functions in the servers, so fish's highlighter
# and completion treat them as valid commands.
typeset -g _fishy_cmds_sig=''
_fishy_sync_commands() {
  local -a names=(${(k)aliases} ${(k)functions} ${(k)builtins} ${(k)reswords})
  local sig=${(j: :)${(o)names}}
  [[ $sig == "$_fishy_cmds_sig" ]] && return
  fishy-tell sync define-commands "${names[@]}"
  fishy-tell async define-commands "${names[@]}"
  _fishy_cmds_sig=$sig
}

_fishy_line_init() {
  (( ${#_fishy_face} )) || fishy-theme-collect
  fishy-reader-line-init
}

# fish's final rendering keeps the syntax colors but drops the suggestion and
# the pager.
_fishy_line_finish() {
  _fishy_prompt_line_finish
  fishy-pager-clear
  fishy-suggest-clear
  fishy-render
}

zle -N fishy-async-ready _fishy_w_async_ready
add-zle-hook-widget line-init _fishy_line_init
add-zle-hook-widget line-pre-redraw fishy-render
add-zle-hook-widget line-finish _fishy_line_finish
fishy-prompt-install

fishy-keys-install
# darin's fish layers atuin and fzf on top of the defaults; so does fishy
# (FISHY_INTEGRATIONS=0 keeps stock fish bindings, e.g. for the harness).
[[ ${FISHY_INTEGRATIONS:-1} == 1 ]] && fishy-integrations-install

# ctrl-c while editing: fish binds it to clear-commandline (clear in place, no
# ^C, no new prompt). zsh delivers it as SIGINT, and a widget run from inside
# the trap is cut short by the pending interrupt. So the trap only sends a
# no-op request to the async server; its reply wakes zle's input wait (zle -F)
# and the handler runs clear-commandline as an ordinary widget.
_fishy_async_done_intr() { _fishy_w_ctrl_c }

functions[_fishy_prev_trapint]=${functions[TRAPINT]-}
TRAPINT() {
  if [[ -n $CONTEXT ]] && fishy-async-send intr noop 2>/dev/null; then
    return 0
  fi
  if [[ -n ${functions[_fishy_prev_trapint]} ]]; then
    _fishy_prev_trapint "$@"
    return
  fi
  return $(( 128 + $1 ))
}

# Queue the theme request: the first prompt only collects the answer.
fishy-theme-request
