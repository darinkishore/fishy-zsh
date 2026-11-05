# fishy paste: fish's bracketed paste.
#
# fish's input layer turns a paste into three events (src/reader/input.rs
# paste_start_buffering / paste_commit):
#   begin-undo-group            readline command
#   __fish_paste DATA           a command (share/functions/__fish_paste.fish)
#   end-undo-group              readline command
# __fish_paste itself runs in the server (`__fishy paste`: fish's function line
# for line, with zsh's quoting where fish would write fish syntax); its
# `commandline` edit is applied here the way the reader applies one
# (apply_commandline_state_changes).

_fishy_cmd_begin-undo-group() {
  fishy-search-focused && return   # fishy's search field keeps no undo history
  fishy-editline-begin-group
}
_fishy_cmd_end-undo-group() {
  fishy-search-focused && return
  fishy-editline-end-group
}

fishy-paste() {
  _fishy_run begin-undo-group
  _fishy_paste_apply "$1"
  _fishy_run end-undo-group
}

# __fish_paste DATA: fish's function in the server, its edit applied here.
_fishy_paste_apply() {
  local text=$1
  # The request is NUL-terminated with \x1f/\x1e framing, so control
  # characters can't travel in it. __fish_paste deletes every one of them
  # except \r and \n (which split lines) anyway, so drop them first.
  text=${text//[$'\x00'-$'\x09'$'\x0b'$'\x0c'$'\x0e'-$'\x1f'$'\x7f']/}

  fishy-call sync paste $_fp_search_shown $CURSOR "$BUFFER" "$text" || return
  local -a f=("${(@ps:\x1f:)fishy_reply[1]}")
  case $f[1] in
    (S)
      # commandline --search-field -i: the search field's cursor is at its end.
      _fp_search_text+=$f[2]
      fishy-pager-refilter
      fishy-pager-selection-changed
      ;;
    (B) _fishy_commandline_change "$f[2]" $f[3] ;;
  esac
}
