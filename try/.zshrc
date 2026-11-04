# `nix run .#try`: your real zsh config, then fishy on top (nothing installed).
[[ -r $HOME/.zshrc ]] && source $HOME/.zshrc
source "$FISHY_ROOT/fishy/fishy.zsh"
