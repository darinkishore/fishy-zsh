#!/usr/bin/env zsh -f
# Decode input with fishy's port of fish's decoder and print every key event
# the way `fish_key_reader -cV` does (harness/keys.py compares the two).
#
#   zsh -f harness/keydecode.zsh PRINTF-ESCAPED-INPUT...
#
# Each argument is one burst of input, decoded on its own (the end of a burst
# is a read timeout, like a pause between keypresses).

emulate zsh
setopt extended_glob
fishy-log() { : }
source ${0:A:h}/../fishy/input.zsh
_fk_verase=127   # termctrl's pty, like Ghostty's: erase = ^?

# zle's `read -k 1 [-t T] VAR`, fed from $_in; an empty buffer times out.
typeset -g _in=''
read() {
  local var=${@[-1]}
  (( ${#_in} )) || return 1
  : ${(P)var::=${_in[1]}}
  _in=${_in:1}
}

# fish: char_to_symbol.
_sym() {
  local -i c=$1 first=$2
  if (( c <= 32 || c == 127 )); then
    case $c in
      (9) REPLY='\t' ;; (13) REPLY='\r' ;; (27) REPLY='\e' ;;
      (*) REPLY=$(printf '\\x%02x' $c) ;;
    esac
  elif (( c < 128 )); then
    local ch=${(#)c}
    if [[ $ch == [\[\]\(\)\<\>\{\}\*\\\$\;\&\|\'\"] ]] || { (( first )) && [[ $ch == [~#] ]] }; then
      REPLY="\\$ch"
    else
      REPLY=$ch
    fi
  elif (( c >= 0xF600 && c < 0xF700 )); then
    REPLY=$(printf '\\x%02x' $(( c - 0xF600 )))
  elif (( c >= 0xE000 && c <= 0xF8FF )); then
    REPLY=$(printf '\\u%04X' $c)
  else
    local ch=${(#)c}
    if (( ${(m)#ch} > 0 )); then REPLY=$ch
    elif (( c <= 0xFFFF )); then REPLY=$(printf '\\u%04X' $c)
    else REPLY=$(printf '\\U%06X' $c)
    fi
  fi
}

typeset -A _names
for k v in ${(kv)_fk_cp}; do [[ $k == f<-> ]] || _names[$v]=$k; done

# fish: From<Key> for WString.
_key_name() {
  local -i m=$1 c=$2
  if [[ -n ${_names[$c]} ]]; then REPLY=$_names[$c]
  elif (( c >= _FK_F1 && c < _FK_F1 + 12 )); then REPLY=f$(( c - _FK_F1 + 1 ))
  else _sym $c $(( m == 0 ))
  fi
  (( m & _FK_SHIFT )) && REPLY="shift-$REPLY"
  (( m & _FK_ALT )) && REPLY="alt-$REPLY"
  (( m & _FK_CTRL )) && REPLY="ctrl-$REPLY"
  (( m & _FK_SUPER )) && REPLY="super-$REPLY"
}

local arg ev seq out i
local -a f
for arg in "$@"; do
  printf -v _in "$arg"
  _fishy_evq=()
  while _fishy_readch 0; do
    ev=$REPLY
    [[ ${ev[1]} == K ]] || continue
    f=("${(@ps:\x1f:)ev}")
    _fk_ev_seq "$ev"; seq=$REPLY
    out=''
    for (( i = 1; i <= ${#seq}; i++ )); do
      local ch=${seq[i]}
      _sym $(( #ch )) $(( i == 1 )); out+=$REPLY
    done
    print -r -- "# decoded from: $out"
    if [[ -n $f[7] ]]; then
      local -i notext=0
      _fk_text $f[2] $f[3] $f[4] '' || notext=1
      if (( ${#f[7]} > 1 || notext )) || [[ ${f[7][1]} != "$REPLY" ]]; then
        print -r -- "# text for insertion (not used for bind matching): $f[7]"
      fi
    fi
    _key_name $f[2] $f[3]; print -r -- "bind $REPLY 'do something'"
    if (( f[4] )); then
      _key_name $(( f[2] & ~_FK_SHIFT )) $f[4]; print -r -- "bind $REPLY 'do something' # shifted key"
    fi
    if (( f[2] && f[5] )); then
      _key_name $f[2] $f[5]; print -r -- "bind $REPLY 'do something' # physical key"
    fi
  done
  print -r -- '--'
done
