# fishy-zsh dev zshrc (baseline = darin's current zsh setup, minus unrelated hooks)
PROMPT='> '
HISTSIZE=100000
SAVEHIST=100000
autoload -U compinit && compinit -d "$HOME/.zcompdump"
source /nix/store/lni2rmgh94kjwy3kbv9iyll803y6x2hy-zsh-autosuggestions-0.7.1/share/zsh-autosuggestions/zsh-autosuggestions.zsh
ZSH_AUTOSUGGEST_STRATEGY=(history)
source /nix/store/9v0w1g0hdqirrk7sg7jsvcx1mvigmq26-zsh-syntax-highlighting-0.8.0/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
