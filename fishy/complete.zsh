# fishy complete: fish's Tab logic (src/reader/reader.rs compute_and_apply_completions,
# handle_completions, try_insert, completion_insert, pager_selection_changed).
#
# Completion candidates, their flags and the insertion itself (with zsh
# quoting) come from the fish server; the decisions in between are ported here.

typeset -gi FISHY_PREFIX_MAX_LEN=9
typeset -g  _fishy_cycle_line=''
typeset -gi _fishy_cycle_cursor=0
typeset -g  _fishy_completion_action=''   # '' | unique | ambiguous
typeset -g  _fishy_transient=''           # '' | pager | history

# zsh options that change which characters need escaping.
_fishy_zopts() {
  REPLY=''
  [[ -o extendedglob ]] && REPLY+=e
  [[ -o banghist ]] && REPLY+=h
}

# fish: completion_apply_to_command_line (zsh quoting) -> REPLY=new line, REPLY_CURSOR
_fishy_apply() {
  local val=$1 flags=$2 line=$5
  local -i cursor=$3 append_only=$4 unique=$6
  _fishy_zopts
  fishy-call sync apply "$REPLY" "$val" "$flags" $cursor $append_only $unique "$line" || return 1
  local -a f=("${(@ps:\x1f:)fishy_reply[1]}")
  REPLY=$f[2] REPLY_CURSOR=$f[3]
}

