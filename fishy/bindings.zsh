# fishy bindings: the fish-code bindings of fish 4.9.3's defaults
# (fish_default_key_bindings + __fish_shared_key_bindings) that the reader
# doesn't implement itself.
#
# Bindings that only edit the command line run fish's own code in the server
# (`__fishy bind-run`): their `commandline` edits and `commandline -f` calls
# come back and are applied here. Bindings that run something on the terminal
# (man, the editor, a pager, ls, dirh) are ported line for line and run in zsh.
#
#   alt-#        __fish_toggle_comment_commandline      (server)
#   alt-s        fish_commandline_prepend sudo/doas/... (server)
#   alt-p        __fish_paginate                        (server, `|&` for zsh)
#   alt-d        dirh on an empty line, else kill-word
#   alt-l        __fish_list_current_token
#   alt-w        __fish_whatis_current_token
#   alt-o        __fish_preview_current_file
#   alt-h, f1    __fish_man_page
#   alt-e, alt-v edit_command_buffer
#   ctrl-x       fish_clipboard_copy
#   ctrl-v       fish_clipboard_paste
#   shift-delete history-delete or backward-delete-char
#   ctrl-l       scrollback-push (if the terminal has indn) + clear-screen

# fish: apply_commandline_state_changes. A `commandline` edit replaces the
# line (one edit), closes the pager, ends the history search, and the next
# event starts with no last command (reset_loop_state).
_fishy_commandline_change() {
  local text=$1
  local -i pos=$2
  [[ $text == "$BUFFER" ]] && (( pos == CURSOR )) && return 1
  fishy-pager-clear
  _fishy_set_buffer_maintaining_pager "$text" $pos
  _fishy_last_cmd='' _fishy_completion_action=''
  return 0
}

