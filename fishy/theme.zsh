# fishy theme: every color comes from fish's own resolver (HighlightColorResolver)
# via the server, so fish_color_* / fish_pager_color_* (universal variables,
# themes, fallbacks) apply exactly as in fish.

typeset -gA _fishy_face

# key -> "FG_ROLE BG_ROLE VALID_PATH FORCE_UNDERLINE"
typeset -gA _fishy_face_roles=(
  autosuggestion     'autosuggestion normal 0 0'
  search_match       'search_match search_match 0 0'
  selection          'selection selection 0 0'
  progress           'pager_progress pager_progress 0 0'
  search             'normal normal 0 1'
  n:plain            'normal normal 0 0'
  n:spacer           'normal normal 0 0'
  n:prefix           'pager_prefix pager_background 0 0'
  n:comp             'pager_completion pager_background 0 0'
  n:desc             'pager_description pager_background 0 0'
  n:bg               'normal pager_background 0 0'
  n:paren            'pager_completion pager_background 0 0'
  s:prefix           'pager_secondary_prefix pager_secondary_background 0 0'
  s:comp             'pager_secondary_completion pager_secondary_background 0 0'
  s:desc             'pager_secondary_description pager_secondary_background 0 0'
  s:bg               'normal pager_secondary_background 0 0'
  s:paren            'pager_completion pager_secondary_background 0 0'
  x:prefix           'pager_selected_prefix pager_selected_background 0 0'
  x:comp             'pager_selected_completion pager_selected_background 0 0'
  x:desc             'pager_selected_description pager_selected_background 0 0'
  x:bg               'normal pager_selected_background 0 0'
  x:paren            'pager_selected_completion pager_selected_background 0 0'
  # When the pager prefix is not highlighted it uses the completion role.
  # (Keys n:comp etc. cover that case.)
)

# zle highlight attributes this zsh understands. zsh 5.9.x knows only bold,
# standout and underline; italic and faint arrived on zsh master (51280) and
# an unknown attribute invalidates the whole spec, so drop what is missing.
typeset -ga _fishy_zattrs
# Must run inside zle: zsh re-renders region_highlight entries from what it
# parsed, so an attribute survives the round trip only if zle supports it.
_fishy_probe_zattrs() {
  _fishy_zattrs=(bold standout underline)
  local -a saved=("$region_highlight[@]")
  local a
  for a in italic faint; do
    region_highlight=("0 0 $a")
    [[ ${region_highlight[1]} == *$a* ]] && _fishy_zattrs+=($a)
  done
  region_highlight=("$saved[@]")
}

# Strip attributes zle cannot render from a resolved fish face.
_fishy_face_sanitize() {
  local -a parts=(${(s:,:)1}) keep=()
  local p
  for p in $parts; do
    case $p in
      fg=*|bg=*|none) keep+=($p) ;;
      *) (( ${_fishy_zattrs[(Ie)$p]} )) && keep+=($p) ;;
    esac
  done
  (( ${#keep} )) || keep=(none)
  REPLY=${(j:,:)keep}
}

# Fetch all faces in one request. Called once the server is up.
fishy-theme-load() {
  emulate -L zsh
  local -a keys=(${(ok)_fishy_face_roles}) args=()
  local k
  for k in $keys; do args+=(${=_fishy_face_roles[$k]}); done
  fishy-call sync face "${args[@]}" || return 1
  (( ${#_fishy_zattrs} )) || _fishy_probe_zattrs
  local -i i=1
  for k in $keys; do
    _fishy_face_sanitize "${fishy_reply[i]#F$'\x1f'}"
    _fishy_face[$k]=$REPLY
    (( i++ ))
  done
}