# fish: ReaderData::set_buffer_maintaining_pager
_fishy_set_buffer_maintaining_pager() {
  local new=$1
  local -i pos=$2
  fishy-push-edit 0 ${#BUFFER} "$new"
  CURSOR=$(( pos < ${#new} ? pos : ${#new} ))
  fishy-hsearch-reset
}

# fish: completion_insert(val, token_end, flags, is_unique)
_fishy_completion_insert() {
  local val=$1 flags=$3
  local -i token_end=$2 unique=$4
  (( CURSOR != token_end )) && CURSOR=$token_end
  _fishy_apply "$val" "$flags" $CURSOR 0 "$BUFFER" $unique || return 1
  _fishy_set_buffer_maintaining_pager "$REPLY" $REPLY_CURSOR
}

# fish: reader_can_replace
_fishy_can_replace() {
  local tok=$1 flags=$2
  [[ ${flags[3]} == n ]] && return 0
  [[ $tok != *[\$\*\?\(\{\}\)]* ]]
}

# fish: ReaderData::pager_selection_changed
fishy-pager-selection-changed() {
  local -i cursor=$_fishy_cycle_cursor
  if [[ $_fishy_transient == pager ]]; then
    _fishy_transient=''
    _fishy_undo_internal
  fi
  _fishy_transient=''
  if fishy-pager-selected; then
    local -i ui=$REPLY
    _fishy_apply "$_fp_u_raw[ui]" "$_fp_u_flags[ui]" $cursor 0 "$_fishy_cycle_line" 0 || return
    local new=$REPLY
    if [[ $new != "$BUFFER" && $new != "$_fishy_cycle_line" ]]; then
      _fishy_set_buffer_maintaining_pager "$new" $REPLY_CURSOR
      _fishy_transient=pager
    fi
  fi
}

# fish: select_completion_in_direction(dir, force)
fishy-select-completion() {
  local dir=$1
  local -i force=${2:-0}
  # Render first so the selection motion sees the current layout.
  _fishy_render_pager
  if fishy-pager-select $dir || (( force )); then
    fishy-pager-selection-changed
  fi
}

# fish: compute_and_apply_completions(c) with c = complete | complete-and-search
fishy-compute-and-apply-completions() {
  local cmd=$1
  # Remove a trailing backslash (is_backslashed at the cursor).
  local before=${BUFFER[1,CURSOR]}
  local bs=${before##*[^\\]}
  [[ $before == \\## ]] && bs=$before
  if (( ${#bs} % 2 == 1 )); then
    fishy-push-edit $(( CURSOR - 1 )) $CURSOR ''
  fi

  fishy-call sync complete $CURSOR "$BUFFER" || return
  local -a recs=("$fishy_reply[@]")
  local -a t=("${(@ps:\x1f:)recs[1]}")
  local -i tok_start=$t[2] tok_end=$t[3]
  local kind=${recs[2]%%$'\x1f'*}
  if [[ $kind == W ]]; then
    # Wildcard expanded in place: replace the token, no completion action.
    _fishy_completion_action=''
    fishy-push-edit $tok_start $tok_end "${recs[2]#W$'\x1f'}"
    return
  fi
  if [[ $kind == F ]]; then
    fishy-flash $tok_start $tok_end
    return
  fi

  _fishy_cycle_line=$BUFFER
  _fishy_cycle_cursor=$tok_end
  local -a raw desc flags match rank
  local rec
  for rec in "${(@)recs[2,-1]}"; do
    local -a f=("${(@ps:\x1f:)rec}")
    [[ $f[1] == C ]] || continue
    raw+=("$f[2]") desc+=("$f[4]") flags+=("$f[5]") match+=("$f[6]") rank+=($f[7])
  done
  local -i inserted_unique=0
  _fishy_handle_completions $tok_start $tok_end && inserted_unique=1
  if (( inserted_unique )); then
    _fishy_completion_action=unique
  elif ! fishy-pager-is-empty; then
    _fishy_completion_action=ambiguous
  else
    _fishy_completion_action=''
  fi
  if [[ $cmd == complete-and-search ]] && (( ! inserted_unique )) && ! fishy-pager-is-empty; then
    _fp_search_shown=1
    fishy-select-completion next
  fi
}

# fish: handle_completions. Uses arrays raw/desc/flags/match/rank from the caller.
# Returns 0 if a unique completion was inserted.
_fishy_handle_completions() {
  local -i tok_start=$1 tok_end=$2 i n=${#raw}
  local tok=${BUFFER[tok_start+1,tok_end]}

  # Keep only the best rank.
  local -i best=999999
  for (( i = 1; i <= n; i++ )); do (( rank[i] < best )) && best=$rank[i]; done
  local -a keep=()
  for (( i = 1; i <= n; i++ )); do (( rank[i] == best )) && keep+=($i); done

  # will_replace_token: every best-rank candidate replaces the token.
  local -i will_replace=1
  for i in $keep; do [[ ${flags[i][1]} == [Tt] ]] || will_replace=0; done

  local -a surv=()
  for i in $keep; do
    if [[ ${flags[i][1]} == [Tt] ]] && ! _fishy_can_replace "$tok" "$flags[i]"; then continue; fi
    surv+=($i)
  done
  if (( ! will_replace )); then
    for i in $surv; do
      [[ ${flags[i][1]} == [Tt] ]] && flags[i]="t${flags[i][2,-1]}"
    done
  fi

  local -i len=${#surv}
  if (( len == 0 )); then
    if (( tok_start == tok_end )); then fishy-flash 0 ${#BUFFER}; else fishy-flash $tok_start $tok_end; fi
    return 1
  fi
  if (( len == 1 )); then
    i=$surv[1]
    # fish: try_insert
    if [[ ${flags[i][1]} != [Tt] ]] || _fishy_can_replace "$tok" "$flags[i]"; then
      _fishy_completion_insert "$raw[i]" $tok_end "$flags[i]" 1
    fi
    return 0
  fi

  # Common prefix among candidates that want the pager prefix.
  local -i use_prefix=0 all_exact_or_prefix=1 first=1
  local common='' cflags=''
  for i in $surv; do [[ ${match[i][1]} == [xp] ]] || all_exact_or_prefix=0; done
  if (( all_exact_or_prefix )); then
    for i in $surv; do
      [[ ${flags[i][1]} == t ]] && continue   # wants_pager_prefix() is false
      if (( first )); then
        common=$raw[i] cflags=$flags[i] first=0
      else
        local -i max=$(( ${#common} < ${#raw[i]} ? ${#common} : ${#raw[i]} )) k=0
        while (( k < max )) && [[ ${common[k+1]} == "${raw[i][k+1]}" ]]; do (( k++ )); done
        common=${common[1,k]}
        (( k == 0 )) && break
      fi
    done
    local -i need=$(( will_replace ? ${#tok} : 0 ))
    (( ${#common} > need )) && use_prefix=1
    if (( use_prefix )); then
      # More than one completion contributed: no suffix.
      cflags="${cflags[1]}n${cflags[3,-1]}"
      _fishy_completion_insert "$common" $tok_end "$cflags" 0
      _fishy_cycle_line=$BUFFER
      _fishy_cycle_cursor=$CURSOR
    fi
  fi

  # Pager prefix.
  local prefix=''
  if ! (( will_replace && ! use_prefix )); then
    local full
    if (( will_replace )); then full=$common; else full=$tok$common; fi
    if (( ${#full} <= FISHY_PREFIX_MAX_LEN )); then
      prefix=$full
    else
      local truncated=${full[-FISHY_PREFIX_MAX_LEN,-1]}
      if [[ $truncated == */* ]]; then
        prefix=$FISHY_ELLIPSIS/${truncated##*/}
      else
        prefix=$FISHY_ELLIPSIS$truncated
      fi
    fi
  fi

  local -a pager_args=()
  local -i clen=${#common}
  for i in $surv; do
    local r=$raw[i] fl=$flags[i]
    local -i show=1
    [[ ${fl[1]} == t ]] && show=0
    if (( use_prefix && show )); then
      fl="n${fl[2,-1]}"
      r=${r[clen+1,-1]}
    fi
    pager_args+=("$r" "$desc[i]" "$fl" $show)
  done
  _fp_prefix=$prefix _fp_highlight_prefix=1
  fishy-pager-set-completions "$pager_args[@]"
  fishy-pager-selection-changed
  return 1
}
