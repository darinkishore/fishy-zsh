# fishy early start: boot the fish servers (and fish's interactive setup on
# the async one) while the rest of the shell's startup files run, so the first
# prompt does not wait for fish to start. Optional: fishy.zsh starts them
# itself if this was not sourced.
#
#   source /path/to/fishy/start.zsh    # .zshenv (before /etc/zshrc loads zle)
#   ...                                # the rest of your config
#   source /path/to/fishy/fishy.zsh    # end of .zshrc

[[ -o interactive && -o zle ]] || return 0

typeset -g FISHY_DIR=${${(%):-%x}:A:h}

# zsh's own terminal integration (OSC 133 marks, OSC 7) would duplicate fish's,
# which prompt.zsh writes. zle reads this when its module loads (it probes the
# terminal then, and reports the cwd), so it must come before anything loads
# zle: one more reason to source this file first.
{ eval '.term.extensions+=(-integration)' } 2>/dev/null
(( $+functions[fishy-call] )) || source $FISHY_DIR/bridge.zsh
_fishy_ensure sync
_fishy_ensure async
# fish's interactive setup (__fish_config_interactive: e.g. builtins complete
# no files). The sync server gets it from its first fish_prompt event, like
# fish; the async server, which never sees prompts, gets it now.
fishy-tell async capture __fish_on_interactive
typeset -gi _fishy_started_early=1
