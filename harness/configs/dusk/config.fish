# The plugins dusk's fish loads (plugins: autopair, fzf.fish, sponge) on top of
# the neutral harness prompt.
set -g fish_greeting
function fish_prompt
    echo -n '> '
end
function fish_right_prompt
end
