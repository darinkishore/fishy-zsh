# fishy keys: fish 4.9.3's default emacs bindings (fish_default_key_bindings +
# __fish_shared_key_bindings, as printed by `bind` in an interactive fish) on a
# dedicated zle keymap.
#
# Two kinds of bindings, as in fish:
#   readline commands  -> widget calls _fishy_run CMD  (dispatch bookkeeping)
#   fish functions     -> widget calls the function directly (no last_cmd update)

# Readline-command widgets.
_fishy_rl_widget() {
  local cmd=$1
  eval "_fishy_w_$cmd() { _fishy_run $cmd }"
  zle -N fishy-$cmd _fishy_w_$cmd
}
local _c
for _c in \
  beginning-of-line end-of-line beginning-of-buffer end-of-buffer \
  clear-commandline cancel complete complete-and-search pager-toggle-search \
  backward-delete-char delete-char delete-or-exit backward-char forward-char forward-single-char \
  up-line down-line beginning-of-history end-of-history \
  history-token-search-backward history-token-search-forward \
  prevd-or-backward-word nextd-or-forward-word backward-word forward-word \
  backward-bigword forward-bigword forward-token backward-token \
  kill-word kill-bigword kill-token backward-kill-token \
  backward-kill-word backward-kill-bigword backward-kill-path-component \
  kill-line backward-kill-line yank yank-pop transpose-chars transpose-words \
  upcase-word downcase-word capitalize-word undo redo expand-abbr \
  suppress-autosuggestion accept-autosuggestion clear-screen repaint
do
  _fishy_rl_widget $_c
done
unset _c

# Function-style bindings (fish functions that call `commandline -f ...`).
_fishy_w_up_or_search() { fishy-unswap; _fishy_cmd_up-or-search }
_fishy_w_down_or_search() { fishy-unswap; _fishy_cmd_down-or-search }
zle -N fishy-up-or-search _fishy_w_up_or_search
zle -N fishy-down-or-search _fishy_w_down_or_search

