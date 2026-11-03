# fishy paste: fish's bracketed-paste handling (share/functions/__fish_paste.fish).
# Placeholder that inserts the text as a single edit; the exact transformation
# rules are ported in a later pass (see spec MI-* paste behaviors).

fishy-paste() {
  local text=$1
  [[ -n $text ]] || return
  fishy-push-edit $CURSOR $CURSOR "$text"
  _fishy_transient='' _fs_suppress=0
  fishy-pager-clear
  fishy-hsearch-reset
  _fishy_last_cmd=''
  fishy-suggest-update
}
