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
# Printable keys whose binding is not plain self-insert (from the binding
# table, see fishy-keys-install): "e" self-insert expand-abbr, "o" anything
# else (they end a batch).
typeset -gA _fishy_print_bind
_fishy_is_self_insert_key() {
  local k=$1
  [[ ${#k} == 1 ]] || return 1
  [[ $k == [[:print:]] || $k == [^[:ascii:]] ]] || return 1
  [[ ${_fishy_print_bind[$k]} != o ]]
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
    if [[ ${_fishy_print_bind[$k]} == e ]]; then
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
    [[ ${_fishy_print_bind[$k]} == e ]] && _fishy_run expand-abbr
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

# shift-space: insert a space, then expand-abbr.
_fishy_w_shift_space() {
  fishy-unswap
  _fishy_insert ' '
  _fishy_run expand-abbr
}
zle -N fishy-shift-space _fishy_w_shift_space

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

# fish 4.9.3's preset bindings for the default (emacs) mode, in the order
# `bind` lists them (fish_default_key_bindings + __fish_shared_key_bindings;
# TERM=xterm-ghostty, so no conemu clipboard binding). -s: fish code rather
# than readline functions.
fishy-bind ctrl-y fishy-yank
fishy-bind alt-y fishy-yank-pop
fishy-bind right fishy-forward-char
fishy-bind left fishy-backward-char
fishy-bind ctrl-right fishy-forward-token
fishy-bind ctrl-left fishy-backward-token
fishy-bind pageup fishy-beginning-of-history
fishy-bind pagedown fishy-end-of-history
fishy-bind -s ctrl-x fishy-clipboard-copy
fishy-bind -s ctrl-v fishy-clipboard-paste
fishy-bind escape fishy-cancel
fishy-bind 'ctrl-[' fishy-cancel
fishy-bind tab fishy-complete
fishy-bind ctrl-i fishy-complete
fishy-bind ctrl-s fishy-pager-toggle-search
fishy-bind shift-tab fishy-complete-and-search
fishy-bind shift-delete fishy-shift-delete
fishy-bind down fishy-down-or-search
fishy-bind up fishy-up-or-search
fishy-bind shift-right fishy-forward-bigword
fishy-bind shift-left fishy-backward-bigword
fishy-bind alt-b fishy-prevd-or-backward-word
fishy-bind alt-f fishy-nextd-or-forward-word
fishy-bind alt-right fishy-nextd-or-forward-word
fishy-bind $'\e[1;9C' fishy-nextd-or-forward-word
fishy-bind alt-left fishy-prevd-or-backward-word
fishy-bind $'\e[1;9D' fishy-prevd-or-backward-word
fishy-bind alt-up fishy-history-token-search-backward
fishy-bind alt-down fishy-history-token-search-forward
fishy-bind $'\e[1;9A' fishy-history-token-search-backward
fishy-bind $'\e[1;9B' fishy-history-token-search-forward
fishy-bind alt-. fishy-history-token-search-backward
fishy-bind -s alt-l fishy-list-token
fishy-bind -s alt-o fishy-preview
fishy-bind -s alt-w fishy-whatis
fishy-bind -s ctrl-l fishy-ctrl-l
fishy-bind ctrl-c fishy-ctrl-c
fishy-bind ctrl-u fishy-backward-kill-line
fishy-bind ctrl-k fishy-kill-line
fishy-bind ctrl-w fishy-backward-kill-path-component
fishy-bind end fishy-end-of-line
fishy-bind home fishy-beginning-of-line
fishy-bind -s alt-d fishy-alt-d
fishy-bind ctrl-d fishy-delete-or-exit
fishy-bind -s alt-s fishy-prepend-sudo
fishy-bind -s f1 fishy-man-page
fishy-bind -s alt-h fishy-man-page
fishy-bind -s alt-p fishy-paginate
fishy-bind -s 'alt-#' fishy-toggle-comment
fishy-bind -s alt-e fishy-edit-command-buffer
fishy-bind -s alt-v fishy-edit-command-buffer
fishy-bind '' @self-insert
fishy-bind space @self-insert-expand
fishy-bind ';' @self-insert-expand
fishy-bind '|' @self-insert-expand
fishy-bind '&' @self-insert-expand
fishy-bind '>' @self-insert-expand
fishy-bind '<' @self-insert-expand
fishy-bind -s shift-enter fishy-newline
fishy-bind -s alt-enter fishy-newline
fishy-bind ')' @self-insert-expand
fishy-bind -s ctrl-space fishy-ctrl-space
fishy-bind -s shift-space fishy-shift-space
fishy-bind enter fishy-execute
fishy-bind ctrl-j fishy-execute
fishy-bind ctrl-m fishy-execute
fishy-bind ctrl-enter fishy-execute
fishy-bind delete fishy-delete-char
fishy-bind backspace fishy-backward-delete-char
fishy-bind shift-backspace fishy-backward-delete-char
fishy-bind ctrl-a fishy-beginning-of-line
fishy-bind ctrl-e fishy-end-of-line
fishy-bind ctrl-h fishy-backward-delete-char
fishy-bind ctrl-p fishy-up-or-search
fishy-bind ctrl-n fishy-down-or-search
fishy-bind ctrl-f fishy-forward-char
fishy-bind ctrl-b fishy-backward-char
fishy-bind ctrl-t fishy-transpose-chars
fishy-bind ctrl-g fishy-cancel
fishy-bind ctrl-/ fishy-undo
fishy-bind ctrl-_ fishy-undo
fishy-bind ctrl-z fishy-undo
fishy-bind ctrl-shift-z fishy-redo
fishy-bind alt-/ fishy-redo
fishy-bind alt-t fishy-transpose-words
fishy-bind alt-u fishy-upcase-word
fishy-bind alt-c fishy-capitalize-word
fishy-bind alt-backspace fishy-backward-kill-word
fishy-bind ctrl-alt-h fishy-backward-kill-word
fishy-bind ctrl-backspace fishy-backward-kill-token
fishy-bind alt-delete fishy-kill-word
fishy-bind ctrl-delete fishy-kill-token
fishy-bind 'alt-<' fishy-beginning-of-buffer
fishy-bind 'alt->' fishy-end-of-buffer
# (ctrl-r history-pager: fishy has no history pager; darin's atuin binds it.)

# The zle keymap only routes bytes (input.zsh): control characters, DEL and
# ESC go to fish's decoder, printable text to self-insert -- or, for printable
# keys with a binding of their own, to that binding's widget.
fishy-keys-install() {
  emulate -L zsh
  _fishy_binds_compile
  bindkey -N fishy                 # fresh keymap, nothing inherited
  bindkey -M fishy -R ' '-'~' fishy-self-insert
  bindkey -M fishy -R '\M-^@'-'\M-^?' fishy-self-insert
  bindkey -M fishy -R '^@'-'^_' fishy-key
  bindkey -M fishy '^?' fishy-key

  # The binding fish picks for an unmodified printable key (find_binding on
  # that one key event), for each key some binding could match.
  _fishy_print_bind=()
  local -A cand
  local -i i n=${#_fkb_style} m c
  local k
  for (( i = 1; i <= n; i++ )); do
    [[ $_fkb_style[i] == G ]] && continue
    k=${_fkb_keys[i]%% *}       # the first key
    m=${k%%:*} c=${k#*:}
    (( c == _FK_SPACE )) && c=32
    (( m & ~_FK_SHIFT )) && continue
    (( c >= 32 && c <= 126 )) && cand[${(#)c}]=1
    if (( (m & _FK_SHIFT) && c >= 97 && c <= 122 )); then
      (( c -= 32 ))
      cand[${(#)c}]=1
    fi
  done
  local ch w
  for ch in "${(@k)cand}"; do
    c=$(( #ch ))
    (( c == 32 )) && c=$_FK_SPACE
    _fishy_binds_lookup_key $c || continue
    w=$_fkb_widget[_fb]
    if (( _fpk_wanted )); then
      # A longer binding starts with this key: fish's matcher reads on.
      _fishy_print_bind[$ch]=o
      bindkey -M fishy -- "$ch" fishy-key
    elif [[ $_fkb_style[_fb] == G || $w == @self-insert ]]; then
      continue
    elif [[ $w == @self-insert-expand ]]; then
      _fishy_print_bind[$ch]=e
      bindkey -M fishy -- "$ch" fishy-self-insert-expand
    else
      _fishy_print_bind[$ch]=o
      if [[ $_fkb_keys[_fb] == *' '* || $_fkb_style[_fb] == R ]]; then
        bindkey -M fishy -- "$ch" fishy-key
      elif [[ $_fkb_flags[_fb] == *s* ]]; then
        zle -N fishy-script-$w _fishy_w_script_key
        bindkey -M fishy -- "$ch" fishy-script-$w
      else
        bindkey -M fishy -- "$ch" $w
      fi
    fi
  done
  bindkey -A fishy main
}
