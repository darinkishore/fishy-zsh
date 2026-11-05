# darin's abbreviations, shaped exactly as home-manager writes them: inside
# config.fish's interactive-only block (so the server must load its config as
# interactive fish does). `e` is harness-only: an abbreviation Enter can run.
set -g fish_greeting
function fish_prompt
    echo -n '> '
end
function fish_right_prompt
end

status is-interactive; and begin

    # Abbreviations
    abbr --add -- cl 'claude --dangerously-skip-permissions -v'
    abbr --add -- js 'cd $FLAKE && just sys'
    abbr --add -- e 'echo expanded'

end
