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

# Fetch all faces in one request. Called once the server is up.
fishy-theme-load() {
  emulate -L zsh
  local -a keys=(${(ok)_fishy_face_roles}) args=()
  local k
  for k in $keys; do args+=(${=_fishy_face_roles[$k]}); done
  fishy-call sync face "${args[@]}" || return 1
  local -i i=1
  for k in $keys; do
    _fishy_face[$k]=${fishy_reply[i]#F$'\x1f'}
    (( i++ ))
  done
}
