# `nix run .#try`. fishy's early start goes here, the only file zsh reads
# before /etc/zshrc: that one runs `bindkey -e`, which loads zle, and zle must
# not load before start.zsh has turned off zsh's own terminal integration.
# fish then also boots while every other startup file runs.
source "$FISHY_ROOT/fishy/start.zsh"
[[ -r $HOME/.zshenv ]] && source $HOME/.zshenv
