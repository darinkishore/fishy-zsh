# fishy-zsh

zsh with fish 4.9.3's interactive UX, exactly. zsh runs the commands; every
fish decision comes from fish itself, via a patched fish running as a server.

## Layout

- `fishy/` — the zsh side. `fishy.zsh` is the entry point; `start.zsh` boots
  the servers early (source it from `.zshenv`, see below).
  - `bridge.zsh` — two persistent fish servers (coprocs): `sync` (Tab,
    history, word motion, prompt) and `async` (suggestions, highlighting).
  - `reader.zsh` and friends — a zsh port of fish's reader control flow.
  - `input.zsh` — fish's key input layer (decoder, `find_binding`, keyboard
    protocols); `keys.zsh` — fish's preset binding table; see "Keys" below.
  - `prompt.zsh` — fish draws the prompt; see "Prompt" below.
  - `server.fish` — the server loop.
- `functions.zsh` — fish's interactive functions ported line for line
    (ls ll la, cd with directory history, prevd nextd dirh cdh); colors via
    the server (`__fishy_set_color`), help via fish's `__fish_print_help`.
    pushd/popd/dirs stay zsh's builtins (zsh code passes them zsh flags).
- `bindings.zsh` — fish's fish-code bindings (alt-# alt-s alt-p alt-d alt-l
    alt-w alt-o alt-h/f1 alt-e/alt-v ctrl-x ctrl-v shift-delete ctrl-l).
    Command-line-only ones run fish's own code in the server (`__fishy
    bind-run`: `commandline` works on zsh's line, `commandline -f` calls are
    recorded and run by zsh afterwards); terminal ones (man, editor, pager,
    ls, dirh via `__fish_echo`) are ported and run in zsh.
- `paste.zsh` — bracketed paste: fish's begin-undo-group / `__fish_paste` /
    end-undo-group sequence; `__fish_paste` itself runs in the server.
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
  - `zsh-implicit-cd.patch` — `IMPLICIT_CD` option: fish's implicit cd (no
    args/redirections/precommand modifier, command not found, path-like
    `/` `./` `../` `x/` `..`, a directory) runs `cd -- dir` via the cd
    function. zsh's `AUTO_CD` takes any directory name and the cd builtin.
  - `zsh-wrapped-builtin-errors.patch` — a function wrapping a builtin of its
    own name (`cd() { ...builtin cd }`) gets the builtin's errors as at top
    level (`cd: ...`, not `cd:cd:22: ...`); hooks run inside keep theirs.
  Regenerate a patch after committing on its branch; nix only sees files jj
  has snapshotted (run `jj st` before `nix build`).
- `harness/` — `fz.py`: fish and zsh side by side in termctrl (Ghostty's
  terminal core, Ghostty's exact environment), screens diffed cell by cell.
  Scenario files (`scenarios*.txt`) pick a fish config with `#! config NAME`
  (`harness/configs/NAME`; default: the neutral `fish-config.fish`). Suites:
  `scenarios` (core), `-pure`, `-transient`, `-rprompt`, `-abbr` (abbrs in an
  interactive-only block, as home-manager writes them), `-paste` (`paste:`
  steps send Ghostty's bracketed-paste framing), `-dirs` (ls/ll/la,
  implicit cd, cd -, prevd/nextd/dirh/cdh, alt-left/right), `-kitty` (keys
  that differ under kitty's keyboard protocol). `keys.py` / `keymatch.py`:
  the decoder and the matcher against fish itself (see "Keys").
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
    FISHY_KEYS=legacy uv run harness/fz.py suite  # keys as a legacy terminal sends them
    uv run --no-project python harness/keys.py      # decoder vs fish_key_reader
    uv run --no-project python harness/keymatch.py  # find_binding vs fish

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

## Server config

The server is a non-interactive fish, but it loads the user's config as an
interactive fish does: `__fishy_interactive_config=1` (bridge.zsh) makes
`status is-interactive` true while fish's init files run (patch in
`src/bin/fish.rs`, scoped to `read_init`; the server never owns the
terminal). So `status is-interactive; and begin ... end` blocks (where
home-manager puts abbreviations, zoxide, fzf, atuin) define the same
abbreviations, functions and completions as in interactive fish (checked:
abbr/functions/complete/variables/handlers identical to `fish -i`).

That block also installs the fish hooks of tools that hook zsh too. Shell
state belongs to zsh: server.fish erases them (direnv: environment; atuin:
history records; zoxide: directory scores), or every replayed event would act
twice. A new tool with fish+zsh hooks must be added there.

## History

