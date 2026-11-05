# fishy input: fish's key input layer, ported from fish 4.9.3:
#   src/key.rs            key notation, canonical control characters
#   src/input/decode.rs   bytes -> key events (legacy, CSI/SS3, kitty CSI u)
#   src/input/binding.rs  key events -> the binding fish runs (find_binding)
#   src/tty_handoff.rs    which keyboard protocol to turn on, and when
#
# zle only routes bytes. Printable text goes straight to the self-insert widgets
# (fish's generic binding, batched like read_normal_chars; keys.zsh). Every
# other byte (control characters, DEL, ESC) runs fishy-key, which reads the
# rest of the sequence like fish's decoder and matches the resulting key events
# against the binding table (fish's key notation; user bindings before presets)
# the way find_binding does: modifiers, kitty's shifted and base-layout keys,
# legacy ESC-prefixed alt, raw escape-sequence bindings.
#
# One timing difference: zle's read timeout counts in 1/100 s, so the wait
# that tells a lone legacy ESC from an escape sequence is 10ms (fish: 1ms).
# Every other wait (30ms) is exact.

typeset -g _fk_us=$'\x1f'

# ---------------------------------------------------------------- keys

# Modifier bits, as kitty and fish's parse_mask number them.
typeset -gi _FK_SHIFT=1 _FK_ALT=2 _FK_CTRL=4 _FK_SUPER=8

