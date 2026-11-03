# fishy-zsh: fish 4.9's interactive UX for zsh.
#
#   source /path/to/fishy/fishy.zsh
#
# Needs the patched fish (`fishy-fish`, with the __fishy builtin) on PATH or in
# $FISHY_FISH. See AGENTS.md for the architecture.

[[ -o interactive && -o zle ]] || return 0

typeset -g FISHY_DIR=${${(%):-%x}:A:h}
autoload -Uz add-zle-hook-widget

source $FISHY_DIR/bridge.zsh
source $FISHY_DIR/editline.zsh
source $FISHY_DIR/suggest.zsh
source $FISHY_DIR/pager.zsh
source $FISHY_DIR/complete.zsh
source $FISHY_DIR/theme.zsh
source $FISHY_DIR/reader.zsh
source $FISHY_DIR/keys.zsh
source $FISHY_DIR/paste.zsh

# fish_escape_delay_ms defaults to 30ms; zsh's KEYTIMEOUT is in 1/100 s.
KEYTIMEOUT=3

# Shared history: commands run here are added to fish's history (with fish's
# path detection), so autosuggestions and history search match fish exactly.
fishy-history-add() {
  fishy-call sync history-add "$PWD" "$1"
}

_fishy_precmd() {
  # Make the last command searchable/suggestible and saved (fish: resolve_pending
  # after the command finishes), and pick up exported-environment changes.
  fishy-call sync history-resolve
  _fishy_sync_env sync
  _fishy_sync_env async
}

_fishy_line_init() {
  (( ${#_fishy_face} )) || fishy-theme-load
  fishy-reader-line-init
}

_fishy_line_finish() {
  POSTDISPLAY=''
  region_highlight=("${(@)region_highlight:#*memo=fishy}")
}

zle -N fishy-suggest-ready _fishy_w_suggest_ready
add-zle-hook-widget line-init _fishy_line_init
add-zle-hook-widget line-pre-redraw fishy-render
add-zle-hook-widget line-finish _fishy_line_finish
autoload -Uz add-zsh-hook
add-zsh-hook precmd _fishy_precmd

fishy-keys-install

# Start both servers now so the first prompt never waits for fish to boot.
_fishy_ensure sync
_fishy_ensure async