The sync server owns the history file (`history-add`, `history-resolve`
save it). The async server computes autosuggestions from its own History, so
it gets every command too, in memory only (`history-add ... memory`,
`history-resolve nosave`): one fish process suggests its own commands. It
never writes the file. A removal (shift-delete) is saved by the sync server;
the async server then `forget`s the item and re-reads the file (fish's
in-memory remove alone would not hide file items, and saving from the async
server is not allowed: fish's rewrite merges by text, and it holds items it
must not write).

## Paste

`__fishy paste` is `share/functions/__fish_paste.fish` line for line (split
on \r and \n, drop ASCII control characters, search field, current-token
quote state, leading-whitespace trims, `$ ` stripping via `--insert-smart`,
root check), with zsh's quoting: `__fish_tokenizer_state` knows zsh's
literal single quotes and `$'...'`, and a paste into an unmatched `'...`
escapes `'` as `'\''` (fish's `\'` would close a zsh quote). The edit is
applied like the reader applies a `commandline` change (whole-line edit,
pager closed, history search ended, last command reset), inside one undo
group.

## Keys

fish matches bindings on decoded key events, not bytes, so fishy does too.
zle's keymap only routes: printable text goes to self-insert (batched like
read_normal_chars); every control character, DEL and ESC runs `fishy-key`,
which reads the rest of the sequence with fish's decoder (`decode.rs`: legacy
bytes, ESC-prefixed alt, CSI/SS3 with xterm modifiers, modifyOtherKeys, kitty
CSI u with shifted/base-layout keys and text; replies and reports dropped)
and picks the binding like `find_binding` (user bindings first, then presets
in `bind` order; exact, modulo-shift and base-layout matches; escape deferred;
raw escape-sequence bindings; ESC then a key within 30ms is alt). Printable
keys with a binding of their own are routed by running that same matcher on
the key at install time. The table is fish's own notation (`fishy-bind KEY
WIDGET`, `-u` user, `-s` fish code); the harness user bindings (fzf, atuin)
are registered by integrations.zsh.

Protocols (`tty_handoff.rs`): zsh's terminal probe asks for kitty's protocol
(`query-modkeys-kitty` in start.zsh); `zle_bracketed_paste` carries fish's
on/off sequences (bracketed paste + `=5u`, or modifyOtherKeys + DECKPAM, per
fish's terminal quirks), which zle writes when it starts and stops reading
a line. Like fish, fish-code bindings (`-s`) run with the protocols off.

Oracles: `keys.py` sends 1112 inputs to `fish_key_reader -cV` and to the
port (`keydecode.zsh`) and diffs every decoded event; `keymatch.py` rebinds
every fish preset to insert its index and diffs the binding chosen per input
(`keymatch.zsh`). The harness encodes each step as Ghostty 1.3.1 on macOS
does for the kitty flags the shell has set (replayed from its output), or
always legacy (`FISHY_KEYS=legacy`); both must pass.

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

Harness limit: `!cmd` waits for the cursor row to change, so a scenario
that scrolls the 30-row screen stalls; keep scenarios to one screen.

Deliberate differences from fish: alt-p appends `|& PAGER` (fish's `&|` is
"background and disown" in zsh); alt-e's file is `command-line.zsh`;
errors from commands are zsh's
(`cd: no such file or directory: x`, `permission denied: ./file`), like
every other zsh error; titles say `zsh` where fish says `fish`
(`status current-command` at the prompt); fish's greeting is not printed; a
paste into an unmatched single quote is spelled `'\''` (same literal text as
fish's `\'`); a raw ESC inside a paste is dropped like other control
characters, whereas fish's decoder runs the escape sequence as a key binding
(ESC b inside a paste would move a word back), which is what bracketed paste
exists to prevent.

Known gaps:
- Prompt functions that inspect `jobs` see the server's jobs (none).
- No terminal queries in the server: `status terminal` is empty, and light/dark
  theme variants (`fish_terminal_color_theme`, DECSET 2031) are not followed.
  fish's default theme has no variants.
- Invisible ordering: fish enables bracketed paste before drawing the prompt,
  zsh after.
- A prompt taller than the screen, and form feeds in prompts, are laid out by
  zsh's rules (fish: visible_prompt_lines / FF as line break).
- Mouse clicks on the command line (Ghostty's click-to-move: fish's OSC 133
  `click_events=1` makes it send `CSI < 0;x;y M`) are decoded and dropped;
  fish moves the cursor there (`mouse_left_click`), fishy does not yet.
- zle's read timeout counts in 1/100 s: a lone legacy ESC is told from an
  escape sequence after 10ms (fish: 1ms). Under kitty's protocol ESC is a
  sequence of its own, so this only matters on legacy terminals.
- No history pager: ctrl-r does nothing without atuin (darin's atuin binds
  it).