# fish's named keys are private-use codepoints from U+F500 (key.rs).
typeset -gA _fk_cp=(minus 45 comma 44)
() {
  local -a names=(backspace delete escape enter up down left right pageup pagedown
                  home end insert tab space menu printscreen)
  local -i i
  for (( i = 1; i <= $#names; i++ )); do _fk_cp[$names[i]]=$(( 0xF500 + i - 1 )); done
  for (( i = 1; i <= 12; i++ )); do _fk_cp[f$i]=$(( 0xF500 + 242 + i )); done
}
typeset -gi _FK_BACKSPACE=$_fk_cp[backspace] _FK_DELETE=$_fk_cp[delete] \
  _FK_ESCAPE=$_fk_cp[escape] _FK_ENTER=$_fk_cp[enter] _FK_UP=$_fk_cp[up] \
  _FK_DOWN=$_fk_cp[down] _FK_LEFT=$_fk_cp[left] _FK_RIGHT=$_fk_cp[right] \
  _FK_PAGE_UP=$_fk_cp[pageup] _FK_PAGE_DOWN=$_fk_cp[pagedown] _FK_HOME=$_fk_cp[home] \
  _FK_END=$_fk_cp[end] _FK_INSERT=$_fk_cp[insert] _FK_TAB=$_fk_cp[tab] \
  _FK_SPACE=$_fk_cp[space] _FK_MENU=$_fk_cp[menu] _FK_PRINT_SCREEN=$_fk_cp[printscreen] \
  _FK_F1=$_fk_cp[f1]

# The tty's erase character at startup (fish: get_terminal_mode_on_startup's
# VERASE), which fish reads as backspace; -1 if unset.
typeset -gi _fk_verase=-1
_fishy_input_read_verase() {
  local s
  s=$(command stty -a </dev/tty 2>/dev/null) || return 0
  [[ $s =~ 'erase = ([^;[:space:]]+)' ]] || return 0
  case $match[1] in
    ('^?') _fk_verase=127 ;;
    (^?) local ch=${match[1][2]}; _fk_verase=$(( #ch ^ 64 )) ;;
    (?) local ch=$match[1]; _fk_verase=$(( #ch )) ;;
  esac
}

# fish: canonicalize_keyed_control_char.
_fk_keyed() {
  local -i c=$1
  if (( c == 13 )); then REPLY=$_FK_ENTER
  elif (( c == 9 )); then REPLY=$_FK_TAB
  elif (( c == 32 )); then REPLY=$_FK_SPACE
  elif (( c == _fk_verase )); then REPLY=$_FK_BACKSPACE
  elif (( c == 127 )); then REPLY=$_FK_DELETE
  elif (( c == 27 )); then REPLY=$_FK_ESCAPE
  else REPLY=$c
  fi
}

# fish: canonicalize_unkeyed_control_char.
_fk_unkeyed() {
  local -i c=$1
  if (( c == 0 )); then REPLY=$_FK_SPACE
  elif (( c < 27 )); then REPLY=$(( c - 1 + 97 ))
  else REPLY=$(( c - 1 + 65 ))
  fi
}

# fish: canonicalize_control_char for byte $1. Sets _fk_m/_fk_c; fails if
# the byte is not a control character.
_fk_control() {
  local -i c=$1
  _fk_keyed $c
  if (( REPLY > 255 )); then _fk_m=0 _fk_c=$REPLY; return 0; fi
  (( c < 32 )) || return 1
  _fk_unkeyed $c
  _fk_m=$_FK_CTRL _fk_c=$REPLY
}

# fish: Key::from_single_char for codepoint $1 -> _fk_m/_fk_c.
_fk_single_char() {
  local -i c=$1
  if (( c < 256 )) && _fk_control $c; then return 0; fi
  _fk_m=0 _fk_c=$c
}

# fish: canonicalize_key for (mods $1, codepoint $2) -> _fk_m/_fk_c.
_fk_canonicalize() {
  _fk_m=$1 _fk_c=$2
  (( _fk_c == 27 )) && return 0   # leave raw escapes to canonicalize_raw_escapes
  _fk_keyed $_fk_c
  _fk_c=$REPLY
  if (( _fk_c < 32 )); then
    (( _fk_m & _FK_CTRL )) && return 1   # "Cannot add control modifier to control character"
    _fk_unkeyed $_fk_c
    _fk_c=$REPLY
    (( _fk_m |= _FK_CTRL ))
  fi
  return 0
}

typeset -gi _fk_m=0 _fk_c=0

# fish: parse_keys (bind's key notation) -> reply=("mods:cp" ...).
# REPLY=raw if bind would treat it as a raw escape sequence.
_fk_parse_keys() {
  local value=$1 name key
  local -a keys
  local -i i n=${#value} m c
  reply=() REPLY=normal
  (( n )) || return 0
  local -i first=$(( #value ))
  if (( n == 1 )); then
    _fk_canonicalize 0 $first
    keys=("$_fk_m:$_fk_c")
  elif { (( n >= 2 && n <= 3 )) && [[ $value != *[-,]* && -z ${_fk_cp[$value]+x} \
         && $value != F* && $value != f[0-9]* ]] } || (( first < 32 )); then
    # Legacy notation: one key per character.
    for (( i = 1; i <= n; i++ )); do
      local ch=${value[i]}
      _fk_canonicalize 0 $(( #ch )) || return 1
      keys+=("$_fk_m:$_fk_c")
    done
    (( n > 2 && first == 27 )) && REPLY=raw
  else
    for name in "${(@s:,:)value}"; do
      if [[ $name == - ]]; then
        _fk_canonicalize 0 45; keys+=("$_fk_m:$_fk_c"); continue
      fi
      local -a parts=("${(@s:-:)name}")
      m=0
      for (( i = 1; i < $#parts; i++ )); do
        case $parts[i] in
          (ctrl) (( m |= _FK_CTRL )) ;;
          (alt) (( m |= _FK_ALT )) ;;
          (shift) (( m |= _FK_SHIFT )) ;;
          (super) (( m |= _FK_SUPER )) ;;
          (*) return 1 ;;
        esac
      done
      key=$parts[-1]
      if [[ -n ${_fk_cp[$key]+x} && $key != f<-> ]]; then
        _fk_canonicalize $m $_fk_cp[$key] || return 1
      elif (( ${#key} == 1 )); then
        _fk_canonicalize $m $(( #key )) || return 1
      elif [[ $key == f<1-12> ]]; then
        _fk_m=$m _fk_c=$_fk_cp[$key]
      else
        return 1
      fi
      keys+=("$_fk_m:$_fk_c")
    done
  fi
  # fish: canonicalize_raw_escapes (historical \ek means alt-k).
  if [[ " ${keys[*]} " == *':27 '* ]]; then
    local -a canon
    local -i lit=0
    for key in $keys; do
      m=${key%%:*} c=${key#*:}
      if (( lit )); then
        lit=0
        if (( m & _FK_ALT )); then
          canon+=("0:$_FK_ESCAPE")
        else
          (( m |= _FK_ALT ))
          (( c == 27 )) && c=$_FK_ESCAPE
        fi
      elif (( c == 27 )); then
        lit=1
        continue
      fi
      canon+=("$m:$c")
    done
    (( lit )) && canon+=("0:$_FK_ESCAPE")
    keys=("$canon[@]")
  fi
  reply=("$keys[@]")
}

# ---------------------------------------------------------------- bindings
#
# Entries "notation<US>widget<US>flags", in fish's `bind` order. Widgets:
# a zle widget name, or @self-insert / @self-insert-expand (fish's self-insert,
# and self-insert expand-abbr). Flag s: fish code rather than readline
# functions (fish turns the keyboard protocols off while it runs).

typeset -ga _fishy_user_binds _fishy_preset_binds
# fishy-bind [-u] [-s] [-K [-R]] KEY WIDGET
#   -u  a user binding (tried before the presets)
#   -s  fish code (protocols off while it runs)
#   -K  KEY is already keys in fishy's "mods:cp ..." form; -R a raw escape
#       sequence binding (user-bindings hands them over that way)
fishy-bind() {
  local list=_fishy_preset_binds flags=''
  while [[ $1 == -[usKR] ]]; do
    case $1 in
      (-u) list=_fishy_user_binds ;;
      (-s) flags+=s ;;
      (-K) flags+=K ;;
      (-R) flags+=R ;;
    esac
    shift
  done
  local spec=$1 widget=$2 e
  local -a cur=("${(@P)list}")
  local -i i
  for (( i = 1; i <= $#cur; i++ )); do
    e=$cur[i]
    if [[ ${e%%$_fk_us*} == "$spec" ]]; then
      cur[i]="$spec$_fk_us$widget$_fk_us$flags"
      set -A $list "$cur[@]"
      _fishy_binds_dirty=1
      return
    fi
  done
  set -A $list "$cur[@]" "$spec$_fk_us$widget$_fk_us$flags"
  _fishy_binds_dirty=1
}

# The compiled table, user bindings first (fish: bindings, then
# preset_bindings): style (G generic, N normal, R raw), keys, widget, flags.
# _fkb_first[key]: the first binding whose first key is key; _fkb_raw_first:
# the first raw binding (see _fishy_find_binding's shortcut).
typeset -ga _fkb_style _fkb_keys _fkb_widget _fkb_flags
typeset -gA _fkb_first
typeset -gi _fishy_binds_dirty=1 _fkb_raw_first=0
_fishy_binds_compile() {
  emulate -L zsh
  _fkb_style=() _fkb_keys=() _fkb_widget=() _fkb_flags=() _fkb_first=() _fkb_raw_first=0
  local e spec
  local -a f
  for e in "$_fishy_user_binds[@]" "$_fishy_preset_binds[@]"; do
    f=("${(@ps:\x1f:)e}")
    spec=$f[1]
    if [[ -z $spec ]]; then
      _fkb_style+=(G) _fkb_keys+=('')
    elif [[ $f[3] == *K* ]]; then
      if [[ $f[3] == *R* ]]; then _fkb_style+=(R); else _fkb_style+=(N); fi
      _fkb_keys+=("$spec")
    else
      _fk_parse_keys "$spec" || { fishy-log "bind: cannot parse key '$spec'"; continue }
      if [[ $REPLY == raw ]]; then _fkb_style+=(R); else _fkb_style+=(N); fi
      _fkb_keys+=("${(j: :)reply}")
    fi
    _fkb_widget+=("$f[2]") _fkb_flags+=("$f[3]")
  done
  local -i i
  local k
  for (( i = 1; i <= ${#_fkb_style}; i++ )); do
    [[ $_fkb_style[i] == G ]] && continue
    if [[ $_fkb_style[i] == R ]]; then
      (( _fkb_raw_first )) || _fkb_raw_first=$i
      continue
    fi
    k=${_fkb_keys[i]%% *}
    [[ -n ${_fkb_first[$k]} ]] || _fkb_first[$k]=$i
  done
  (( _fkb_raw_first )) || _fkb_raw_first=$(( ${#_fkb_style} + 1 ))
  _fishy_binds_dirty=0
}

# ---------------------------------------------------------------- decoding
#
# An event is "kind<US>mods<US>cp<US>shifted<US>base<US>explicit<US>text<US>seq"
# (seq, the input it came from, may itself contain US: it is everything after
# the seventh one):
#   K  a key (shifted/base 0 when the terminal reported none)
#   P  bracketed paste starts (zle's bracketed-paste reads the rest)
#   M  left mouse click; cp = x, shifted = y (viewport cells, from 0)
#   I/O  focus in/out

typeset -g _fd_buf='' _fd_state='' _fd_ev=''

# REPLY = the seq field of event $1.
_fk_ev_seq() { REPLY=${1#*$_fk_us*$_fk_us*$_fk_us*$_fk_us*$_fk_us*$_fk_us*$_fk_us} }
typeset -gi _fd_unc=0
typeset -ga _fd_out

_fd_key_event() {  # mods cp [shifted base explicit text]
  _fd_ev="K$_fk_us$1$_fk_us$2$_fk_us${3:-0}$_fk_us${4:-0}$_fk_us${5:-0}$_fk_us$6$_fk_us$_fd_buf"
  _fd_state=C
}

# fish: read_sequence_byte. 1ms after a lone ESC (10ms here), else 30ms.
_fd_read() {
  local c t=0.0299
  [[ $_fd_buf == $'\e' ]] && t=0.0099
  read -k 1 -t $t c || { REPLY=''; return 1 }
  _fd_buf+=$c
  REPLY=$c
}

# fish: on_byte_read, for the char $1 zle already read. Appends the events,
# in fish's queue order, to _fd_out.
_fishy_decode() {
  _fd_buf=$1 _fd_state=I _fd_ev='' _fd_unc=0
  [[ $1 == $'\e' ]] && _fishy_parse_escape 0
  local state=$_fd_state ev=$_fd_ev
  local -i unc=$_fd_unc
  if [[ $state == I ]]; then
    # Not an escape sequence: the last char, as a control character or text.
    local lch=${_fd_buf[-1]}
    local -i lc=$(( #lch ))
    if (( lc < 128 )) && _fk_control $lc; then
      _fd_key_event $_fk_m $_fk_c
    else
      _fd_key_event 0 $lc
    fi
    ev=$_fd_ev
  elif [[ $state == E ]]; then
    ev=''
  fi
  local -i push_esc=0
  if (( unc )); then
    if [[ $ev != K* ]]; then
      push_esc=1
    else
      local -a f=("${(@ps:\x1f:)ev}")
      local -i have_legacy
      if (( !(f[2] & _FK_ALT) && !f[6] )); then
        (( f[2] |= _FK_ALT ))
        have_legacy=$(( unc == 2 ))
      else
        have_legacy=1
      fi
      local seq=${(pj:\x1f:)f[8,-1]}
      if (( have_legacy )); then
        seq=${seq:1}
        push_esc=1
      fi
      ev=${(pj:\x1f:)f[1,7]}$_fk_us$seq
    fi
  fi
  # fish pushes the escape to the front first, then the event in front of it.
  [[ -n $ev ]] && _fd_out+=("$ev")
  (( push_esc )) && _fd_out+=("K${_fk_us}0$_fk_us$_FK_ESCAPE${_fk_us}0${_fk_us}0${_fk_us}0$_fk_us$_fk_us"$'\e')
  return 0
}

# fish: parse_escape_sequence. _fd_buf is "\e".
_fishy_parse_escape() {
  local -i recursive=$1
  if ! _fd_read; then
    _fd_key_event 0 $_FK_ESCAPE
    _fd_unc=0
    return
  fi
  case $REPLY in
    ($'\e')
      if (( ! recursive )); then
        _fd_buf=$'\e'
        _fishy_parse_escape 1
        if [[ $_fd_state == I ]]; then
          _fd_buf=$'\e'$_fd_buf
        elif [[ $_fd_state == C && $_fd_ev == K* ]]; then
          _fk_ev_seq "$_fd_ev"
          _fd_ev=${_fd_ev%"$REPLY"}$'\e'$REPLY
        fi
        (( _fd_unc++ ))
        return
      fi
      _fd_state=I _fd_unc=1
      return ;;
    ('[') _fishy_parse_csi ;;
    (O) _fishy_parse_ss3 ;;
    (']') _fishy_parse_osc ;;
    (P) _fishy_parse_dcs ;;
    (*) _fd_state=I _fd_unc=1; return ;;
  esac
  _fd_unc=0
}

# fish: char::from_u32 validity.
_fd_valid_char() { (( $1 < 0x110000 && ($1 < 0xD800 || $1 > 0xDFFF) )) }

# fish: parse_mask -> REPLY = modifier bits; caps lock in _fd_caps.
typeset -gi _fd_caps=0
_fd_mask() {
  local -i mask=$1
  REPLY=$(( mask & 15 ))
  _fd_caps=$(( (mask & 64) != 0 ))
}

# fish: parse_csi. _fd_buf is "\e[".
_fishy_parse_csi() {
  local c private=''
  if ! _fd_read; then _fd_key_event $_FK_ALT 91; return; fi
  c=$REPLY
  if [[ $c == '[' ]]; then
    # Linux console function keys: ESC [ [ A..E
    _fd_read; local -i k
    case $REPLY in
      (A) k=1 ;; (B) k=2 ;; (C) k=3 ;; (D) k=4 ;; (E) k=5 ;;
      (*) _fd_state=E; return ;;
    esac
    _fd_key_event 0 $(( _FK_F1 + k - 1 ))
    return
  fi
  if [[ $c == [?\<=\>] ]]; then
    private=$c
    _fd_read; c=$REPLY
  fi
  local -a p=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
              0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
  local -i count=0 sub=0 v
  while (( count < 16 )) && [[ -n $c && $c == [0-9:\;\<=\>?] ]]; do
    if [[ $c == [0-9] ]]; then
      v=$(( p[count*4+sub+1] * 10 + c ))
      (( v > 4294967295 )) && { _fd_state=E; return }
      p[count*4+sub+1]=$v
    elif [[ $c == : ]] && (( sub < 3 )); then
      (( sub++ ))
    elif [[ $c == ';' ]]; then
      (( count++ )); sub=0
    else
      _fd_state=E; return
    fi
    _fd_read; c=$REPLY
  done
  if [[ $c != '$' ]]; then
    if [[ -z $c ]] || (( #c < 0x40 || #c > 0x7e )); then _fd_state=E; return; fi
  fi
  local -i p00=$p[1] p01=$p[2] p02=$p[3] p10=$p[5]
  case $c in
    ('$')
      _fd_read
      [[ $REPLY == y ]] && { _fd_state=E; return }   # DECRPM
      case $p00 in
        (23|24) _fd_key_event $_FK_SHIFT $(( _FK_F1 + 10 + p00 - 23 )) ;;   # rxvt
        (*) _fd_state=E ;;
      esac
      return ;;
    (A) _fd_masked $_FK_UP ;;
    (B) _fd_masked $_FK_DOWN ;;
    (C) _fd_masked $_FK_RIGHT ;;
    (D) _fd_masked $_FK_LEFT ;;
    (E) _fd_masked 53 ;;           # numeric keypad 5
    (F) _fd_masked $_FK_END ;;
    (H) _fd_masked $_FK_HOME ;;
    ([Mm])
      local -i sgr=0
      [[ $private == '<' ]] && sgr=1
      (( ! sgr )) && [[ $c == m ]] && { _fd_state=E; return }
      local -i button x y
      if (( sgr )); then
        button=$p00
      else
        _fd_read || { _fd_state=E; return }
        button=$(( #REPLY - 32 )); (( button < 0 )) && { _fd_state=E; return }
      fi
      if (( sgr )); then x=$p[5]; else _fd_read && x=$(( #REPLY - 32 )) || x=-1; fi
      (( x < 0 )) && { _fd_state=E; return }
      (( x -= 1 )); (( x < 0 )) && { _fd_state=E; return }
      if (( sgr )); then y=$p[9]; else _fd_read && y=$(( #REPLY - 32 )) || y=-1; fi
      (( y < 0 )) && { _fd_state=E; return }
      (( y -= 1 )); (( y < 0 )) && { _fd_state=E; return }
      _fd_mask $(( (button >> 2) & 7 ))
      if (( (button & 0x43) != 0 )) || [[ $c != M ]] || (( REPLY != 0 )); then
        _fd_state=E; return
      fi
      _fd_ev="M${_fk_us}0$_fk_us$x$_fk_us$y${_fk_us}0${_fk_us}0$_fk_us$_fk_us$_fd_buf"
      _fd_state=C
      return ;;
    (t) _fd_read; _fd_read; _fd_state=E; return ;;
    (T) local -i i; for (( i = 0; i < 6; i++ )); do _fd_read; done; _fd_state=E; return ;;
    (P) _fd_masked $_FK_F1 ;;
    (Q) _fd_masked $(( _FK_F1 + 1 )) ;;
    (R) _fd_state=E; return ;;      # cursor position report
    (S) _fd_masked $(( _FK_F1 + 3 )) ;;
    ('~')
      case $p00 in
        (1|7) _fd_masked $_FK_HOME ;;
        (2) _fd_masked $_FK_INSERT ;;
        (3) _fd_masked $_FK_DELETE ;;
        (4|8) _fd_masked $_FK_END ;;
        (5) _fd_masked $_FK_PAGE_UP ;;
        (6) _fd_masked $_FK_PAGE_DOWN ;;
        (1[1-5]) _fd_masked $(( _FK_F1 + p00 - 11 )) ;;
        (1[7-9]|2[01]) _fd_masked $(( _FK_F1 + 5 + p00 - 17 )) ;;
        (2[34]) _fd_masked $(( _FK_F1 + 10 + p00 - 23 )) ;;
        (2[56]) _fd_key_event $_FK_SHIFT $(( _FK_F1 + 2 + p00 - 25 )) ;;
        (27)
          local -i k=$p[9]
          _fd_valid_char $k || { _fd_state=E; return }
          _fk_keyed $k
          _fd_masked $REPLY ;;
        (2[89]) _fd_key_event $_FK_SHIFT $(( _FK_F1 + 4 + p00 - 28 )) ;;
        (3[12]) _fd_key_event $_FK_SHIFT $(( _FK_F1 + 6 + p00 - 31 )) ;;
        (3[34]) _fd_key_event $_FK_SHIFT $(( _FK_F1 + 8 + p00 - 33 )) ;;
        (200)
          _fd_ev="P${_fk_us}0${_fk_us}0${_fk_us}0${_fk_us}0${_fk_us}0$_fk_us$_fk_us"$'\e[200~'
          _fd_state=C ;;
        (*) _fd_state=E ;;
      esac
      return ;;
    (u)
      [[ $private == '?' ]] && { _fd_state=E; return }   # kitty keyboard support reply
      local -i key
      case $p00 in
        (5735[89]|57360|57362|574(1[6]|2[89]|[3-4][0-9]|5[0-4])) _fd_state=E; return ;;
        (57361) key=$_FK_PRINT_SCREEN ;;
        (57363) key=$_FK_MENU ;;
        (5739[9]|5740[0-8]) key=$(( 48 + p00 - 57399 )) ;;
        (57409) key=46 ;; (57410) key=47 ;; (57411) key=42 ;; (57412) key=45 ;;
        (57413) key=43 ;; (57414) key=$_FK_ENTER ;; (57415) key=61 ;;
        (57417) key=$_FK_LEFT ;; (57418) key=$_FK_RIGHT ;; (57419) key=$_FK_UP ;;
        (57420) key=$_FK_DOWN ;; (57421) key=$_FK_PAGE_UP ;; (57422) key=$_FK_PAGE_DOWN ;;
        (57423) key=$_FK_HOME ;; (57424) key=$_FK_END ;; (57425) key=$_FK_INSERT ;;
        (57426) key=$_FK_DELETE ;;
        (*)
          _fd_valid_char $p00 || { _fd_state=E; return }
          _fk_keyed $p00; key=$REPLY ;;
      esac
      _fd_valid_char $p01 || { _fd_state=E; return }
      _fd_valid_char $p02 || { _fd_state=E; return }
      _fk_keyed $p01
      _fd_kitty $key $REPLY $p02 1
      return ;;
    (Z) _fd_key_event $_FK_SHIFT $_FK_TAB ;;
    (I) _fd_ev="I${_fk_us}0${_fk_us}0${_fk_us}0${_fk_us}0${_fk_us}0$_fk_us$_fk_us$_fd_buf"; _fd_state=C ;;
    (O) _fd_ev="O${_fk_us}0${_fk_us}0${_fk_us}0${_fk_us}0${_fk_us}0$_fk_us$_fk_us$_fd_buf"; _fd_state=C ;;
    (*) _fd_state=E ;;   # DA1 reply, color theme reports, ...
  esac
}

# fish: masked_key (kitty_key without alternate keys); uses p from the caller.
_fd_masked() { _fd_kitty $1 0 0 0 }

# fish: kitty_key(key, shifted, base). $4: the shifted/base fields were sent.
_fd_kitty() {
  local -i key=$1 shifted=$2 base=$3
  local -i raw=$p[5]
  local -i mask=$(( raw > 0 ? raw - 1 : 0 )) explicit=$(( raw != 0 ))
  _fd_mask $mask
  local -i mods=$REPLY i t
  local text='' ch
  if (( _fd_caps && mods == _FK_SHIFT )); then
    # capslock-shift-<letter>: capslock and shift cancel out.
    ch=${(#)key}
    [[ ${(U)ch} != "$ch" ]] && mods=0
  fi
  for (( i = 0; i < 4; i++ )); do
    t=$p[9+i]
    (( t == 0 )) && break
    _fd_valid_char $t || break
    (( t < 32 || (t >= 127 && t < 160) )) && break
    text+=${(#)t}
  done
  _fd_key_event $mods $key $shifted $base $explicit "$text"
}

# fish: parse_ss3. _fd_buf is "\eO".
_fishy_parse_ss3() {
  if ! _fd_read; then _fd_key_event $_FK_ALT 79; return; fi
  local code=$REPLY
  local -i raw=0
  while [[ $code == [0-9] ]]; do
    raw=$(( raw * 10 + code ))
    _fd_read; code=$REPLY
  done
  _fd_mask $(( raw > 0 ? raw - 1 : 0 ))
  local -i m=$REPLY k
  case $code in
    (' ') k=$_FK_SPACE ;;
    (A) k=$_FK_UP ;; (B) k=$_FK_DOWN ;; (C) k=$_FK_RIGHT ;; (D) k=$_FK_LEFT ;;
    (F) k=$_FK_END ;; (H) k=$_FK_HOME ;; (I) k=$_FK_TAB ;; (M) k=$_FK_ENTER ;;
    (P) k=$_FK_F1 ;; (Q) k=$(( _FK_F1 + 1 )) ;; (R) k=$(( _FK_F1 + 2 )) ;; (S) k=$(( _FK_F1 + 3 )) ;;
    (X) k=61 ;; (j) k=42 ;; (k) k=43 ;; (l) k=44 ;; (m) k=45 ;; (n) k=46 ;; (o) k=47 ;;
    ([p-y]) k=$(( 48 + #code - 112 )) ;;
    (*) _fd_state=E; return ;;
  esac
  _fd_key_event $m $k
}

# fish: read_until_sequence_terminator.
_fd_read_until_st() {
  local -i allow_bel=$1 esc=0
  while _fd_read; do
    (( allow_bel )) && [[ $REPLY == $'\a' ]] && return 0
    (( esc )) && [[ $REPLY == '\' ]] && return 0
    [[ $REPLY == $'\e' ]] && esc=1 || esc=0
  done
  return 1
}

# fish: parse_osc (only background color replies mean anything to fish).
_fishy_parse_osc() { _fd_read_until_st 1; _fd_state=E }

# fish: parse_dcs (XTGETTCAP and XTVERSION replies).
_fishy_parse_dcs() {
  if ! _fd_read; then _fd_key_event $_FK_ALT 80; return; fi
  case $REPLY in
    ([01])
      _fd_read && [[ $REPLY == + ]] && _fd_read && [[ $REPLY == r ]] && _fd_read_until_st 0 ;;
    ('>') _fd_read_until_st 0 ;;
  esac
  _fd_state=E
}

# ---------------------------------------------------------------- event queue

# Decoded events not handled yet (fish's input queue), front first.
typeset -ga _fishy_evq

# fish: readch / readch_timed. $1: timeout for the first byte (seconds), or
# none to wait. REPLY = the event.
_fishy_readch() {
  if (( ${#_fishy_evq} )); then
    REPLY=$_fishy_evq[1]
    shift _fishy_evq
    return 0
  fi
  local c
  if [[ -n $1 ]]; then
    read -k 1 -t $1 c || return 1
  else
    read -k 1 c || return 1
  fi
  while :; do
    _fd_out=()
    _fishy_decode "$c"
    if (( ${#_fd_out} )); then
      REPLY=$_fd_out[1]
      _fishy_evq=("${(@)_fd_out[2,-1]}")
      return 0
    fi
    read -k 1 c || return 1
  done
}

# ---------------------------------------------------------------- matching
#
# fish's EventQueuePeeker: events read while trying bindings, with fields
# split out once.
typeset -ga _fpk_ev _fpk_kind _fpk_mods _fpk_cp _fpk_sh _fpk_base _fpk_seq
typeset -gi _fpk_idx=0 _fpk_sub=0 _fpk_timeout=0
# _fishy_binds_lookup_key: never read input; note that a binding wanted more.
typeset -gi _fpk_noread=0 _fpk_wanted=0

_fpk_add() {
  local -a f=("${(@ps:\x1f:)1}")
  _fpk_ev+=("$1") _fpk_kind+=("$f[1]") _fpk_mods+=("$f[2]") _fpk_cp+=("$f[3]")
  _fpk_sh+=("$f[4]") _fpk_base+=("$f[5]") _fpk_seq+=("${(pj:\x1f:)f[8,-1]}")
}

# fish: apply_shift -> _fk_m/_fk_c; fails when there is no shifted form.
_fk_apply_shift() {  # mods cp do_ascii shifted
  _fk_m=$1 _fk_c=$2
  (( _fk_m & _FK_SHIFT )) || return 0
  if (( $4 )); then
    _fk_c=$4
  elif (( $3 && _fk_c >= 97 && _fk_c <= 122 )); then
    (( _fk_c -= 32 ))
  else
    return 1
  fi
  (( _fk_m &= ~_FK_SHIFT ))
  return 0
}

# fish: match_key_event_to_key for peeked event $1 and key (mods $2, cp $3).
# REPLY = quality: 3 exact, 2 modulo shift, 1 base layout, 0 base layout
# modulo shift.
_fk_match() {
  local -i j=$1 m=$2 c=$3
  local -i em=$_fpk_mods[j] ec=$_fpk_cp[j]
  if (( em == m && ec == c )); then REPLY=3; return 0; fi
  local -i sem sec kem kec kok=1
  if _fk_apply_shift $m $c 1 0; then kem=$_fk_m kec=$_fk_c; else kok=0; fi
  if _fk_apply_shift $em $ec 0 $_fpk_sh[j]; then
    if (( kok && _fk_m == kem && _fk_c == kec )); then REPLY=2; return 0; fi
  fi
  local -i b=$_fpk_base[j]
  if (( em != 0 && b != 0 )); then
    if (( em == m && b == c )); then REPLY=1; return 0; fi
    if _fk_apply_shift $em $b 1 0 && (( kok && _fk_m == kem && _fk_c == kec )); then
      REPLY=0; return 0
    fi
  fi
  return 1
}

# fish: EventQueuePeeker::next_is_char. $1 style, $2 mods, $3 cp, $4 escaped.
_fpk_next_is_char() {
  local style=$1
  local -i m=$2 c=$3 escaped=$4
  (( escaped && _fpk_timeout )) && return 1
  if (( _fpk_idx == ${#_fpk_ev} )); then
    (( _fpk_noread )) && { _fpk_wanted=1; return 1 }
    if (( escaped )); then
      _fishy_readch 0.0299 || { _fpk_timeout=1; return 1 }
    else
      _fishy_readch || { _fpk_timeout=1; return 1 }
    fi
    _fpk_add "$REPLY"
  fi
  local -i j=$(( _fpk_idx + 1 ))
  [[ $_fpk_kind[j] == K ]] || return 1
  local seq=$_fpk_seq[j]
  if [[ $seq == $'\e' ]] && (( m == _FK_ALT )); then
    (( _fpk_idx++ )); _fpk_sub=0
    _fpk_next_is_char $style 0 $c 1
    return
  fi
  if [[ $style == N ]]; then
    _fk_match $j $m $c || return 1
    (( _fpk_idx++ ))
    return 0
  fi
  local -i len=${#seq}
  (( len )) || return 1
  local sc=${seq[_fpk_sub+1]}
  _fk_single_char $(( #sc ))
  if (( _fk_m == m && _fk_c == c )); then
    (( _fpk_sub++ ))
    (( _fpk_sub == len )) && { (( _fpk_idx++ )); _fpk_sub=0 }
    REPLY=3
    return 0
  fi
  if (( m == _FK_ALT )) && [[ $sc == $'\e' ]]; then
    if (( _fpk_sub + 1 == len )); then
      (( _fpk_idx++ )); _fpk_sub=0
      _fpk_next_is_char $style 0 $c 1
      return
    fi
    local nc=${seq[_fpk_sub+2]}
    _fk_single_char $(( #nc ))
    if (( _fk_c == c )); then
      (( _fpk_sub += 2 ))
      (( _fpk_sub == len )) && { (( _fpk_idx++ )); _fpk_sub=0 }
      REPLY=3
      return 0
    fi
  fi
  return 1
}

# fish: try_peek_sequence for binding $1. REPLY = the qualities.
_fpk_try() {
  local style=$_fkb_style[$1] k prev='' q=''
  local -i escaped
  for k in ${=_fkb_keys[$1]}; do
    escaped=0
    [[ $style != N && $prev == "0:$_FK_ESCAPE" ]] && escaped=1
    _fpk_next_is_char $style ${k%%:*} ${k#*:} $escaped || return 1
    q+=$REPLY
    prev=$k
  done
  (( _fpk_sub == 0 )) || return 1
  REPLY=$q
}

# fish: find_binding -> _fb (binding index); _fpk_idx = events it consumes.
typeset -gi _fb=0
_fishy_find_binding() {
  # Shortcut, same answer as the loop: only an exact match on the first key
  # can win outright, so if the first binding for this key is a single key
  # (not escape) and no raw binding can apply, the loop would return it. Raw
  # bindings all start with ESC; a lone ESC event goes through the loop
  # (bindings with alt read on after it).
  local k="$_fpk_mods[1]:$_fpk_cp[1]"
  local -i i=${_fkb_first[$k]:-0}
  if (( i && _fpk_idx == 0 )) && [[ $_fkb_keys[i] != *' '* && $k != "0:$_FK_ESCAPE" \
       && $_fpk_seq[1] != $'\e' ]] && { [[ $_fpk_seq[1] != $'\e'* ]] || (( i < _fkb_raw_first )) }; then
    _fpk_idx=1 _fb=$i
    return 0
  fi
  local -i n=${#_fkb_style} best=0 best_idx=0 best_sub=0 is_escape matched
  local best_q='' q
  # A single-key binding against the first event (already read, not a lone
  # ESC) is just match_key_event_to_key: inline it.
  local -i simple=0 em=$_fpk_mods[1] ec=$_fpk_cp[1] eb=$_fpk_base[1] bm bc
  [[ $_fpk_kind[1] == K && $_fpk_seq[1] != $'\e' ]] && simple=1
  for (( i = 1; i <= n; i++ )); do
    if [[ $_fkb_style[i] == G ]]; then
      (( best )) || { best=$i best_q='' best_idx=$_fpk_idx best_sub=$_fpk_sub }
      continue
    fi
    if (( simple )) && [[ $_fkb_style[i] == N && $_fkb_keys[i] != *' '* ]]; then
      k=$_fkb_keys[i]
      bm=${k%%:*} bc=${k#*:}
      if (( bm == em && bc == ec )); then
        REPLY=3 matched=1 _fpk_idx=1
      elif (( !((bm | em) & _FK_SHIFT) && !(em && eb) )); then
        matched=0     # without shift or a base-layout key only exact matches
      else
        _fk_match 1 $bm $bc && { matched=1; _fpk_idx=1 } || matched=0
      fi
    else
      _fpk_try $i && matched=1 || matched=0
    fi
    if (( matched )); then
      q=$REPLY
      is_escape=0
      [[ $_fkb_keys[i] == "0:$_FK_ESCAPE" ]] && is_escape=1
      if (( ! is_escape )) && [[ $q != *[012]* ]]; then
        _fb=$i
        return 0
      fi
      if (( ! best )) || { (( ! is_escape )) && [[ ! $q < $best_q ]] }; then
        best=$i best_q=$q best_idx=$_fpk_idx best_sub=$_fpk_sub
      fi
    fi
    _fpk_idx=0 _fpk_sub=0
  done
  (( best )) || return 1
  _fpk_idx=$best_idx _fpk_sub=$best_sub
  _fb=$best
}

# find_binding for one unmodified key event with codepoint $1, without
# reading input (fishy-keys-install routes printable keys with it). _fb = the
# binding; _fpk_wanted = some binding would have read more keys.
_fishy_binds_lookup_key() {
  local ch=${(#)1}
  (( $1 == _FK_SPACE )) && ch=' '
  _fpk_ev=() _fpk_kind=() _fpk_mods=() _fpk_cp=() _fpk_sh=() _fpk_base=() _fpk_seq=()
  _fpk_add "K${_fk_us}0$_fk_us$1${_fk_us}0${_fk_us}0${_fk_us}0$_fk_us$_fk_us$ch"
  _fpk_idx=0 _fpk_sub=0 _fpk_timeout=0 _fpk_noread=1 _fpk_wanted=0
  _fishy_find_binding
  local -i r=$?
  _fpk_noread=0
  return r
}

# ---------------------------------------------------------------- dispatch

# fish: codepoint_text / text_to_insert for event fields (mods cp shifted
# text). REPLY = the text, or fails.
_fk_text() {
  local -i m=$1 c=$2 sh=$3
  if [[ -n $4 ]]; then REPLY=$4; return 0; fi
  if (( sh && (m & _FK_SHIFT) )); then (( m &= ~_FK_SHIFT )); c=$sh; fi
  (( m )) && return 1
  if (( c == _FK_SPACE )); then REPLY=' '
  elif (( c == _FK_ENTER )); then REPLY=$'\n'
  elif (( c == _FK_TAB )); then REPLY=$'\t'
  elif (( (c >= 0xE000 && c < 0xF900) || c <= 27 )); then return 1
  else REPLY=${(#)c}
  fi
}

# fish: handle_char_event for a Key event (the generic self-insert binding).
_fishy_key_insert() {
  local -a f=("${(@ps:\x1f:)1}")
  if _fk_text $f[2] $f[3] $f[4] "$f[7]"; then
    _fishy_insert "$REPLY"
  else
    _fishy_last_cmd=''
  fi
}

# Run binding $1 for the key event $2 (fish: binding_execute).
_fishy_bind_exec() {
  local widget=$_fkb_widget[$1]
  local -i script=0
  [[ $_fkb_flags[$1] == *s* ]] && script=1
  (( script )) && _fishy_protocols_set 0
  typeset -g _fishy_cur_event=$2    # the key event (a user binding's self-insert)
  case $widget in
    (@self-insert) _fishy_key_insert "$2" ;;
    (@self-insert-expand) _fishy_key_insert "$2"; _fishy_run expand-abbr ;;
    (*) zle $widget ;;
  esac
  (( script && ! _fishy_accept )) && _fishy_protocols_set 1
  return 0
}

# Handle the event at the front of the queue (fish: read_char and
# handle_char_event).
_fishy_dispatch_one() {
  local ev=$_fishy_evq[1]
  case ${ev[1]} in
    (P)
      shift _fishy_evq
      local text
      zle .bracketed-paste text
      fishy-paste "$text"
      return ;;
    (M)
      shift _fishy_evq
      local -a f=("${(@ps:\x1f:)ev}")
      _fishy_mouse_left $f[3] $f[4]
      return ;;
    (I) shift _fishy_evq; _fishy_bind_run 'emit fish_focus_in'; return ;;
    (O) shift _fishy_evq; _fishy_bind_run 'emit fish_focus_out'; return ;;
  esac
  (( _fishy_binds_dirty )) && _fishy_binds_compile
  _fpk_ev=() _fpk_kind=() _fpk_mods=() _fpk_cp=() _fpk_sh=() _fpk_base=() _fpk_seq=()
  _fpk_idx=0 _fpk_sub=0 _fpk_timeout=0
  _fishy_readch
  _fpk_add "$REPLY"
  if ! _fishy_find_binding; then
    # Nothing matched (not even the generic binding): drop the event.
    _fishy_evq=("${(@)_fpk_ev[2,-1]}" "$_fishy_evq[@]")
    return
  fi
  local -i b=$_fb used=$_fpk_idx
  local first=$_fpk_ev[1]
  # Unconsumed peeked events go back to the front of the queue.
  _fishy_evq=("${(@)_fpk_ev[used+1,-1]}" "$_fishy_evq[@]")
  if [[ $_fkb_style[b] == G ]]; then
    # self-insert takes the next key event off the queue.
    shift _fishy_evq
    _fishy_key_insert "$first"
    return
  fi
  _fishy_bind_exec $b "$first"
}

# fishy-key: a control character, DEL or ESC arrived.
_fishy_w_key() {
  fishy-unswap
  _fd_out=()
  _fishy_decode "$KEYS"
  _fishy_evq=("$_fd_out[@]" "$_fishy_evq[@]")
  _fishy_accept=0
  while (( ${#_fishy_evq} && ! _fishy_accept )); do
    _fishy_dispatch_one
  done
  if (( ${#_fishy_evq} )); then
    # The line was accepted: the rest is typed ahead for the next prompt.
    local ev raw=''
    for ev in "$_fishy_evq[@]"; do _fk_ev_seq "$ev"; raw+=$REPLY; done
    _fishy_evq=()
    zle -U -- "$raw"
  fi
  return 0
}
zle -N fishy-key _fishy_w_key

# A printable key whose binding is fish code (e.g. atuin's `?`): zle calls
# it directly, so it turns the protocols off around it here.
_fishy_w_script_key() {
  local w=${WIDGET#fishy-script-}
  _fishy_protocols_set 0
  _fishy_accept=0
  zle $w
  (( _fishy_accept )) || _fishy_protocols_set 1
}

# fish: mouse_left_click. Not ported yet: the click is dropped.
_fishy_mouse_left() { return 0 }

# ---------------------------------------------------------------- protocols
#
# fish (tty_handoff.rs) turns these on while it reads keys and off while
# anything else runs: commands, and the fish code of bindings. zle writes
# zle_bracketed_paste's pair when it starts and stops reading a line; fishy
# fills it with fish's sequences, and toggles them around fish-code bindings.
# fish also turns on color-theme reporting (2031), which fishy has no use for
# yet: fish only acts on it for light/dark themes.

typeset -g _fishy_proto_on=$'\e[?2004h' _fishy_proto_off=$'\e[?2004l'
typeset -gi _fishy_proto_active=0

_fishy_protocols_set() {
  (( _fishy_proto_active == $1 )) && return 0
  _fishy_proto_active=$1
  if (( $1 )); then
    print -rn -- "$_fishy_proto_on" >/dev/tty
  else
    print -rn -- "$_fishy_proto_off" >/dev/tty
  fi
}

# fish: TtyQuirks::detect + get_supported_protocol + get_protocols, from what
# zsh's terminal probe found (query-modkeys-kitty, .term.id/.term.version).
_fishy_protocols_init() {
  local -a ext=("${(@P)${:-.term.extensions}}")
  local id=${(P)${:-.term.id}} ver=${(P)${:-.term.version}} xtv
  case $id in
    (iTerm.app) xtv="iTerm2 $ver" ;;     # TERM_PROGRAM; XTVERSION says iTerm2
    (*) xtv="$id${ver:+ $ver}" ;;
  esac
  local quirk=none
  local -a v
  if [[ -n ${MC_SID-} && -z ${__mc_kitty_keyboard-} ]]; then
    quirk=mc
  elif [[ $xtv == 'iTerm2 '* ]]; then
    v=("${(@s:.:)${${xtv#iTerm2 }%% *}}")
    if (( $#v >= 3 )) && [[ $v[1] == <-> && $v[2] == <-> && $v[3] == <-> ]] \
       && (( v[1] < 3 || (v[1] == 3 && (v[2] < 5 || (v[2] == 5 && v[3] < 12))) )); then
      quirk=buggy-kitty
    fi
  elif [[ $xtv == 'Konsole '* ]]; then
    quirk=buggy-kitty
  elif [[ $xtv == 'tmux '* ]]; then
    v=("${(@s:.:)${${xtv#tmux }%% *}}")
    (( $#v >= 2 )) && [[ $v[1] == <-> && $v[2] == <-> ]] && quirk=tmux
  elif [[ $xtv == 'WezTerm '* ]]; then
    quirk=wezterm
  fi
  local on='' off=''
  [[ $quirk == tmux ]] && { on+=$'\e[?1004h' off+=$'\e[?1004l' }
  on+=$'\e[?2004h' off+=$'\e[?2004l'
  local proto
  if [[ $quirk == mc ]]; then proto=none
  elif [[ $quirk == buggy-kitty ]]; then proto=other
  elif (( ${ext[(Ie)modkeys-kitty]} )); then proto=kitty
  elif [[ $quirk == wezterm ]]; then proto=wezterm
  else proto=other
  fi
  case $proto in
    (kitty) on+=$'\e[=5u' off+=$'\e[=0u' ;;
    (other) on+=$'\e[>4;1m\e=' off+=$'\e[>4;0m\e>' ;;
    (wezterm) on+=$'\e=' off+=$'\e>' ;;
  esac
  typeset -g _fishy_proto_kind=$proto
  _fishy_proto_on=$on _fishy_proto_off=$off
  zle_bracketed_paste=("$on" "$off")
}

# zle writes the "on" sequences right after line-init and the "off" ones right
# before line-finish.
_fishy_protocols_line_init() { _fishy_proto_active=1 }
_fishy_protocols_line_finish() { _fishy_proto_active=0 }

# On the way out (exit from a binding skips zle's own reset).
_fishy_protocols_exit() { (( _fishy_proto_active )) && _fishy_protocols_set 0; return 0 }
