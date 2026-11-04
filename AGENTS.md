# fishy-zsh

zsh with fish 4.9.3's interactive UX, exactly. zsh runs the commands; every
fish decision comes from fish itself, via a patched fish running as a server.

## Layout

- `fishy/` — the zsh side. `fishy.zsh` is the entry point; `start.zsh` boots
  the servers early (source it from `.zshenv`, see below).
  - `bridge.zsh` — two persistent fish servers (coprocs): `sync` (Tab,
    history, word motion, prompt) and `async` (suggestions, highlighting).
  - `reader.zsh` and friends — a zsh port of fish's reader control flow.
  - `prompt.zsh` — fish draws the prompt; see "Prompt" below.
  - `server.fish` — the server loop.
- `nix/` — patches. `fish-fishy-builtin.patch` (the `__fishy` builtin) is
  `git diff 4.9.3 HEAD` of branch `fishy-4.9.3` in
  `~/vendor/github.com/fish-shell/fish-4.9.3`. The `zsh-*.patch` files are
  one commit each on branch `fishy-zle` in
  `~/vendor/github.com/zsh-users/zsh-fishy`, applied to pinned zsh master:
  - `zsh-fishy-zle-display.patch` — `zle_display`: continuation indent,
    case-flipped suggestion display.
  - `zsh-sigint-newline.patch` — `SIGINT_NEWLINE` option (fishy unsets it).
  - `zsh-termquery-extvar-uaf.patch` — upstream bug: use-after-free in
    `query_terminal` when `.term.extensions` exists before zle loads and
    `COLORTERM=truecolor`. Upstreamable.
  - `zsh-rprompt-indent0.patch` — with `ZLE_RPROMPT_INDENT=0` the right prompt
    may touch the text (fish's fit rule).
  Regenerate a patch after committing on its branch; nix only sees files jj
  has snapshotted (run `jj st` before `nix build`).
- `harness/` — `fz.py`: fish and zsh side by side in termctrl (Ghostty's
  terminal core, Ghostty's exact environment), screens diffed cell by cell.
  Scenario files (`scenarios*.txt`) pick a fish config with `#! config NAME`
  (`harness/configs/NAME`; default: the neutral `fish-config.fish`).
- `spec/fish-behavior.md` — 340 source-cited fish behaviors.
- `try/` — `nix run .#try`: fishy on top of your real zsh config.

## Running

    nix build .#deps -o deps                    # shells for the harness
    uv run harness/fz.py suite                  # scenarios.txt
    uv run harness/fz.py suite --file harness/scenarios-pure.txt
    uv run harness/fz.py shot --config pure '!false' '=git ch' tab
    FISHY_DEV_FISH=~/vendor/github.com/fish-shell/fish-4.9.3/target/release/fish \
      uv run harness/fz.py suite                # against a cargo build
    FISHY_LOG=/tmp/fishy.log nix run .#try      # bridge log with per-call ms

Sandboxes live in `/private/tmp/fishy-zsh-sandbox` (`$FISHY_SANDBOX`): outside
any repository, because prompts run git/jj.

## Server protocol

Requests go to the server's stdin; replies come back on fd 3, written by
`__fishy reply ID SUB ARGS...` itself. Never use a fish `>&3` redirection:
event handlers that fire while a redirection is active (OSC 7 on a PWD
change) write into it. The server's fds 1/2 go to /dev/null; the prompt
subcommands capture them (a scratch file dup2'd over 1 and 2), because fish
writes event output and titles straight to those fds. The coproc is started
with `no_multios`: otherwise zsh tees stdout instead of redirecting it.

## Prompt

`prompt.zsh` replays fish's prompt lifecycle at the matching zsh hooks:
postexec (CMD_DURATION, OSC 133 D, fish_postexec, show cursor), then
prompt-event (PROMPT_SP ⏎ sequence, the fish_prompt event) in the first
precmd hook, other precmd hooks, then prompt (mode/left/right prompts, title)
in the last one, transient re-render at line-finish, and exec (133 C,
fish_preexec, title) in preexec. Prompt text comes back in zsh prompt syntax
with fish's widths baked in (`%{text%NG%}`), already truncated the way fish's
screen truncates it.

Gotchas:
- Capture `$?` and `$pipestatus` in one command: any command, even `local`,
  resets `$pipestatus`.
- `start.zsh` must run before zle loads (nix-darwin's `/etc/zshrc` runs
  `bindkey -e`), i.e. from `.zshenv`: it turns off zsh master's own terminal
  integration (`.term.extensions+=(-integration)`), which would duplicate
  fish's OSC 133/OSC 7. It also gets fish booting while zsh reads its config.
- Ghostty's zsh integration is dropped (its deferred init is removed from
  precmd_functions): under nix-darwin Ghostty's fish integration never loads,
  so fish's own sequences are what Ghostty sees from fish.
- Shell state belongs to zsh: the server drops fish hooks of tools that also
  hook zsh (direnv's vendor_conf.d hook loads even in non-interactive fish).
- `define-commands` (zsh's ~2000 functions as fish stubs) is sent after the
  prompt request so it never delays the prompt.

Deliberate differences from fish: titles say `zsh` where fish says `fish`
(`status current-command` at the prompt); fish's greeting is not printed.

Known gaps:
- Prompt functions that inspect `jobs` see the server's jobs (none).
- No terminal queries in the server: `status terminal` is empty, and light/dark
  theme variants (`fish_terminal_color_theme`, DECSET 2031) are not followed.
  fish's default theme has no variants.
- Invisible ordering: fish enables bracketed paste before drawing the prompt,
  zsh after.
- A prompt taller than the screen, and form feeds in prompts, are laid out by
  zsh's rules (fish: visible_prompt_lines / FF as line break).
