# fishy server: zsh's line editor asks this (patched, non-interactive) fish for
# fish's own completion / autosuggestion / history / highlighting decisions.
#
# Started per zsh session with the user's normal config, so fish_complete_path,
# functions, abbreviations and history are exactly those of interactive fish.
# Everything here is spelled `builtin ...`: user functions (or the stubs that
# define-commands creates for zsh-only names) must never shadow the loop.
#
# Protocol (stdin -> stdout), every record NUL-terminated, fields \x1f-separated:
#   request : ID \x1f CWD \x1f SUBCOMMAND \x1f ARGS...
#             SUBCOMMAND is a `__fishy` subcommand, or `env` whose ARGS are
#             NAME=VALUE pairs replacing the exported environment.
#   reply   : the `__fishy` records, then the terminator  \x1e ID

function __fishy_serve
    while builtin read --null --local req
        builtin set --local f (builtin string split -- \x1f $req)
        builtin set --local id $f[1]
        builtin cd -- $f[2] 2>/dev/null
        if builtin test "$f[3]" = env
            __fishy_set_env $f[4..]
        else
            builtin __fishy $f[3..]
        end
        builtin printf '\x1e%s\0' $id
    end
end

function __fishy_set_env
    builtin set --local names
    for kv in $argv
        builtin set --append names (builtin string split --max 1 -- = $kv)[1]
    end
    # Drop exports zsh no longer has; fish's own read-only variables refuse quietly.
    for n in (builtin set --names --export)
        builtin contains -- $n $names; or builtin set --erase --global $n 2>/dev/null
    end
    for kv in $argv
        builtin set --local nv (builtin string split --max 1 -- = $kv)
        builtin test (builtin count $nv) -eq 2; or continue
        builtin set --global --export $nv[1] $nv[2] 2>/dev/null
    end
end

builtin __fishy serve-init
__fishy_serve
