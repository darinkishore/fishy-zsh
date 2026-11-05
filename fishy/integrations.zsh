# fishy integrations: the atuin and fzf bindings of darin's fish, ported from
# the fish versions they actually run (atuin-fish-config, `fzf --fish`), on top
# of fishy's edit model. Each piece is installed only if its tool exists.
#
#   up         atuin (fish: _atuin_bind_up), falling back to up-or-search
#   ctrl-r     atuin search (fish: _atuin_search)
#   ?          atuin ai on an empty line (fish: _atuin_ai_question_mark)
#   ctrl-t     fzf-file-widget (fish version: token-aware root and query)
#   alt-c      fzf-cd-widget (fish version)
#   shift-tab  fzf_complete (fish completions in fzf; complete-and-search in pager)
#   z, zi      zoxide's fish functions: jumps go through fish's cd (directory
#              history), `z -` is fish's cd - (prevd/nextd)

# ---------------------------------------------------------------- helpers

# fish: commandline -rt -- TEXT (replace the token under the cursor).
_fishy_replace_token() {
  fishy-call sync token-extent $CURSOR "$BUFFER" || return 1
  local -a e=("${(@ps:\x1f:)fishy_reply[1]}")
  fishy-push-edit $e[2] $e[3] "$1"
  CURSOR=$(( e[2] + ${#1} ))
}

# fish: commandline -t (the token under the cursor)
_fishy_current_token() {
  fishy-call sync token-extent $CURSOR "$BUFFER" || return 1
  local -a e=("${(@ps:\x1f:)fishy_reply[1]}")
  REPLY=${BUFFER[e[2]+1,e[3]]}
}

# fish: string escape -n -- ARGS (zsh-correct escaping). reply = escaped list.
_fishy_escape_n() {
  reply=()
  (( $# )) || return
  _fishy_zopts
  fishy-call sync escape "$REPLY" "$@" || return 1
  local r
  for r in "$fishy_reply[@]"; do reply+=("${r#Q$'\x1f'}"); done
}

# The shell fzf runs helper commands with, as in fish (`status fish-path`).
_fishy_fzf_shell() { REPLY="${commands[fish]:-fish} -c" }

# Run a full-screen tool from a widget (fish: tty handoff around the call).
_fishy_tty_begin() { zle -I }
_fishy_tty_end() { zle reset-prompt }

# ---------------------------------------------------------------- atuin

if (( $+commands[atuin] )); then
  # fish: _atuin_search, result applied through the edit model.
  _fishy_atuin_search() {
    local out st
    _fishy_tty_begin
    out=$(ATUIN_SHELL=zsh ATUIN_QUERY=$BUFFER atuin search "$@" -i 3>&1 1>&2 2>&3 3>&-)
    st=$?
    _fishy_tty_end
    if (( st != 0 )); then
      [[ -n $out ]] && print -r -- "$out" >/dev/tty
      return $st
    fi
    out=${${out##[[:space:]]#}%%[[:space:]]#}
    [[ -n $out ]] || return 0
    if [[ $out == __atuin_accept__:* ]]; then
      fishy-push-edit 0 ${#BUFFER} "${out#__atuin_accept__:}"
      _fishy_w_execute
      return
    fi
    fishy-push-edit 0 ${#BUFFER} "$out"
  }

  # fish: _atuin_bind_up
  _fishy_w_atuin_up() {
    fishy-unswap
    if (( _fh_active )) || ! fishy-pager-is-empty; then
      _fishy_cmd_up-or-search
      return
    fi
    if [[ ${BUFFER[1,CURSOR]} != *$'\n'* ]]; then
      emulate -L zsh -o extendedglob
      _fishy_atuin_search --shell-up-key-binding
    else
      _fishy_cmd_up-or-search
    fi
  }
  zle -N fishy-atuin-up _fishy_w_atuin_up

  _fishy_w_atuin_search() {
    fishy-unswap
    emulate -L zsh -o extendedglob
    _fishy_atuin_search
  }
  zle -N fishy-atuin-search _fishy_w_atuin_search

  # fish: _atuin_ai_question_mark
  _fishy_w_atuin_question() {
    fishy-unswap
    if [[ -z $BUFFER || $BUFFER == '?' ]]; then
      fishy-push-edit 0 ${#BUFFER} ''
      printf '\033]133;C\007' >/dev/tty
      local out
      _fishy_tty_begin
      out=$(atuin ai inline --hook 3>&1 1>&2 2>&3)
      case $out in
        __atuin_ai_print__:*) print -r -- "${out#__atuin_ai_print__:}" >/dev/tty ;;
        __atuin_ai_cancel__) ;;
        __atuin_ai_execute__:*)
          fishy-push-edit 0 ${#BUFFER} "${out#__atuin_ai_execute__:}"
          _fishy_tty_end
          _fishy_w_execute
          return ;;
        __atuin_ai_insert__:*) fishy-push-edit 0 ${#BUFFER} "${out#__atuin_ai_insert__:}" ;;
        '') ;;
        *) fishy-push-edit 0 ${#BUFFER} "$out" ;;
      esac
      _fishy_tty_end
    else
      _fishy_insert '?'
    fi
  }
  zle -N fishy-atuin-question _fishy_w_atuin_question
fi

# ---------------------------------------------------------------- fzf

if (( $+commands[fzf] )); then
  # fish: __fzf_defaults PREPEND APPEND...
  _fishy_fzf_defaults() {
    local height=${FZF_TMUX_HEIGHT:-40%} file_opts=''
    [[ -r $FZF_DEFAULT_OPTS_FILE ]] && file_opts=${(j: :)${(f)"$(<$FZF_DEFAULT_OPTS_FILE)"}}
    REPLY="--height $height --min-height=20+ --bind=ctrl-z:ignore $1 $file_opts $FZF_DEFAULT_OPTS ${(j: :)@[2,-1]}"
  }

  # fish: __fzf_parse_commandline -> REPLY_DIR REPLY_QUERY REPLY_PREFIX
  _fishy_fzf_parse_commandline() {
    emulate -L zsh -o extendedglob
    local query='' prefix='' dir='.'
    _fishy_current_token; local tok=$REPLY
    # --tokens-expanded: quote removal, ~ and $VAR expansion (no globbing,
    # no command substitution).
    local expanded=${(Q)tok}
    if [[ $expanded == '~'* ]]; then
      local head=${expanded%%/*} rest=${expanded#*/}
      [[ $expanded != */* ]] && rest='' || rest=/$rest
      if [[ $head == '~' ]]; then head=$HOME
      elif (( $+userdirs[${head#\~}] )); then head=$userdirs[${head#\~}]
      fi
      expanded=$head$rest
    fi
    while [[ $expanded == (#b)(*)'$'([A-Za-z_][A-Za-z0-9_]#)(*) ]]; do
      expanded=$match[1]${(P)match[2]}$match[3]
    done
    query=$expanded
    # An -option= (or -o) prefix, unless " -- " precedes the token.
    fishy-call sync token-extent $CURSOR "$BUFFER"
    local -a e=("${(@ps:\x1f:)fishy_reply[1]}")
    local before=${BUFFER[1,e[2]]}
    if [[ $before != *' -- '* ]]; then
      if [[ $query == (#b)(-[^[:space:]=]##=)(*) ]]; then
        prefix=$match[1] query=$match[2]
      elif [[ $query == (#b)(-[^-[:space:]])(*) ]]; then
        prefix=$match[1] query=$match[2]
      fi
    fi
    if [[ -n $query ]]; then
      # fish: path normalize, then the longest existing directory.
      local norm=${query:a}
      [[ $query != /* ]] && norm=${${query:a}#$PWD/}
      [[ $query == */ && $norm != */ ]] && norm+=/
      dir=${norm%/}
      while [[ -n $dir && ! -d $dir ]]; do
        [[ $dir == */* ]] && dir=${dir%/*} || dir=.
        [[ $dir == . ]] && break
      done
      [[ -z $dir ]] && dir=/
      query=$norm
      if [[ $dir != . || $query == .(/|)* ]]; then
        local d=$dir
        query=${query#$d}
        query=${query#/}
      fi
    fi
    REPLY_DIR=$dir REPLY_QUERY=$query REPLY_PREFIX=$prefix
  }

  # fish: fzf-file-widget
  _fishy_w_fzf_file() {
    fishy-unswap
    _fishy_fzf_parse_commandline
    local dir=$REPLY_DIR query=$REPLY_QUERY prefix=$REPLY_PREFIX
    _fishy_fzf_defaults "--reverse --walker=file,dir,follow,hidden --scheme=path" "--multi $FZF_CTRL_T_OPTS --print0"
    local opts=$REPLY
    local -a result
    _fishy_tty_begin
    if [[ -n $FZF_CTRL_T_COMMAND ]]; then
      result=("${(@0)$(eval "$FZF_CTRL_T_COMMAND" | FZF_DEFAULT_OPTS=$opts FZF_DEFAULT_OPTS_FILE= FZF_DEFAULT_COMMAND= fzf --query=$query)}")
    else
      result=("${(@0)$(FZF_DEFAULT_OPTS=$opts FZF_DEFAULT_OPTS_FILE= FZF_DEFAULT_COMMAND= fzf --walker-root=$dir --query=$query)}")
    fi
    _fishy_tty_end
    result=("${(@)result:#}")
    if (( ${#result} )); then
      _fishy_escape_n "${result[@]}"
      _fishy_replace_token "${(j: :)${(@)reply/#/$prefix}} "
    fi
  }
  zle -N fishy-fzf-file _fishy_w_fzf_file

  # fish: fzf-cd-widget
  _fishy_w_fzf_cd() {
    fishy-unswap
    _fishy_fzf_parse_commandline
    local dir=$REPLY_DIR query=$REPLY_QUERY prefix=$REPLY_PREFIX
    _fishy_fzf_defaults "--reverse --walker=dir,follow,hidden --scheme=path" "$FZF_ALT_C_OPTS --no-multi --print0"
    local opts=$REPLY result
    _fishy_tty_begin
    result=${"$(dir=$dir FZF_DEFAULT_OPTS=$opts FZF_DEFAULT_OPTS_FILE= FZF_DEFAULT_COMMAND=$FZF_ALT_C_COMMAND fzf --query=$query --walker-root=$dir)"%$'\0'}
    if [[ -n $result ]]; then
      builtin cd -- $result
      _fishy_replace_token "$prefix"
      # fish repaints the prompt for the new directory.
      local f
      for f in $precmd_functions; do $f; done
    fi
    _fishy_tty_end
  }
  zle -N fishy-fzf-cd _fishy_w_fzf_cd

  # fish: fzf_complete
  _fishy_w_fzf_complete() {
    fishy-unswap
    emulate -L zsh -o extendedglob
    # In the pager, shift-tab keeps fish's complete-and-search.
    if ! fishy-pager-is-empty; then
      _fishy_run complete-and-search
      return
    fi
    # Remove a trailing unescaped backslash from the token.
    _fishy_current_token; local token=$REPLY
    if [[ $token == (#b)(*[^\\]|)((\\\\)#)\\ ]]; then
      token=$match[1]$match[2]
      _fishy_replace_token "$token"
    fi
    token=${token//\\$'\n'/}
    # Unquoted glob in the token -> wildcard expansion mode.
    local glob_pattern=''
    local stripped=${token//\\?/}
    stripped=${stripped//\'[^\']#\'/}
    stripped=${stripped//\"([^\"\\]|\\?)#\"/}
    if [[ $stripped == *'*'* ]]; then
      glob_pattern=$token
      [[ $stripped == *[\'\"]* ]] && glob_pattern+=${stripped//[^\'\"]/}[-1]
    fi
    local height=${FZF_TMUX_HEIGHT:-40%} file_opts='' mode_opts
    [[ -r $FZF_DEFAULT_OPTS_FILE ]] && file_opts=${(j: :)${(f)"$(<$FZF_DEFAULT_OPTS_FILE)"}}
    if [[ -n $glob_pattern ]]; then mode_opts=$FZF_EXPANSION_OPTS; else mode_opts=$FZF_COMPLETION_OPTS; fi
    _fishy_fzf_shell; local with_shell=$REPLY
    local opts="--height=$height --min-height=20+ --bind=ctrl-z:ignore $file_opts $FZF_DEFAULT_OPTS --bind=alt-r:toggle-raw --multi --wrap=word --reverse $mode_opts"
    local -a fzf_cmd=(fzf)
    [[ $FZF_TMUX == 1 ]] && fzf_cmd=(fzf-tmux ${=FZF_TMUX_OPTS} -d$height --)
    local -a result=()
    if [[ -n $glob_pattern ]]; then
      local cmdline="for i in $glob_pattern; test -d \"\$i\"; and string match -qv -- \"*/\" \$i; and set -- i \$i/; string join0 -- \$i; end"
      _fishy_tty_begin
      result=("${(@0)$(FZF_DEFAULT_OPTS=$opts FZF_DEFAULT_OPTS_FILE= FZF_DEFAULT_COMMAND=$cmdline $fzf_cmd --with-shell=$with_shell --read0 --print0 --scheme=path --no-multi-line)}")
      _fishy_tty_end
      result=("${(@)result:#}")
      (( ${#result} )) && { _fishy_escape_n "${result[@]}"; result=("$reply[@]") }
    else
      # fish: complete -C --escape on the process up to the cursor.
      _fishy_zopts
      fishy-call sync complete-tokens "$REPLY" "${BUFFER[1,CURSOR]}" || return
      local -a list=()
      local rec
      for rec in "$fishy_reply[@]"; do
        local -a f=("${(@ps:\x1f:)rec}")
        if [[ -n $f[3] ]]; then list+=("$f[2]"$'\t'"$f[3]"); else list+=("$f[2]"); fi
      done
      (( ${#list} )) || return
      # Tabstop for description alignment (fish: same computation).
      local -i tabstop=4 maxc=$(( ${COLUMNS:-80} - 40 ))
      if [[ $FZF_DEFAULT_OPTS == (#b)*--tabstop[=\ ]0#([1-9][0-9]##|[4-9])* ]]; then
        tabstop=$(( match[1] - 4 ))
      fi
      local item
      for item in "${(@)list[1,500]}"; do
        [[ $item == *$'\t'* ]] || continue
        local -i len=${(m)#${item%%$'\t'*}}
        (( len > tabstop && len < maxc )) && tabstop=$len
      done
      (( tabstop += 4 ))
      _fishy_tty_begin
      result=("${(@f)$(print -rl -- "$list[@]" | FZF_DEFAULT_OPTS="$opts --with-shell=$with_shell" FZF_DEFAULT_OPTS_FILE= $fzf_cmd --delimiter=$'\t' --tabstop=$tabstop --wrap-sign=$'\t↳ ' --accept-nth=1)}")
      _fishy_tty_end
      result=("${(@)result:#}")
    fi
    (( ${#result} )) || return
    local tail=' '
    (( ${#result} == 1 )) && [[ $result[1] == */ ]] && tail=''
    _fishy_replace_token "${(j: :)result}$tail"
  }
  zle -N fishy-fzf-complete _fishy_w_fzf_complete
fi

# Bind on top of fish's defaults, exactly where darin's fish binds them.
# ---------------------------------------------------------------- zoxide

# `zoxide init fish`: __zoxide_cd is a copy of fish's cd.fish (so z records
# directory history) and __zoxide_z is fish's. zsh's init calls the builtin cd
# and handles `-` as $OLDPWD; these replace its two functions.
_fishy_zoxide_install() {
  __zoxide_cd() { cd "$@" }

  __zoxide_z() {
    local -i argc=$#
    if (( argc == 0 )); then
      __zoxide_cd $HOME
    elif [[ "$*" == - ]]; then
      __zoxide_cd -
    elif (( argc == 1 )) && [[ -d $1 ]]; then
      __zoxide_cd $1
    elif (( argc == 2 )) && [[ $1 == -- ]]; then
      __zoxide_cd -- $2
    else
      local result
      result=$(command zoxide query --exclude "$(__zoxide_pwd)" -- "$@") \
        && __zoxide_cd $result
    fi
  }
}

fishy-integrations-install() {
  (( $+functions[__zoxide_z] && $+functions[__zoxide_pwd] )) && _fishy_zoxide_install
  # Their key bindings are the user's fish bindings (user.zsh), which map
  # these functions to their ports here.
}
