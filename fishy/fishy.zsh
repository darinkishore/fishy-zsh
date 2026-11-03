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
source $FISHY_DIR/highlight.zsh
source $FISHY_DIR/suggest.zsh
source $FISHY_DIR/pager.zsh
source $FISHY_DIR/complete.zsh
source $FISHY_DIR/theme.zsh
source $FISHY_DIR/reader.zsh
source $FISHY_DIR/keys.zsh
source $FISHY_DIR/paste.zsh

# Cursor shape: under nix-darwin, Ghostty's fish integration never loads (fish
# builds its vendor_conf.d list from the Nix profiles, not XDG_DATA_DIRS), so
# fish keeps the terminal's default block cursor. Ghostty's zsh integration
# would switch to a bar; drop its `cursor` feature (read at the first precmd)
# so zsh looks like fish. Set FISHY_GHOSTTY_CURSOR=1 to keep Ghostty's bar.
if [[ -n $GHOSTTY_SHELL_FEATURES && $FISHY_GHOSTTY_CURSOR != 1 ]]; then
  GHOSTTY_SHELL_FEATURES=${(j:,:)${(@)${(s:,:)GHOSTTY_SHELL_FEATURES}:#cursor*}}
fi

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
  fishy-call sync define-commands "${names[@]}"
  fishy-call async define-commands "${names[@]}"
  _fishy_cmds_sig=$sig
}

_fishy_precmd() {
  _fishy_sync_commands
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

zle -N fishy-async-ready _fishy_w_async_ready
add-zle-hook-widget line-init _fishy_line_init
add-zle-hook-widget line-pre-redraw fishy-render
add-zle-hook-widget line-finish _fishy_line_finish
autoload -Uz add-zsh-hook
add-zsh-hook precmd _fishy_precmd

fishy-keys-install

# Start both servers now so the first prompt never waits for fish to boot.
_fishy_ensure sync
_fishy_ensure async
