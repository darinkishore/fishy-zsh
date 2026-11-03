# fishy pager: a line-by-line port of fish's completion pager (src/pager.rs).
#
# State mirrors fish's Pager; rendering produces plain lines plus highlight
# spans (column ranges with a role key resolved via the theme), which the
# reader turns into POSTDISPLAY + region_highlight.

typeset -gi FISHY_PAGER_SPACER=2            # PAGER_SPACER_STRING = "  "
typeset -gi FISHY_PAGER_UNDISCLOSED_MAX_ROWS=4
typeset -gi FISHY_PAGER_MIN_WIDTH=16 FISHY_PAGER_MIN_HEIGHT=4
typeset -gi FISHY_PAGER_MAX_COLS=6 FISHY_PAGER_SEARCH_FIELD_WIDTH=12
typeset -g  FISHY_ELLIPSIS=$'…'

# Unfiltered completion infos (PagerComp), 1-based parallel arrays.
typeset -ga _fp_u_comp _fp_u_desc _fp_u_raw _fp_u_flags _fp_u_cw _fp_u_dw _fp_u_show
# Filtered view: indices into the unfiltered arrays.
typeset -ga _fp_idx
typeset -g  _fp_prefix=''
typeset -gi _fp_highlight_prefix=0
typeset -gi _fp_selected=-1 _fp_suggested_row_start=0 _fp_fully_disclosed=0
typeset -gi _fp_search_shown=0
typeset -g  _fp_search_text='' _fp_extra_progress=''
typeset -gi _fp_term_w=0 _fp_term_h=0
# Current rendering (PageRendering).
typeset -gi _fpr_rows=0 _fpr_cols=0 _fpr_row_start=0 _fpr_row_end=0 _fpr_remaining=0
typeset -gi _fpr_selected=-1 _fpr_term_w=0 _fpr_term_h=0
typeset -ga _fpr_lines _fpr_spans   # spans: "LINE START END ROLEKEY" (0-based, half-open)