# Run fish CODE as a binding against the command line (fish: eval_bind_cmd).
# Sets _fishy_bind_fns=(the `commandline -f` functions it requested) and
# _fishy_bind_out=(what it wrote). (Applying the edit clobbers REPLY/reply.)
typeset -g _fishy_bind_out=''
typeset -ga _fishy_bind_fns
_fishy_bind_eval() {
  local code=$1 rec
  _fishy_bind_out='' _fishy_bind_fns=()
  fishy-call sync bind-run $CURSOR "$BUFFER" "$code" || return 1
  local -a recs=("$fishy_reply[@]") f
  for rec in "$recs[@]"; do
    case $rec in
      (O$'\x1f'*) _fishy_bind_out+=${rec#O$'\x1f'} ;;
      (B$'\x1f'*)
        f=("${(@ps:\x1f:)rec}")
        _fishy_commandline_change "$f[2]" $f[3] ;;
      (F$'\x1f'*) _fishy_bind_fns+=(${rec#F$'\x1f'}) ;;
    esac
  done
}

# A binding to fish code: run it, print what it wrote (fish writes binding
# output straight to the terminal), then the readline functions it asked for.
_fishy_bind_run() {
  _fishy_bind_eval "$1" || return
  local -a fns=("$_fishy_bind_fns[@]")
  [[ -n $_fishy_bind_out ]] && print -rn -- "$_fishy_bind_out"
  local fn
  for fn in "$fns[@]"; do
    if [[ $fn == execute ]]; then
      # Enter's whole path (accept the line, add it to history).
      _fishy_w_execute
    elif (( $+functions[_fishy_cmd_$fn] )); then
      _fishy_run $fn
    else
      fishy-log "bind: no readline function $fn"
    fi
  done
  fishy-suggest-update
  fishy-highlight-update
}

# A fish single-quoted word for $1.
_fishy_fish_quote() {
  local bs='\' q="'"
  local s=${1//$bs/$bs$bs}
  REPLY=$q${s//$q/$bs$q}$q
}

# fish CODE that prints its result as fields each ending in \x1d (group
# separator: NUL can't travel in a reply), run against the command line; ARGS
# become its $argv. reply = the fields.
_fishy_bind_query() {
  local code=$1 a
  shift
  if (( $# )); then
    local args=''
    for a in "$@"; do _fishy_fish_quote "$a"; args+=" $REPLY"; done
    code="set -l argv$args
$code"
  fi
  _fishy_bind_eval "$code" || return 1
  reply=()
  [[ -n $_fishy_bind_out ]] || return 0
  # Every field ends in \x1d (empty fields included): the split leaves one
  # empty element after the last.
  reply=("${(@ps:\x1d:)_fishy_bind_out}")
  reply[-1]=()
  return 0
}

# __fish_echo: run a command below the command line, then redraw the prompt
# under its output. The same bytes as fish: below the line, clear, the
# command (stdout to stderr), then as many newlines as the prompt and line
# rows above the cursor, which the repaint moves back up over.
_fishy_echo() {
  local before=${BUFFER[1,CURSOR]} nl
  nl=${before//[^$'\n']/}
  local -i line=$(( ${#nl} + 1 ))
  local all=${BUFFER//[^$'\n']/}
  local -i count=$(( ${#all} + 1 ))
  local -i prompt_lines=$(( _fp_lines > 0 ? _fp_lines : 1 ))
  {
    # zle may leave its last drawing attributes (an underlined path, the
    # suggestion's color) active; fish's screen leaves none. The repaint
    # below redraws from a reset state anyway.
    printf '\e[m'
    _fishy_newlines $(( count - line + 1 ))
    printf '\e[J'
    # fish runs the command as `$argv >&2`: for fish's own functions (ls,
    # dirh) a redirected stdout is no tty (`isatty stdout` is false), though
    # external commands still write to the terminal.
    local -i _fishy_stdout_is_tty=0
    "$@"
    _fishy_newlines $(( prompt_lines - 1 ))
    _fishy_newlines $(( line - 1 ))
  } >&2
  _fishy_run repaint
}

# string repeat -N \n --count=N
_fishy_newlines() {
  local -i n=$1
  (( n > 0 )) && print -rn -- ${(pl:n::\n:)}
  return 0
}

# ---------------------------------------------------------------- server-side

_fishy_w_toggle_comment() {
  fishy-unswap
  _fishy_bind_run __fish_toggle_comment_commandline
}
_fishy_w_prepend_sudo() {
  fishy-unswap
  _fishy_bind_run 'for cmd in sudo doas please run0; if command -q $cmd; fish_commandline_prepend $cmd; break; end; end'
}
# __fish_paginate with zsh's spelling of "pipe stdout and stderr" (fish's
# `&|` means "background and disown" in zsh).
_fishy_w_paginate() {
  fishy-unswap
  _fishy_bind_run 'set -l cmd (__fish_anypager); or return 1
set -l pipe " |& $cmd"
if string match -rq -- '"'"' \n\.$'"'"' "$(commandline -j; echo .)"
    set pipe "|& $cmd"
end
fish_commandline_append $pipe'
}

# ---------------------------------------------------------------- zsh-side

# alt-d: 'if test "$(commandline; printf .)" = \n.; __fish_echo dirh; else; commandline -f kill-word; end'
_fishy_w_alt_d() {
  fishy-unswap
  if [[ -z $BUFFER ]]; then
    _fishy_echo dirh
  else
    _fishy_run kill-word
  fi
}

# __fish_list_current_token
_fishy_w_list_token() {
  fishy-unswap
  _fishy_current_token || return
  local val=${REPLY/#\~/$HOME} dir
  local -a cmd
  if [[ -d $val ]]; then
    cmd=(ls $val)
  else
    dir=$(command dirname -- "$val")
    if [[ $dir != . && -d $dir ]]; then cmd=(ls $dir); else cmd=(ls); fi
  fi
  _fishy_echo $cmd
}

# __fish_whatis_current_token, with zsh's idea of what the token is.
_fishy_w_whatis() {
  fishy-unswap
  _fishy_bind_query 'printf "%s\x1d" (commandline -pt)' || return
  local token=${reply[1]-}
  [[ -n $token ]] || return
  local desc="$token: nothing appropriate."
  local -a w=(${(z)$(whence -w -- $token 2>/dev/null)})
  case ${w[2]-} in
    (function)
      # fish: functions --details --verbose, line 5 (the description). The
      # server knows zsh's functions too (fishy's ports keep fish's
      # descriptions; zsh-only ones are stubs without one).
      _fishy_bind_query 'printf "%s\x1d" (functions $argv[1] --details --verbose)[5]' "$token"
      (( ${#reply} )) && [[ $reply[1] != n/a ]] && desc="$token - $reply[1]" ;;
    (builtin|reserved)
      desc=$(__fish_print_help $token 2>/dev/null | sed -n 4p)
      desc=${${desc##[[:space:]]#}%%[[:space:]]#} ;;
    (command)
      local tmpdesc
      tmpdesc=$(whatis $token 2>/dev/null) && desc=$tmpdesc ;;
  esac
  _fishy_echo print -r -- $desc
}

# __fish_anypager [--with-manpager] -> reply
_fishy_anypager() {
  reply=()
  [[ -n ${PAGER+x} ]] && reply=(${(z)PAGER})
  [[ $1 == --with-manpager && -n ${MANPAGER+x} ]] && reply=(${(z)MANPAGER})
  (( ${#reply} )) && (( $+commands[$reply[1]] )) && return 0
  local cmd
  for cmd in less lv most more; do
    (( $+commands[$cmd] )) && { reply=($cmd); return 0 }
  done
  reply=()
  return 1
}

# __fish_anyeditor -> reply
_fishy_anyeditor() {
  reply=()
  if [[ -n ${VISUAL+x} ]]; then
    reply=(${(z)VISUAL})
  elif [[ -n ${EDITOR+x} ]]; then
    reply=(${(z)EDITOR})
  else
    _fishy_echo print -r -- 'External editor requested but $VISUAL or $EDITOR not set.' \
      $'\n''Please set VISUAL or EDITOR to your preferred editor.'
    return 1
  fi
}

# __fish_preview_current_file (with __fish_edit_command_if_at_cursor)
_fishy_w_preview() {
  fishy-unswap
  # At the command token: edit the command's source if it is a text file.
  _fishy_bind_query 'set -l tokens (commandline -xpc)
if not set -q tokens[1]
    printf "%s\x1d" (commandline -xp)[1]
else if test (count $tokens) = 1 && test -z "$(commandline -t)"
    printf "%s\x1d" $tokens[1]
end' || return
  local command=${reply[1]-} command_path
  if [[ -n $command ]] && command_path=$(command -v -- $command 2>/dev/null) \
      && [[ -r $command_path && $(file --brief --mime-type -L -- $command_path) == text/* ]]; then
    _fishy_anyeditor || return 0
    $reply $command_path </dev/tty
    return 0
  fi

  local -a pager
  if _fishy_anypager; then pager=("$reply[@]"); else pager=(cat); fi
  # The current token, evaluated as the shell would (fish: eval set -l files
  # $file); if empty, the last expanded token before the cursor, literally.
  _fishy_current_token || return
  local file=$REPLY
  local -i literal=0
  if [[ -z $file ]]; then
    _fishy_bind_query 'printf "%s\x1d" (commandline -xc)[-1]' || return
    (( ${#reply} )) || return
    file=$reply[1] literal=1
  fi
  # strip -option= from token if present
  file=${file/#-[^[:space:]=]#=/}
  local -a files
  if (( literal )); then
    files=("$file")
  else
    eval "files=( $file )" 2>/dev/null || return   # bail if it doesn't parse
  fi
  if (( ${#files} )) && [[ -f $files[1] ]]; then
    _fishy_echo $pager $files
  fi
}

# __fish_man_page
_fishy_w_man_page() {
  fishy-unswap
  # Tokens not starting with "-", up to and including the cursor's.
  _fishy_bind_query 'printf "%s\x1d" (string match -rv '"'"'^-|^$'"'"' -- (commandline -cpx && commandline -t))' || return
  local -a args=("$reply[@]")
  if (( ! ${#args} )); then
    printf '\a'
    return
  fi
  # Skip leading commands and show the manpage of the following command.
  while (( ${#args} >= 2 )) && [[ $args[1] =~ '^(and|begin|builtin|caffeinate|command|doas|entr|env|exec|if|mosh|nice|not|or|pipenv|please|prime-run|run0|setsid|sudo|systemd-nspawn|time|watch|while|xargs|.*=.*)$' ]]; do
    args[1]=()
  done
  local maincmd=${args[1]:t}
  if (( ${#args} >= 2 )) && [[ $args[2] != */* ]] && man "$maincmd-$args[2]" &>/dev/null; then
    man "$maincmd-$args[2]" </dev/tty
  elif man "$maincmd" &>/dev/null; then
    man "$maincmd" </dev/tty
  else
    printf '\a'
  fi
  _fishy_run repaint
}

# fish_indent --only-indent / --only-unindent with zsh's indentation levels
# (fishy-indents: the continuation indent fishy draws). REPLY = the result.
_fishy_indent() {
  local src=$1 out='' rec
  local -i i=0 off lvl
  fishy-indents "$src"
  local -a recs=("$reply[@]")
  for rec in "$recs[@]"; do
    off=${rec% *} lvl=${rec#* }
    (( off == ${#src} )) && continue     # a final newline gets no indent
    out+=${src[i+1,off]}${(l:lvl*4:)}
    i=$off
  done
  REPLY=$out${src[i+1,-1]}
}
_fishy_unindent() {
  local src=$1 out='' rec
  local -i i=0 off lvl
  fishy-indents "$src"
  local -a recs=("$reply[@]")
  for rec in "$recs[@]"; do
    off=${rec% *} lvl=${rec#* }
    (( off == ${#src} )) && continue
    # Indented everywhere, or leave it all alone.
    [[ ${src[off+1,off+lvl*4]} == ${(l:lvl*4:)} ]] || { REPLY=$src; return }
    out+=${src[i+1,off]}
    i=$(( off + lvl * 4 ))
  done
  REPLY=$out${src[i+1,-1]}
}

# edit_command_buffer (the file is command-line.zsh: it holds zsh code).
_fishy_w_edit_command_buffer() {
  fishy-unswap
  local tmpdir
  tmpdir=$(command mktemp -d -- ${TMPDIR:-/tmp}/fish.XXXXXX) || return 1
  local f=$tmpdir/command-line.zsh
  command touch $f || return 1
  _fishy_anyeditor || return 1
  local -a editor=("$reply[@]")

  _fishy_indent "$BUFFER"
  local indented=$REPLY
  print -r -- "$indented" >$f
  local -a indented_lines=("${(@f)indented}")
  # Cursor line and column: the column counts the indentation added above.
  local before=${BUFFER[1,CURSOR]} nl
  nl=${before//[^$'\n']/}
  local -i line=$(( ${#nl} + 1 ))
  local -a lines=("${(@ps:\n:)BUFFER}")
  local tail=${before##*$'\n'}
  local -i offset=${#tail}
  local -i col=$(( offset + 1 + ${#indented_lines[line]} - ${#lines[line]} ))

  # Editors that the editor's completions say it wraps.
  local editor_basename=${editor[1]:t}
  _fishy_bind_query 'for wrap_target in (complete -- $argv[1] | string replace -rf '"'"'^complete [^/]+ --wraps (.+)$'"'"' '"'"'$1'"'"')
    set -l tmp
    string unescape -- $wrap_target | read -at tmp
    printf "%s\x1d" $tmp[1]
end' "$editor_basename"
  local -a wrapped_commands=("$reply[@]")
  local found=0 cursor_from_editor='' editor_command vi_version
  for editor_command in $editor_basename $wrapped_commands; do
    case $editor_command in
      (vi|vim|nvim)
        if [[ $editor_command == vi ]] && ! vi_version=$(vi --version 2>/dev/null); then
          [[ $vi_version == *BusyBox* ]] && break
          editor+=(+$line $f)
          found=1
          break
        fi
        cursor_from_editor=$(command mktemp -- ${TMPDIR:-/tmp}/fish-edit_command_buffer.XXXXXX) || return
        editor+=(+$line "+norm! $col|" $f
          "+au VimLeave * ++once call writefile([printf(\"%s %s %s\", shellescape(bufname()), line(\".\"), col(\".\"))], \"$cursor_from_editor\")")
        ;;
      (emacs|emacsclient|gedit) editor+=(+$line:$col $f) ;;
      (kak)
        cursor_from_editor=$(command mktemp -- ${TMPDIR:-/tmp}/fish-edit_command_buffer.XXXXXX) || return
        editor+=(+$line:$col $f -e "
                hook -always -once global ClientClose %val{client} %{
                    echo -to-file $cursor_from_editor -quoting shell \\
                        %val{buffile} %val{cursor_line} %val{cursor_column}
                }
            ") ;;
      (nano) editor+=(+$line,$col $f) ;;
      (joe|ee) editor+=(+$line $f) ;;
      (code|code-oss) editor+=(--goto $f:$line:$col --wait) ;;
      (subl) editor+=($f:$line:$col --wait) ;;
      (micro) editor+=($f +$line:$col) ;;
      (helix|hx) editor+=($f:$line:$col) ;;
      (*) continue ;;
    esac
    found=1
    break
  done
  (( found )) || editor+=($f)

  $editor </dev/tty

  local raw=''
  [[ -s $f ]] && raw=$(<$f)
  _fishy_unindent "$raw"
  local unindented=$REPLY
  # fish means to check the editor's exit status here, but by now $status is
  # that of the fish_indent command substitution (0): only the file counts.
  if [[ -s $f ]]; then
    _fishy_commandline_change "$unindented" ${#unindented}
  else
    print
    print -r -- 'Ignoring the output of your editor since its exit status was non-zero'
    print -r -- 'or the file was empty'
  fi
  if [[ -n $cursor_from_editor ]]; then
    local -a pos=(${(Q)${(z)"$(<$cursor_from_editor)"}})
    if (( ${#pos} >= 3 )) && [[ $pos[1] == $f ]]; then
      local -a raw_lines=("${(@f)raw}") un_lines=("${(@f)unindented}")
      local -i pline=$pos[2]
      local -i pindent=$(( ${#raw_lines[pline]} - ${#un_lines[pline]} ))
      local -i column=$(( pos[3] - pindent ))
      if (( pline < 1 || pline > ${#un_lines} )); then
        _fishy_run end-of-buffer
      else
        local -i base=0 k
        for (( k = 1; k < pline; k++ )); do (( base += ${#un_lines[k]} + 1 )); done
        # commandline --column is 1-based; past the line's end -> end-of-line
        if (( column >= 1 && column - 1 <= ${#un_lines[pline]} )); then
          CURSOR=$(( base + column - 1 ))
        else
          CURSOR=$base
          _fishy_run end-of-line
        fi
      fi
    fi
    command rm -f -- $cursor_from_editor
  fi
  command rm -rf -- $tmpdir
  _fishy_run repaint
}

# fish_clipboard_copy: the line as drawn (fish_indent --only-indent), to the
# system clipboard and via OSC 52.
_fishy_w_clipboard_copy() {
  fishy-unswap
  _fishy_indent "$BUFFER"
  local cmdline=$REPLY
  if (( $+commands[pbcopy] )); then
    printf '%s' "$cmdline" | pbcopy
  elif [[ -n ${WAYLAND_DISPLAY-} ]] && (( $+commands[wl-copy] )); then
    printf '%s' "$cmdline" | wl-copy 2>/dev/null &!
  elif [[ -n ${DISPLAY-} ]] && (( $+commands[xsel] )); then
    printf '%s' "$cmdline" | xsel --clipboard
  elif [[ -n ${DISPLAY-} ]] && (( $+commands[xclip] )); then
    printf '%s' "$cmdline" | xclip -selection clipboard
  elif (( $+commands[clip.exe] )); then
    printf '%s' "$cmdline" | clip.exe
  fi
  if (( $+commands[base64] )) && [[ $TERM != dumb ]]; then
    if [[ ! -t 1 ]]; then
      print -ru2 -- 'fish_clipboard_copy: stdout is not a terminal'
      return 1
    fi
    local encoded=${"$(printf %s "$cmdline" | base64)"//$'\n'/}
    printf '\e]52;c;%s\a' "$encoded"
    if [[ -n ${TMUX-} ]]; then
      local tmux_tty
      tmux_tty=$(tmux display-message -p '#{client_tty}') || return 1
      [[ -w $tmux_tty ]] && printf '\e]52;c;%s\a' "$encoded" >$tmux_tty
    fi
  fi
}

# fish_clipboard_paste: the clipboard through __fish_paste (no undo group:
# only a bracketed paste gets one).
_fishy_w_clipboard_paste() {
  fishy-unswap
  local data=''
  if (( $+commands[pbpaste] )); then
    data=$(pbpaste 2>/dev/null; print -n .); data=${data%.}
  elif [[ -n ${WAYLAND_DISPLAY-} ]] && (( $+commands[wl-paste] )); then
    data=$(wl-paste -n 2>/dev/null; print -n .); data=${data%.}
  elif [[ -n ${DISPLAY-} ]] && (( $+commands[xsel] )); then
    data=$(xsel --clipboard; print -n .); data=${data%.}
  elif [[ -n ${DISPLAY-} ]] && (( $+commands[xclip] )); then
    data=$(xclip -selection clipboard -o 2>/dev/null; print -n .); data=${data%.}
  fi
  [[ -n $data ]] || return 1
  _fishy_paste_apply "$data"
  fishy-suggest-update
  fishy-highlight-update
}

# shift-delete: history-delete or backward-delete-char
typeset -gi _fishy_function_status=0
_fishy_cmd_history-delete() {
  local -i is_history_search=0 is_autosuggestion=0
  fishy-hsearch-at-present || is_history_search=1
  fishy-suggest-at-end && is_autosuggestion=1
  if (( is_history_search || is_autosuggestion )); then
    _fishy_function_status=1
    if (( is_autosuggestion && ! _fs_whole )); then
      _fishy_flash_suggestion=1
      fishy-flash 0 0
      return
    fi
    if (( is_history_search )); then
      local removed=$_fh_result
      fishy-call sync hsearch-delete || return
      # The async server's copy too: it forgets the item and re-reads the
      # file the sync server just saved (it never writes the file itself).
      fishy-tell async history-remove "$removed" forget
      _fh_parse
      _fishy_update_from_hsearch
    else
      fishy-call sync history-remove "$_fs_text"
      fishy-tell async history-remove "$_fs_text" forget
      fishy-suggest-clear
    fi
    return
  fi
  _fishy_function_status=0
}
_fishy_w_shift_delete() {
  fishy-unswap
  _fishy_run history-delete
  (( _fishy_function_status )) || _fishy_run backward-delete-char
}

# ctrl-l: 'status test-terminal-feature scroll-content-up && commandline -f
# scrollback-push' clear-screen. scroll-content-up is the terminal's answer to
# an XTGETTCAP query for indn (asked once, fenced by primary DA, like fish);
# scrollback-push scrolls the screen above the prompt into the scrollback.
typeset -g _fishy_indn=''
_fishy_query_indn() {
  [[ -n $_fishy_indn ]] && return
  _fishy_indn=0
  local resp='' c
  printf '\eP+q696e646e\e\\\e[c' >/dev/tty
  # Read up to the primary DA reply (ESC [ ? ... c), which ends the answers.
  while read -rsk 1 -t 1 c </dev/tty; do
    resp+=$c
    [[ $c == c && $resp == *$'\e[?'* ]] && break
  done
  [[ $resp == *$'\eP1+r696e646e'* ]] && _fishy_indn=1
}

# fish's viewport_y: the screen row the prompt starts on.
_fishy_prompt_row() {
  local resp='' c
  printf '\e[6n' >/dev/tty
  while read -rsk 1 -t 1 c </dev/tty; do
    resp+=$c
    [[ $c == R ]] && break
  done
  [[ $resp =~ $'\e\\[([0-9]+);([0-9]+)R' ]] || return 1
  _fishy_screen_lines "${BUFFER[1,CURSOR]}"
  REPLY=$(( match[1] - 1 - (REPLY - 1) ))
  (( REPLY < 0 )) && REPLY=0
  return 0
}

_fishy_w_ctrl_l() {
  fishy-unswap
  _fishy_query_indn
  if (( _fishy_indn )) && _fishy_prompt_row && (( REPLY > 0 )); then
    printf '\e[%dS\e[%dA' $REPLY $REPLY
  fi
  _fishy_run clear-screen
}

fishy-bindings-install() {
  zle -N fishy-toggle-comment _fishy_w_toggle_comment
  zle -N fishy-prepend-sudo _fishy_w_prepend_sudo
  zle -N fishy-paginate _fishy_w_paginate
  zle -N fishy-alt-d _fishy_w_alt_d
  zle -N fishy-list-token _fishy_w_list_token
  zle -N fishy-whatis _fishy_w_whatis
  zle -N fishy-preview _fishy_w_preview
  zle -N fishy-man-page _fishy_w_man_page
  zle -N fishy-edit-command-buffer _fishy_w_edit_command_buffer
  zle -N fishy-clipboard-copy _fishy_w_clipboard_copy
  zle -N fishy-clipboard-paste _fishy_w_clipboard_paste
  zle -N fishy-shift-delete _fishy_w_shift_delete
  zle -N fishy-ctrl-l _fishy_w_ctrl_l
}
