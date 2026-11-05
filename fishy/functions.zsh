# fishy functions: fish 4.9.3's interactive functions (share/functions/*.fish),
# ported line for line. They run in zsh because they act on zsh's state (the
# directory, the terminal); colors come from fish (the server resolves
# set_color), help from fish itself.
#
#   ls ll la                 ls.fish ll.fish la.fish
#   cd (directory history)   cd.fish
#   prevd nextd dirh cdh     prevd.fish nextd.fish dirh.fish cdh.fish
#   __fish_move_last         __fish_move_last.fish
#
# Implicit cd (`..`, `dir/`) is zsh's IMPLICIT_CD option (fishy's zsh patch),
# which calls this cd. pushd/popd/dirs stay zsh's builtins: fish's versions
# don't take zsh's flags (`pushd -q`), which zsh code relies on.

# fish's dirprev/dirnext/__fish_cd_direction (globals in fish too).
typeset -ga dirprev dirnext

# set_color for a fish color variable (or --reset), resolved by fish. REPLY =
# the escape sequence; returns 1 if set_color printed nothing (an unset
# variable), in which case fish's (set_color ...) expands to no argument.
_fishy_set_color() {
  REPLY=''
  fishy-call sync capture __fishy_set_color "$1" || return 1
  local rec=${fishy_reply[1]-}
  REPLY=${rec#O$'\x1f'}
  [[ -n $REPLY ]]
}

# fish's argparse for `NAME --max-args=MAX h/help l/list`: sets _flag_help /
# _flag_list in the caller, reply=(positional args). Errors as argparse
# prints them (status 2 for an unknown option, 1 for too many arguments).
_fishy_dirhist_argparse() {
  local name=$1 a c
  local -i max=$2 i
  shift 2
  reply=()
  while (( $# )); do
    a=$1; shift
    if [[ $a == -- ]]; then reply+=("$@"); break; fi
    if [[ $a == --?* ]]; then
      case ${a#--} in
        (help) _flag_help=--help ;;
        (list) [[ $name == dirh ]] || { _flag_list=--list; continue }
          print -ru2 -- "$name: $a: unknown option"; return 2 ;;
        (*) print -ru2 -- "$name: $a: unknown option"; return 2 ;;
      esac
    elif [[ $a == -?* ]]; then
      for (( i = 2; i <= ${#a}; i++ )); do
        c=${a[i]}
        case $c in
          (h) _flag_help=-h ;;
          (l) [[ $name == dirh ]] || { _flag_list=-l; continue }
            print -ru2 -- "$name: -$c: unknown option"; return 2 ;;
          (*) print -ru2 -- "$name: -$c: unknown option"; return 2 ;;
        esac
      done
    else
      reply+=("$a")
    fi
  done
  if (( ${#reply} > max )); then
    print -ru2 -- "$name: expected <= $max arguments; got ${#reply}"
    return 1
  fi
}

# fish's own help text for a fish function.
__fish_print_help() {
  command $FISHY_FISH --no-config -c '__fish_print_help $argv[1]' -- "$1"
}

# ---------------------------------------------------------------- ls ll la

# ls.fish: colors and type indicators, probed once like fish does.
ls() {
  if (( ! ${+__fish_ls_command} )); then
    typeset -g __fish_ls_command=ls
    typeset -ga __fish_ls_color_opt=() __fish_ls_indicators_opt=()
    # OpenBSD's colorls takes -G and -F (a ruby colorls doesn't take -F).
    if (( ${+commands[colorls]} )) && command colorls -GF >/dev/null 2>&1; then
      __fish_ls_command=colorls
      __fish_ls_color_opt=(-G)
      __fish_ls_indicators_opt=(-F)
    else
      local opt
      for opt in --color=auto -G --color; do
        if command ls $opt / >/dev/null 2>&1; then
          __fish_ls_color_opt=($opt)
          break
        fi
      done
      command ls -F / >/dev/null 2>&1 && __fish_ls_indicators_opt=(-F)
    fi
  fi

  # fish: isatty stdout (false inside a redirected fish function, as under
  # __fish_echo: _fishy_stdout_is_tty=0).
  local -i stdout_tty=0
  [[ -t 1 ]] && (( ${_fishy_stdout_is_tty:-1} )) && stdout_tty=1
  local -a indicators_opt=()
  (( stdout_tty )) && indicators_opt+=($__fish_ls_indicators_opt)

  # Terminal.app sets neither COLORTERM nor CLICOLOR (fish #8309).
  [[ $TERM_PROGRAM == Apple_Terminal ]] && local -x CLICOLOR=1

  # An exported CLICOLOR_FORCE colors piped output: drop the color option
  # then. (As in fish, this clears the global for the rest of the session.)
  [[ ${parameters[CLICOLOR_FORCE]-} == *export* ]] && (( ! stdout_tty )) && __fish_ls_color_opt=()

  command $__fish_ls_command $__fish_ls_color_opt $indicators_opt "$@"
}

# ll.fish / la.fish
ll() { ls -lh "$@" }
la() { ls -lAh "$@" }

# ---------------------------------------------------------------- directory history

# cd.fish: wrap the builtin cd to maintain directory history.
cd() {
  setopt local_options no_ksh_arrays no_sh_word_split
  local -i MAX_DIR_HIST=25

  # Skip history in subshells (fish: command substitutions).
  if (( ZSH_SUBSHELL )); then
    builtin cd "$@"
    return
  fi

  local previous=$PWD

  # fish: test "$argv" = -
  if [[ "$*" == - ]]; then
    if [[ ${__fish_cd_direction-} == next ]]; then
      nextd
    else
      prevd
    fi
    return
  fi

  builtin cd "$@"
  local -i cd_status=$?

  if (( cd_status == 0 )) && [[ $PWD != "$previous" ]]; then
    (( ${#dirprev} >= MAX_DIR_HIST )) && dirprev[1]=()
    dirprev+=("$previous")
    dirnext=()
    typeset -g __fish_cd_direction=prev
  fi

  return cd_status
}

# __fish_move_last.fish: move the last element of a directory history from
# src to dest, and go there.
__fish_move_last() {
  setopt local_options no_ksh_arrays no_sh_word_split
  local src=$1 dest=$2
  local -a ssrc=("${(@P)src}")
  local -i size_src=${#ssrc}

  if (( size_src == 0 )); then
    # Cannot make this step; a bel is fish's notification for it.
    printf '\a'
    return 1
  fi

  # Append current dir to the end of the destination.
  set -A $dest "${(@P)dest}" "$PWD"

  # Change dir to the last entry in the source dir-hist.
  builtin cd "$ssrc[size_src]"

  # Keep all but the last from the source dir-hist.
  set -A $src "${(@)ssrc[1,size_src-1]}"
  return 0
}

# prevd.fish / nextd.fish
prevd() { _fishy_prevnextd prevd dirprev dirnext next "$@" }
nextd() { _fishy_prevnextd nextd dirnext dirprev prev "$@" }
_fishy_prevnextd() {
  setopt local_options no_ksh_arrays no_sh_word_split
  local name=$1 src=$2 dest=$3 direction=$4
  shift 4
  local _flag_help='' _flag_list=''
  _fishy_dirhist_argparse $name 1 "$@" || return

  if [[ -n $_flag_help ]]; then
    __fish_print_help $name
    return 0
  fi

  local -i times=1
  if (( ${#reply} )); then
    if [[ $reply[1] == <-> ]]; then
      times=$reply[1]
    else
      printf '%s: The number of positions to skip must be a non-negative integer\n' $name >&2
      return 1
    fi
  fi

  # Traverse history.
  local -i code=1 i
  for (( i = 1; i <= times; i++ )); do
    if __fish_move_last $src $dest; then
      # A success if at least 1 step was possible.
      code=0
    else
      break
    fi
  done

  # Show history if needed.
  [[ -n $_flag_list ]] && dirh

  # Set direction for 'cd -'.
  (( code == 0 )) && typeset -g __fish_cd_direction=$direction

  return code
}

# dirh.fish: print the directory history (the prev and next lists).
dirh() {
  setopt local_options no_ksh_arrays no_sh_word_split
  local _flag_help='' _flag_list=''
  _fishy_dirhist_argparse dirh 0 "$@" || return

  if [[ -n $_flag_help ]]; then
    __fish_print_help dirh
    return 0
  fi

  local -i dirc=${#dirprev} i
  if (( dirc > 0 )); then
    local -a dirprev_rev=("${(@Oa)dirprev}")
    for (( i = dirc; i >= 1; i-- )); do
      printf '%2d) %s\n' $i "$dirprev_rev[i]"
    done
  fi

  # fish: echo (set_color $fish_color_history_current)'   ' $PWD(set_color --reset)
  local -a words=()
  _fishy_set_color fish_color_history_current && words+=("$REPLY   ")
  _fishy_set_color --reset
  words+=("$PWD$REPLY")
  print -r -- "${words[@]}"

  dirc=${#dirnext}
  if (( dirc > 0 )); then
    local -a dirnext_rev=("${(@Oa)dirnext}")
    for (( i = 1; i <= dirc; i++ )); do
      printf '%2d) %s\n' $i "$dirnext_rev[i]"
    done
  fi
  print
}

# cdh.fish: a menu of the recently visited directories to cd to.
cdh() {
  setopt local_options no_ksh_arrays no_sh_word_split
  # With an argument (e.g. from cdh's completion): just cd there.
  if (( $# >= 1 )); then
    cd "$@"
    return
  fi

  local -a all_dirs=("${dirprev[@]}" "${dirnext[@]}")
  if (( ! ${#all_dirs} )); then
    print -ru2 -- 'No previous directories to select. You have to cd at least once.'
    return 0
  fi

  # Most recent first, each directory once (its most recent visit).
  local -a uniq_dirs=()
  local dir
  for dir in "${(@Oa)all_dirs}"; do
    (( ${uniq_dirs[(Ie)$dir]} )) || uniq_dirs+=("$dir")
  done

  local -a letters=({a..z})
  local -i dirc=${#uniq_dirs} i
  if (( dirc > ${#letters} )); then
    print -ru2 -- 'This should not happen. Have you changed the cd function?'
    printf 'There are %s unique dirs in your history but I can only handle %s\n' $dirc ${#letters} >&2
    return 1
  fi

  # Oldest to newest (the list is newest first, so count down).
  # fish: label_color is $fish_color_cwd if set, else --reset.
  local label reset current dir_color
  _fishy_set_color fish_color_cwd || _fishy_set_color --reset
  label=$REPLY
  _fishy_set_color --reset
  reset=$REPLY
  _fishy_set_color fish_color_history_current
  current=$REPLY
  for (( i = dirc; i >= 1; i-- )); do
    dir=$uniq_dirs[i]
    dir_color=''
    [[ $dir == "$PWD" ]] && dir_color=$current
    # fish: string match -r "^$HOME(/.*|\$)" "$dir"
    if [[ $dir =~ "^${HOME}(/.*|\$)" ]]; then
      dir="~$match[1]"
    fi
    printf '%s %s %2d) %s %s%s%s\n' "$label" $letters[i] $i "$reset" "$dir_color" "$dir" "$reset"
  done

  # Ask which directory from the history to cd to.
  local choice=''
  read -r "choice?Select directory by letter or number: "
  if [[ -z $choice ]]; then
    return 0
  elif [[ $choice == [a-z] ]]; then
    # Convert the letter to an index number.
    choice=${letters[(ie)$choice]}
  fi

  if [[ $choice == <-> ]]; then
    if (( choice >= 1 && choice <= dirc )); then
      cd "$uniq_dirs[choice]"
      return
    fi
  fi
  printf 'Error: expected a number between 1 and %d or letter in that range, got "%s"\n' $dirc "$choice" >&2
  return 1
}

# Alt-Left / Alt-Right on an empty command line (prevd-or-backward-word,
# nextd-or-forward-word): fish evals prevd/nextd, then repaints the prompt.
fishy-dirhist() {
  if [[ $1 == prev ]]; then prevd; else nextd; fi
  _fishy_cmd_repaint
}
