#!/usr/bin/env zsh -f
# Which binding fishy's port of fish's find_binding picks for each input, in
# the order fish lists its presets (harness/keymatch.py compares with fish).
#
#   zsh -f harness/keymatch.zsh PRINTF-ESCAPED-INPUT...
#
# For every key event: "N;" (the Nth preset binding), or the text the generic
# self-insert binding inserts. Each argument is one burst of input.

emulate zsh
setopt extended_glob
zmodload zsh/zle
fishy-log() { : }
source ${0:A:h}/../fishy/input.zsh
source ${0:A:h}/../fishy/keys.zsh
# fish's last preset, which fishy leaves out (no history pager), so the
# numbering lines up.
fishy-bind ctrl-r fishy-history-pager
_fishy_binds_compile
_fk_verase=127

typeset -g _in=''
read() {
  local var=${@[-1]}
  (( ${#_in} )) || return 1
  : ${(P)var::=${_in[1]}}
  _in=${_in:1}
}

local arg out ev c first
for arg in "$@"; do
  printf -v _in "$arg"
  _fishy_evq=() out=''
  while (( ${#_in} || ${#_fishy_evq} )); do
    if (( ! ${#_fishy_evq} )); then
      c=${_in[1]} _in=${_in:1}
      _fd_out=()
      _fishy_decode "$c"
      _fishy_evq=("$_fd_out[@]")
      continue
    fi
    ev=$_fishy_evq[1]
    if [[ ${ev[1]} != K ]]; then shift _fishy_evq; continue; fi
    # _fishy_dispatch_one's matching.
    _fpk_ev=() _fpk_kind=() _fpk_mods=() _fpk_cp=() _fpk_sh=() _fpk_base=() _fpk_seq=()
    _fpk_idx=0 _fpk_sub=0 _fpk_timeout=0
    _fishy_readch
    _fpk_add "$REPLY"
    if ! _fishy_find_binding; then
      _fishy_evq=("${(@)_fpk_ev[2,-1]}" "$_fishy_evq[@]")
      continue
    fi
    first=$_fpk_ev[1]
    _fishy_evq=("${(@)_fpk_ev[_fpk_idx+1,-1]}" "$_fishy_evq[@]")
    if [[ $_fkb_style[_fb] == G ]]; then
      shift _fishy_evq
      local -a f=("${(@ps:\x1f:)first}")
      _fk_text $f[2] $f[3] $f[4] "$f[7]" && out+=$REPLY
    else
      out+="$_fb;"
    fi
  done
  print -r -- "$out"
  print -r -- '--'
done
