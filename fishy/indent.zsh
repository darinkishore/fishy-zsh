# fishy indent: fish's continuation-line indentation for zsh's grammar.
#
# fish draws every line after the first indented by the prompt width plus
# 4 columns per indent level (screen.rs, compute_indents). fish computes the
# levels from fish's AST; for zsh syntax we apply fish's rules (fish_indent
# output) to zsh's grammar, using zsh's own lexer (${(z)}):
#   - a block adds one level for the lines inside it;
#   - a line starting with the block's middle/closing keyword (then, else,
#     elif, do, fi, done, esac, }, ...) sits at the block's outer level;
#   - case items are one level in, their bodies two (fish: switch/case);
#   - a line continuing a job (after | |& && || or an escaped newline) gets
#     one extra level;
#   - newlines inside a word (quotes, $(...)) add no level.
#
# fishy-indents BUFFER -> reply=( "OFFSET LEVEL" ... ), one per newline,
# OFFSET = index of the character after the newline.

fishy-indents() {
  emulate -L zsh -o extendedglob
  local buf=$1
  reply=()
  [[ $buf == *$'\n'* ]] || return
  local -a toks=("${(@z)buf}") stack=()
  local -i pos=0 n=${#buf} i depth=0 cmdpos=1 pending_cont=0 line_rec=-1 line_start=1
  local -a recs=()    # parallel: newline offsets and levels
  local -a lvls=()
  local tok prev=''

  _fi_newline() {   # $1 = offset after the newline, $2 = continuation(0/1)
    local -i lvl=$(( depth + $2 ))
    recs+=($1) lvls+=($lvl)
    line_rec=${#recs} line_start=1
  }

  for tok in "${toks[@]}"; do
    # Skip blanks; an escaped newline continues the job on the next line.
    while (( pos < n )); do
      local c=${buf[pos+1]}
      if [[ $c == [$' \t'] ]]; then (( pos++ )); continue; fi
      if [[ $c == \\ && ${buf[pos+2]} == $'\n' ]]; then
        (( pos += 2 ))
        _fi_newline $pos 1
        continue
      fi
      break
    done
    # A newline shows up as a ';' token; tell it apart from a literal ';'.
    if [[ $tok == ';' && ${buf[pos+1]} == $'\n' ]]; then
      (( pos++ ))
      _fi_newline $pos $pending_cont
      pending_cont=0 cmdpos=1 prev=$'\n'
      continue
    fi
    # Newlines inside this word (quotes, $( ), ...) add no level.
    local -i tlen=${#tok} k
    for (( k = 1; k <= tlen; k++ )); do
      [[ ${tok[k]} == $'\n' ]] && { recs+=($(( pos + k ))) lvls+=(0) }
    done
    (( pos += tlen ))

    # First token on a line: middle/closing keywords sit at the outer level.
    if (( line_start && line_rec > 0 )); then
      case $tok in
        (then|else|elif|do|fi|done|esac|'}'|')'|end)
          (( lvls[line_rec] > 0 )) && (( lvls[line_rec]-- )) ;;
        (';;'|';&'|';|')
          ;;
      esac
    fi
    line_start=0

    # Block structure (keywords only count in command position).
    local top=${stack[-1]-}
    if (( cmdpos )); then
      case $tok in
        (if|for|foreach|while|until|select|repeat)
          stack+=($tok); (( depth++ )) ;;
        (case)
          stack+=(case); (( depth++ )) ;;
        (fi|done|end)
          (( ${#stack} )) && { stack[-1]=(); (( depth > 0 )) && (( depth-- )) } ;;
        (esac)
          [[ $top == casebody ]] && { stack[-1]=(); (( depth-- )) }
          (( ${#stack} )) && { stack[-1]=(); (( depth > 0 )) && (( depth-- )) } ;;
        ('{'|'(')
          stack+=($tok); (( depth++ )) ;;
        ('}')
          (( ${#stack} )) && { stack[-1]=(); (( depth > 0 )) && (( depth-- )) } ;;
      esac
    fi
    # case items: "pattern)" opens the item body, ;; ;& ;| close it.
    if [[ $top == case && $tok == *')' && $tok != '$('* ]]; then
      stack+=(casebody); (( depth++ ))
    elif [[ $tok == (';;'|';&'|';|') && $top == casebody ]]; then
      stack[-1]=(); (( depth-- ))
    elif [[ $tok == ')' && $top == '(' ]]; then
      stack[-1]=(); (( depth-- ))
    fi

    # Command position for the next token.
    case $tok in
      (';'|'&&'|'||'|'|'|'|&'|'&'|'&!'|'&|'|'{'|'('|then|else|elif|do|';;'|';&'|';|'|'!')
        cmdpos=1 ;;
      (if|while|until|time|nocorrect|noglob|builtin|command|exec|-)
        cmdpos=1 ;;
      (*)
        cmdpos=0 ;;
    esac
    [[ $tok == ('|'|'|&'|'&&'|'||') ]] && pending_cont=1 || pending_cont=0
    prev=$tok
  done
  # Trailing newlines after the last token.
  while (( pos < n )); do
    local c=${buf[pos+1]}
    if [[ $c == \\ && ${buf[pos+2]} == $'\n' ]]; then
      (( pos += 2 ))
      _fi_newline $pos 1
      continue
    fi
    (( pos++ ))
    [[ $c == $'\n' ]] && _fi_newline $pos $pending_cont && pending_cont=0
  done
  for (( i = 1; i <= ${#recs}; i++ )); do reply+=("$recs[i] $lvls[i]"); done
  unfunction _fi_newline 2>/dev/null
}