fishy-pager-is-empty() { (( ${#_fp_u_comp} == 0 )) }
fishy-pager-navigating() { (( _fp_selected >= 0 )) }

# fish: Pager::clear (+ ReaderData::clear_pager's search field reset).
fishy-pager-clear() {
  _fp_u_comp=() _fp_u_desc=() _fp_u_raw=() _fp_u_flags=() _fp_u_cw=() _fp_u_dw=() _fp_u_show=()
  _fp_idx=() _fp_prefix='' _fp_highlight_prefix=0 _fp_selected=-1 _fp_fully_disclosed=0
  _fp_search_shown=0 _fp_search_text='' _fp_extra_progress=''
  _fp_suggested_row_start=0
  _fpr_lines=() _fpr_spans=() _fpr_rows=0 _fpr_cols=0 _fpr_row_start=0 _fpr_row_end=0
  _fpr_remaining=0 _fpr_selected=-1
  _fishy_transient=''
}

# fish: escape_string(Script{no_printables, no_quoted, symbolic}) for display.
_fp_display() {
  local s=$1 out='' c
  local -i i code
  for (( i = 1; i <= ${#s}; i++ )); do
    c=$s[i]
    case $c in
      $'\t') out+=$'␉' ;;
      $'\n') out+=$'␤' ;;
      $'\b') out+=$'␈' ;;
      $'\r') out+=$'␍' ;;
      $'\e') out+=$'␛' ;;
      $'\x7f') out+=$'␡' ;;
      [$'\x01'-$'\x19']) code=$(( #c )); out+=${(#)$(( 0x2400 + code ))} ;;
      *) out+=$c ;;
    esac
  done
  REPLY=$out
}

# fish: mangle_1_completion_description
_fp_mangle_desc() {
  emulate -L zsh -o extendedglob
  local s=$1
  s=${s##[[:space:]]#}
  s=${s%%[[:space:]]#}
  s=${s//[[:space:]]##/ }
  REPLY=$s
}

# fish: set_completions(raw, enable_refilter=true). Arguments come in groups
# of four: RAW DESC FLAGS SHOW_PREFIX(0/1).
fishy-pager-set-completions() {
  _fp_selected=-1
  _fp_u_comp=() _fp_u_desc=() _fp_u_raw=() _fp_u_flags=() _fp_u_cw=() _fp_u_dw=() _fp_u_show=()
  while (( $# >= 4 )); do
    _fp_display "$1"; _fp_u_comp+=("$REPLY")
    _fp_mangle_desc "$2"; _fp_u_desc+=("$REPLY")
    _fp_u_raw+=("$1") _fp_u_flags+=("$3") _fp_u_show+=($4)
    shift 4
  done
  # fish: join_completions only when the prefix is exactly "-".
  if [[ $_fp_prefix == - ]]; then
    local -A first
    local -a keep=()
    local -i i
    for (( i = 1; i <= ${#_fp_u_comp}; i++ )); do
      local d=$_fp_u_desc[i]
      if [[ -z $d ]]; then keep+=($i); continue; fi
      if [[ -z ${first[$d]} ]]; then
        first[$d]=$i; keep+=($i)
      else
        local -i j=$first[$d]
        _fp_u_comp[j]+=$'\x1e'$_fp_u_comp[i]
      fi
    done
    local -a c=() d=() r=() f=() s=()
    for i in $keep; do
      c+=("$_fp_u_comp[i]") d+=("$_fp_u_desc[i]") r+=("$_fp_u_raw[i]") f+=("$_fp_u_flags[i]") s+=($_fp_u_show[i])
    done
    _fp_u_comp=("$c[@]") _fp_u_desc=("$d[@]") _fp_u_raw=("$r[@]") _fp_u_flags=("$f[@]") _fp_u_show=("$s[@]")
  fi
  # fish: measure_completion_infos
  local -i prefix_len=${(m)#_fp_prefix} i
  for (( i = 1; i <= ${#_fp_u_comp}; i++ )); do
    local -a strs=("${(@ps:\x1e:)_fp_u_comp[i]}")
    local -i w=0 j=0
    local str=""
    for str in "$strs[@]"; do
      (( j >= 1 )) && (( w += 2 ))
      (( _fp_u_show[i] )) && (( w += prefix_len ))
      (( w += ${(m)#str} ))
      (( j++ ))
    done
    _fp_u_cw[i]=$w
    _fp_u_dw[i]=${(m)#_fp_u_desc[i]}
  done
  fishy-pager-refilter
}

# fish: completion_info_passes_filter + refilter_completions. The fuzzy
# matching is fish's own (string_fuzzy_match_string), evaluated by the server.
fishy-pager-refilter() {
  _fp_idx=()
  local -i i
  if (( ! _fp_search_shown )) || [[ -z $_fp_search_text ]]; then
    for (( i = 1; i <= ${#_fp_u_comp}; i++ )); do _fp_idx+=($i); done
    return
  fi
  local -a args=()
  for (( i = 1; i <= ${#_fp_u_comp}; i++ )); do
    args+=("$_fp_u_desc[i]" "$_fp_u_comp[i]")
  done
  fishy-call sync pager-filter "$_fp_search_text" "$_fp_prefix" "${args[@]}" || return
  local rec
  for rec in "$fishy_reply[@]"; do
    _fp_idx+=($(( ${rec#M$'\x1f'} + 1 )))
  done
}

# fish: visual_selected_completion_index
_fp_visual_selected() {
  local -i rows=$1 cols=$2 n=${#_fp_idx} r=$_fp_selected
  REPLY=-1
  (( n == 0 )) && return
  (( r == 0 )) && { REPLY=0; return }
  (( rows == 0 || cols == 0 )) && return
  (( r < 0 )) && return
  while (( r >= n && r >= rows )); do (( r -= rows )); done
  (( r >= n )) && r=$(( n - 1 ))
  REPLY=$r
}

_fp_div_up() { local -i a=$1 b=$2; (( a == 0 )) && { REPLY=0; return }; REPLY=$(( a / b + (a % b != 0) )) }

# fish: print_max_impl. Appends to the current line buffer _fpl (text) and
# records spans with role key $3. Returns consumed width in REPLY.
typeset -g _fpl=''
typeset -gi _fpl_line=0
_fp_print_max() {
  local s=$1 key=$2
  local -i max=$3 has_more=$4 remaining=$3 i width
  local -i start=${#_fpl}
  local c
  for (( i = 1; i <= ${#s}; i++ )); do
    c=$s[i]
    width=${(m)#c}
    (( width > remaining )) && break
    if (( width == remaining )) && (( has_more || i < ${#s} )); then
      _fpl+=$FISHY_ELLIPSIS
      (( remaining -= 1 ))
      break
    fi
    _fpl+=$c
    (( remaining -= width ))
  done
  (( ${#_fpl} > start )) && _fpr_spans+=("$_fpl_line $start ${#_fpl} $key")
  REPLY=$(( max - remaining ))
}

# Role keys: <kind>:<element>, kind in n (normal) s (secondary) x (selected).
# Elements: bg prefix comp desc paren. Resolved in theme.zsh.

# fish: completion_print_item
_fp_print_item() {
  local -i i=$1 cw_col=$2 desc_align=$3 secondary=$4 selected=$5
  local kind=n
  (( secondary )) && kind=s
  (( selected )) && kind=x
  local -i comp_width pref=$(( _fp_u_cw[i] + (_fp_u_dw[i] ? _fp_u_dw[i] + 4 : 0) ))
  local -i dpw=$(( _fp_u_dw[i] ? _fp_u_dw[i] + 4 : 0 ))
  if (( pref <= cw_col )); then
    comp_width=$_fp_u_cw[i]
  else
    local -i wms=$(( cw_col > 4 ? cw_col - 4 : 0 ))
    local -i two_thirds=$(( (wms / 3) * 2 + ((wms % 3) * 2) / 3 ))
    comp_width=$(( _fp_u_cw[i] < two_thirds ? _fp_u_cw[i] : two_thirds ))
    if (( cw_col > dpw )); then
      (( comp_width = comp_width > cw_col - dpw ? comp_width : cw_col - dpw ))
    fi
  fi
  local prefix_key=${kind}:prefix
  (( _fp_highlight_prefix )) || prefix_key=${kind}:comp
  local -i comp_remaining=$comp_width k=0
  local -a strs=("${(@ps:\x1e:)_fp_u_comp[i]}")
  local str=""
  for str in "$strs[@]"; do
    if (( k > 0 )); then
      _fp_print_max "  " ${kind}:bg $comp_remaining 1; (( comp_remaining -= REPLY ))
    fi
    if (( _fp_u_show[i] )); then
      _fp_print_max "$_fp_prefix" $prefix_key $comp_remaining $(( ${#str} > 0 )); (( comp_remaining -= REPLY ))
    fi
    _fp_print_max "$str" ${kind}:comp $comp_remaining $(( k + 1 < ${#strs} )); (( comp_remaining -= REPLY ))
    (( k++ ))
  done
  local -i desc_remaining=$(( cw_col - comp_width + comp_remaining ))
  if (( _fp_u_dw[i] > 0 && desc_remaining > 4 )); then
    _fp_print_max "  " ${kind}:bg $desc_remaining 0; (( desc_remaining -= REPLY ))
    local -i a=$(( cw_col > desc_align ? cw_col - desc_align : 0 )) b=$(( _fp_u_dw[i] + 2 ))
    local -i pad=$(( desc_remaining - (a > b ? a : b) ))
    (( pad < 0 )) && pad=0
    _fp_print_max "${(l:pad:: :)}" ${kind}:bg $desc_remaining 0; (( desc_remaining -= REPLY ))
    local paren_key=n:paren
    (( selected )) && paren_key=x:paren
    (( secondary && ! selected )) && paren_key=s:paren
    _fp_print_max "(" $paren_key 1 0; (( desc_remaining -= REPLY ))
    _fp_print_max "$_fp_u_desc[i]" ${kind}:desc $(( desc_remaining - 1 )) 0; (( desc_remaining -= REPLY ))
    _fp_print_max ")" $paren_key 1 0; (( desc_remaining -= REPLY ))
    _fp_print_max "${(l:desc_remaining:: :)}" ${kind}:bg $desc_remaining 0
  else
    _fp_print_max "${(l:desc_remaining:: :)}" ${kind}:bg $desc_remaining 0
  fi
}

# fish: completion_try_print. Returns 1 if too narrow for col_count columns.
_fp_try_print() {
  local -i col_count=$1 suggested_start_row=$2 n=${#_fp_idx}
  if (( _fp_term_w < FISHY_PAGER_MIN_WIDTH || _fp_term_h < FISHY_PAGER_MIN_HEIGHT )); then
    return 0
  fi
  local -i term_width=$_fp_term_w
  local -i term_height=$(( _fp_term_h - 1 - _fp_search_shown ))
  if (( ! _fp_fully_disclosed )); then
    local -i half=$(( term_height / 2 ))
    (( half < FISHY_PAGER_UNDISCLOSED_MAX_ROWS )) && half=$FISHY_PAGER_UNDISCLOSED_MAX_ROWS
    (( term_height > half )) && term_height=$half
  fi
  _fp_div_up $n $col_count; local -i row_count=$REPLY
  if (( ! _fp_fully_disclosed && row_count > term_height )); then
    _fpr_remaining=$(( row_count - term_height ))
  else
    _fpr_remaining=0
  fi
  if (( _fpr_remaining == 1 )); then
    (( term_height++ ))
    _fpr_remaining=0
  fi
  # Column widths.
  local -a col_w col_align
  local -i c r total=0
  for (( c = 0; c < FISHY_PAGER_MAX_COLS; c++ )); do
    local -i max_comp=0 max_desc=0
    for (( r = 0; r < row_count; r++ )); do
      local -i ci=$(( c * row_count + r ))
      (( ci >= n )) && continue
      local -i ui=$_fp_idx[ci+1]
      (( _fp_u_cw[ui] > max_comp )) && max_comp=$_fp_u_cw[ui]
      local -i dpw=$(( _fp_u_dw[ui] ? _fp_u_dw[ui] + 4 : 0 ))
      (( dpw > max_desc )) && max_desc=$dpw
    done
    local -i w=$(( max_comp + max_desc ))
    (( w > term_width )) && w=$term_width
    col_w+=($w) col_align+=($(( max_comp + 2 )))
    (( total += w ))
  done
  (( total += (col_count - 1) * FISHY_PAGER_SPACER ))
  (( term_width < total )) && return 1

  local -i start_row stop_row
  if (( row_count <= term_height )); then
    start_row=0 stop_row=$row_count
  else
    local -i last_start=$(( row_count - term_height ))
    start_row=$(( suggested_start_row < last_start ? suggested_start_row : last_start ))
    stop_row=$(( start_row + term_height ))
  fi

  # fish: completion_print
  _fpr_row_start=$start_row _fpr_row_end=$stop_row
  _fp_visual_selected $row_count $col_count; local -i eff_sel=$REPLY
  local -i line=0
  for (( r = start_row; r < stop_row; r++ )); do
    _fpl='' _fpl_line=$line
    for (( c = 0; c < col_count; c++ )); do
      local -i idx=$(( c * row_count + r ))
      (( idx >= n )) && continue
      _fp_print_item $_fp_idx[idx+1] $col_w[c+1] $col_align[c+1] $(( r % 2 != 0 )) $(( idx == eff_sel ))
      if (( c + 1 < col_count )); then
        _fp_print_max "  " n:spacer 2 0
      fi
    done
    _fpr_lines+=("$_fpl")
    (( line++ ))
  done

  # Progress line.
  local progress=''
  if (( _fpr_remaining > 1 )); then
    progress="${FISHY_ELLIPSIS}and $_fpr_remaining more rows"
  elif (( start_row > 0 || stop_row < row_count )); then
    progress="rows $(( start_row + 1 )) to $stop_row of $row_count"
  elif (( _fp_search_shown && n == 0 )); then
    progress='(no matches)'
  fi
  if [[ -n $_fp_extra_progress ]]; then
    [[ -n $progress ]] && progress+='. '
    progress+=$_fp_extra_progress
  fi
  if [[ -n $progress ]]; then
    _fpl='' _fpl_line=$line
    _fp_print_max "$progress" progress $term_width 1
    _fpr_lines+=("$_fpl")
    (( line++ ))
  fi

  (( _fp_search_shown )) || return 0
  # Search field: inserted as line 0, shifting everything down.
  local field=$_fp_search_text
  (( ${#field} < FISHY_PAGER_SEARCH_FIELD_WIDTH )) && field+=${(l:FISHY_PAGER_SEARCH_FIELD_WIDTH-${#field}:: :)}
  local -a shifted=()
  local sp
  for sp in "$_fpr_spans[@]"; do
    local -a p=(${=sp})
    shifted+=("$(( p[1] + 1 )) $p[2] $p[3] $p[4]")
  done
  _fpr_spans=("$shifted[@]")
  _fpl='' _fpl_line=0
  local -i remaining=$(( term_width - 1 ))
  _fp_print_max "search: " n:plain $remaining 0; (( remaining -= REPLY ))
  _fp_print_max "$field" search $remaining 0
  _fpr_lines=("$_fpl" "$_fpr_lines[@]")
  return 0
}

# fish: Pager::render. TERM_W TERM_H are the available pager size.
fishy-pager-render() {
  _fp_term_w=$1 _fp_term_h=$2
  _fpr_term_w=$1 _fpr_term_h=$2
  local -i cols n=${#_fp_idx}
  for (( cols = FISHY_PAGER_MAX_COLS; cols >= 1; cols-- )); do
    _fpr_lines=() _fpr_spans=()
    _fp_div_up $n $cols; local -i min_rows=$REPLY
    _fp_div_up $n $min_rows; local -i min_cols=$REPLY
    (( n == 0 )) && min_cols=0
    if (( cols > 1 && min_cols < cols )); then continue; fi
    _fpr_cols=$cols _fpr_rows=$min_rows
    _fp_visual_selected $_fpr_rows $_fpr_cols; _fpr_selected=$REPLY
    _fp_try_print $cols $_fp_suggested_row_start && break
  done
}

# fish: select_next_completion_in_direction. DIR: north east south west
# page-north page-south next prev deselect. Returns 0 if selection changed.
fishy-pager-select() {
  local dir=$1
  local -i n=${#_fp_idx}
  (( n == 0 )) && return 1
  if (( _fp_selected < 0 )); then
    case $dir in
      south|page-south|next) _fp_selected=0 ;;
      north|prev) _fp_selected=$(( n - 1 )) ;;
      *) return 1 ;;
    esac
  else
    local -i old=$_fp_selected new
    case $dir in
      deselect) new=-1 ;;
      next) new=$(( old + 1 >= n ? 0 : old + 1 )) ;;
      prev) new=$(( old == 0 ? n - 1 : old - 1 )) ;;
      *)
        local -i rows=$_fpr_rows cols=$_fpr_cols row col
        if (( rows == 0 )); then row=-1 col=-1
        else row=$(( _fpr_selected % rows )) col=$(( _fpr_selected / rows )); fi
        local -i page=$(( _fpr_term_h - 1 > 1 ? _fpr_term_h - 1 : 1 ))
        case $dir in
          page-north) (( row > page )) && (( row -= page )) || row=0 ;;
          north)
            if (( row > 0 )); then (( row-- ))
            else row=$(( rows - 1 )); (( col > 0 )) && (( col-- )) || col=$(( cols - 1 )); fi ;;
          page-south)
            if (( row + page < rows )); then (( row += page ))
            else
              row=$(( rows - 1 ))
              (( col * rows + row >= n )) && row=$(( (n - 1) % rows ))
            fi ;;
          south)
            if (( row + 1 < rows && col * rows + row + 1 < n )); then (( row++ ))
            else row=0; col=$(( (col + 1) % cols )); fi ;;
          east)
            if (( col + 1 < cols && (col + 1) * rows + row < n )); then (( col++ ))
            else col=0; row=$(( (row + 1) % rows )); fi ;;
          west)
            if (( col > 0 )); then (( col-- ))
            else col=$(( cols - 1 )); (( row > 0 )) && (( row-- )) || row=$(( rows - 1 )); fi ;;
        esac
        new=$(( col * rows + row ))
        ;;
    esac
    (( new == old )) && return 1
    _fp_selected=$new
  fi
  # Keep the selection visible.
  local -i visible=$(( _fpr_row_end - _fpr_row_start ))
  (( visible == 0 )) && return 0
  (( _fp_selected < 0 )) && return 0
  local -i sel_row=$(( _fpr_rows ? _fp_selected % _fpr_rows : -1 ))
  (( _fp_suggested_row_start > sel_row )) && _fp_suggested_row_start=$sel_row
  if (( _fp_suggested_row_start + visible <= sel_row )); then
    if [[ $dir == (south|east) ]] && (( ! _fp_fully_disclosed && _fpr_remaining > 0 )); then
      _fp_fully_disclosed=1
    else
      _fp_suggested_row_start=$(( sel_row - visible + 1 ))
      _fp_fully_disclosed=1
    fi
  fi
  return 0
}

# fish: Pager::selected_completion (visual index) -> REPLY = unfiltered index or -1
fishy-pager-selected() {
  _fp_visual_selected $_fpr_rows $_fpr_cols
  if (( REPLY < 0 )); then REPLY=-1; return 1; fi
  REPLY=$_fp_idx[REPLY+1]
}

# fish: active_edit_line_tag() == SearchField, i.e. the search field is shown
# and the pager is navigating (an index is selected, even if filtered away).
fishy-search-focused() { (( _fp_search_shown && _fp_selected >= 0 )) }
