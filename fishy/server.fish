# fishy server: zsh's line editor asks this (patched, non-interactive) fish for
# fish's own completion / autosuggestion / history / word-motion decisions.
#
# Started per zsh session with the user's normal config, so fish_complete_path,
# functions, abbreviations and history are exactly those of interactive fish.
#
# Protocol (stdin -> stdout), every record NUL-terminated, fields \x1f-separated:
#   request : ID \x1f CWD \x1f SUBCOMMAND \x1f ARGS...
#             SUBCOMMAND is a `__fishy` subcommand, or `env` whose ARGS are
#             NAME=VALUE pairs replacing the exported environment.
#   reply   : the `__fishy` records, then the terminator  \x1e ID

function __fishy_serve
    while read --null --local req
        set --local f (string split -- \x1f $req)
        set --local id $f[1]
        builtin cd -- $f[2] 2>/dev/null
        switch $f[3]
            case env
                __fishy_set_env $f[4..]
            case '*'
                __fishy $f[3..]
        end
        printf '\x1e%s\0' $id
    end
end

function __fishy_set_env
    set --local names
    for kv in $argv
        set --append names (string split --max 1 -- = $kv)[1]
    end
    # Drop exports zsh no longer has; fish's own read-only variables refuse quietly.
    for n in (set --names --export)
        contains -- $n $names; or set --erase --global $n 2>/dev/null
    end
    for kv in $argv
        set --local nv (string split --max 1 -- = $kv)
        test (count $nv) -eq 2; or continue
        set --global --export $nv[1] $nv[2] 2>/dev/null
    end
end

__fishy_serve