# Self-insert, with fish's read_normal_chars batching: while more input is
# already pending, consecutive self-inserting keys are read ahead and inserted
# as ONE edit (this decides undo granularity). A key read when nothing more is
# pending is handled on its own (the Key event path). Keys bound to
# `self-insert expand-abbr` end the batch and then run expand-abbr.
typeset -g _fishy_expand_chars=' ;|&><)'
_fishy_is_self_insert_key() {
  local k=$1
  [[ ${#k} == 1 ]] || return 1
  [[ $k == [[:print:]] || $k == [^[:ascii:]] ]]
}
#
# The key that ends a batch is handled in the same fish event loop iteration
# (read_normal_chars returns it), so fish's color_suggest_repaint_now does not
# run between the two: the batch then requests no highlight/autosuggestion
# (the next command's own update does). This decides, e.g., whether Enter
# right after typed-ahead text gets the quick no-I/O highlight.
_fishy_w_self_insert() {
  fishy-unswap
  local k=$KEYS acc=''
  local -i expand_after_acc=0 deferred=0
  while (( PENDING > 0 )); do
    acc+=$k
    if [[ $_fishy_expand_chars == *"$k"* ]]; then
      expand_after_acc=1 k=''
      break
    fi
    read -k 1 k || { k=''; break }
    if ! _fishy_is_self_insert_key "$k"; then
      zle -U -- "$k"
      k='' deferred=1
      break
    fi
  done
  if [[ -n $acc ]]; then
    _fishy_insert_batch "$acc" $(( deferred || expand_after_acc ))
    (( expand_after_acc )) && _fishy_run expand-abbr
  fi
  if [[ -n $k ]]; then
    _fishy_insert "$k"
    [[ $_fishy_expand_chars == *"$k"* ]] && _fishy_run expand-abbr
  fi
}
zle -N fishy-self-insert _fishy_w_self_insert
zle -N fishy-self-insert-expand _fishy_w_self_insert

# ctrl-space: insert a space without expanding (only on a non-empty line).
_fishy_w_ctrl_space() {
  fishy-unswap
  [[ -n $BUFFER ]] && _fishy_insert ' '
}
zle -N fishy-ctrl-space _fishy_w_ctrl_space

# alt-enter / shift-enter: insert a newline, then expand-abbr.
_fishy_w_newline() {
  fishy-unswap
  _fishy_insert $'\n'
  _fishy_run expand-abbr
}
zle -N fishy-newline _fishy_w_newline

# ctrl-c arrives as SIGINT while zle is active; fish binds it to
# clear-commandline (clear the line in place, no ^C, no new prompt).
_fishy_w_ctrl_c() {
  fishy-unswap
  _fishy_run clear-commandline
}
zle -N fishy-ctrl-c _fishy_w_ctrl_c

# Enter.
_fishy_w_execute() {
  fishy-unswap
  _fishy_accept=0
  _fishy_run execute
  (( _fishy_accept )) || return 0
  fishy-history-add "$BUFFER"
  zle .accept-line
}
zle -N fishy-execute _fishy_w_execute

# Bracketed paste: fish inserts pasted text as one edit (see paste.zsh).
_fishy_w_paste() {
  fishy-unswap
  local text
  zle .bracketed-paste text
  fishy-paste "$text"
}
zle -N fishy-bracketed-paste _fishy_w_paste

fishy-keys-install() {
  emulate -L zsh
  bindkey -N fishy                 # fresh keymap, nothing inherited
  # Every printable character self-inserts (fish: '' self-insert).
  bindkey -M fishy -R ' '-'~' fishy-self-insert
  bindkey -M fishy -R '\M-^@'-'\M-^?' fishy-self-insert
  local k
  for k in ' ' ';' '|' '&' '>' '<' ')'; do bindkey -M fishy "$k" fishy-self-insert-expand; done

  local -A map=(
    '^M' execute  '^J' execute
    '^I' complete  '\e[Z' complete-and-search  '^S' pager-toggle-search
    '\e' cancel  '^G' cancel
    '^C' clear-commandline
    '^?' backward-delete-char  '^H' backward-delete-char  '\e[3~' delete-char  '^D' delete-or-exit
    '^B' backward-char  '\e[D' backward-char  '\eOD' backward-char
    '^F' forward-char  '\e[C' forward-char  '\eOC' forward-char
    '^A' beginning-of-line  '\e[H' beginning-of-line  '\eOH' beginning-of-line  '\e[1~' beginning-of-line
    '^E' end-of-line  '\e[F' end-of-line  '\eOF' end-of-line  '\e[4~' end-of-line
    '\e<' beginning-of-buffer  '\e>' end-of-buffer
    '\e[5~' beginning-of-history  '\e[6~' end-of-history
    '\e[1;3A' history-token-search-backward  '\e[1;9A' history-token-search-backward
    '\e[1;3B' history-token-search-forward  '\e[1;9B' history-token-search-forward
    '\e.' history-token-search-backward
    '\eb' prevd-or-backward-word  '\e[1;3D' prevd-or-backward-word  '\e[1;9D' prevd-or-backward-word
    '\ef' nextd-or-forward-word  '\e[1;3C' nextd-or-forward-word  '\e[1;9C' nextd-or-forward-word
    '\e[1;2D' backward-bigword  '\e[1;2C' forward-bigword
    '\e[1;5D' backward-token  '\e[1;5C' forward-token
    '\e^?' backward-kill-word  '\e^H' backward-kill-word
    '\e[3;3~' kill-word  '\ed' kill-word
    '\e[3;5~' kill-token
    '^W' backward-kill-path-component
    '^K' kill-line  '^U' backward-kill-line
    '^Y' yank  '\ey' yank-pop
    '^T' transpose-chars  '\et' transpose-words
    '\eu' upcase-word  '\ec' capitalize-word
    '^Z' undo  '^_' undo  '\e/' redo
    '^L' clear-screen
  )
  for k in ${(k)map}; do bindkey -M fishy "$k" fishy-$map[$k]; done
  bindkey -M fishy '\e[A' fishy-up-or-search  '\eOA' fishy-up-or-search  '^P' fishy-up-or-search
  bindkey -M fishy '\e[B' fishy-down-or-search '\eOB' fishy-down-or-search '^N' fishy-down-or-search
  bindkey -M fishy '^@' fishy-ctrl-space
  bindkey -M fishy '\e^M' fishy-newline  '\e^J' fishy-newline
  bindkey -M fishy '\e[200~' fishy-bracketed-paste
  bindkey -A fishy main
}
