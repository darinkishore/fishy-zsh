# fish 4.9.3 interactive behavior spec (source-derived)

Target: make zsh behave exactly like fish 4.9.3's interactive UX. Every behavior below is derived from the
fish 4.9.3 source tree (`~/vendor/github.com/fish-shell/fish-4.9.3`; CHANGELOG head: "fish 4.9.3 (released
September 08, 2026)") and cites `path:line` relative to that checkout. Each behavior is marked **Observed**
(run against the installed fish 4.9.3 in tmux 3.6a) or **Source only**. Where docs (`doc_src/`) and code
disagree, the code is authoritative and the discrepancy is noted in the behavior.

Each behavior has: ID, one-line name, **Behavior** (exact, with edge cases), **Source** (citations),
**Test** (tmux recipe: setup / keys / expect), and optionally **Observed**.

## Sections and ID prefixes

| § | Area | Prefix | Count |
|---|---|---|---|
| 1 | Autosuggestions | AS | 35 |
| 2a | Tab completion: engine & insertion | TC | 47 |
| 2b | Completion pager UI | PG | 49 |
| 3 | History (line search, token search, ctrl-r pager, storage) | HS | 26 |
| 4 | Syntax highlighting & theme defaults | HL | 48 |
| 5 | Keybindings & line-editing commands (emacs mode) | KB | 70 |
| 6 | Abbreviations | AB | 26 |
| 7 | Misc interactive behavior | MI | 39 |
| | **Total** | | **340** |

Overlaps are intentional and cross-checked (e.g. AS-23..26 and KB-10/13/18/70 describe suggestion
acceptance from the two sides; PG-29/30 vs KB-43/45 for cancel/ctrl-c; AB-02..05 vs KB-47..49 for
abbreviation triggers). Where two sections touch the same behavior they agree.

---

## 0. Shared test harness (read before any recipe)

All recipes assume this harness. Section-specific fixtures (extra files in `$W`, seeded history, conf.d
snippets) are given at the top of each section and in each test's `setup:` line.

```sh
FISH=/nix/store/cxam19d2wm0f5zflz830z9rf72brxiw5-fish-4.9.3/bin/fish   # = readlink -f $(which fish)
H=$(mktemp -d); W=$H/w; mkdir -p $W
mkdir -p $H/.local/share/fish $H/.config/fish/conf.d
T() { /opt/homebrew/bin/tmux -L fishspec "$@"; }
T new-session -d -s t -x 100 -y 30 -c "$W" \
  "env -i HOME=$H TERM=xterm-256color LANG=en_US.UTF-8 __NIX_DARWIN_SET_ENVIRONMENT_DONE=1 \
       PATH=/usr/bin:/bin:/usr/sbin:/sbin $FISH"
T set -s extended-keys on
sleep 1.5
T send-keys -t t -l 'echo hel'     # literal text: ALWAYS use -l for text
T send-keys -t t Right             # named keys: Right Left Up Down Home End BTab Tab Enter Escape BSpace C-a M-f M-Right C-Space S-Enter M-Enter ...
T capture-pane -t t -p             # plain text
T capture-pane -t t -p -e          # with SGR escapes (colors)
T kill-server                      # when done
```

Harness facts discovered while writing this spec (all verified):

- **Nix preinit must be disabled.** This nix-built fish always sources `/etc/fish/nixos-env-preinit.fish`,
  even under `env -i`; it runs `fenv source .../set-environment`, which replaces `PATH` and sets `EDITOR=nano`,
  `PAGER="less -R"`, `HOMEBREW_BUNDLE_FILE`, unless `__NIX_DARWIN_SET_ENVIRONMENT_DONE` is set. With the
  variable set (as above), `PATH` stays `/usr/bin /bin /usr/sbin /sbin` and none of those variables exist.
  (`/etc/fish/foreign-env/{shellInit,interactiveShellInit}` are empty on this machine.) Sections 2a and 5 were
  partly written before this was known; where they say "tests use their own variables because the system
  config adds PAGER/PATH entries", the harness above makes that precaution unnecessary but harmless.
- **Clean-HOME start screen:** `Welcome to fish, the friendly interactive shell` / `Type help for
  instructions on how to use fish` / prompt `user@host ~/w> ` (MI-01, MI-02). Locate the prompt by its
  `> ` suffix; user/host differ per machine.
- **Theme defaults exist only in interactive shells** (`share/config.fish:146-151`, HL-01): `fish -c 'set -S
  fish_color_command'` prints nothing; use `fish -ic` or a tmux session. Likewise key bindings: `fish -ic bind`
  in a non-tty context shows only the Rust fallback presets (KB-03); the real table is KB-02.
- **Background-color query:** a detached tmux does not answer OSC 11, so `$fish_terminal_color_theme` is
  `unknown`. The default theme has no light/dark variants (HL-02, HL-04), so this does not change colors.
- **Keyboard protocol under tmux 3.6a:** fish enables modifyOtherKeys (not kitty: tmux does not answer
  fish's kitty query), keypad mode, focus reporting and bracketed paste while reading (KB-05, KB-08, MI-27).
  With `extended-keys on`, shift-enter, alt-enter, ctrl-enter, shift-space, ctrl-space, ctrl-backspace are
  distinguishable. ctrl-shift-z arrives as ctrl-z (so use alt-/ to test redo); ctrl-/ arrives as ctrl-_.
- **Escape vs alt:** tmux `M-x` sends `ESC x` in one write; fish treats ESC followed by a byte within
  `fish_escape_delay_ms` (default 30 ms) as alt (KB-06). A bare `Escape` needs >30 ms of quiet afterwards
  before the next key, so sleep ≥0.1 s after sending Escape.
- **tmux drops a trailing `;`** from a send-keys argument; send `\;` (or use `-l`).
- **Typing speed matters for undo:** text sent in one `send-keys` arrives as one burst and fish's read-ahead
  inserts it as multi-character chunks, which changes undo grouping (KB-09, KB-42). Undo tests must send one
  key per send-keys with ~40 ms gaps.
- **Asynchrony:** autosuggestions and highlighting are computed on background threads (AS-07, HL-15); script
  bindings (alt-p, alt-s, alt-l, ...) repaint after running. Sleep ≥0.3 s (≥0.5 s for script bindings)
  before capture-pane.
- **Autosuggestions pollute plain captures:** the grey suggestion text is indistinguishable from typed text
  in `capture-pane -p`. Completion/pager tests disable them with
  `echo 'set -g fish_autosuggestion_enabled 0' > $H/.config/fish/conf.d/noauto.fish`, or assert with `-e`.
- **History seeding:** write `$H/.local/share/fish/fish_history` before starting fish, oldest first, newest
  LAST: `- cmd: <cmd, with \ → \\ and newline → \n>` / `  when: <past unix time>`. Entries with a `when`
  later than session start are invisible; leading whitespace in `cmd` is stripped on read (AS harness notes).
- **Flashes** (no-completion, failed search, failed undo) last 100 ms (`src/reader/reader.rs:4637-4675`) and
  are not reliably capturable; assert their absence/presence only with a fast polling capture loop.
- **macOS specifics:** APFS is case-insensitive (affects HL-38, TC-27); `whatis`-based command descriptions
  depend on a cache fish builds in the background (`~/.cache/fish/apropos`), so do not assert them on a
  fresh HOME (TC-39).
- **Unicode test strings:** send escape-sequence test strings from a quoted heredoc/file; passing `é`
  on a command line may arrive pre-converted.

---

## 1. Autosuggestions

fish 4.9.3 computes one autosuggestion at a time, on a background thread. It searches history first and then completions. The result is drawn after the cursor's line in `fish_color_autosuggestion`. Whether a suggestion is accepted, and how much of it, depends on the binding. Every key below is a default emacs-mode (`fish_default_key_bindings`) binding. All paths are relative to `/Users/darin/vendor/github.com/fish-shell/fish-4.9.3`. Each behavior is marked either **Observed** (seen in tmux 3.6a against the installed fish 4.9.3, 100x30, socket `fishspec-as`) or **Source only**.

**Shared test harness used by every recipe below** (the brief's standard fixture, plus two helpers):

    # HIST <cmd1> <cmd2> ...   -> writes $H/.local/share/fish/fish_history BEFORE starting fish.
    #   oldest first; each entry is "- cmd: <cmd with \ -> \\ and newline -> \n>\n  when: <1700000000+i>\n"
    #   (newest entry LAST). Timestamps MUST be in the past: entries whose when/added_when is newer than the
    #   session start are invisible (src/history/yaml_backend.rs:283-308).
    #   Leading whitespace of a cmd value is stripped on read (yaml_backend.rs:127), so a history entry
    #   that starts with a space cannot be seeded.
    # START  -> tmux -L <sock> new-session ... fish (brief fixture), then `set -s extended-keys on`, sleep 1.5
    # Text is sent with `send-keys -l '<text>'`; named keys with send-keys <Key>; sleep >=0.3s between steps
    # (results arrive asynchronously; Escape needs >30 ms of quiet, fish_escape_delay_ms default 30,
    #  src/input/input.rs:294).
    # Clean-HOME screen: line0 "Welcome to fish, the friendly interactive shell",
    #   line1 "Type help for instructions on how to use fish", line2 prompt "darin@echo ~/w> " (16 cols;
    #   user/host vary by machine — tests should locate the prompt by its "> " suffix).

### AS-01 — History is searched first; case-sensitive prefix match on the whole command line, most recent wins
**Behavior.** fish walks history from newest to oldest. It takes the first entry that starts with the entire current command line (every line of it, not only the cursor's line), compared case-sensitively, and that passes validation (AS-08 to AS-12). That entry becomes the suggestion and the search stops. Identical entries are deduplicated during the walk. If the newest matching entry is exactly equal to the command line, it still wins. Nothing new is then shown, and older, longer matches are NOT consulted.
**Source.** `src/reader/reader.rs:5341-5348` (Prefix search over `0..command_line.len()` first), `:5363-5372` (HistorySearch, backward, `ignore_case:true` so the walk also visits icase matches), `:5378-5381` (case-sensitive `full.starts_with(search_string)` takes precedence), `:5428-5448` (first valid case-sensitive hit is returned at once), `src/history/history.rs:1578-1625` (backward walk, newest first, dedup unless `no_dedup`).
**Test.**
    setup: HIST 'echo hello one' 'echo hello two' 'echo Hello three' 'echo'
    keys:  send-keys -l 'echo h'
    expect: line `echo hello two`, with "ello two" as suggestion; cursor col 22 (just after "h")
    keys:  C-u; send-keys -l 'echo'
    expect: line shows only `echo`. No suggestion, because the newest match is exactly "echo".
    keys:  send-keys -l ' '
    expect: `echo Hello three` ("Hello three" is the suggestion)
**Observed.** Exactly as expected (all three steps).

### AS-02 — Case-insensitive history match is only a fallback
**Behavior.** fish keeps the first entry that matches case-insensitively, under Unicode lowercase mapping. It is used only when no valid case-sensitive history match exists. Even then, it beats a completion-based suggestion unless the top completion is a case-sensitive (exact-case) match (AS-05).
**Source.** `src/reader/reader.rs:5336-5337`, `:5383-5388` (icase is checked only when no icase result exists yet), `:5444-5446` (stored, not returned), `:5483-5498` (fallback order), `crates/wcstringutil/src/lib.rs:45-49` (lowercase both strings, then prefix compare).
**Test.**
    setup: HIST 'echo Hello World'
    keys:  send-keys -l 'echo h'
    expect: a suggestion is shown even though the case differs (see AS-15 for exact display)
**Observed.** Yes.

### AS-03 — Multi-line command lines: whole-buffer prefix first, then a per-line prefix ("LinePrefix")
**Behavior.** After the whole-buffer prefix search, fish runs a second search when the cursor's line is non-empty and that line contains the first token of the process under the cursor. The search string is just the cursor's line (`range_of_line_at_cursor`). For each history entry, fish suggests the first line of the entry that starts with that string. It tries case-sensitive first, then case-insensitive if no icase result exists yet. Only that one line is suggested, not the whole entry. The line must itself start a process in the history entry; otherwise it is rejected. For a single-line command line both searches use the same string. This is also how a one-line command line can be suggested a single inner line of a multi-line history entry.
**Source.** `src/reader/reader.rs:5339-5362` (second search; skipped unless the cursor line has the process start), `:5391-5419` (find the matching line inside the entry), `src/highlight/highlight.rs:361-366` (a partial-entry suggestion must begin at a process's first token), `src/editable_line.rs:344-360` (`range_of_line_at_cursor`), CHANGELOG.rst:242.
**Test.**
    setup: START (no history); run: send-keys -l 'begin'; Enter; send-keys -l 'echo hi'; Enter; send-keys -l 'end'; Enter
    keys:  send-keys -l 'true'; M-Enter; send-keys -l 'ech'
    expect: row1 `true`, row2 (indented under the command line) `echo hi`, with "o hi" as suggestion
    keys:  Right
    expect: row2 becomes `echo hi`, cursor at its end; row1 unchanged
**Observed.** Yes. The history file stored `- cmd: begin\necho hi\nend`; fish's visual indentation is NOT stored.

### AS-04 — Completions are the second source; when they are consulted
**Behavior.** Completions are tried only when no valid case-sensitive history match was found. All of these must also hold:
- (a) the cursor's line is non-empty;
- (b) NOT (the cursor is not at the end of its line AND the line's last character is whitespace);
- (c) NOT (the line ends in `'` or `"` AND the cursor is at the end of its line).

"At end" means cursor == buffer length, or the character at the cursor is `\n`. Completion runs on the text up to the end of the cursor's line. That is the same as a cursor placed at the end of that line, even when the real cursor is elsewhere. The completion engine runs in autosuggestion mode:
- prefix matching only, no fuzzy/substring matches;
- no descriptions;
- nothing for an empty process, such as an empty line or just after `;` or `|`;
- no file candidates for an empty argument, so `cat ` gets no suggestion;
- leading `and`/`or`/`not`-style subcommand keywords are dropped.

**Source.** `src/reader/reader.rs:5458-5475` (a, b, c), `:5477-5481` (`complete(&command_line[..line_range.end], Autosuggestion)`), `src/complete.rs:328-339` (no descriptions, no fuzzy), `:773-784` (strip leading subcommand keywords), `:804-808` (empty process returns nothing), `:943-945` (no file completion for an empty token).
**Test.**
    setup: START, no history; in $W: touch file.txt File2.txt; mkdir subdir
    keys:  send-keys -l 'ech'        expect: suggestion `o ` (full display `echo `; the trailing space comes from the completion's space suffix)
    keys:  C-u; send-keys -l 'cat fi'  expect: `cat file.txt ` ("le.txt " suggested)
    keys:  C-u; send-keys -l 'cat '    expect: no suggestion
    keys:  C-u; send-keys -l 'cd s'    expect: `cd subdir/` ("ubdir/" suggested, no trailing space)
**Observed.** All four as expected. The typed `ech` was drawn in fish_color_error (`ESC[91m`).

### AS-05 — Choosing among completions, and turning a completion into a suggestion
**Behavior.** The completion list is first sorted and pruned: keep only the best rank, dedup, sort naturally. It is then stably re-sorted by case-fold: exact before smartcase before insensitive. Ties are broken by not repeating an argument already on the line, and then by penalizing names ending in `~`. The first completion wins, with two exceptions. If it is a smartcase or insensitive match AND a case-insensitive history result exists, the history result is used instead. If there are no completions at all, the icase history result is used if one exists; otherwise there is no suggestion. The chosen completion is applied in append-only mode. The suggestion is the full resulting line at the cursor, recorded as case-insensitive with `icase_matched_codepoints = lowercase-count(current line)`. It is never "a whole item from history" (this matters for AS-27).
**Source.** `src/complete.rs:636-666` (`sort_and_prioritize`, including the autosuggestion-only re-sort at :657-665), `src/reader/reader.rs:5483-5521`.
**Test.**
    setup: START; in $W: touch file.txt File2.txt
    keys:  send-keys -l 'cat FI'
    expect: display `cat FIle.txt ` ("le.txt " suggested; the typed "FI" keeps its case because it contains uppercase, see AS-15)
**Observed.** Yes.

### AS-06 — There is no abbreviation-expansion or "previous command" source
**Behavior.** Only two sources exist: history and completions. Abbreviations are not expanded in a suggestion. In command position, abbreviation *names* are ordinary completion candidates alongside commands, so typing a prefix of an abbreviation name can be suggested the name plus a trailing space. Once space expands the abbreviation (`self-insert expand-abbr`), the suggestion is recomputed for the expanded text. History holds expanded commands, because expansion happens before execution. With an empty command line there is no suggestion at all, so no "repeat last command" behavior (AS-13).
**Source.** `src/reader/reader.rs:5319-5521` (the only two sources), `src/complete.rs:864-866` (`complete_abbr(current_token)` in command position), `src/complete.rs:1311-1336`, `share/functions/__fish_shared_key_bindings.fish:110` (space = self-insert + expand-abbr), `src/reader/reader.rs:4590-4599` (abbreviation expanded before execution and before history).
**Test.**
    setup: START; HIST 'git checkout main'; config: run `abbr -a gco git checkout` first (send-keys + Enter)
    keys:  send-keys -l 'gco '
    expect: line becomes `git checkout ` followed by suggestion `main`
**Source only.**

### AS-07 — The suggestion is computed asynchronously and discarded if stale
**Behavior.** At the top of every input-loop iteration fish calls `update_autosuggestion`, which does the following in order:
1. If suggestions are not allowed (AS-13), clear the suggestion.
2. If the current suggestion still fits the cursor's line (`is_at_line_with_autosuggestion`), keep it.
3. If a request for exactly this buffer text is already in flight, do nothing.
4. Otherwise clear the suggestion and queue a background computation. Its thread-abandon timeout is 500 ms.

When a result arrives, it is applied only if all of the following hold: its command-line text equals the current text, suggestions are still allowed, and the searched string still prefixes the suggestion. If a completion script had to be loaded, the computation restarts. So there can be a short moment with no suggestion; tests must sleep about 0.3 s.
**Source.** `src/reader/reader.rs:2767-2776`, `:5590-5625`, `:5549-5588`, `src/reader/iothreads.rs:36-42`.
**Test.**
    setup: HIST 'echo hello'
    keys:  send-keys -l 'echo hel'; sleep 0.3
    expect: suggestion `lo` present
**Observed.** Yes (it appears within 0.3 s).

### AS-08 — Validation: a non-command entry is always valid; otherwise the command must exist
**Behavior.** A history candidate is parsed. If its first job's statement is not a plain (decorated) command, for example `function`, `if`, `for`, `begin`, `while` or `switch` blocks, it is valid as-is. Otherwise the command word is expanded; if expansion fails, validation fails. After the `cd` special case (AS-09), the command must be one of: a builtin, a function that is loaded or autoloadable, or an executable found on `$PATH`. Abbreviations do NOT count here. A path-qualified command such as `./x` goes through the `$PATH`/path lookup. If the command fails these checks, the candidate is skipped and the search continues with older entries.
**Source.** `src/highlight/highlight.rs:301-330` (parse, first decorated statement, first argument), `:368-374` (non-decorated returns true), `:392-398` (builtin, function, or path), `:1192-1202` (expand the command), `src/function.rs:235-255` (`exists_no_autoload`).
**Test.**
    setup: HIST 'nosuchcmd123 foo'
    keys:  send-keys -l 'nosuch'
    expect: no suggestion
**Observed.** Yes.

### AS-09 — Validation: `cd DIR` needs DIR to exist (honoring CDPATH) and not be the current directory
**Behavior.** This applies only when the command is literally `cd` and there is no `complete --wraps` defined for `cd`, and the first argument is non-empty and expands (command substitutions make expansion fail). An argument that is a prefix of `--help`, `-h`, `--logical`, `-L`, `--physical` or `-P` is always valid. Otherwise the directory is resolved:
- an absolute path as-is;
- `./`, `../`, `.` or `..` against `$PWD`;
- anything else via each `$CDPATH` entry and then `.`.

The candidate is valid only if one resolved path is a directory AND it is not the same file as `$PWD`, compared as paths first and then by inode/device. When the `cd` path is taken, required paths (AS-10) are not checked.
**Source.** `src/highlight/highlight.rs:332-347`, `:376-390`, `src/path.rs:315-331` (`path_get_cdpath`), `:334-381` (`path_apply_cdpath`), `:494-503` (`paths_are_same_file`).
**Test.**
    setup: HIST 'cd existing' 'cd missingdir' 'cd .' ; mkdir $W/existing
    keys:  send-keys -l 'cd '
    expect: suggestion `existing` ("cd ." is the current directory and "cd missingdir" is missing; both skipped)
    keys:  send-keys -l 'm'
    expect: no suggestion
**Observed.** Yes.

### AS-10 — Validation: "required paths" recorded at execution time must still exist relative to the CURRENT $PWD
**Behavior.** A history entry stores no working directory. When a command is executed, every AST argument that is non-empty and does not start with `-` is a potential path. On a background thread each one is expanded: variables and `~` only, no wildcards, no command substitution. It is kept if it exists, absolute or relative to the `$PWD` of that moment. The original unexpanded spellings are stored as `paths:` in the history file. This detection is skipped, and the entry saved immediately, when the statement is `exec`-decorated or its command is `exit`, `reboot`, `restart` or `echo`. At suggestion time every stored path is re-expanded and must exist relative to the current `$PWD`. Special cases: `.` and `./` are always valid; `..` and `../` are valid unless `$PWD` is `/`. If any path is missing, the entry is skipped.
**Source.** `src/history/history.rs:1062-1065` (`string_could_be_path`), `:1258-1342` (`add_pending_with_file_detection`, the exit/reboot/restart/echo/exec rule at :1288-1297), `:1716-1740` (`expand_and_detect_paths`), `:1745-1762` (`all_paths_are_valid`), `src/path.rs:474-491` (`path_is_valid`), `src/highlight/highlight.rs:400-403`, `src/history/yaml_backend.rs:16-18,190-208` (`paths:` list format).
**Test.**
    setup: START; mkdir $W/sub; touch $W/a.txt
    keys:  send-keys -l 'cat a.txt'; Enter; send-keys -l 'ls -l a.txt sub nonexist'; Enter; send-keys -l 'echo a.txt'; Enter
    expect: the history file has entry "cat a.txt" with "  paths:\n    - a.txt", entry "ls -l a.txt sub nonexist" with paths a.txt and sub, and entry "echo a.txt" with no paths
    keys:  send-keys -l 'cd sub'; Enter; send-keys -l 'cat '
    expect: no suggestion; then C-u, 'cd ..', Enter, 'cat '  ->  suggestion `a.txt`
    alt seed: '- cmd: cat gone.txt\n  when: 1700000004\n  paths:\n    - gone.txt\n' (with gone.txt absent) gives no suggestion for 'cat g'
**Observed.** Yes, all of it.

### AS-11 — Validation of a single line taken from a multi-line entry
**Behavior.** When the suggested range is not the whole entry (the LinePrefix case of AS-03), it must start exactly at the first token of a process in the entry. Only that line is parsed and validated. The entry's required paths are still checked in full.
**Source.** `src/highlight/highlight.rs:361-369`, `:401`.
**Test.**
    setup: HIST $'printf a \\\n  b'   (an entry whose second line is a continuation, not a process start)
    keys:  send-keys -l 'true'; M-Enter; send-keys -l 'b'
    expect: no history suggestion from that continuation line
**Source only.**

### AS-12 — Command-line text before validation: what counts as "the command"
**Behavior.** fish uses the first decorated statement of the first job. `command foo`, `builtin foo` and `exec foo` are decorations, so the inner name is validated. A leading variable assignment is part of the statement, and the expanded command word is what gets checked. Only the first argument matters for the `cd` check.
**Source.** `src/highlight/highlight.rs:312-327`.
**Test.**
    setup: HIST 'command nosuchzz arg'
    keys:  send-keys -l 'command n'
    expect: no suggestion
**Source only.**

### AS-13 — When suggestions are not computed or shown at all
**Behavior.** No suggestion is computed, and any existing one is cleared, if any of these holds:
- `fish_autosuggestion_enabled` is exactly `0` (AS-14);
- suppression is active: after backspace or delete, a kill, `yank-pop`, `suppress-autosuggestion`, or a cursor move that crossed a newline;
- a history search is active and not back at its starting point (HS-*);
- the focused edit line is the pager search field (ctrl-r pager, or pager search after ctrl-s);
- the buffer contains no character other than space, `\t`, `\r`, `\n` or `\x0B`. An empty or whitespace-only line gets nothing.

Inserting text clears suppression. A line that starts with spaces but has other text is NOT excluded; it just cannot match history (AS-21).
**Source.** `src/reader/reader.rs:5534-5546` (`can_autosuggest`), `:5590-5596`, `:1978-1990` (insert resets suppression), `:2205-2229` (delete_char sets suppression), `:2313-2316` (kills), `:3287`, `:3369`, `:3748`, `:3773`, `:1605-1615` (newline-crossing moves), `:3946-3952`, `:1458-1463` (search field focus).
**Test.**
    setup: HIST 'echo hello world'
    keys:  send-keys -l '  '        expect: no suggestion
    keys:  C-u; send-keys -l 'echo h'; Up    expect: no suggestion drawn while the found entry is shown
**Observed.** Whitespace-only case observed.

### AS-14 — `fish_autosuggestion_enabled`
**Behavior.** Suggestions are disabled only when the variable's value, list elements joined by spaces, is exactly the string `0`. If unset, empty, `false` or anything else, they stay enabled. Changing the variable takes effect immediately and triggers a repaint.
**Source.** `src/reader/reader.rs:1108-1112` (`check_bool_var`: `v != "0"`), `:1115-1124`, `:831`, `src/env_dispatch.rs:76-78`, `doc_src/interactive.rst:30-32`.
**Test.**
    setup: HIST 'echo hello world'
    keys:  send-keys -l 'set -g fish_autosuggestion_enabled 0'; Enter; send-keys -l 'echo h'
    expect: no suggestion
    keys:  C-u; send-keys -l 'set -g fish_autosuggestion_enabled 1'; Enter; send-keys -l 'echo h'
    expect: `ello world` suggested
**Observed.** Yes. (The `false` and empty-value cases are source only.)

### AS-15 — Display when the case differs: whose case is shown
**Behavior.** This applies when the typed line is NOT a case-sensitive prefix of the suggestion (an icase match). fish looks at the token containing the last character of the whole buffer (`get_token_extent(cmdline, len-1)`):
- If that token has NO uppercase character, the typed portion is redrawn in the suggestion's case. Displayed = `cmdline[..line_start] + suggestion + cmdline[cursor_line_end..]`.
- Otherwise the typed text is drawn as typed, followed by the remaining `len(suggestion) - len(line)` characters of the suggestion.

This is display only. The buffer still holds what was typed.
**Source.** `src/reader/reader.rs:1669-1712` (`combine_command_and_autosuggestion`), `:1844-1857` (used for painting).
**Test.**
    setup: HIST 'echo Hello World'
    keys:  send-keys -l 'echo h'
    expect: screen shows `echo Hello World`. "H" is drawn in param color (`ESC[36m`), "ello World" in `ESC[90m`. Cursor col 22.
    keys:  C-u; send-keys -l 'echo HE'
    expect: `echo HE` + suggestion `llo World`
**Observed.** Exactly: `echo ␛[36mH␛[90mello World␛[39m`, and `echo ␛[36mHE␛[90mllo World`.

### AS-16 — What accepting does to case: full accept replaces, partial accepts append
**Behavior.**
- Full accept (`forward-char` at the end, `end-of-buffer`, `accept-autosuggestion`) REPLACES the searched range with the suggestion text. The typed characters take the suggestion's case, even when the display showed the typed case (AS-15, uppercase branch).
- Line accept (`end-of-line`) and partial accepts (word, token, single character) only APPEND characters after the typed text. The typed characters keep their typed case, even if the display had shown them in the suggestion's case.
**Source.** `src/reader/reader.rs:5679-5739` (`Count(usize::MAX)` gives `(search_string_range, whole text)`; all other portions give an insertion at `search_string_range.end`).
**Test.**
    setup: HIST 'echo Hello World'
    keys:  send-keys -l 'echo h'; End      expect: buffer `echo hello World`
    keys:  C-u; send-keys -l 'echo h'; Right  expect: buffer `echo Hello World`
    keys:  C-u; send-keys -l 'echo h'; M-f; send-keys -l 'x'   expect: buffer `echo hellox` (after M-f the screen showed `echo Hello` + ` World`, but the buffer was "echo hello")
    keys:  C-u; send-keys -l 'echo HE'; Right  expect: buffer `echo Hello World` (the typed "HE" is lost)
**Observed.** All four exactly.

### AS-17 — Rendering: color, position, soft wrap
**Behavior.** The suggestion characters are drawn with foreground role `fish_color_autosuggestion`, falling back to `fish_color_normal`; the default theme value is `brblack` (`ESC[90m`). The background is normal. During a "flash" (AS-27) they are drawn with search_match as both foreground and background. The suggestion starts right after the end of the cursor's line. Text after that line, on later lines of the buffer, comes after the suggestion. Long suggestions soft-wrap onto the following screen rows. The cursor stays where it was. The right prompt is hidden when prompt + first line + suggestion + right prompt is wider than the screen.
**Source.** `src/reader/reader.rs:1844-1861`, `:1900-1912` (color splice), `src/highlight/highlight.rs:1221` (variable name), `:1239-1260` (Autosuggestion falls back to Normal), `share/themes/default.theme:4`, `src/screen.rs:1909-1923`, `:2007-2022` (right prompt hiding), CHANGELOG.rst:338.
**Test.**
    setup: HIST "echo $(printf 'abcdefghij%.0s' $(seq 15))"   (155 characters)
    keys:  send-keys -l 'echo a'
    expect: row2 = prompt + `echo abcdefghij...abcdefghi` (exactly 100 columns), row3 = `jabcdefghij...abcdefghij`, all after "a" in ESC[90m; cursor (22,2)
**Observed.** Yes.

### AS-18 — Rendering: vertical truncation with "…"
**Behavior.** fish uses the cursor-position report to learn how many rows remain below the cursor's row. The suggestion may use only those rows, including soft wraps. It is cut off at the first character that would need one more row, and "…" (U+2026) is appended in the same color as the last shown character. If the terminal gives no cursor-position report, only one row is available, which means truncation at the right edge of the current row. A character that would end exactly at the last column is treated as wrapping. Upward ("Up") history search uses the fact that the suggestion was truncated (HS-05).
**Source.** `src/screen.rs:1920-1923` (available rows; 1 when the viewport position is unknown), `:1956-1979` (wrap counting), `:2033-2045` (drop + ellipsis), `:352-354` (`autosuggestion_is_truncated`), `crates/widestring/src/lib.rs:34`.
**Test.**
    setup: as AS-17; then: send-keys -l 'clear'; Enter; send-keys -l 'seq 40'; Enter   (prompt now on the last row, 29)
    keys:  send-keys -l 'echo a'
    expect: row29 = prompt + `echo abcdefghij...abcdefgh…`. The "…" is in column 99 (the last), in ESC[90m. Nothing wraps.
**Observed.** Yes.

### AS-19 — Rendering a multi-line suggestion
**Behavior.** If the suggestion has newlines (a multi-line history entry matched by whole-buffer prefix), the rest is drawn on the following rows. Each row is indented per fish's auto-indent of the combined text, at 4 columns per level, starting at the column where the command line starts. Literal leading spaces stored in the entry are drawn in addition to that indent.
**Source.** `src/reader/reader.rs:1914-1915` (indents computed on the combined line), `src/screen.rs:1926-2002`.
**Test.**
    setup: START; run 'begin' Enter 'echo hi' Enter 'end' Enter
    keys:  send-keys -l 'begin'; Enter; send-keys -l 'ec'
    expect: row A `begin`; row B starts at column 20 with `ec` (fish_color_error) + `ho hi` (ESC[90m); row C starts at column 16 with `end` (ESC[90m)
**Observed.** Yes.

### AS-20 — The suggestion stays visible while the cursor moves within its line
**Behavior.** A suggestion is kept, not recomputed, as long as one of these holds:
- the cursor's line range equals the searched range;
- for a whole-buffer search (searched range starts at 0), the cursor is at or before the end of the searched range.

So pressing Left/Home on the same line keeps it on screen. Moving the cursor across a newline clears it until the next insertion (AS-13).
**Source.** `src/reader/reader.rs:5650-5665`, `:5598-5607`, `:1605-1615`.
**Test.**
    setup: HIST 'echo hello world'
    keys:  send-keys -l 'echo hel'; Left; Left
    expect: `echo hel` + suggestion `lo world` still drawn; cursor col 22
**Observed.** Yes.

### AS-21 — Lines that start with whitespace
**Behavior.** A line such as ` ech` is NOT excluded from suggestions. History cannot match it, because entries never start with a space (AS-36/HS-23 and the read-side trimming in the harness note). Completions still apply.
**Source.** `src/reader/reader.rs:5534-5546` (only whitespace-only lines are excluded), `src/history/yaml_backend.rs:127`.
**Test.**
    setup: START, no history
    keys:  send-keys -l ' ech'
    expect: ` ech` + suggestion `o `
**Observed.** Yes. (This contradicts an old 3.x changelog line, CHANGELOG.rst:2543; current code wins.)

### AS-22 — After a trailing space
**Behavior.** A trailing space is just more prefix text. `echo ` matches the newest valid history entry that starts with `echo `. Completions apply only under AS-04: a space at the end gives an empty token, so no file suggestion. If the cursor is not at the end and the line ends in whitespace, the completion path is skipped entirely.
**Source.** `src/reader/reader.rs:5463-5470`, `src/complete.rs:943-945`.
**Test.** See AS-01, step 3 (`echo ` gives `Hello three`), and AS-04 (`cat ` gives nothing).
**Observed.** Yes.

### AS-23 — `forward-char` (right, ctrl-f): accept all at the end, otherwise move one character
**Behavior.** `right` and `ctrl-f` are bound to `forward-char`. Priority order:
1. If the completion pager is being navigated, select East.
2. Else if the cursor is at the end of the searched range (`is_at_autosuggestion`), accept the WHOLE suggestion, including every line of a multi-line suggestion, by replacement (AS-16). The cursor goes to the end of the inserted text.
3. Else, if not at the end of the buffer, move one character right.
4. Else do nothing.

`forward-single-char` (not bound by default in emacs mode) is identical except that step 2 appends exactly one character. `forward-char-passive` never accepts.
**Source.** `share/functions/__fish_shared_key_bindings.fish:18`, `share/functions/fish_default_key_bindings.fish:20,35`, `src/reader/reader.rs:3593-3608`, `:3609-3616`, `:5635-5648`, `:5680-5696`.
**Test.**
    setup: HIST 'echo hello world'
    keys:  send-keys -l 'echo hel'; C-b; C-f     expect: cursor moves to col 24; suggestion still shown; not accepted
    keys:  C-f     expect: buffer `echo hello world`, cursor col 32
**Observed.** Yes (Right and C-f both).

### AS-24 — `end-of-line` (end, ctrl-e): move to the end of the line first, accept one line second
**Behavior.** If the cursor is at the end of the searched range, `end-of-line` appends the suggestion's remainder up to, but not including, its first `\n`. If that remainder starts with `\n`, it does nothing. Otherwise, if the cursor is not at the end of its line, it moves there WITHOUT accepting. So from the middle of a line, the first End moves and the second End accepts. `end-of-buffer` (`alt->`) accepts the whole suggestion by replacement when at the suggestion, and otherwise jumps to the end of the buffer.
**Source.** `share/functions/fish_default_key_bindings.fish:28,31,56`, `src/reader/reader.rs:3042-3066`, `:3071-3080`, `:5697-5710`.
**Test.**
    setup: HIST 'echo hello world'
    keys:  send-keys -l 'echo hel'; Left; Left; Right   expect: cursor col 23, suggestion kept
    keys:  End    expect: cursor col 24, NOT accepted
    keys:  End    expect: `echo hello world`, cursor col 32
    multi-line: START; run begin/echo hi/end;  send-keys -l 'for' with HIST $'for i in 1 2\necho $i\nend':
      End gives `for i in 1 2` (first line only; the rest stays a suggestion); End again does nothing; Right accepts all
**Observed.** Yes, including the multi-line case.

### AS-25 — Accept one word: `alt-f` / `alt-right` (`nextd-or-forward-word`), and `shift-right` (`forward-bigword`)
**Behavior.** This applies when the cursor is at the end of the searched range. With an empty buffer, alt-f/alt-right run `nextd` instead, but an empty buffer never has a suggestion. fish appends a prefix of the suggestion's unaccepted remainder `R`, chosen by the state machine below (word style "Punctuation" for alt-f/alt-right, "Whitespace" for shift-right):

    # direction Left is used deliberately (to_word_end = true), consuming FORWARD through R
    consumed = 0; last = None
    for c in R:
        cls = class(c)            # Punctuation style: WordCharClass::from_char; Whitespace style: bigword_class
        if last is None: take c                       # first char always taken
        elif last == Blank: take c                    # blanks never stop
        elif last == Newline: stop if cls == Newline else take c
        else: stop if cls in {Blank, Newline} or cls != last else take c
        last = cls
    accept R[:consumed]

In words: take any leading blanks, then one run of same-class characters, and stop before the next blank, newline or class change. Classes in Punctuation style:
- Blank: space, tab, NUL, NBSP, U+1680, U+2000-200B, U+2028-2029, U+202F, U+205F, U+3000.
- Newline: `\n`.
- Word: ASCII alphanumerics, Latin-1 letters À-ÿ except × and ÷, and most other non-ASCII characters.
- Punctuation: everything else below U+100. **`_` and `-` are punctuation.**
- Further classes: Emoji, Superscript, Subscript, Braille, Hiragana, Katakana, Cjk, Hangul.

Whitespace style has only three classes: Newline, Blank, and Word (everything else). Accepted text is appended (AS-16). If the cursor is not at the suggestion, these keys do ordinary word motion; see the editing section.
**Source.** `share/functions/__fish_shared_key_bindings.fish:44,48-52`, `src/reader/reader.rs:3617-3655`, `:5711-5734`, `src/reader/word_motion.rs:59-97`, `:116-174`, `:176-221`, `:132-140`, `crates/widestring/src/word_char.rs:28-65`, `:102-178`.
**Test.**
    setup: HIST 'echo hello world' 'git commit --amend' 'ls /usr/bin'
    keys:  send-keys -l 'git c'; M-f   expect: `git commit` + suggestion ` --amend`, cursor 26
    keys:  M-f   expect: cursor 29 (accepted " --")
    keys:  M-f   expect: cursor 34 (accepted "amend")
    keys:  C-u; send-keys -l 'ls '; M-Right ×4   expect cursor 20 ("/"), 23 ("usr"), 24 ("/"), 27 ("bin")
    keys:  C-u; send-keys -l 'ls /u'; S-Right    expect: `ls /usr/bin`, cursor 27 (bigword "sr/bin")
**Observed.** All exactly as listed.

### AS-26 — Accept one token: `ctrl-right` (`forward-token`)
**Behavior.** When at the suggestion: build the displayed line D (the AS-15 combination) and take the cursor's command substitution within it. Tokenize it, keeping only string tokens. The new position is the end of the first string token whose end is after the cursor. Append `newpos - (end of cursor line)` characters of the suggestion. If there is no such token the count is 0, and nothing happens. Separators such as `|` and `;` are not string tokens, so they are skipped over and included in the appended text. When not at the suggestion, it moves the cursor to the next token end, unless the cursor is already at the end.
**Source.** `share/functions/__fish_shared_key_bindings.fish:22`, `src/reader/reader.rs:3784-3801`, `:4428-4464`.
**Test.**
    setup: as AS-25
    keys:  send-keys -l 'git c'; C-Right   expect: `git commit` + suggestion ` --amend`, cursor 26
    keys:  C-Right   expect: `git commit --amend`, cursor 34
**Observed.** Yes.

### AS-27 — `shift-delete` (`history-delete`) on a suggestion
**Behavior.** The binding is `shift-delete → history-delete or backward-delete-char`. When the cursor is at the suggestion (cursor at the end of the searched range):
- If the suggestion is a whole history entry (whole-buffer history match whose range covers the full entry): remove EVERY entry with that exact text from history, rewrite the history file, clear the suggestion, and return true. `backward-delete-char` does not run.
- If it came from completions or is a single line of a multi-line entry: flash the suggestion for 100 ms in search_match foreground and background, delete nothing, and return true.

When not at a suggestion and no history search or pager is active, it returns false, so `backward-delete-char` runs.
**Source.** `share/functions/__fish_shared_key_bindings.fish:39`, `src/reader/reader.rs:3535-3563`, `:4637-4676` (flash), `:1905-1906`, `src/history/history.rs:830-848` (remove all exact matches), `:726-739` (deletions force a rewrite).
**Test.**
    setup: HIST 'echo zzz unique'
    keys:  send-keys -l 'echo z'; S-DC     (tmux name for shift-delete)
    expect: suggestion disappears; buffer `echo z`; the history file no longer contains "echo zzz unique"
**Source only.**

### AS-28 — `accept-autosuggestion` and `suppress-autosuggestion` (unbound input functions)
**Behavior.**
- `accept-autosuggestion` works with the cursor anywhere on the suggestion's line (`is_at_line_with_autosuggestion`). It does a full replace-accept, leaves the cursor at the end of the inserted text, and returns status true. With no suggestion it returns false.
- `suppress-autosuggestion` sets suppression, clears the suggestion, and returns true only if one was showing.
- `commandline --showing-suggestion` is true only when the suggestion is non-empty AND it is not just the current line plus one trailing space.

Both input functions also end the pager (`accept-autosuggestion` always; `suppress-autosuggestion` never).
**Source.** `src/reader/reader.rs:3946-3959`, `:1197-1210`, `:6226`, `:6246`.
**Test.**
    setup: HIST 'echo hello'; send-keys -l 'bind ctrl-o accept-autosuggestion'; Enter
    keys:  send-keys -l 'echo h'; C-a; C-o    expect: `echo hello`, cursor at end
**Source only.**

### AS-29 — Typing into the suggestion keeps it, with no recomputation or flicker
**Behavior.** fish checks each edit to see whether it keeps the current suggestion. The edit must end exactly at the end of the searched range and must not start before its beginning. The replacement text must then continue the suggestion: compared case-insensitively (after lowercasing) for icase suggestions, case-sensitively otherwise. This covers typing the next characters, and also a replace-all that is still a prefix. If so, the suggestion is preserved and the searched range is extended or shrunk. Any other edit clears it.
**Source.** `src/reader/reader.rs:2037-2101`, `:2104-2114`, `:1496`.
**Test.**
    setup: HIST 'echo hello world'
    keys:  send-keys -l 'echo hel'; send-keys -l 'l'
    expect: `echo hell` + `o world`, shown immediately with no gap
**Observed.** Yes.

### AS-30 — Backspace removes the suggestion; one wrong character can be undone with backspace
**Behavior.**
- `backward-delete-char` and `delete-char` always set suppression, so the suggestion disappears and stays gone until the next inserted text.
- One exception: typing at the suggestion's end a text that does NOT continue it saves the suggestion. If the very next edit deletes exactly from that point (backspace over what was just typed), the saved suggestion is restored and suppression is cleared.
- Any other intervening edit drops the saved copy.
**Source.** `src/reader/reader.rs:2205-2229` (suppress), `:2115-2134` (RemoveAndSave / Restore), `:1493-1505` (the saved copy is taken on every command-line change).
**Test.**
    setup: HIST 'echo hello world'
    keys:  send-keys -l 'echo hel'; BSpace      expect: `echo he`, no suggestion
    keys:  send-keys -l 'l'                     expect: `echo hel` + `lo world`
    keys:  send-keys -l 'x'                     expect: `echo helx`, no suggestion
    keys:  BSpace                               expect: `echo hel` + `lo world` (restored)
    keys:  send-keys -l 'xy'; BSpace            expect: `echo helx`, no suggestion
    keys:  BSpace                               expect: `echo hel`, no suggestion
**Observed.** Exactly.

### AS-31 — Editing in the middle of the line
**Behavior.** An edit that does not end at the searched range's end clears the suggestion, and a new one is computed. The history search still uses the whole buffer, or the cursor's line, as the prefix. A history suggestion therefore still appears after the end of the line while the cursor sits in the middle. The completion path is skipped when the line ends in whitespace (AS-04b).
**Source.** `src/reader/reader.rs:2061-2063`, `:5341-5344`, `:5466-5470`.
**Test.**
    setup: HIST 'echo hello world'
    keys:  send-keys -l 'echo hll'; Left; Left; send-keys -l 'e'
    expect: `echo hell` + suggestion `o world`, cursor col 22
**Source only.**

### AS-32 — Pager interaction
**Behavior.**
- While the completion pager is open, and also while it is being navigated without the search field, suggestions are still computed and drawn on the command line.
- A pager selection that keeps the line a prefix of the suggestion preserves it.
- Accepting a suggestion clears the pager.
- When the pager search field has focus (ctrl-r history pager, or completion pager search after ctrl-s), there are no suggestions.
**Source.** `src/reader/reader.rs:5541`, `:1458-1463`, `:5672-5673`, `:4714-4726`.
**Test.**
    setup: HIST 'cat fileA.txt extra'; touch $W/fileA.txt $W/fileB.txt
    keys:  send-keys -l 'cat f'; Tab     expect: line `cat file` + `A.txt extra`; pager row `fileA.txt  fileB.txt`
    keys:  Tab                           expect: `cat fileA.txt ` + `extra`; fileA.txt drawn in reverse video
**Observed.** Yes.

### AS-33 — Multiple lines in the buffer: which line gets the suggestion
**Behavior.** The suggestion is attached to the line holding the cursor. For a whole-buffer match it is attached to the end of the buffer. Accepting works only when the cursor is at the end of the searched range: the end of the cursor's line (LinePrefix), or the end of the buffer (whole-buffer match). Completions use the text up to the end of the cursor's line.
**Source.** `src/reader/reader.rs:5635-5648`, `:5650-5665`, `:5479-5481`.
**Test.** See AS-03 and AS-19.
**Observed.** Via AS-03 and AS-19.

### AS-34 — After accepting, and after executing
**Behavior.** Accepting only edits the buffer. History records exactly what is executed: trailing spaces and newlines are trimmed unless backslash-escaped (HS-22). Executing clears the suggestion before the final repaint, so no grey text is left in scrollback. After a full accept, the buffer usually equals the suggestion, so nothing more is drawn. A newer, longer entry with the same prefix would be shown, though.
**Source.** `src/reader/reader.rs:4561-4564`, `:2634-2639`.
**Test.**
    setup: HIST 'echo hello world'
    keys:  send-keys -l 'echo h'; Right; Enter
    expect: the row with the executed command shows plain `echo hello world` (no grey); output `hello world`
**Source only.**

### AS-35 — `ctrl-c` and cancel
**Behavior.**
- `ctrl-c` (`clear-commandline`) empties the buffer, which clears the suggestion. Nothing is printed and the prompt stays on the same row.
- `escape` / `ctrl-g` (`cancel`) leave a suggestion alone, unless they are ending a history search (HS-10) or undoing a just-inserted unique completion.
**Source.** `share/functions/__fish_shared_key_bindings.fish:32-33,72`, `share/functions/fish_default_key_bindings.fish:38`, `src/reader/reader.rs:3081-3149`.
**Test.**
    setup: HIST 'echo hello world'
    keys:  send-keys -l 'echo h'; C-c   expect: empty prompt on the same row; no `^C`
**Observed.** Yes (observed together with HS-11).

### Notes for zsh implementers (Autosuggestions)
- **Exact suggestion algorithm** (`src/reader/reader.rs:5328-5521`):
  ```
  icase = None
  for (kind, S) in [(WHOLE, buf[0:len]), (LINE, cursor_line)]:
      if S empty: continue
      if kind==LINE and line_of(first_token_of_process_at_cursor) != cursor_line: continue
      for item in history newest->oldest, dedup, matching S case-insensitively (lowercase both):
          rng = WHOLE ? (item.startswith(S) ? all : None)
                      : first line L of item with L.startswith(S)
          if rng is None and icase is None: rng = icase-variant of the above; is_icase = true
          if rng is None: continue
          if validate(item, rng, item.paths, $PWD):
              if not is_icase: return item[rng]             # case-sensitive wins immediately
              icase = item[rng]
  if cursor_line empty: return none
  last = cursor_line[-1]
  if cursor not at line end and last is whitespace: return none
  if cursor at line end and last in '"\'': return none
  comps = complete(buf[0:end_of_cursor_line], prefix-only, no-desc)
  if comps empty: return icase or none
  sort: best rank, natural order, then exact-case < smartcase < icase, then non-duplicate-arg, then no '~'
  if icase and comps[0].case is smart/icase: return icase
  return line_at_cursor(apply(comps[0], append_only))
  ```
  Note the subtle point: the icase fallback *survives* past the completion step only when completions are not exact-case.
- The display-case rule (AS-15) depends on the **last token of the whole buffer**, not the typed line.
- Full accept REPLACES, partial and line accepts APPEND (AS-16). This produces visible case flips that zsh-autosuggestions does not do.
- Word acceptance uses vim-style character classes, with `_` and `-` as punctuation. It is not zsh's `WORDCHARS`. Port the state machine in AS-25 verbatim.


---

## 2a. Tab completion — engine & insertion

This section covers what Tab computes and what it inserts. It describes how completions are generated (files, commands, variables, users, options, abbreviations), how they are matched and ranked (`StringFuzzyMatch`), how they are deduplicated and sorted, and the exact first/second-Tab state machine. It also covers how a chosen completion is written into the command line: escaping, quoting, trailing space or `/`, and replacing the token versus appending to it. Pager layout, colors and navigation belong to section 2b; where this section touches the pager, it only says *what* the pager is given.
Paths are relative to the fish 4.9.3 checkout `/Users/darin/vendor/github.com/fish-shell/fish-4.9.3`. Each behavior is marked **Observed** (seen in tmux or `complete -C` on the installed fish 4.9.3) or **Source-only**.

### Shared fixture for all TC tests

Start from the standard brief fixture (`$H`, `$W`, tmux socket `fishspec-tc`), then add:

```sh
cd $W && mkdir Documents docs Downloads .hiddendir \
      && touch data.txt Data.csv 'foo bar.txt' .hidden file1 file2 file10 file02
mkdir -p $H/.config/fish/{functions,completions,conf.d}
# Turn autosuggestions off so the line shows only what Tab inserted
# (the default theme draws autosuggestions in brblack and capture-pane -p cannot tell them apart):
echo 'set -g fish_autosuggestion_enabled 0' > $H/.config/fish/conf.d/noauto.fish
printf 'function mycmd --description %s\nend\n' "'My test command'" > $H/.config/fish/functions/mycmd.fish
printf 'function mycmd2\nend\n' > $H/.config/fish/functions/mycmd2.fish
cat > $H/.config/fish/completions/mycmd.fish <<'EOF'
complete -c mycmd -s a -l all -d 'Show all'
complete -c mycmd -s b -l brief -d 'Be brief'
complete -c mycmd -l color -a 'auto always never' -d 'Colorize'
complete -c mycmd -l format -x -a 'json yaml' -d 'Output format'
complete -c mycmd -s v -d 'Verbose'
EOF
```

To clear the line between tests use `send-keys C-e C-u` (`C-u` only kills text to the left of the cursor). When the pager search field is focused, press `Escape` first. In the "expect" lines, a trailing `␠` means a literal trailing space, and the cursor is at the end of the shown line unless stated otherwise.
Machine caveat: macOS APFS is case-insensitive, which matters only where noted. On this machine the nix-installed fish also sources system config that adds `PAGER`, `HOMEBREW_BUNDLE_FILE` and extra `PATH` entries. Tests therefore use their own variables.
Quick non-interactive check (it skips the reader-only filtering described in TC-06, see TC-46): `fish -c "complete -C 'ls doc'"`, run with `cwd=$W` and the same `env -i`.

---

### TC-01 — Tab dispatch: first press vs repeated press
**Behavior.** The `complete` command (bound to `tab` and `ctrl-i`) works like this:
- If completion is disabled for this reader (`conf.complete_ok == false`, e.g. some `read` invocations), it does nothing.
- If the user is already navigating the pager contents (a completion is selected, or the history pager is open), **or** the previous Tab showed an ambiguous list (`completion_action == ShownAmbiguous`) and the previous readline command was exactly `complete`, then:
  - if the current pager rendering still has rows left to disclose (`remaining_to_disclose != 0`), Tab only expands the pager to show everything (`set_fully_disclosed`) and selects nothing;
  - otherwise Tab selects the next completion (`SelectionMotion::Next`). Shift-tab (`complete-and-search`) selects the previous one instead.
- Otherwise fish computes completions afresh (TC-02). Before doing so it disables the terminal keyboard protocols so that ctrl-c sends SIGINT.

Any self-inserted character sets `last_cmd = None` and clears the pager, so the next Tab is a "first" Tab again. Rendering-only commands (`repaint`, `force-repaint`, `repaint-mode`, `clear-screen`) do not overwrite `last_cmd`.
**Source.** `share/functions/__fish_shared_key_bindings.fish:34-35` (tab/ctrl-i → complete), `src/reader/reader.rs:3183-3213` (dispatch), `src/reader/reader.rs:1438-1440` (`is_navigating_pager_contents`), `src/reader/reader.rs:2754-2760,2882-2889` (typing clears pager and sets last_cmd=None), `src/reader/reader.rs:2863-2865,6334-6341` (rendering-only commands do not update last_cmd).
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls fil'; send-keys Tab; send-keys Tab; send-keys Tab
    expect: after Tab 1: line `ls file`, pager `file1  file02  file2  file10`, nothing selected;
            after Tab 2: `file1` selected and the line reads `ls file1␠`;
            after Tab 3: `file02` selected, line `ls file02␠`
**Observed.** Yes, with 100x30. The 4-item list fit on screen, so Tab 2 selected an item instead of only disclosing more rows.

### TC-02 — Completion pipeline on a fresh Tab (order of operations)
**Behavior.** `compute_and_apply_completions` runs these steps in order:
1. If the cursor sits right after an odd run of backslashes (a dangling escape), delete that one backslash (backspace) (TC-34).
2. Find the command substitution around the cursor. Then find the token under the cursor inside it: a string token that contains the cursor **or ends exactly at it**; if the cursor is in whitespace, the token is empty. The token is clamped so it never extends past the end of the command substitution.
3. Try wildcard expansion of the token (TC-30). If that succeeds, replace the token and stop.
4. Call `complete()` on the text **from the start of the command substitution to the end of the token**. Text after the cursor that belongs to the same token is included (TC-33). Text after the token is ignored.
5. `sort_and_prioritize` (TC-11).
6. Save `cycle_command_line`/`cycle_cursor_pos` (= token end), then `handle_completions` (TC-03…TC-07).
7. Set `completion_action` to `InsertedUnique` if a unique completion was inserted, `ShownAmbiguous` if the pager is non-empty, otherwise `None`.
**Source.** `src/reader/reader.rs:6932-7033`, `src/parse_util.rs:453-510` (`get_token_extent`), `src/complete.rs:2494-2509` (`complete()` only looks at the innermost cmdsubst).
**Test.**
    setup: shared fixture
    keys:  send-keys 'echo (ls Doc'; send-keys Tab
    expect: line `echo (ls Documents/` (the completion happens inside the open command substitution)
**Observed.** No (source-only). `complete.rs` tests cover `echo (ls test/complete_test/testfil` → `e` (`src/complete.rs:2878-2884`).

### TC-03 — Candidates of worse rank are discarded (best-rank-only rule)
**Behavior.** Every candidate has a numeric rank (TC-09); lower is better. Fish keeps **only** the candidates whose rank equals the minimum rank and drops all others. This happens in `sort_and_prioritize` and again in `handle_completions`. As a result, a case-sensitive prefix match hides every case-insensitive (uppercase-input) match, substring match and subsequence match. Smartcase prefix matches (lowercase input) tie with case-sensitive prefix matches and are kept (TC-10).
**Source.** `src/complete.rs:641-645`, `src/reader/reader.rs:7066-7073`.
**Test.**
    setup: shared fixture (contains Documents/, docs/, Downloads/)
    keys:  send-keys 'ls Doc'; send-keys Tab
    expect: line `ls Documents/` (unique, no trailing space, no pager). docs/ matches only case-insensitively ("Doc" has an uppercase letter, rank 6) and is dropped because Documents/ is a case-sensitive prefix match (rank 4).
**Observed.** Yes.

### TC-04 — Exactly one candidate: insert it
**Behavior.** If exactly one candidate survives, it is inserted (`try_insert`, `is_unique=true`). The cursor first moves to the token end, then `completion_apply_to_command_line` runs (TC-18…TC-24). A replacing candidate (TC-08) is inserted only if the token can be replaced (TC-06). A filtered-out replacing candidate never reaches this point, so "exactly one" is counted after that filter. The result is `completion_action = InsertedUnique`, and Escape will undo it (TC-15).
**Source.** `src/reader/reader.rs:7100-7105`, `src/reader/reader.rs:7035-7046`, `src/reader/reader.rs:7225-7251`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls Downl'; send-keys Tab
    expect: line `ls Downloads/` (directory → `/`, no space)
**Observed.** Yes (also via the mid-token variant, TC-33).

### TC-05 — No candidates: flash the token, no bell
**Behavior.** If no candidate survives, nothing is inserted and the pager stays closed. The **token** being completed is "flashed": its characters are repainted with foreground and background role `SearchMatch` (`fish_color_search_match`, default theme `white --background=brblack --bold`, which tmux shows as SGR `1;37;100`). After a 100 ms sleep the normal colors are repainted.
- If the token range is empty (cursor in whitespace), the whole command line is flashed instead.
- If the command line is also empty, nothing flashes.
- A flash requested less than 50 ms after the previous one is skipped (debounce).
- No BEL is ever written.
**Source.** `src/reader/reader.rs:7092-7099`, `src/reader/reader.rs:4637-4676` (flash; 50 ms debounce at 4642-4649; 100 ms at 4667), `src/highlight/highlight.rs:1216`, `share/themes/default.theme:22`. There is no `\x07` in the reader (grep).
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls zzz'; send-keys Tab; then capture-pane -e every 15 ms
    expect: for ~100 ms `zzz` is shown as `ESC[1m ESC[37m ESC[100m zzz ESC[0m`, then back to `ESC[36mzzz` (param color); line unchanged `ls zzz`
**Observed.** Yes. Four 15 ms samples showed `^[[1m^[[37m^[[100mzzz^[[0m`, then `^[[36mzzz^[[39m`.

### TC-06 — Replacing candidates are dropped if the token contains `$ * ? ( { } )`
**Behavior.** A candidate that wants to replace the whole token (case-insensitive, substring or subsequence match, TC-08) is discarded if the current token contains any of `$` `*` `?` `(` `{` `}` `)`, unless that candidate is marked "don't escape" (variable-name and `~user` completions). After this filter the unique/ambiguous decision is made on the remaining candidates. Example: with only `Documents/` matching `$PWD/doc` case-insensitively, the result is "no completions" (flash). With `docs/` also present, `docs/` becomes unique.
**Source.** `src/reader/reader.rs:6920-6928` (`reader_can_replace`), `src/reader/reader.rs:7079`, `src/reader/reader.rs:7038`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls $PWD/doc'; send-keys Tab
    expect: line `ls $PWD/docs/` (the case-insensitive `Documents/` candidate was dropped, so docs/ is unique)
    keys:  send-keys C-e C-u 'ls $PWD/Doc'; send-keys Tab
    expect: line `ls $PWD/Documents/`
**Observed.** Yes. (`complete -C 'ls $PWD/doc'` still lists the absolute `/…/w/Documents/` replacer, because `complete -C` skips this reader-only filter.)

### TC-07 — Several candidates: insert the common prefix, open the pager on the FIRST Tab
**Behavior.** With ≥2 surviving candidates (after TC-03 and TC-06):
1. `will_replace_token` = **every** candidate replaces the token. If at least one does not, every replacing candidate is re-flagged `show_pager_prefix=false`. Such a candidate takes no part in the common-prefix computation and is shown in the pager without the prefix.
2. A common prefix is computed **only if every candidate is an exact or prefix match** (no substring or subsequence). It is the longest literal common prefix (case-sensitive char compare) of the `completion` strings of the candidates that still want the pager prefix. For appending candidates those strings are the *suffixes* to add; for an all-replacing set they are the full new tokens.
3. The prefix is inserted iff its length is greater than `tok.len()` when `will_replace_token`, and greater than 0 otherwise. It is inserted with `is_unique=false` and **no suffix** (no space, no closing quote) (TC-19). The cycle line and cursor are then reset to the new line.
4. The pager is always opened on this first Tab (`completion_action = ShownAmbiguous`). There is no "second Tab to list" behavior. The pager prefix is `tok + common_prefix`, or just `common_prefix` when `will_replace_token`, or empty when `will_replace_token` and nothing was inserted. If it is longer than 9 characters it is shortened to `…` + its last 9 chars, and if those 9 chars contain a `/` it becomes `…/` + the last path component. The inserted prefix is removed from the front of every candidate that shows the prefix, and those candidates are switched to append mode.
**Source.** `src/reader/reader.rs:7077-7089`, `src/reader/reader.rs:7107-7164`, `src/reader/reader.rs:7166-7195` (pager prefix; `PREFIX_MAX_LEN = 9` at `src/reader/reader.rs:1300`), `src/reader/reader.rs:7197-7215`, `doc_src/interactive.rst:39`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls fil'; send-keys Tab
    expect: line `ls file` (common suffix `e` appended, no space), pager shows `file1  file02  file2  file10`,
            each with `file` in prefix style (SGR `1;4`) and the remainder plain
**Observed.** Yes: `^[[1;4mfile^[[0m1  ^[[1;4mfile^[[0m02 …`.

### TC-08 — When a candidate replaces the whole token
**Behavior.** A candidate replaces the token, rather than appending its text at the cursor, when any of the following hold:
- **(a)** its match `requires_full_replacement()`, i.e. its case fold is not `Sensitive` (smartcase *or* insensitive) or its type is `Substr`/`Subseq`;
- **(b)** a literal (non-wildcard) segment before a wildcard matched only case-insensitively;
- **(c)** it comes from a fuzzy-matched intermediate directory (TC-27);
- **(d)** the token has an unquoted, unescaped `[` (TC-35).

Appending candidates carry only the missing suffix (e.g. `uments/`). Replacing candidates carry the full new token (e.g. `Documents/`, `$PATH`, `~root`, `--color`).
**Source.** `crates/wcstringutil/src/lib.rs:203-211` (`requires_full_replacement`), `src/complete.rs:243-260` (`Completion::new` sets `ReplacementScope::Token`), `src/wildcard.rs:137-145` (full vs suffix text), `src/wildcard.rs:181-194`, `src/wildcard.rs:780-785`, `src/complete.rs:2215-2266`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls ume'; send-keys Tab
    expect: line `ls Documents/` (substring match replaced the token "ume")
**Observed.** Yes.

### TC-09 — Match types, case folds and the rank formula (StringFuzzyMatch)
**Behavior.** `try_create(typed, candidate, anchor_start)` returns the first test that succeeds, in this order:
1. `typed.len() > candidate.len()` → no match.
2. exact, same case → (Exact, Sensitive).
3. candidate starts with typed (same case) → (Prefix, Sensitive).
4. exact ignoring case → (Exact, F).
5. prefix ignoring case (both lowercased per char) → (Prefix, F).
6. if `anchor_start` → stop, no match.
7. substring, same case → (Substr, Sensitive).
8. substring ignoring case, where additionally `_` and `-` count as equal → (Substr, F).
9. subsequence, same case only → (Subseq, Sensitive).
10. no match. There is no case-insensitive subsequence.

F = `Insensitive` if the typed text contains any uppercase char (`char::is_uppercase`), else `Smart`.

Enum order: `ContainType {Exact=0, Prefix=1, Substr=2, Subseq=3}` and `CaseSensitivity {Sensitive=0, Smart=1, Insensitive=2}`.

`rank = (from_separator<<4) + (eff_type<<2) + eff_case`, where Exact is ranked as Prefix and Smart is ranked as Sensitive. Resulting ranks: prefix/exact samecase or smartcase = 4; prefix/exact insensitive = 6; substring samecase/smartcase = 8; substring insensitive = 10; subsequence = 12. Add 16 if the candidate came from after a `=`/`:` separator (TC-28).
**Source.** `crates/wcstringutil/src/lib.rs:144-170` (enums, "order affects sort order"), `crates/wcstringutil/src/lib.rs:216-304` (`try_create`), `crates/wcstringutil/src/lib.rs:306-326` (`rank`), `crates/wcstringutil/src/lib.rs:118-142` (`ifind` fuzzy `_`→`-`), `crates/wcstringutil/src/lib.rs:90-111` (subsequence), `crates/fallback/src/lib.rs:83-96` (case-insensitive compare = per-char `to_lowercase`); unit tests `crates/wcstringutil/src/lib.rs:626-701`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls Dcmnt'; send-keys Tab
    expect: line `ls Documents/` (samecase subsequence D…c…m…n…t)
    keys:  send-keys C-e C-u 'ls dcmnt'; send-keys Tab
    expect: line unchanged, token flashed (lowercase `d` has no case-insensitive subsequence)
**Observed.** `ls Dcmnt` yes (via `complete -C`); `dcmnt` is source-only.

### TC-10 — Smartcase: lowercase input also matches uppercase names, ranked equal
**Behavior.** Typed text with no uppercase letters matches case-insensitively with fold `Smart`, which ranks the same as `Sensitive` (TC-09). So `doc` keeps both `docs/` (samecase, appends `s/`) and `Documents/` (smartcase, replaces). Typed text with **any** uppercase letter matches case-insensitively with fold `Insensitive`, which ranks worse and is dropped when any samecase match exists (TC-03). Uppercase input never "prefers" anything except via rank.
**Source.** `crates/wcstringutil/src/lib.rs:222-230,253-267,316-320`; CHANGELOG.rst:335 ("Prefix-matching completions are now shown even if they don't match the case typed by the user (#7944)").
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls DOC'; send-keys Tab
    expect: line unchanged `ls DOC`; pager `docs/  Documents/` (both insensitive, both replace, common prefix of
            full strings "docs/" vs "Documents/" is empty, so nothing is inserted)
**Observed.** Yes.

### TC-11 — Dedup and sort order of candidates
**Behavior.** After the best-rank filter (TC-03), candidates are deduplicated **by completion string only**. The first occurrence wins and keeps its description and flags. Then a stable sort is applied:
- candidates from `complete -k/--keep-order` (`dont_sort`) come first, in the order they were produced;
- all others are ordered by `wcsfilecmp` on the **completion string**. That string is the suffix for appending candidates and the full token for replacing ones (so the sort can look odd, see TC-12).

`wcsfilecmp(a, b)`:
- Walk both strings. When both current chars are ASCII digits, compare the whole digit runs numerically: leading zeros are skipped, a longer run is bigger, otherwise the first differing digit decides; trailing whitespace after the run is skipped. If the runs are equal and either string ends, stop.
- Otherwise identical chars advance. Different chars are mapped (`-`→`[`, `/`→`\0`), uppercased, and compared by code point; the first difference decides.
- If one string is a prefix of the other, the shorter one is smaller.
- If both are "logically equal", the raw code-point comparison decides (so `AbC < abc`, `file02 < file2`).

The overall effect: case-insensitive natural order; digits sort before letters; `-` sorts after all letters; `/` sorts before everything.
**Source.** `src/complete.rs:619-632` (dedup), `src/complete.rs:636-666` (`sort_and_prioritize`), `src/complete.rs:584-596` (`natural_compare_completions`), `crates/util/src/lib.rs:35-108` (`wcsfilecmp`), `crates/util/src/lib.rs:193-244` (digit runs); unit tests `crates/util/src/lib.rs:270-319`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls '; send-keys Tab
    expect: pager order (column-major) `Data.csv data.txt docs/ Documents/ Downloads/ file1 file02 file2 file10 foo bar.txt`
            (hidden files absent, TC-25)
**Observed.** Yes (`complete -C 'ls '` printed exactly that order).

### TC-12 — Mixed append and replace sets: common prefix comes only from appenders
**Behavior.** When appending (samecase) and replacing (smartcase) candidates are mixed, only the appenders feed the common prefix (TC-07 step 1). With a single appender, its whole suffix becomes the "common prefix" and **is inserted**, even though other candidates exist and the pager opens.
- Example: `ls doc` → `s/` is inserted (line `ls docs/`), and the pager lists `Documents/` (no prefix, full text) and `docs/` (prefix `docs/` + empty remainder). Pager order follows the sort keys `"Documents/"` < `"s/"`.
- Next Tabs cycle `Documents/` → `docs/` → `Documents/` …. Selecting the replacing `Documents/` rewrites the whole token.
- Example `ls d` (5 matches): appenders `ata.txt` and `ocs/` share no prefix → nothing inserted. Pager order follows the sort keys `ata.txt`, `Data.csv`, `Documents/`, `Downloads/`, `ocs/`, i.e. it displays `data.txt  Data.csv  Documents/  Downloads/  docs/`.
**Source.** `src/reader/reader.rs:7081-7089`, `src/reader/reader.rs:7115-7118`, `src/reader/reader.rs:7199-7204` (non-prefix candidates keep replacement semantics), `src/pager.rs:440-448` (prefix drawn only for `wants_pager_prefix`), `src/complete.rs:293-299`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls doc'; send-keys Tab; send-keys Tab; send-keys Tab
    expect: Tab1: line `ls docs/`, pager `Documents/  docs/` (the `docs/` item in prefix style `ESC[1;4m`, `Documents/` plain);
            Tab2: line `ls Documents/` (first item selected); Tab3: line `ls docs/`
    keys:  send-keys C-e C-u 'ls d'; send-keys Tab
    expect: line `ls d`, pager `data.txt  Data.csv  Documents/  Downloads/  docs/`
**Observed.** Yes, both.

### TC-13 — No common prefix is inserted if any candidate is a substring/subsequence match
**Behavior.** If any surviving candidate is a Substr or Subseq match, the common-prefix step is skipped entirely and the pager opens with prefix `""`. Because all candidates share the same rank, either all are prefix/exact or all are substring/subsequence. Substring/subsequence candidates always replace (TC-08).
**Source.** `src/reader/reader.rs:7109-7111`, `src/reader/reader.rs:7167-7168`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls oc'; send-keys Tab
    expect: line unchanged `ls oc`; pager `docs/  Documents/`
**Observed.** Yes.

### TC-14 — Second Tab when the pager has undisclosed rows
**Behavior.** If the first Tab produced a pager that does not fit in its initial allotment (`remaining_to_disclose != 0`, e.g. `…and N more rows`), the second consecutive Tab only expands the pager to full and selects nothing. The third Tab selects the first item. With complete-and-search the same applies, but it selects `Prev`.
**Source.** `src/reader/reader.rs:3193-3194`; disclosure sizing is in 2b (`src/pager.rs:1057`).
**Test.**
    setup: shared fixture; terminal 100x10
    keys:  send-keys Tab   (empty command line → all commands)
    expect: pager ends with a line `…and N more rows`; send-keys Tab → more rows shown, line still empty; send-keys Tab → first item `!` selected, line `!␠`
**Observed.** First Tab observed (100x30: `…and 2270 more rows`); the 2nd/3rd Tab steps are source-only.

### TC-15 — Escape undoes a unique completion just inserted
**Behavior.** If the last command was `complete`/`complete-and-search` **and** it inserted a unique completion (`InsertedUnique`), then `cancel` (Escape, ctrl-[ and ctrl-g in emacs mode) undoes that insertion and restores the old cursor position. After an ambiguous Tab (prefix inserted + pager), Escape only closes the pager and the inserted common prefix stays. After a wildcard expansion (TC-30), `completion_action` is `None`, so Escape does not undo it.
**Source.** `src/reader/reader.rs:3132-3149`, `src/reader/reader.rs:6214-6234` (cancel ends paging), `share/functions/__fish_shared_key_bindings.fish:32-33`, `share/functions/fish_default_key_bindings.fish:38`, `src/reader/reader.rs:6989`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls Doc'; send-keys Tab; send-keys Escape
    expect: line back to `ls Doc`, cursor after `Doc`
    keys:  send-keys C-e C-u 'ls fil'; send-keys Tab; send-keys Escape
    expect: pager gone, line `ls file` (prefix kept)
**Observed.** Yes, both.

### TC-16 — complete-and-search (shift-tab)
**Behavior.** `shift-tab` → `complete-and-search`.
- On a "first" press it computes completions exactly like Tab (TC-02, including unique insert and common-prefix insert).
- If the result was **not** a unique insert and the pager is non-empty, it then shows the pager search field and selects the **first** candidate (`Next`), which applies it to the line. Focus is in the search field.
- When pressed again while navigating, it selects `Prev` (wrapping from the first item to the last). A following Tab selects `Next`.
- Note: the repeated-press shortcut for a not-yet-navigating pager requires `last_cmd == complete` exactly. A second shift-tab therefore counts as "navigating" only because the first one already selected an item.
- UI details (search field rendering, filtering) are in section 2b.
**Source.** `share/functions/__fish_shared_key_bindings.fish:37-38`, `src/reader/reader.rs:7028-7032`, `src/reader/reader.rs:3187-3203`, `src/pager.rs:704-713`; CHANGELOG.rst:1373.
**Test.**
    setup: shared fixture; tmux `set -s extended-keys on` (BTab)
    keys:  send-keys 'ls fil'; send-keys BTab
    expect: line `ls file1` (prefix `e` inserted, then first item `file1` applied), second line `search: ` with cursor in it, `file1` drawn selected
    keys:  send-keys BTab → line `ls file10` (wrapped to last); send-keys Tab → line `ls file1`
**Observed.** Yes. The cursor was reported in the search row (x=8, y=1) and the selected item was drawn as `ESC[1;4;7mfile ESC[0;7m1`.

### TC-17 — Candidates when the cursor is in whitespace or on an empty line
**Behavior.**
- **Empty process** (empty line, or the cursor right after `;`, `|`, `&`, `&&`, `||` or a newline, modulo spaces): complete command names with an empty prefix (all commands; TC-40 for sources), plus abbreviations.
- **Cursor after a space following an argument:** the current argument is `""` (all files etc.), and the previous argument (used by option logic) is the token before the cursor. Trailing spaces before the cursor are skipped when locating the process.
- **Inside a comment:** no candidates.
**Source.** `src/complete.rs:763-766`, `src/complete.rs:803-812`, `src/complete.rs:820-822`, `src/complete.rs:875-903`.
**Test.**
    setup: shared fixture
    keys:  send-keys Tab
    expect: pager listing commands starting `!  (Negate exit status of job)`, `:  (Return a successful result)`, …
**Observed.** Yes.

### TC-18 — Trailing space after a unique completion; when there is none
**Behavior.** By default a unique completion is followed by one space. No space is added when:
- the candidate is a directory (the completion ends with `/`);
- it is an abbreviation;
- it is a `~user` completion;
- it is a long option ending in `=`;
- it is a `complete -a` value ending in one of `/ = @ : . , -` (`WantsSuffix::Auto`);
- the token has an unclosed `{` brace;
- or it is a common prefix (TC-19).

If the character right under the cursor is already a space, no new space is inserted, **but the cursor still moves one cell right**, past that space.
**Source.** `src/complete.rs:147-167` (default `Yes`, `NO_SPACE`), `src/wildcard.rs:404-417` (dirs → `/` + no suffix), `src/wildcard.rs:330-332` (unclosed brace), `src/complete.rs:563-578` (Auto rule), `src/builtins/complete.rs:587-593` (`complete -a` uses Auto), `src/reader/reader.rs:6769,6834-6839,6905-6908`, insertion tests `src/reader/reader.rs:7345-7355`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls data.txt'; send-keys Tab
    expect: `ls data.txt␠` (exact match → empty completion + space)
    keys:  send-keys C-e C-u 'ls data.t zzz'; send-keys Left×4 (cursor right after "data.t", before the space); send-keys Tab
    expect: `ls data.txt zzz`, no second space inserted, cursor on the `z` (moved past the existing space)
**Observed.** First part yes; the second part is source-only (from unit test `"foo^ baz"` → `"foobar ^baz"`).

### TC-19 — Inserting a common prefix: no suffix, no closing quote, backslash escaping
**Behavior.** The common prefix is inserted with `wants_suffix=No` and `is_unique=false`. As a result it never adds a space or `/`, never closes an open quote, and always uses backslash escaping (`no_quoted`), never quoting. Inside an open quote it is escaped for that quote (TC-21).
**Source.** `src/reader/reader.rs:7152-7163`, `src/reader/reader.rs:6773-6775`.
**Test.**
    setup: shared fixture
    keys:  send-keys "ls 'fil"; send-keys Tab
    expect: line `ls 'file` (no closing quote), pager open
**Observed.** No (source-only).

### TC-20 — Escaping of an appended (non-replacing) unique completion
**Behavior.** When the candidate appends to a **non-empty** unquoted token, the text is backslash-escaped (`no_quoted` forced because the token is non-empty).
- Characters that get a `\`: `\` `'` `&` `$` space `#` `<` `>` `(` `)` `[` `]` `{` `}` `*` `|` `;` `"` `%` `~`.
- Exceptions: `?` is never escaped (`qmark-noglob` is on by default); `#` is not escaped when the previous char of the inserted string is alphanumeric; `~` is not escaped when the completion asks for literal tildes (TC-29); `,` is never escaped.
- Control chars become `\n`, `\t`, `\b`, `\r`, `\e`, `\x7f`, `\cX` or `\xHH`. Bytes that are not valid UTF-8 become `\XHH`.
**Source.** `src/reader/reader.rs:6847-6877` (`have_token` → `no_quoted`), `crates/common/src/lib.rs:133-322` (special set at 254-275; `?` via `QuestionMarkNoGlob` at 138,262-267), `crates/feature-flags/src/lib.rs:82-86` (qmark-noglob default true).
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls foo'; send-keys Tab
    expect: `ls foo\ bar.txt␠`
**Observed.** Yes.

### TC-21 — Completing inside an open quote, or right after a closing quote
**Behavior.** Append path only:
- **Open quote:** if the token has an unclosed `'` or `"` before the cursor (`get_quote`), the completion is escaped for that quote. Inside `'…'` only `\` and `'` are backslashed. Inside `"…"`, `\`, `"` and `$` are backslashed. Newline/tab/backspace/CR are written as `quote \n quote`. If a suffix (space) will follow, the matching quote is inserted first, then the space: `ls 'foo` → `ls 'foo bar.txt' `. If the suffix is `/` (directory or variable that names a directory), the quote is **not** closed: `ls "Doc` → `ls "Documents/`.
- **Just after a closing quote:** if the token is closed but the character right before the cursor is an unescaped quote, the insertion moves inside it (before that quote), and no second quote is added: `ls 'foo'` → `ls 'foo bar.txt' `.
- An escaped quote (`foo\'`) is not treated as a quote.
**Source.** `src/reader/reader.rs:6711-6736` (`get_quote`), `src/reader/reader.rs:6680-6689`, `src/reader/reader.rs:6857-6868` (#552 back-into-quote), `src/reader/reader.rs:6890-6909`, `crates/common/src/lib.rs:327-380`; insertion unit tests `src/reader/reader.rs:7345-7458`.
**Test.**
    setup: shared fixture
    keys:  send-keys "ls 'foo"; send-keys Tab        expect: `ls 'foo bar.txt'␠`
    keys:  send-keys C-e C-u 'ls "foo'; send-keys Tab expect: `ls "foo bar.txt"␠`
    keys:  send-keys C-e C-u "ls 'foo'"; send-keys Tab expect: `ls 'foo bar.txt'␠`
**Observed.** First two yes; third source-only (unit test `"'foo'^"` → `"'foobar' ^"`).

### TC-22 — Escaping of a replacing unique completion: quotes instead of backslashes
**Behavior.** When a **unique** candidate replaces the token **and** a space suffix will follow, escaping may use quotes. If the text needs escaping, contains no "complex" chars (control chars, raw bytes, a leading `~` that must stay literal), and printables are escaped, the whole token is wrapped in single quotes. Double quotes are used instead if `count(') > count(") + count($)`. Otherwise backslashes are used.
Backslash escaping is always used when the completion is not unique (pager selection, common prefix), has no space suffix (directories end in `/`), or is append-only. The same quoting applies to an appending unique completion whose token is empty. The whole token range (from `get_token_extent` at the cursor) is replaced, including any text after the cursor in that token.
**Source.** `src/reader/reader.rs:6770-6782` (`no_quoted` unless unique ∧ has-suffix ∧ ¬append_only), `src/reader/reader.rs:6805-6845`, `crates/common/src/lib.rs:303-319`; CHANGELOG.rst:709 ("quoted… only if the completion is unambiguous").
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls FOO'; send-keys Tab
    expect: `ls 'foo bar.txt'␠`   (contrast TC-20: `ls foo` gives `foo\ bar.txt`)
**Observed.** Yes.

### TC-23 — Selecting a candidate from the pager: what is written
**Behavior.** Every pager selection change applies the selected candidate to the saved `cycle_command_line` at `cycle_cursor_pos`, with `append_only=false` and `is_unique=false`. That means backslash escaping (never quotes), but a space suffix (or `/` for directories, closing quote for open quotes) **is** added. The previous pager edit is undone first, so cycling never accumulates text. If the result equals the current line or the cycle line, no edit is made.
**Source.** `src/reader/reader.rs:4681-4711`, `src/reader/reader.rs:7017-7019,7161-7162`.
**Test.**
    setup: shared fixture; `touch '$W/foo baz.txt'`
    keys:  send-keys 'ls foo'; send-keys Tab; send-keys Tab
    expect: Tab1: line `ls foo\ ba`, pager `foo bar.txt  foo baz.txt`; Tab2: line `ls foo\ bar.txt␠` (backslash style, space added)
**Observed.** No (source-only).

### TC-24 — Directory completions: `/` appended, never a space
**Behavior.** A file-system candidate that is a directory (via `stat` if needed, so symlinks to directories count) gets `/` appended to its text and `WantsSuffix::No`. Tab on `Documents` (exact, no slash) therefore inserts `/`.
**Source.** `src/wildcard.rs:404-417`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls Documents'; send-keys Tab
    expect: `ls Documents/` (no space)
**Observed.** Yes.

### TC-25 — Hidden files and `.`/`..` only when the path component starts with `.`
**Behavior.** In file completion, a name starting with `.` matches only if the typed component also starts with a literal `.`. Wildcards do not match a leading dot. When the typed component does start with `.`, the directory is read **with** the `.` and `..` entries, so `./` and `../` are offered. Custom `complete -a` values are exempt and may start with `.`. Intermediate fuzzy directory matching skips `.` and `..`.
**Source.** `src/wildcard.rs:103-111` (`allow_nonliteral_leading_dot`), `src/wildcard.rs:582-588` (dots when `for_completions`), `src/complete.rs:1376-1383` (`complete -a` allows leading dots), `src/wildcard.rs:750-753`; CHANGELOG.rst:958,1259.
**Test.**
    setup: shared fixture (.hidden, .hiddendir/)
    keys:  send-keys 'ls .'; send-keys Tab
    expect: line `ls .`, pager `./  ../  .hidden  .hiddendir/`
    keys:  send-keys C-e C-u 'ls .h'; send-keys Tab
    expect: line `ls .hidden`, pager `.hidden  .hiddendir/`
**Observed.** Yes, both.

### TC-26 — File completions have no descriptions; command-position files do
**Behavior.** Argument file completions carry **no** description (descriptions are switched off whenever file completion is on, per issue #254). In command position, path candidates do get descriptions: executables `command`, executable symlinks `command link`, directories `directory`, directory symlinks `dir symlink` (and `file`/`symlink` where applicable). Only executables and directories are offered there.
**Source.** `src/complete.rs:1740-1743`, `src/wildcard.rs:30-37`, `src/wildcard.rs:289-314` (`file_get_desc`), `src/wildcard.rs:380-402`, `src/complete.rs:1236-1276`.
**Test.**
    setup: shared fixture + `printf '#!/bin/sh\n' > $W/run.sh; chmod +x $W/run.sh`
    keys:  send-keys './'; send-keys Tab
    expect: pager `./docs/  (directory)  ./Documents/  (directory)  ./Downloads/  (directory)  ./run.sh  (command)`; data.txt etc. absent
**Observed.** Yes.

### TC-27 — Fuzzy intermediate directories (`d/f<Tab>` style)
**Behavior.** For a literal (wildcard-free) non-final path segment, fish first tries the literal directory. A fuzzy match is attempted only if that produced nothing **and** the literal path does not exist (and fuzzy matching is on, which it is for Tab unless the token starts with `-`). The fuzzy match runs `string_fuzzy_match(segment, entry)` against each directory in the parent (prefix, case-insensitive, substring or subsequence; same-case exact matches skipped). Every result found below such a directory replaces the whole token, with the real directory name spliced in, and takes the fuzzier of the two match ranks.
Because macOS APFS is case-insensitive, `documents/x` exists literally there and is not fuzzy-matched.
**Source.** `src/wildcard.rs:532-563`, `src/wildcard.rs:734-794`.
**Test.**
    setup: shared fixture + `touch $W/Downloads/report.txt`
    keys:  send-keys 'ls Dwn/rep'; send-keys Tab
    expect: `ls Downloads/report.txt␠` (Dwn → subsequence of Downloads)
**Observed.** No (source-only).

### TC-28 — `=` and `:` separators inside a token
**Behavior.** Unless the token is inside an open quote, the last unescaped `=` or `:` in the token splits it.
- If the token does **not** start with `-`, the whole token is completed as a path first.
- In every case the part after the separator is completed separately. Those candidates get `from_separator=true` (rank +16), so they survive only when the whole-token completion found nothing. If they replace the token, the `…=`/`…:` prefix is put back in front.
- For a token starting with `-` (e.g. `--file=Doc`), only the part after the separator is completed.
- File fuzzy matching is off for tokens starting with `-`.
- In command position, a `VAR=value` token completes only the value, and the `VAR=` prefix is kept when the token is replaced.
**Source.** `src/complete.rs:1745-1815`, `src/complete.rs:849-863` (`keep_variable_override_prefix`), `src/reader/reader.rs:6817-6823`; unit tests `src/complete.rs:2935-2957,3136-3149`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'echo --file=Doc'; send-keys Tab
    expect: `echo --file=Documents/`
    keys:  send-keys C-e C-u 'echo x=Doc'; send-keys Tab
    expect: `echo x=Documents/`
**Observed.** No (source-only; unit tests confirm `something --abc=te` → `stfile`).

### TC-29 — Tilde paths: `~` is kept
**Behavior.** `~/…` and `~user/…` are expanded for matching. Appending candidates add only the suffix, so the `~` stays as typed. For replacing candidates, the expanded home prefix is turned back into `~`/`~user` and that tilde is marked literal (not escaped). `~` with no `/` and no other `~` is user-name completion (TC-31), not a path.
**Source.** `src/complete.rs:1107-1113` (`preserve_home_tildes`), `src/expand.rs:1576-1624` (`unexpand_tildes`), `src/expand.rs:1184-1216`.
**Test.**
    setup: shared fixture (HOME=$H, which contains only `w/` plus hidden `.config`, `.local`)
    keys:  send-keys 'ls ~/'; send-keys Tab                 expect: `ls ~/w/`
    keys:  send-keys C-e C-u 'ls ~/W'; send-keys Tab        expect: `ls ~/w/` (smartcase → replace → `~` restored)
    keys:  send-keys C-e C-u 'ls ~/w/doc'; send-keys Tab    expect: `ls ~/w/docs/`, pager `~/w/docs/  ~/w/Documents/`
**Observed.** Yes, all three. (`ls ~/W` matched `w/` case-insensitively; "W" has an uppercase letter, so this is the Insensitive fold, rank 6. It is the only candidate, so it is unique.)

### TC-30 — Tab on a glob expands it in place
**Behavior.** A glob is expanded in place only if the **current path component** under the cursor contains an unescaped `*`. The component is bounded by unescaped `/` around the cursor. `?` is not a glob (qmark-noglob), and a quoted `*` does not count. When a glob is found:
- The whole token is expanded with command substitution failing, variables skipped, and home tildes preserved, limited to **256** results.
- **Ok:** the token is replaced by every match, each escaped (`no_quoted`), each followed by one space. Order is `wcsfilecmp_glob` (case-insensitive natural order without the `-`/`/` tweaks). Directories get **no** trailing `/` and hidden files are not matched. No pager opens, and `completion_action = None`.
- **Overflow** (>256 matches): flash the token and change nothing.
- **No match:** fall through to normal completion of the literal token, which usually yields nothing → flash.
- `**` is never tab-completed.
**Source.** `src/reader/reader.rs:6967-6996`, `src/reader/reader.rs:6586-6659` (256 at 6613-6615), `src/wildcard.rs:1159-1178` (`wildcard_has`), `src/expand.rs:1555-1556` (glob sort), `crates/util/src/lib.rs:111-173`, `src/wildcard.rs:1041-1045`; CHANGELOG.rst:1507.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls *.txt'; send-keys Tab     expect: `ls data.txt foo\ bar.txt␠`
    keys:  send-keys C-e C-u 'ls D*s'; send-keys Tab expect: `ls Documents Downloads␠` (no `/`)
    keys:  send-keys C-e C-u 'ls *.xyz'; send-keys Tab expect: line unchanged, `*.xyz` flashed
**Observed.** Yes, all three.

### TC-31 — `~user` completion
**Behavior.** A token that starts with `~`, contains no `/`, and has no second `~` completes user names. Names come from `getpwent()`, which is iterated for at most ~200 ms. Matching is anchored (exact or prefix, case-insensitive allowed; no substring). The description is `Home for <name>`. No space and no `/` are appended. A case-insensitive match replaces the token with `~<name>` unescaped. If any user matched, no other completions (files) are produced. If none matched, file completion continues (so a literal file `~foo…` can match).
**Source.** `src/complete.rs:1947-2024`, `src/complete.rs:55-58`, `src/complete.rs:840-847`.
**Test.**
    setup: shared fixture
    keys:  send-keys '~ro'; send-keys Tab
    expect: line `~root` (no space, no slash)
**Observed.** Yes (also `complete -C '~ro'` → `~root<TAB>Home for root`).

### TC-32 — Variable-name completion and its descriptions
**Behavior.**
- **When it triggers:** after an unescaped `$` that is not inside single quotes (double quotes are fine), when only variable-name characters (alphanumeric or `_`) follow up to the end of the token. Then **only** variable names are offered, from all scopes. `$` with nothing after it lists all variables on Tab (never for autosuggestions). Escaped `\$` and `'$` do not trigger.
- **Matching:** fuzzy (TC-09). A samecase prefix appends the rest of the name. Any other match replaces the token with `<text up to and including $><NAME>`, unescaped.
- **Description:** `Variable: <value>`. The value is the list elements joined by single spaces. Each element is wrapped in `'…'` if the list has more than one element or the element contains a space (and it can be single-quoted); otherwise it is fish-escaped. For `$history` the description is instead the history items at indices 1…63, each escaped/quoted the same way, joined by spaces, with no `Variable:` prefix. The pager trims, collapses whitespace and truncates descriptions (2b).
- **Suffix:** after insertion, if the token up to the cursor expands to an existing directory, the suffix is `/`; otherwise it is a space. With an open double quote and a space suffix, the quote is closed first.
**Source.** `src/complete.rs:1882-1942`, `src/complete.rs:1819-1880`, `src/complete.rs:59-60`, `src/expand.rs:287-307,311-322`, `src/reader/reader.rs:6796-6810,6890-6894`, `src/common.rs:293-295`; unit tests `src/complete.rs:2814-2854,3040-3042,3104-3108`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'set -g tcvar_one a; set -g tcvar_two "x y" z' Enter; send-keys C-l; send-keys 'echo $tcvar_'; send-keys Tab
    expect: line `echo $tcvar_`, pager `$tcvar_one  (Variable: a)  $tcvar_two  (Variable: 'x y' 'z')`
    keys:  send-keys C-e C-u 'echo $HOM'; send-keys Tab …(on a machine where HOME is the only $HOM* var) expect: `echo $HOME/`
    keys:  send-keys C-e C-u 'echo "$tcvar_o'; send-keys Tab   expect: `echo "$tcvar_one"␠`
**Observed.** Partly. `echo $PAG` → `echo $PAGER␠`; `echo "$PAG` → `echo "$PAGER"␠`; `echo $HOM` → `echo $HOME` with pager `$HOME (Variable: /private/…)` and `$HOMEBREW_BUNDLE_FILE …`; `complete -C 'echo $HOM'` printed `$HOME/`. The `tcvar` lines are derived from source.

### TC-33 — Cursor in the middle of a token
**Behavior.** The whole token (including text after the cursor) is the completion input (TC-02 step 4). Before inserting, the cursor jumps to the **end of the token**, and appending candidates are added there. Replacing candidates replace the whole token.
**Source.** `src/reader/reader.rs:7001-7005`, `src/reader/reader.rs:7234-7237`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls Downl'; send-keys Left Left; send-keys Tab
    expect: `ls Downloads/`, cursor at end
    keys:  send-keys C-e C-u 'ls Dowxx'; send-keys Left Left; send-keys Tab
    expect: line unchanged, token flashed (the input is "Dowxx", not "Dow")
**Observed.** Yes, both.

### TC-34 — A trailing backslash is removed before completing
**Behavior.** If the character before the cursor is a backslash preceded by an even number of backslashes (i.e. a dangling escape), it is deleted (backspace) before completion. Completion then proceeds normally.
**Source.** `src/reader/reader.rs:6939-6944`, `src/reader/reader.rs:6663-6678`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls foo\'; send-keys Tab
    expect: `ls foo\ bar.txt␠`
**Observed.** Yes.

### TC-35 — Unquoted `[` in the token forces token replacement
**Behavior.** If the argument contains an unquoted, unescaped `[`, all its file candidates are switched to replace-token mode. Each is prefixed with the unescaped argument and has its tildes kept literal, so the `[` gets escaped on insertion. As a unique completion with a space, this yields quoting: `touch bracket[` → `touch 'bracket[abc]' `.
**Source.** `src/complete.rs:2210-2266`; unit tests `src/complete.rs:2995-3019`.
**Test.**
    setup: shared fixture + `touch '$W/bracket[abc]'`
    keys:  send-keys 'touch bracket['; send-keys Tab
    expect: `touch 'bracket[abc]'␠`
**Observed.** No (source-only; unit test).

### TC-36 — Unclosed brace: no trailing space
**Behavior.** If the token has an unterminated `{`, file candidates get no space suffix, so `touch {testfi` → `touch {testfile`. Replacing candidates in such a token are dropped (TC-06, because of `{`).
**Source.** `src/complete.rs:1727-1729`, `src/wildcard.rs:330-332`; unit tests `src/complete.rs:2984-2993`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls {data.t'; send-keys Tab
    expect: `ls {data.txt` (no space)
**Observed.** No (source-only).

### TC-37 — `cd` arguments: directories only, CDPATH, logical paths
**Behavior.** If the command (or anything in its `--wraps` chain) is `cd`, file completion becomes directories-only.
- Relative names are searched in every `$CDPATH` entry plus `.`. Names starting with `/`, `./` or `../` use only the cwd.
- Paths are normalized logically, so `cd ../<Tab>` does not resolve symlinks.
- `__fish_complete_cd` additionally prints CDPATH matches with the description `CDPATH <dir with $HOME→~>`. It skips `.` and `$PWD` entries, prints nothing when CDPATH is unset, and prints nothing for tokens starting with `/`, `./` or `../`.
- There are no descriptions for ordinary directories. Hidden directories follow TC-25.
**Source.** `src/complete.rs:949-951`, `src/complete.rs:1731-1737`, `src/expand.rs:1510-1535`, `src/wildcard.rs:932-935,983-996`, `share/completions/cd.fish:1`, `share/functions/__fish_complete_cd.fish:5-40`.
**Test.**
    setup: shared fixture + `mkdir -p $H/cdp/subdir1 $H/cdp/subdir2`
    keys:  send-keys "set -g CDPATH $H/cdp" Enter; send-keys C-l 'cd sub'; send-keys Tab
    expect: line `cd subdir`, pager `subdir1/  (CDPATH ~/cdp)  subdir2/  (CDPATH ~/cdp)`
    keys:  send-keys C-e C-u 'cd '; send-keys Tab
    expect: pager `docs/  Documents/  Downloads/` (no files)
**Observed.** Yes, both.

### TC-38 — Command-name completion: sources and order of precedence
**Behavior.** In command position (first token, not a `VAR=` token), candidates are added in this order:
1. **abbreviations** (non-regex; only here, never in argument position);
2. **executables**: in `$PATH` (plus cwd entries with `/`); for tokens with `/`, `./`, `../` or a leading `/` only that path; wildcards are not expanded for commands;
3. **directories** (implicit cd);
4. **functions**, only if the token has no `/` and does not start with `~`; names starting with `_` only when the token starts with `_`;
5. **builtins**, under the same `/`/`~` condition.

Because dedup keeps the first occurrence (TC-11), an abbreviation hides a same-named command, and an executable hides a same-named function or builtin. Examples on macOS: `/usr/bin/cd` shows `cd (command)`, not the builtin description. `share/functions/abbr.fish` (an intentionally blank autoload file) makes `abbr` show with **no** description, because functions come before builtins. Exception: on an empty line, commands are added before abbreviations.
**Source.** `src/complete.rs:864-867` (abbr then cmd), `src/complete.rs:803-812` (empty: cmd then abbr), `src/complete.rs:1236-1308`, `src/function.rs:333-358` (`get_names`, hidden `_`), `src/expand.rs:1482-1484,1510-1518`, `src/complete.rs:619-632`, `share/functions/abbr.fish:1-5`.
**Test.**
    setup: shared fixture
    keys:  send-keys Tab
    expect: pager row `abbr` has no description; `!` has `(Negate exit status of job)`
    check: `fish -c "complete -C cd"` → `cd<TAB>command` (macOS)
**Observed.** Yes, both.

### TC-39 — Command descriptions
**Behavior.**
- **Executables:** `command`, or `command link` for symlinks. Directories: `directory` / `dir symlink`.
- **whatis lookup:** if the typed basename is ≥2 chars, has no wildcard, and at least one candidate does not end in `/`, fish runs `__fish_describe_command -- <cmd>` once. That calls `apropos "^<cmd>"` and keeps section 1/8 entries as `name\tdesc`. Matching entries replace the description, with the description's first character uppercased. On macOS, `apropos` uses a private whatis database in `~/.cache/fish/apropos/whatis` (via `__fish_make_cache_dir`), which is (re)built **in the background** when missing or older than 600000 s. Descriptions on a fresh HOME are therefore plain `command` until that build finishes, which makes test results time-dependent.
- **Functions:** the `--description` of a **loaded** function. An autoloadable function that has not been loaded yet shows no description; it gets one only after it has been loaded (run, `functions`, `type`, or its completions loaded).
- **Builtins:** fixed strings, e.g. `set` → `Handle environment variables`, `!` → `Negate exit status of job`.
- **Abbreviations:** `Abbreviation: <expansion>` or `Abbreviation: <expansion> # <abbr description>`.
**Source.** `src/wildcard.rs:30-37,289-314`, `src/complete.rs:1115-1230` (len≥2 at 1133, wildcard at 1137, keep_going at 1141-1147, uppercase at 1213-1218), `share/functions/__fish_describe_command.fish:13-30`, `share/functions/__fish_apropos.fish:8-43`, `src/complete.rs:2332-2338` + `src/function.rs:207-213` (no autoload), `src/builtins/shared/misc.rs:478-546`, `src/complete.rs:1311-1341,62-63`.
**Test.**
    setup: shared fixture
    check: `fish -c "complete -C myc"` → `mycmd` and `mycmd2` with no description; `fish -c "mycmd; complete -C myc"` → `mycmd<TAB>My test command`
    keys:  send-keys 'abbr -a gco git checkout' Enter; send-keys C-l 'gc'; send-keys Tab
    expect: pager contains `gco  (Abbreviation: git checkout)`; selecting it inserts `gco` with no trailing space
**Observed.** Yes (both `complete -C` variants; the pager showed `gcc (command)`, `gcloud (command link)`, `gco (Abbreviation: git checkout)`, `gcore (Get a core image of a running process)`, `gcov (command)`).

### TC-40 — Option completion (`-x`, `--long`) from completion scripts
**Behavior.**
- **Long options:** offered when the token starts with `-` and the option name (with its dashes) is at least as long as the token. Matching is fuzzy (prefix, substring and subsequence all allowed; e.g. `--lor` → `--color`). A samecase prefix appends the rest; otherwise the token is replaced.
- **Optional arguments:** a `--long` option that has arguments but does not require them (`-a` given without `-r/-x`) is offered twice: `--opt=` (no space) and `--opt` (space).
- **Short options:** listed only when the token is exactly `-`. In a group like `-a`, the other short options not already present are offered (`-ab`, `-av`), but not after an option that requires a parameter.
- **Option arguments:** after `--opt=`, or after a separate `--opt ` token when the option requires a parameter, the `-a` values with the option's `-d` description are offered (`--color=auto`…).
- **`--`:** an earlier `--` argument disables option completion.
- **Descriptions:** the `-d` text.
- **Pager joining:** when the pager prefix is exactly `-`, entries with identical non-empty descriptions are joined into one pager item (`-a  --all  (Show all)`); see 2b.
**Source.** `src/complete.rs:1591-1700` (short 1606-1640, long 1642-1699, fuzzy 1656-1657, `=` 1673-1689), `src/complete.rs:1472-1517` (`--opt=arg`), `src/complete.rs:1518-1580` (separate arg), `src/complete.rs:897-902,912` (`--`), `src/pager.rs:664-666,1228-1258`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'mycmd --col'; send-keys Tab
    expect: line `mycmd --color`, pager `--color  (Colorize)  --color=  (Colorize)`
    keys:  send-keys C-e C-u 'mycmd -'; send-keys Tab
    expect: line `mycmd -`, pager items in order: `-a --all (Show all)`, `-b --brief (Be brief)`, `-v (Verbose)`, `--color --color= (Colorize)`, `--format (Output format)`
    keys:  send-keys C-e C-u 'mycmd --color='; send-keys Tab
    expect: pager `--color=always  (Colorize)  --color=auto  (Colorize)  --color=never  (Colorize)`
**Observed.** Yes, all three; `complete -C 'mycmd -a'` → `-ab`, `-av`; `complete -C 'mycmd --lor'` → `--color`, `--color=`.

### TC-41 — Completion scripts are autoloaded on demand
**Behavior.** For an argument position, fish takes the basename of the resolved command. If it is a builtin, a function (loaded or autoloadable) or found in `$PATH`, it:
1. autoloads `functions/<cmd>.fish` (it may define `--wraps`);
2. autoloads `<cmd>.fish` from the first `$fish_complete_path` directory that has it, once per command;
3. gathers rules from every `complete` entry whose name wildcard-matches the command, evaluating `-n` conditions (results cached per Tab).

Commands that do not exist get no custom completions. `complete -e cmd` on a command with no completions leaves a tombstone that blocks autoloading. `--wraps` targets are walked up to a depth of 24. If any command in the chain uses `-f`/no-files, file completions are off, unless `-F` forces them.
**Source.** `src/complete.rs:1409-1462`, `src/complete.rs:2597-2637`, `src/complete.rs:2478-2489`, `src/complete.rs:2127-2208`, `src/complete.rs:983-1008`, `src/complete.rs:1703-1707`.
**Test.**
    setup: shared fixture (completions/mycmd.fish)
    keys:  send-keys 'mycmd --f'; send-keys Tab
    expect: `mycmd --format␠` (loaded from ~/.config/fish/completions/mycmd.fish on first use)
**Observed.** Yes (implicitly by TC-40).

### TC-42 — Long-option completions drop file fuzzing
**Behavior.** For a token starting with `-`, file-name matching is prefix-only (no substring or subsequence) (#568). Option matching (TC-40) stays fuzzy.
**Source.** `src/complete.rs:1774-1778`.
**Test.**
    setup: shared fixture + `touch $W/-xfoo`
    keys:  send-keys 'ls -- -foo'; send-keys Tab
    expect: no completion for `-xfoo` (substring only) → flash
**Observed.** No (source-only).

### TC-43 — How many candidates are kept
**Behavior.** Tab completion collects at most `EXPANSION_LIMIT_DEFAULT = 512*1024` candidates; once the limit is hit, further additions are refused. Wildcard-on-Tab expansion is capped separately at 256 (TC-30). There is no other cap; how much the pager shows is covered in 2b.
**Source.** `src/operation_context.rs:17`, `src/parser.rs:1244-1250`, `src/complete.rs:386-392,725-731`.
**Test.**
    setup: shared fixture + `for i in (seq 300); touch $W/many$i.txt; end`
    keys:  send-keys 'ls many*'; send-keys Tab
    expect: line unchanged, `many*` flashed (300 > 256)
**Observed.** No (source-only).

### TC-44 — `_` and `-` are interchangeable in case-insensitive substring matching
**Behavior.** Only in the case-insensitive substring step (step 8 of TC-09) are `_` and `-` treated as equal. Exact, prefix and same-case substring checks are literal.
**Source.** `crates/wcstringutil/src/lib.rs:126-139,286-292`; test `crates/wcstringutil/src/lib.rs:612-623`.
**Test.**
    setup: shared fixture + `touch $W/my-file.log`
    keys:  send-keys 'ls y_f'; send-keys Tab
    expect: `ls my-file.log␠` (replaced)
**Observed.** No (source-only).

### TC-45 — Duplicate arguments only affect autosuggestion order
**Behavior.** Candidates equal to an argument already on the line are marked `duplicates_argument`. Only autosuggestion ordering uses that mark (together with samecase-first and `~`-suffix-last). Tab ordering ignores it, so a file already named on the line is still offered at its normal sort position.
**Source.** `src/complete.rs:2269-2293`, `src/complete.rs:654-665`.
**Test.**
    setup: shared fixture
    keys:  send-keys 'ls data.txt d'; send-keys Tab
    expect: pager still lists `data.txt` first (same as TC-12)
**Observed.** No (source-only).

### TC-46 — `complete -C` output format (test helper)
**Behavior.** `complete -C STRING` (or `--do-complete=STRING`; without an argument it uses the current command line) computes completions for STRING, which is treated as a command line with the cursor at its end. It then applies only `sort_and_prioritize` (best rank, dedup, sort); the reader's replace filter (TC-06) is **not** applied. For each candidate it prints the **whole resulting token**: the completion is applied to the last token with `is_unique=false`, one trailing space is stripped, and the result is **unescaped** unless `--escape` is given. A tab and the description follow if there is one. Recursion through `complete -C` from within a completion is blocked.
**Source.** `src/builtins/complete.rs:474-563`.
**Test.**
    setup: shared fixture
    check: `fish -c "complete -C 'ls foo'"` → `foo bar.txt`; with `--escape` → `foo\ bar.txt`
    check: `fish -c "complete -C 'echo \$HOM'"` → `$HOME/<TAB>Variable: …`
**Observed.** Yes (unescaped form; `$HOME/`). `--escape` is source-only.

### TC-47 — Pager prefix shortening
**Behavior.** The prefix passed to the pager is the token plus the inserted common prefix (or only the common prefix when all candidates replace). If that is longer than 9 chars, it becomes `…` + the last 9 chars. If those 9 chars contain `/`, it becomes `…/` + the final path component instead.
**Source.** `src/reader/reader.rs:7176-7193`, `src/reader/reader.rs:1300`; CHANGELOG.rst:485-486.
**Test.**
    setup: shared fixture + `mkdir -p $W/Documents/sub; touch $W/Documents/sub/alpha1 $W/Documents/sub/alpha2`
    keys:  send-keys 'ls Documents/sub/al'; send-keys Tab
    expect: line `ls Documents/sub/alpha`, pager items drawn as `…/alpha1  …/alpha2` (prefix `…/alpha` in prefix style)
**Observed.** No (source-only). Short prefixes are observed unshortened: `~/w/docs/` (9 chars).

---

### Notes for zsh implementers

- **Ranking is a hard filter, not a sort key.** Port `try_create` and `rank` exactly (TC-09) and keep only `min(rank)`. Ranks: prefix samecase or smartcase = 4, prefix insensitive = 6, substring = 8/10, subsequence = 12, +16 for after-separator.
- **Pseudo-code of handle_completions** (`src/reader/reader.rs:7063-7216`):
  ```
  comps = [c for c in comps if c.rank == min_rank]          # already sorted+deduped
  will_replace = all(c.replaces for c in comps)
  comps = [c for c in comps if not c.replaces or can_replace(tok)]   # no $*?(){} in tok
  if not will_replace: for c in comps: if c.replaces: c.show_prefix = False
  if len(comps)==0: flash(tok or whole line); return
  if len(comps)==1: insert(comps[0], unique=True); return
  if all(c.type in {Exact,Prefix} for c in comps):
      cp = lcp([c.text for c in comps if c.show_prefix])   # case-sensitive chars
      if len(cp) > (len(tok) if will_replace else 0):
          insert(cp, no_suffix, unique=False)
          for c in comps if c.show_prefix: c.text = c.text[len(cp):]; c.replaces=False
  pager.open(prefix = shorten(cp if will_replace else tok+cp), comps)
  ```
- **The sort key is the completion string as stored**: the suffix for appenders and the full token for replacers. That is why `ls d<Tab>` lists `data.txt` before `Data.csv` but `docs/` last (TC-12). The comparison is `wcsfilecmp` (TC-11): uppercase-fold, numeric runs, `-`→`[`, `/`→`\0`, raw code-point tiebreak.
- **Quoting asymmetry**: unique + replaces-token (or empty token) + space suffix → `'…'` quoting. Everything else uses backslashes (TC-20/22/23).
- **Directories never get a space**, even when unique. Variables get `/` instead of a space when their value is a directory.
- **First Tab always opens the pager** when more than one candidate survives. The second Tab either discloses everything or starts selecting. A selection rewrites the line from a saved snapshot (`cycle_command_line`) on every move.
- Disabling autosuggestions (`fish_autosuggestion_enabled 0`) is needed for capture-pane tests. Otherwise the autosuggestion text (SGR 90) looks like inserted text in `capture-pane -p`.

---

## 2b. Completion pager UI

This section covers the completion pager: when it appears, where it is drawn, the layout algorithm in `src/pager.rs` (columns, widths, descriptions, prefix, truncation, disclosure, progress line, search field), navigation keys and what each one does to the selection and the commandline, cancel/accept semantics, pager search, resize, and colors. Which completions are generated, how they are ranked, and how they are inserted is covered in another section; this one assumes the completion list is already computed.
Each item says whether it was **Observed** in fish 4.9.3 under tmux 3.6a, or derived from source only. All SGR strings quoted below are what `tmux capture-pane -e` reports. tmux normalizes attributes, so its output is not fish's raw byte stream, which is exactly what a fish-vs-zsh comparison through tmux needs. Citations are relative to `/Users/darin/vendor/github.com/fish-shell/fish-4.9.3`.

### Section fixtures (shared by the tests below)

All tests use the brief's standard harness (`tmux -L <sock>`, 100x30, `TERM=xterm-256color`, clean `HOME`). With a clean HOME, fish prints a 2-line greeting and the prompt `user@host ~/w> ` lands on screen row 2. So **every test starts with `send-keys 'clear' Enter`**, which puts the prompt on row 0. Row numbers below count from 0 after that `clear`.

- **FX-200**: `cd $W; for i in $(seq -w 1 200); do touch file$i.txt; done` creates 200 entries, `file001.txt`..`file200.txt`, each 11 cells wide.
- **FX-AB**: `cd $W; for i in $(seq -w 1 88); do touch a$i; done; for i in $(seq -w 1 91); do touch b$i; done`.
- **FX-19**: `mkdir $W/n19; cd $W/n19; for i in $(seq -w 0 18); do touch file$i.txt; done` creates 19 entries, `file00.txt`..`file18.txt`, each 10 cells wide (the fixture from the unit test at `src/pager.rs:1323-1327`). In fish, `cd n19; clear` before testing.
- **FX-PGT**: write `$W/pgv.txt` with
  `printf '%s\t%s\n' e9340a "CI: rebase MSYS2 dll" bf5fa4 'feat: implement \`perror_nix\`' fcdcae "l10n: add spanish translation" c7aaf4 'wutil: use \`std::fs::rename\`' 11dda6 'wutil: use \`std::fs::read_link\`' 2ba031 "xtask: don't panic on failure" fa1a12 'nix: use \`getpgrp\` wrapper' 04b799 'nix: use \`access\`' e41f2f 'nix: use \`fchdir\`' 7992fd 'refactor: extract \`perror\`' 73e3b4 "tarball: capture Git version" > $W/pgv.txt`
  (backquotes are literal), and write `$W/pgt.fish` with:
  ```fish
  function fish_prompt; printf '> '; end
  function pgt; end
  complete -c pgt -f -k -a '(printf "%s\t%s\n" coverity_scan_master "Local Branch" curly-underlines "Local Branch" docker-builds "Local Branch" fish-reenable-cirrus "Local Branch" macos-apropos "Local Branch" master "Local Branch")'
  function pgu; end
  complete -c pgu -f -k -a '(printf "%s\t%s\n" ab 12345678 abcdefghi 1234 a 12 abcdefghijklmnopqrs 123456789 abcdefghijklmnopqrst 1)'
  function pgw; end
  complete -c pgw -f -k -a '(cat ~/w/pgv.txt)'
  ```
  In fish, run `source pgt.fish; clear`. The prompt becomes exactly `> ` (2 cells). `-k` keeps the given order, so no sorting happens.
- **FX-PFX**: `mkdir -p $W/pfx/verylongdirectoryname/sub; touch $W/pfx/verylongdirectoryname/sub/file1 $W/pfx/verylongdirectoryname/sub/file2 $W/pfx/abcdefghijklmnoX1 $W/pfx/abcdefghijklmnoX2 $W/pfx/abcdefghi1 $W/pfx/abcdefghi2 $W/pfx/abcdefgh1 $W/pfx/abcdefgh2 "$W/pfx/sp ace1" "$W/pfx/sp ace2"`. In fish, `cd pfx; clear`.

Escape-key tests: tmux `send-keys Escape` sends a lone ESC. fish treats it as `escape` after `fish_escape_delay_ms`, which defaults to 30 ms (`src/input/input.rs:294`). Sleep at least 100 ms after it. `extended-keys on` is needed so that `BTab` arrives as shift-tab.

---

### PG-01 — The pager opens only for 2 or more surviving completions
**Behavior.** Tab (`complete`) computes completions and drops every completion whose match rank is worse than the best one.
- 0 left: the token flashes (or the whole line flashes if the token is empty) and no pager opens.
- 1 left: it is inserted directly and no pager opens.
- 2 or more left: the longest common prefix is inserted (when it lengthens the token) and the pager opens below the commandline. Nothing is selected yet.
**Source.** `src/reader/reader.rs:7066-7073` (keep best rank only), `src/reader/reader.rs:7091-7105` (0: flash, 1: insert), `src/reader/reader.rs:7152-7163` (insert common prefix), `src/reader/reader.rs:7210-7214` (fill pager), `src/pager.rs:659` (selection reset to none).
**Test.**
    setup: FX-AB
    keys:  send-keys 'ls b' Tab
    expect: row 0 `> ls b` (with the default prompt: `user@host ~/w> ls b`), cursor right after `b`; pager rows start at row 1; no item in reverse video
**Observed.** Yes (FX-AB, FX-200).

### PG-02 — Where the pager is drawn
**Behavior.** The pager starts on the screen line right after the **last** line of prompt+commandline (+autosuggestion), at column 0, with no indent. From top to bottom:
1. The search field line, only if search is shown.
2. The completion rows.
3. At most one progress line.

Pager lines are not padded to terminal width. If there is not enough room below the prompt, the terminal scrolls: the prompt moves up and the greeting/scrollback scrolls off.
**Source.** `src/screen.rs:462-483` (lines consumed by prompt+commandline), `src/screen.rs:509-518` (size the pager to the remaining height and append its lines after the commandline), `src/pager.rs:320` (search field inserted at index 0), `src/pager.rs:294-305` (progress line added after the rows).
**Test.**
    setup: FX-200 (do NOT run `clear` here, so the 2 greeting lines are present)
    keys:  send-keys 'ls fi' Tab; send-keys Tab
    expect: after the 2nd Tab the screen has scrolled: prompt on row 0, 28 rows of completions on rows 1-28, `rows 1 to 28 of 34` on row 29
**Observed.** Yes. After the first Tab the prompt stayed on row 2. After the second it was on row 0.

### PG-03 — Vertical budget and the half-screen first display
**Behavior.** Let `avail = terminal_rows - L`, where `L` is the number of screen lines used by prompt+commandline (minimum avail is 1).
- `usable = avail - 1` (one row is always reserved for the progress line), minus 1 more if the search field is shown.
- While not fully disclosed: `visible = min(usable, max(floor(usable/2), 4))`.
- When fully disclosed: `visible = usable`.

On 100x30 with a 1-line prompt: avail=29, usable=28, first display is 14 rows. With the search field: usable=27, first display is 13 rows.
**Source.** `src/screen.rs:483` (avail), `src/pager.rs:182-196` (usable, half rule), `src/pager.rs:67` (`PAGER_UNDISCLOSED_MAX_ROWS = 4`).
**Test.**
    setup: FX-200
    keys:  send-keys 'clear' Enter; send-keys 'ls ' Tab
    expect: rows 1-14 show completions, row 15 = `…and 20 more rows`
**Observed.** Yes (14 rows + `…and 20 more rows`; with shift-tab on FX-AB `ls b`: 13 rows + `…and 3 more rows`).

### PG-04 — Too-small terminal: pager is not drawn but stays active
**Behavior.** If the terminal is narrower than 16 columns, or `avail` (PG-03) is below 4, nothing is drawn: no rows, no progress line, no search field. The pager is still logically open, so navigation keys still change the selection and the commandline. If the search field is focused but `avail < 4`, the cursor stays on the commandline.
**Source.** `src/pager.rs:69-73` (`PAGER_MIN_WIDTH = 16`, `PAGER_MIN_HEIGHT = 4`), `src/pager.rs:174-179` (early return with no lines), `src/screen.rs:487-495` (search cursor only when height ≥ 4).
**Test.**
    setup: FX-200, pager open with an item selected
    keys:  tmux resize-window -x 15; capture; tmux resize-window -x 100
    expect: at width 15 only prompt/commandline are visible; at width 100 the pager reappears with the same selection
**Observed.** Yes.

### PG-05 — Column count selection
**Behavior.** fish tries `cols = 6, 5, …, 1`, with `rows = ceil(n/cols)`:
- Skip `cols` (when cols > 1) if `ceil(n/rows) < cols`, because fewer columns give the same number of rows.
- Otherwise accept the first `cols` whose total width fits: `Σ column widths + 2*(cols-1) <= term_width`.
- One column always succeeds; its width is clamped to term_width.

Items fill **column-major**: item `i` is in column `i / rows`, row `i % rows`. The last column may be short.

Examples:
- 19 items of width 10 give 5 columns × 4 rows (6 columns is skipped because 4 rows only needs 5 columns).
- 200 items of width 11 at 100 cols give 6 × 34.
- 91 items give 6 × 16, with the last column holding 11 items.
**Source.** `src/pager.rs:76` (`PAGER_MAX_COLS = 6`), `src/pager.rs:945-978` (loop and skip rule), `src/pager.rs:237-243` (fit test), `src/pager.rs:429-436` (index = col*rows+row), `src/pager.rs:1122-1129` (ceil; 0/0 = 0).
**Test.**
    setup: FX-19
    keys:  send-keys 'ls ' Tab
    expect: 4 rows: `file00.txt  file04.txt  file08.txt  file12.txt  file16.txt` / `file01.txt  file05.txt …  file17.txt` / `file02.txt … file18.txt` / `file03.txt  file07.txt  file11.txt  file15.txt`
**Observed.** Yes, exactly.

### PG-06 — Per-column width; columns joined by exactly two spaces
**Behavior.** Each column has its own width: `min(max_comp_width + max_punct_desc_width, term_width)`.
- `comp_width` = display width of the prefix (if shown) + the completion string. Joined entries add +2 per extra string, plus the prefix again for each string.
- `punct_desc_width` = `desc_width + 4` if there is a description (2 spaces + 2 parentheses), else 0.

Columns are separated by a two-space spacer drawn in normal colors. The spacer is appended after every column except the last column index, including after the last item of a short final row.
**Source.** `src/pager.rs:215-234`, `src/pager.rs:347-369` (measuring), `src/pager.rs:1098-1106`, `src/pager.rs:64` (spacer `"  "`), `src/pager.rs:450-453`.
**Test.**
    setup: none
    keys:  send-keys 'string ' Tab
    expect: `collect  join0   match   replace  split0  unescape` / `escape   length  pad     shorten  sub     upper` / `join     lower   repeat  split    trim`
**Observed.** Yes, exactly.

### PG-07 — Entry layout with description: `comp  (desc)`, descriptions aligned per column
**Behavior.** When an entry fits its column, it is drawn as: completion, two spaces, alignment padding, `(`, description, `)`, then trailing padding to the column width.
- The alignment padding is `max(0, remaining − max(col_width − (max_comp+2), desc_width + 2))`. In a column whose natural width fits, this left-aligns all descriptions at offset `max_comp+2` within the column.
- In a force-fit column narrower than its natural width (single column clamped to term width), the description is pushed right so that `)` is at the column's right edge.
- No description: the completion is padded with spaces to the column width.
**Source.** `src/pager.rs:569-652`, `src/pager.rs:229-233` (`desc_align = max_comp + 2`).
**Test.**
    setup: FX-PGT
    keys:  send-keys 'pgu ' Tab        (prefix `a` is inserted: line becomes `> pgu a`)
    expect at 70 cols: `ab         (12345678)  abcdefghijklmnopqrs   (123456789)` / `abcdefghi  (1234)      abcdefghijklmnopqrst  (1)` / `a          (12)`
    expect at 50 cols (tmux resize-window -x 50): `ab                    (12345678)` … `abcdefghijklmnopqrst  (1)` (6 rows → here 5 rows, 1 column)
    expect at 20 cols: `ab        (12345678)` / `abcdefghi     (1234)` / `a               (12)` / `abcdefghi…  (12345…)` / `abcdefghijklmn…  (1)`
**Observed.** Yes, all three widths. Note: real completion deduplicates the two `a` entries from the unit test (`src/pager.rs:1597-1633`), so 5 rows instead of 6; the pager algorithm matches the unit test exactly.

### PG-08 — Truncation when an entry does not fit its column
**Behavior.** When `comp_width + punct_desc_width > col_width`:
1. `comp_budget = min(comp_width, floor((col_width−4)*2/3))`.
2. If `col_width > punct_desc_width`, then `comp_budget = max(comp_budget, col_width − punct_desc_width)`, so a short description cedes all remaining space to the completion.
3. The completion is printed into `comp_budget` with ellipsis (PG-09).
4. The description gets the rest: `col_width − comp_budget + unused_comp_budget`. Inside that, two spaces and then the parenthesized description, where the description text gets `remaining−1` cells (1 reserved for `)`) and is ellipsized.

If 4 or fewer cells remain for the description part, the description (and its parentheses) is omitted entirely and replaced by spaces.
**Source.** `src/pager.rs:477-497` (two-thirds rule), `src/pager.rs:569-641` (description), `src/pager.rs:570` (`desc_remaining > 4` gate), `src/pager.rs:642-652` (no-description path).
**Test.**
    setup: FX-PGT
    keys:  tmux resize-window -x 20; send-keys 'pgt ' Tab
    expect: `coverity_…  (Local…)` / `curly-und…  (Local…)` / `docker-bu…  (Local…)` / `fish-reen…  (Local…)` / `macos-apr…  (Local…)` / `master  (Local Bra…)`
    (at 80 cols: `coverity_scan_master  (Local Branch)  fish-reenable-cirrus  (Local Branch)` / `curly-underlines      (Local Branch)  macos-apropos         (Local Branch)` / `docker-builds         (Local Branch)  master                (Local Branch)`; at 40 cols: one column, `master                (Local Branch)` last)
**Observed.** Yes, at 80, 40 and 20. Also FX-PGT `pgw ` at 100/60/30 matched `src/pager.rs:1554-1593` exactly. For example, at 30 cols: `bf5fa4  (feat: implement \`pe…)` and `04b799  (nix: use \`access\`)   `.

### PG-09 — Ellipsis rule (`print_max`)
**Behavior.** Text is printed character by character into a cell budget:
- A character with no printable width (wcwidth undefined) is skipped.
- A character wider than the remaining budget stops printing **without** an ellipsis. For example, a width-2 CJK char facing 1 remaining cell leaves that cell blank (padded).
- A character whose width exactly equals the remaining budget is replaced by `…` (U+2026, width 1) when anything follows it: either more characters, or `has_more` is set.
- `has_more` is set for the prefix when a completion follows, for all but the last string of a joined entry, for the separator between joined strings, and for the progress line. The progress line therefore never uses the last cell for text. For example, at width 17, `…and 20 more rows` renders as `…and 20 more row…`.
**Source.** `src/pager.rs:1139-1186`, `crates/widestring/src/lib.rs:34` (`ELLIPSIS_CHAR = '\u{2026}'`), `src/pager.rs:296-304` (progress uses has_more=true).
**Test.**
    setup: FX-PGT
    keys:  tmux resize-window -x 20; send-keys 'pgt ' Tab
    expect: truncated items end in `…` exactly at the budget edge (see PG-08)
**Observed.** Yes, for the ellipsis cases. The wide-char/no-ellipsis case and the width-17 progress case are derived from source only.

### PG-10 — Description whitespace mangling
**Behavior.** Before display, each description has leading and trailing whitespace removed, and every internal run of whitespace (any Unicode whitespace, including tab and newline) collapsed to one space. Widths are measured after mangling.
**Source.** `src/pager.rs:1189-1226`, `src/pager.rs:1298-1300`.
**Test.**
    setup: in fish: `function pgx; end; complete -c pgx -f -a '(printf "%s\t%s\n" one "  a    b  " two "c")'`
    keys:  send-keys 'pgx ' Tab
    expect: `one  (a b)` / `two  (c)`
Derived from source; not observed.

### PG-11 — How completion strings are displayed (escaping)
**Behavior.** Each completion string in the pager goes through script-style escaping with flags `no_printables`, `no_quoted` and `symbolic`. The effect:
- Printable characters, including space, `$`, `*`, `'`, `"` and `\`, are shown **literally**, with no backslashes and no quotes.
- Control characters become Unicode control pictures: tab is `␉`, newline is `␤` (U+2424), backspace `␈`, CR `␍`, ESC `␛`, DEL `␡`, and other C0 controls `U+2400+c`.
- Bytes that are not valid in the locale encoding become `\XHH`.

The prefix (PG-12) is not escaped, but any C0 control in it is drawn as `U+2400+c` (a newline in the prefix shows as `␊`).

The commandline itself gets the properly escaped form. For example, the line shows `ls sp\ ace1` while the pager shows `sp ace1`.
**Source.** `src/pager.rs:1269-1277`, `crates/common/src/lib.rs:133-322` (tab 172, newline 181, backslash/quote 226-235, special printables 254, C0 276-297, no quoting when `no_quoted` 303), `src/screen.rs:2055-2061` and `src/screen.rs:79-90` (`Line::append` renders C0 as control pictures), unit test `src/pager.rs:1652-1655`.
**Test.**
    setup: FX-PFX
    keys:  send-keys 'ls sp' Tab
    expect: row 0 `> ls sp\ ace1` (`1` is an autosuggestion), row 1 `sp ace1  sp ace2`
**Observed.** Yes.

### PG-12 — The prefix shown in front of each item
**Behavior.** For normal (appending) completions:
- The pager prefix is the current token as typed **plus** the inserted common prefix: `tok + common_prefix`, taken from the raw commandline text.
- Each item shows `prefix` + the completion with the common prefix removed. So the pager displays full names, with the shared part drawn in the prefix color.
- If **all** best-rank completions replace the token (fuzzy, substring or case-correcting matches) and no common prefix lengthened the token, the prefix is empty and items show the full replacement strings.
- In a mixed set, completions that replace the token have their "show prefix" flag cleared and are drawn without the prefix.
**Source.** `src/reader/reader.rs:7077-7089` (mixed set: `show_pager_prefix: false`), `src/reader/reader.rs:7166-7195` (prefix string), `src/reader/reader.rs:7197-7208` (strip common prefix), `src/complete.rs:294-299` (`wants_pager_prefix`), `src/pager.rs:440-448`, `src/pager.rs:540-549`.
**Test.**
    setup: FX-19
    keys:  send-keys 'ls ' Tab
    expect: line `> ls file` + autosuggestion; every item is `file` (prefix color) + `NN.txt` (completion color): SGR `ESC[1;4mfile ESC[0m00.txt`
**Observed.** Yes.

### PG-13 — Prefix abbreviation with `…` (PREFIX_MAX_LEN = 9)
**Behavior.** If the prefix string is longer than 9 **characters** (code points, not cells), it is abbreviated:
1. Take the last 9 characters.
2. If they contain a `/`, display `…/` + the text after the last `/`.
3. Otherwise display `…` + the 9 characters.

Prefixes of 9 or fewer characters are shown in full.
**Source.** `src/reader/reader.rs:1300` (`PREFIX_MAX_LEN = 9`), `src/reader/reader.rs:7176-7193`.
**Test.**
    setup: FX-PFX
    keys:  send-keys 'ls verylongdirectoryname/sub/fi' Tab   → expect `…/file1  …/file2`
           C-c; 'ls abcdefghijklmno' Tab                → expect `…hijklmnoX1  …hijklmnoX2`
           C-c; 'ls abcdefgh' Tab                       → expect `abcdefgh1  abcdefgh2  abcdefghi1  abcdefghi2  abcdefghijklmnoX1  abcdefghijklmnoX2`
           C-c; 'ls abcdefghi' Tab                      → expect `abcdefghi1  abcdefghi2  abcdefghijklmnoX1  abcdefghijklmnoX2` (9-char prefix shown in full)
**Observed.** Yes, all four.

### PG-14 — Merging items with identical descriptions (only when the prefix is exactly `-`)
**Behavior.** Only when the pager prefix is exactly `-`, items with the same non-empty (mangled) description are merged into the first such item, in the first item's position.
- The merged item shows its strings separated by **two spaces**, each with its own prefix: `-a  --append     (Append value to a list)`.
- Items with empty descriptions are never merged.
- With prefix `--` or anything else, no merging happens.
**Source.** `src/pager.rs:663-666`, `src/pager.rs:1228-1258`, `src/pager.rs:528-539` (spacer between merged strings), `src/pager.rs:354-364` (+2 width per extra string).
**Test.**
    setup: none
    keys:  send-keys 'set -' Tab
    expect: rows `-a  --append     (Append value to a list)`, `-e  --erase      (Erase variable)`, … 14 rows then `…and 3 more rows`; SGR row 1: `ESC[1;4m-ESC[0ma  ESC[1;4m-ESC[0m-append     (ESC[3mESC[33mAppend value to a listESC[0m)`
**Observed.** Yes.

### PG-15 — Progress line: `…and N more rows` (never "1 more row")
**Behavior.** While not fully disclosed with `R` total rows and `V` visible rows (PG-03):
- `R − V ≥ 2`: show V rows and then the line `…and N more rows`, with N = R − V. The text starts with U+2026 and always says "rows".
- `R − V == 1`: the progress line is suppressed and that row is shown instead, so V+1 rows are visible.
**Source.** `src/pager.rs:200-213`, `src/pager.rs:275-276`.
**Test.**
    setup: FX-AB (100x30)
    keys:  send-keys 'ls a' Tab   → expect 15 rows (a01..a88, 6 columns), NO progress line
           C-c; 'clear' Enter; 'ls b' Tab → expect 14 rows then `…and 2 more rows`
**Observed.** Yes.

### PG-16 — Progress line: `rows X to Y of Z` when scrollable
**Behavior.** When there are no rows left to disclose but not all rows fit, the progress line is `rows X to Y of Z`. X is the first visible row (1-based), Y the last visible row (1-based, inclusive) and Z the total rows. It is shown even before anything is selected.
**Source.** `src/pager.rs:277-282`.
**Test.**
    setup: FX-200
    keys:  'clear' Enter; 'ls ' Tab; Tab
    expect: 28 rows, then `rows 1 to 28 of 34`
**Observed.** Yes.

### PG-17 — Progress line: `(no matches)` and history extra text
**Behavior.** If the search field is shown and the filter leaves zero items, the only pager content (below the search field) is the progress line `(no matches)`. If `extra_progress_text` is non-empty (history pager only: `Items A to B of C`), it is appended after `. ` when there is other progress text, or used alone otherwise.
**Source.** `src/pager.rs:283-292`, `src/reader/reader.rs:5990-6003`.
**Test.**
    setup: FX-AB
    keys:  'ls b' Tab; C-s; send-keys 'b9x'
    expect: row 1 `search: b9x` (underlined field), row 2 `(no matches)` in progress colors; commandline reverted to `ls b`
**Observed.** Yes.

### PG-18 — Progress line colors and extent
**Behavior.** The progress text uses `fish_pager_color_progress`. The default is `brwhite --background=cyan --bold`, which tmux reports as `ESC[1m ESC[97m ESC[46m` … `ESC[0m`. Only the text cells are colored; the background does not extend to the end of the line.
**Source.** `src/pager.rs:294-305`, `share/themes/default.theme:29`.
**Test.**
    setup: FX-200
    keys:  'clear' Enter; 'ls ' Tab; capture-pane -e
    expect: row 15 `ESC[1mESC[97mESC[46m…and 20 more rowsESC[0m`
**Observed.** Yes.

### PG-19 — Disclosure: the 2nd Tab expands the pager; the next Tab selects
**Behavior.** Pressing Tab again right after a Tab that opened the pager, or any Tab while navigating:
- If rows remain undisclosed, the pager becomes fully disclosed and **no selection is made**.
- Otherwise the selection moves Next. From "nothing selected", Next selects item 0.

So with a long list the sequence is: Tab = show half, Tab = show all (or scroll layout), Tab = select first. With a list that already fits, the 2nd Tab selects the first item.

This applies only when the previous command was `complete` (Tab) and that call showed the pager, or when an item is selected. Otherwise (for example Tab after Escape) completions are recomputed and the pager is shown fresh.
**Source.** `src/reader/reader.rs:3183-3213`, `src/reader/reader.rs:7022-7026` (ShownAmbiguous), `src/pager.rs:704-710`.
**Test.**
    setup: FX-200
    keys:  'clear' Enter; 'ls ' Tab   → 14 rows + `…and 20 more rows`, nothing selected
           Tab                        → 28 rows + `rows 1 to 28 of 34`, nothing selected
           Tab                        → `file001.txt` reverse-video; line `> ls file001.txt ` (trailing space, cursor after it)
    setup2: FX-19: 'ls ' Tab; Tab → `file00.txt` selected immediately
**Observed.** Yes.

### PG-20 — Moving south past the last visible row discloses instead of scrolling
**Behavior.** If a South (Down) or East (Right) move selects an item in a row below the visible area while the pager is not fully disclosed and rows remain, the pager becomes fully disclosed.

If any other motion leaves the visible area, the pager scrolls the minimum amount needed to show the selected row, and is also marked fully disclosed:
- North/West wrap-around to a hidden row.
- PageUp/PageDown.
- South when nothing remains to disclose.
**Source.** `src/pager.rs:849-883`.
**Test.**
    setup: FX-AB
    keys:  'ls b' Tab; Down ×14 → `b14` selected, still 14 rows + `…and 2 more rows`
           Down               → `b15` selected; all 16 rows shown, no progress line
**Observed.** Yes.

### PG-21 — Scrolling keeps the selection visible with minimal movement
**Behavior.** The pager keeps a suggested first row:
- If the selected row is above it, the first row becomes the selected row.
- If the selected row is at or past `first + visible`, the first row becomes `selected_row − visible + 1`.
- At render time it is clamped to `total_rows − visible`.
**Source.** `src/pager.rs:860-882`, `src/pager.rs:245-260`.
**Test.**
    setup: FX-200 in subdir or $W
    keys:  'ls ' Tab; Tab; Tab (file001 selected); Down ×28
    expect: `file029.txt` selected on the bottom visible row; row 1 starts `file002.txt`; progress `rows 2 to 29 of 34`
           NPage → `file034.txt`, `rows 7 to 34 of 34`; Right → `file068.txt`; PPage → `file040.txt`, `rows 6 to 33 of 34`
**Observed.** Yes.

### PG-22 — Tab / shift-tab cycle in column-major order with wrap-around
**Behavior.** While navigating:
- Tab (`complete`) selects index+1, wrapping from the last item to item 0. Because the layout is column-major, this goes down a column and then to the top of the next column.
- shift-tab (`complete-and-search`) selects index−1, wrapping from item 0 to the last item.
- Either key first discloses fully if rows remain (PG-19).
**Source.** `src/pager.rs:726-748`, `src/reader/reader.rs:3196-3203`, `share/functions/__fish_shared_key_bindings.fish:34-38`.
**Test.**
    setup: FX-19
    keys:  'ls ' Tab; Tab → file00; Tab → file01; BTab → file00; BTab → file18
**Observed.** Yes (Tab steps; BTab file00→file18 seen in the PG-23 run).

### PG-23 — shift-tab as the first key opens the pager with search and selects the first item
**Behavior.** shift-tab as the first key computes completions like Tab. If that produced a pager, it shows the search field and selects item 0.
- Unlike ctrl-s, it does **not** force full disclosure: the first display uses the search-adjusted half height.
- Further shift-tabs first disclose (if rows remain), then select Prev.
- If the completion was unique, it is inserted and no search field appears.
**Source.** `src/reader/reader.rs:7028-7032`, `src/reader/reader.rs:3187-3204`.
**Test.**
    setup: FX-19
    keys:  'ls ' BTab → row 1 `search:` + 12 underlined blanks, rows 2-5 the 5×4 grid, `file00.txt` selected, cursor at (8,1)
           BTab → `file18.txt`; Tab → `file00.txt`
    setup2: FX-AB: 'ls b' BTab → 13 rows + `…and 3 more rows`; BTab → all 16 rows, selection still `b01`
**Observed.** Yes.

### PG-24 — Down/Up (and ctrl-n/ctrl-p) inside the pager
**Behavior.** `down`/`up`/`ctrl-n`/`ctrl-p` are bound to `down-or-search`/`up-or-search`. While the pager is non-empty (`commandline --paging-mode`), these call `down-line`/`up-line`.
- **Down** with nothing selected selects item 0. Otherwise it moves to the next row in the same column. On the last row, or when the next cell is empty, it goes to row 0 of the next column, wrapping from the last column to column 0.
- **Up** with nothing selected selects the **last** item. Otherwise it moves to the previous row. On row 0 it goes to the last row of the previous column (wrapping to the last column), then applies column memory (PG-27).
- **Up on the top-left cell** (row 0, column 0) **deselects**: the commandline reverts to its pre-selection text and the pager stays open with nothing highlighted. The next Up selects the last item again.

History search is not involved while the pager is open, except when a history search is already active: `commandline --search-mode` is checked first.
**Source.** `share/functions/fish_default_key_bindings.fish:33-34`, `share/functions/__fish_shared_key_bindings.fish:41-42`, `share/functions/up-or-search.fish:4-14`, `share/functions/down-or-search.fish:3-13`, `src/builtins/commandline.rs:653-660`, `src/reader/reader.rs:3883-3909`, `src/reader/reader.rs:4623-4632` (top check), `src/pager.rs:704-722`, `src/pager.rs:768-806`.
**Test.**
    setup: FX-19
    keys:  'ls ' Tab; Up → file18; Up → file17; Up → file16; Down → file17; Down → file18; Down → file00; Down → file01
           (from file01) Up → file00; Up → deselected: line `> ls file` + autosuggestion `00.txt `, cursor after `file`, no reverse item; Up → file18
**Observed.** Yes, every step.

### PG-25 — Left/Right inside the pager (row-major wrap, no row memory)
**Behavior.** While navigating, `left`/`right` (and ctrl-b/ctrl-f) move the selection instead of the cursor.
- **Right (East):** go to the next column in the same row if that cell is filled. Otherwise go to column 0 of the next row, wrapping from the last row to row 0.
- **Left (West):** go to the previous column. From column 0, go to the last column of the previous row (from row 0, the last row), then apply column memory (PG-27).
- When the pager is visible but nothing is selected, Left/Right do **not** start navigation. They act normally: Left moves the cursor, Right accepts the autosuggestion or moves the cursor. The pager stays open, except that accepting an autosuggestion closes it.
**Source.** `src/reader/reader.rs:3577-3608`, `src/reader/reader.rs:5672-5673`, `src/pager.rs:807-832`, `src/pager.rs:714-720` (East/West from no selection do nothing), `src/reader/reader.rs:6238-6242` (these never end paging).
**Test.**
    setup: FX-19
    keys:  'ls ' Tab; then Tab Left Right Left Left Right Right Tab Tab Left Right Right Right Right Right Left Right Right Right Right Right
    expect selections: 00 15 00 15 11 15 00 01 02 17 02 06 10 14 18 14 18 03 07 11 15
**Observed.** Yes, exactly (matches unit test `src/pager.rs:1371-1396`). The no-selection Left/Right behavior is derived from source.

### PG-26 — PageUp/PageDown inside the pager
**Behavior.** `pageup`/`pagedown` (`beginning-of-history`/`end-of-history`) move the selection by `page = max(avail − 1, 1)` rows within the current column, where `avail` is from PG-03 (28 on 100x30). Note that `page` is not the visible row count.
- PageUp clamps at row 0.
- PageDown clamps at the last row. If that cell is empty, it goes to the row of the last item, `(n−1) % rows`.
- They act on the pager only while an item is selected. With the pager open and nothing selected, they do nothing to the pager (they only move within an already-active history search), and the pager stays open.
**Source.** `share/functions/__fish_shared_key_bindings.fish:25-26`, `src/reader/reader.rs:3863-3873`, `src/pager.rs:758-793`, `src/reader/reader.rs:3865` (navigating only), `src/reader/reader.rs:6247-6248` (never ends paging).
**Test.**
    setup: FX-19
    keys:  (selection at file15) PPage → file12; NPage → file15; PPage → file12; Right → file16; NPage → file18; Right → file03; Up → file02; PPage → file00; NPage → file03
**Observed.** Yes, exactly (matches `src/pager.rs:1397-1406`).

### PG-27 — Column memory when the target cell is empty
**Behavior.** The stored selection index can point past the end of the list, after a North/West wrap into an empty cell of the short last column or after filtering shrinks the list. The drawn and inserted item is then computed by:
1. While `idx >= n` and `idx >= rows`: `idx -= rows` (move left one column).
2. If still `idx >= n`: `idx = n−1`.

Index 0 is never adjusted. The raw (unclamped) index is kept for further motion. For example, in the 5×4 FX-19 grid, West from file00 targets raw 19 and displays file15.
**Source.** `src/pager.rs:132-159`.
**Test.** Same as PG-25: `Left` from file00 selects `file15.txt`.
**Observed.** Yes.

### PG-28 — The selection is inserted into the commandline live
**Behavior.** Each selection change does the following:
1. Undoes the previous pager edit, which is a transient edit.
2. Applies the selected completion to the saved pre-selection commandline (the "cycle" line, which is the line after the common prefix was inserted). This is the same insertion as accepting that completion, including the trailing space for non-directories.
3. Puts the cursor after it.

Deselecting restores the cycle line and its cursor. The pager stays open throughout.
**Source.** `src/reader/reader.rs:4681-4711`, `src/reader/reader.rs:7017-7019`, `src/reader/reader.rs:7161-7162` (cycle line after common-prefix insert), `src/reader/reader.rs:4714-4729`.
**Test.**
    setup: FX-200
    keys:  'ls ' Tab Tab Tab
    expect: line `> ls file001.txt ` with cursor after the trailing space (default prompt: cursor x = len(prompt)+15); Tab → `> ls file002.txt `
**Observed.** Yes.

### PG-29 — Escape / ctrl-g / ctrl-[ (cancel): close the pager and restore
**Behavior.** `cancel` while an item is selected:
1. Undoes the transient pager edit, restoring the commandline and cursor to the state before any selection. The common prefix that Tab inserted is **kept**.
2. Closes the pager, clearing the search field and filter.

`cancel` with the pager open but nothing selected only closes the pager. The common-prefix insertion stays.

Separately, `cancel` right after a Tab that inserted a **unique** completion undoes that insertion. That case has no pager.
**Source.** `share/functions/__fish_shared_key_bindings.fish:32-33`, `share/functions/fish_default_key_bindings.fish:38`, `src/reader/reader.rs:2837-2848`, `src/reader/reader.rs:2156-2163`, `src/reader/reader.rs:3132-3149`, `src/reader/reader.rs:4606-4611`, `src/reader/reader.rs:6230`.
**Test.**
    setup: FX-200
    keys:  'ls fi' Tab Tab Tab Tab (file002 selected); Escape; sleep 0.2
    expect: no pager; line `> ls file` + autosuggestion `001.txt `; cursor right after `file`
**Observed.** Yes (also FX-19: after Escape, `ls file` with cursor after `file`).

### PG-30 — ctrl-c closes the pager and clears the line
**Behavior.** `ctrl-c` (`clear-commandline`) always ends paging and then empties the commandline. The selection is not restored first. The general ctrl-c behavior is described in the editing section.
**Source.** `share/functions/__fish_shared_key_bindings.fish:72`, `src/reader/reader.rs:6229`, `src/reader/reader.rs:3120-3123`.
**Test.**
    setup: FX-19
    keys:  'ls ' Tab Tab; C-c
    expect: empty commandline, no pager
Derived from source (ctrl-c was used as a reset between observed tests and behaved this way).

### PG-31 — Enter while navigating accepts the selection without executing
**Behavior.** `execute` (Enter, ctrl-j, ctrl-m, ctrl-enter) while an item is selected closes the pager and leaves the selected completion, with its trailing space, on the commandline. Nothing is executed. The next Enter executes.

Enter with the pager open but nothing selected closes the pager **and** executes normally.
**Source.** `share/functions/__fish_shared_key_bindings.fish:124-128`, `src/reader/reader.rs:4486-4517`, `src/reader/reader.rs:6253-6258`.
**Test.**
    setup: none
    keys:  'set -' Tab Tab Tab (selects `-a  --append`); Enter
    expect: no pager; line `> set -a ` (cursor after the space); nothing executed
**Observed.** Yes. The no-selection execute case is derived from source.

### PG-32 — Enter in pager search with zero matches inserts the search text
**Behavior.** If the search field is focused and the filter matches nothing, Enter inserts the search-field text into the commandline at its cursor. The cursor is at the cycle position, typically the end of the token. The pager then closes and nothing executes.
**Source.** `src/reader/reader.rs:4503-4511`.
**Test.**
    setup: FX-AB
    keys:  'ls b' Tab; C-s; 'b9x'; Enter
    expect: line `> ls bb9x`, cursor at end, no pager
**Observed.** Yes.

### PG-33 — Typing a character while the pager is open (search not focused)
**Behavior.** A self-inserting key, including space, which is bound to `self-insert expand-abbr`, is inserted at the commandline cursor and closes the pager. The current selection stays on the line. For example, with `b28 ` selected, typing `z` gives `ls b28 z`.

With the pager open and nothing selected, the character is appended after the inserted common prefix and the pager closes.
**Source.** `src/reader/reader.rs:2750-2757`, `src/reader/reader.rs:2878-2887`, `src/input/binding.rs:788-829` (self-insert becomes a key event), `share/functions/__fish_shared_key_bindings.fish:106-110`.
**Test.**
    setup: FX-AB
    keys:  'ls b' Tab; C-s; '8'; Down (b18); C-s (hide search); Down (b28); 'z'
    expect: line `> ls b28 z`, no pager
**Observed.** Yes.

### PG-34 — Editing/motion commands while navigating close the pager first
**Behavior.** When the search field is **not** focused, the commands below first close the pager, without restoring, and then run on the commandline, which still contains the selected completion:
- backward-delete-char (backspace, ctrl-h), delete-char (delete)
- beginning/end-of-line (home, end, ctrl-a, ctrl-e)
- all word/token/bigword motions and kills
- kill-line, backward-kill-line, kill-whole-line, kill-token, backward-kill-path-component (ctrl-w)
- yank, yank-pop, transpose, up/down/capitalize-word
- beginning/end-of-buffer (alt-<, alt->)
- undo/redo

Examples:
- Backspace after selecting `file002.txt ` gives `ls file002.txt`.
- Undo (ctrl-z, ctrl-/) reverts the selection insertion, since that is the last undo entry, giving back the pre-selection line.

These commands also always close the pager: history search commands, accept-autosuggestion, delete-or-exit (ctrl-d), cancel-commandline, clear-commandline (ctrl-c) and cancel.

When the search field **is** focused, the first list acts on the search field instead, and the pager stays open.
**Source.** `src/reader/reader.rs:6214-6306` (`command_ends_paging`), `src/reader/reader.rs:2841-2848`, `src/reader/reader.rs:4343-4357` (undo closes the pager on the commandline), `src/reader/reader.rs:4606-4611` (clear_pager drops the transient marker without undo).
**Test.**
    setup: FX-19
    keys:  'ls ' Tab Tab (file00 selected); BSpace
    expect: line `> ls file00.txt` (space deleted), no pager
Derived from source; not observed.

### PG-35 — Commands that leave the pager open
**Behavior.** These never close the pager:
- complete, complete-and-search, history-pager
- backward-char, forward-char, forward-single-char, and the passive variants
- up-line, down-line, repaint, suppress-autosuggestion
- beginning-of-history, end-of-history (pageup, pagedown)
- every readline command not listed in PG-34, for example `pager-toggle-search` and `expand-abbr`

Running fish script from a binding does not close the pager unless the script changes the commandline text or cursor through `commandline`. Any such change closes it.

Note: while a history search (up-or-search) is active, no command closes the pager through this table.
**Source.** `src/reader/reader.rs:6235-6252`, `src/reader/reader.rs:6304`, `src/reader/reader.rs:2844-2846`, `src/reader/reader.rs:1557-1566`.
**Test.**
    setup: FX-19
    keys:  'ls ' Tab; Tab (file00); Right; Left
    expect: pager still open, selection file04 then file00
**Observed.** Yes, for arrows and page keys. The rest is derived from source.

### PG-36 — ctrl-s toggles the pager search field
**Behavior.** `ctrl-s` (`pager-toggle-search`) does nothing if no completion pager is open. In the history pager it advances the search forward instead.

Otherwise it toggles the search field:
- It always marks the pager fully disclosed.
- On showing, if nothing is selected, it selects item 0 (South).

The field line is `search: ` in normal colors, followed by the field text right-padded with spaces to at least 12 characters, drawn underlined. The whole line is limited to `term_width − 1` cells. The terminal cursor sits on this line at x = width(`search: ` + text), clamped to `term_width − 1`. The literal `search:` is a localizable string; this assumes `LANG=en_US.UTF-8`.
**Source.** `share/functions/__fish_shared_key_bindings.fish:36`, `src/reader/reader.rs:3214-3236`, `src/pager.rs:78-85`, `src/pager.rs:311-344`, `src/pager.rs:1062-1073`, `src/screen.rs:487-495`.
**Test.**
    setup: FX-AB
    keys:  'ls b' Tab; C-s
    expect: row 1 `search: ` + `ESC[4m` 12 spaces `ESC[0m`; rows 2-17 all 16 rows (disclosed); `b01` selected; commandline `> ls b01 `; cursor (8,1)
           type `7` → row 1 `search: ESC[4m7           ESC[0m`, cursor (9,1)
**Observed.** Yes.

### PG-37 — Pager search filter semantics
**Behavior.** With the search field shown and non-empty, an item is kept if the needle fuzzy-matches **either** its mangled description **or** `pager_prefix + completion_string`. Note that this uses the displayed prefix, which may be abbreviated (`…/…`), and the escaped display string.

The match is `string_fuzzy_match` with no start anchor. It accepts any of the following, else rejects:
1. exact
2. prefix
3. case-insensitive exact or prefix
4. case-sensitive substring
5. case-insensitive substring, where `_` and `-` are equivalent
6. case-sensitive subsequence

The needle cannot be longer than the haystack. Item order is unchanged, and the layout is recomputed for the filtered list. Refiltering happens on every search-field edit.
**Source.** `src/pager.rs:372-398`, `crates/wcstringutil/src/lib.rs:216-303`, `crates/wcstringutil/src/lib.rs:90-111` (subsequence), `crates/wcstringutil/src/lib.rs:118-142` (ifind, `_`→`-`), `src/reader/reader.rs:1507-1521`, `src/pager.rs:1030-1037`.
**Test.**
    setup: FX-AB
    keys:  'ls b' Tab; C-s; '7'  → `b07  b37  b67  b72  b75  b78` / `b17  b47  b70  b73  b76  b79` / `b27  b57  b71  b74  b77  b87`
           BSpace; 'b9'         → `b09  b29  b49  b69  b89  b91` / `b19  b39  b59  b79  b90` (b09 etc. by subsequence)
**Observed.** Yes.

### PG-38 — What has focus while the search field is shown
**Behavior.** The search field is the active edit line exactly when it is shown **and** the pager is navigating (an index is selected, even if the filter currently matches nothing).
- Typed characters and the editing commands from PG-34 edit the search field.
- Left/Right still move the pager selection, not the field cursor.
- Up/Down navigate.
- Tab and shift-tab cycle.
- Enter accepts (PG-31/PG-32).
- Escape cancels (PG-29).
**Source.** `src/reader/reader.rs:1458-1463`, `src/reader/reader.rs:3577-3608`, `src/reader/reader.rs:6300-6303`.
**Test.**
    setup: FX-AB
    keys:  'ls b' Tab; C-s; '8'; Down
    expect: row 1 `search: 8`; selection `b18` (Down moved within filtered grid b08,b18,b28 / …); commandline `> ls b18 `
**Observed.** Yes.

### PG-39 — The selected index survives refiltering
**Behavior.** When the filter changes, the stored selected index is kept as a number. The highlighted item, and therefore the commandline, becomes whatever item is at that index in the new list, after column-memory clamping (PG-27). If the list becomes empty, nothing is highlighted and the commandline reverts to the cycle line.
**Source.** `src/reader/reader.rs:1519-1520`, `src/pager.rs:132-159`, `src/reader/reader.rs:4693-4710`.
**Test.**
    setup: FX-AB
    keys:  'ls b' Tab; C-s (b01 selected, idx 0); '7'
    expect: `b07` highlighted, commandline `> ls b07 `; then 'b9x' → `(no matches)`, commandline `> ls b`
**Observed.** Yes.

### PG-40 — Hiding the search field keeps the filter and (bug) leaves the field drawn
**Behavior.** Pressing ctrl-s again hides the search field and returns focus to the commandline. The list is **not** refiltered, so it stays filtered by the old text. Because of a fish 4.9.3 render-cache quirk, the screen keeps showing the old `search: …` line, while the terminal cursor jumps back to the commandline. The line goes away at the next real re-render, for example a selection change, which then draws the filtered grid without the search line.

Cause: `PageRendering.search_field_shown` is never assigned in `render()`, so it is always false. Hiding the field therefore doesn't count as a change.
**Source.** `src/reader/reader.rs:3229-3231`, `src/pager.rs:983-1001` (line 997 compares an always-false field), `src/pager.rs:937-944` (render never sets it), `src/pager.rs:1040-1042`.
**Test.**
    setup: FX-AB
    keys:  'ls b' Tab; C-s; '8'; Down; C-s
    expect: rows unchanged (`search: 8` still on row 1); cursor back on the commandline after `ls b18 `
           Down → row 1 now `b08  b38  b68  b81  b84  b87` (search line gone; still filtered), `b28` selected
**Observed.** Yes.

### PG-41 — Terminal resize while the pager is open
**Behavior.** On resize, the pager is laid out again for the new width and height (column count recomputed, PG-05). The selected index and the scroll offset (first row) are kept, and the offset is clamped. The selected item is **not** scrolled into view, so after a reflow it can be off-screen until the next navigation, which then scrolls to it. The commandline is unchanged.
**Source.** `src/pager.rs:983-1001` (size change re-renders), `src/pager.rs:937-980`, `src/pager.rs:245-260`.
**Test.**
    setup: FX-200, 100x30
    keys:  'ls ' Tab Tab Tab; Down×28; NPage; Right; PPage (file040 selected, rows 6 to 33 of 34); tmux resize-window -x 50
    expect: 4 columns; progress `rows 6 to 33 of 50`; file040 (row 39) not visible; commandline still `ls file040.txt `
           Down → file041, `rows 14 to 41 of 50`
**Observed.** Yes.

### PG-42 — Default colors of each pager element (default theme, observed SGR)
**Behavior.** With a clean HOME, `fish_config theme choose default --no-override` sets these variables, each with a `--theme=default` marker:
- `fish_pager_color_description` = `yellow --italics`
- `fish_pager_color_prefix` = `--bold --underline`
- `fish_pager_color_progress` = `brwhite --background=cyan --bold`
- `fish_pager_color_selected_background` = `-r`

`fish_pager_color_completion`, `_background`, all `_secondary_*`, and `_selected_prefix/_completion/_description` are **unset**, so they fall back (PG-43) to `fish_color_normal`, which is set to `--reset` (terminal default).

Rendered, as reported by tmux:
- Prefix: `ESC[1;4m`.
- Completion text: default colors (`ESC[0m`).
- `(` and `)`: default colors.
- Description: `ESC[3m ESC[33m` (italic yellow).
- Column spacer and padding: default colors.
- **Selected item:** reverse video is added to every part of the item and to its padding up to the column width. Prefix `ESC[1;4;7m`, text `ESC[0;7m`, description `ESC[3m ESC[33m` on top of reverse, then the padding spaces in reverse, then `ESC[0m`. The two-space spacer between columns is not reversed. Example: `ESC[1;4;7m-ESC[0;7ma  ESC[1;4m-ESC[0;7m-append     (ESC[3mESC[33mAppend value to a listESC[0;7m)` + 30 reversed spaces + `ESC[0m`.
- Search field text: `ESC[4m`.
**Source.** `share/config.fish:149-150`, `share/themes/default.theme:3,22,27-30`, `share/functions/fish_config.fish:365-371` (sets each var globally with a `--theme=default` marker), `src/pager.rs:499-524` (role selection), `src/pager.rs:569-641` (padding drawn with bg role), `src/pager.rs:452` (spacer uses default spec), `src/pager.rs:322-324` (search field underline).
**Test.**
    setup: none
    keys:  'set -' Tab Tab Tab; capture-pane -e
    expect: row 1 as quoted above; row 2 `ESC[1;4m-ESC[0me  ESC[1;4m-ESC[0m-erase      (ESC[3mESC[33mErase variableESC[0m)`
           FX-19 'ls ' Tab Tab → row 1 begins `ESC[1;4;7mfileESC[0;7m00.txtESC[0m  ESC[1;4mfileESC[0m04.txt`
**Observed.** Yes.

### PG-43 — Color resolution and fallback chain
**Behavior.** For each role, fish uses the first of `[role, fallback(role), normal]` whose variable is set and non-empty. A value is accepted only if it parses to a non-default face. Fallbacks:
- `secondary_background` → `background`
- `secondary_prefix` and `selected_prefix` → `prefix`
- `secondary_completion` and `selected_completion` → `completion`
- `secondary_description` and `selected_description` → `description`
- **`selected_background` → `fish_color_search_match`**, which defaults to `white --background=brblack --bold` and is used only if `fish_pager_color_selected_background` is empty or unset
- `progress`, `background`, `prefix`, `completion`, `description` → `fish_color_normal`
- If nothing matches, the terminal default is used.

Each cell's face is the foreground role's face, with the background color taken from the background role. Of the background role's styles, only **reverse** is inherited; its bold, italics and so on are ignored. Underline is forced on for the search field.
**Source.** `src/highlight/highlight.rs:154-210`, `src/highlight/highlight.rs:1204-1237` (variable names), `src/highlight/highlight.rs:1241-1277` (fallbacks), `src/highlight/highlight.rs:214-229`.
**Test.**
    setup: in fish: `set -g fish_pager_color_selected_background; set -g fish_pager_color_selected_background ''`
    keys:  'ls ' Tab Tab (FX-19)
    expect: selected item drawn with fish_color_search_match colors (bold, fg white = SGR 37, bg brblack = SGR 100) instead of reverse video
Derived from source; not observed.

### PG-44 — Alternating ("secondary") rows and the parenthesis-color quirk
**Behavior.** Rows with an odd **absolute** row index (1, 3, 5, … counted from the first row of the whole list, not the first visible row) use the `secondary_*` roles. The selected item uses `selected_*` instead. Under the default theme the secondary variables are unset and fall back, so all rows look identical.

Quirk: the `(` `)` around descriptions always use `fish_pager_color_completion`, or `selected_completion` for the selected item, **never** `secondary_completion`, together with the row's background role.
**Source.** `src/pager.rs:446` (`row % 2 != 0`), `src/pager.rs:499-509`, `src/pager.rs:600-607`.
**Test.**
    setup: in fish: `set -g fish_pager_color_secondary_background --background=blue; set -g fish_pager_color_secondary_completion red`
    keys:  'set -' Tab
    expect: rows 2,4,6… (pager rows 1,3,5 in 0-based) have blue background behind item cells (not the inter-column spacer), red completion text, but `(`/`)` in default fg on blue
Derived from source; not observed.

### PG-45 — Colors do not depend on TERM (except dumb/mono)
**Behavior.** Named colors map to fixed SGR codes:
- Foreground: 30–37 for `black`..`white`, 90–97 for `brblack`..`brwhite`.
- Background: 40–47 and 100–107.
- 256-color indices: `38;5;N` and `48;5;N`.

This is the same for any TERM, except:
- `TERM=dumb`: no SGR is written at all.
- `TERM=ansi-m`, `linux-m` or `xterm-mono`: only grayscale palette colors are emitted.
**Source.** `src/terminal.rs:729-745`, `src/terminal.rs:673-697`, `src/terminal.rs:781-784` (underline = `4`), `src/env_dispatch.rs:452-453`.
**Test.**
    setup: none (TERM=xterm-256color)
    keys:  FX-200 'ls ' Tab; capture -e
    expect: progress `ESC[1mESC[97mESC[46m`
**Observed.** Yes for xterm-256color. The dumb/mono behavior is derived from source.

### PG-46 — Mouse click on a pager item selects it
**Behavior.** A left click on a pager item (when the terminal reports mouse clicks) selects that item and inserts it live, the same as a keyboard selection. Clicking on the item that is already selected does nothing.
**Source.** `src/reader/reader.rs:1635-1652`, `src/pager.rs:441-443` (cells carry `CharOffset::Pager(idx)`).
**Test.**
    setup: FX-19
    keys:  'ls ' Tab; tmux send-keys -M (mouse) is not reliable; skip in automated tests
Derived from source; not observed. UNVERIFIED in tmux.

### PG-47 — `commandline --paging-mode` / `--paging-full-mode`
**Behavior.**
- `commandline --paging-mode` returns 0 when the completion or history pager is non-empty, whether or not anything is selected.
- `commandline --paging-full-mode` returns 0 when the pager is non-empty **and** the current rendering has 0 rows left to disclose.
**Source.** `src/builtins/commandline.rs:653-667`, `src/reader/reader.rs:1534-1535`.
**Test.**
    setup: in fish: `bind f5 'commandline --paging-full-mode; and commandline -i FULL; or commandline -i PART'`. Note that inserting closes the pager, so read the inserted text.
    keys:  FX-200 'ls ' Tab; F5 → `PART` inserted; (new) 'ls ' Tab Tab; F5 → `FULL`
Derived from source; not observed.

### PG-48 — History pager (ctrl-r): layout differences only
**Behavior.** The history pager reuses `pager.rs`. Its search semantics are covered in another section. Layout differences:
- The search field is always shown.
- Each item has the prefix `► `, drawn in the **completion** color, not the prefix color (`highlight_prefix=false`).
- Items are syntax-highlighted per character, because they replace the whole line, **except** the selected item, which uses plain selected-completion colors.
- No `-` merging.
- The pager's own fuzzy filter is not used; the search field re-runs the history search.
- The progress line can carry `Items A to B of C`, joined after `. ` when other progress text exists.
- Multi-line commands show newlines as `␤` (PG-11).
**Source.** `src/reader/reader.rs:3510-3513`, `src/pager.rs:513-520`, `src/pager.rs:550-566`, `src/pager.rs:1287-1296`, `src/reader/reader.rs:1508-1514`, `src/reader/reader.rs:5990-6004`.
**Test.**
    setup: seed history with 3 entries
    keys:  C-r
    expect: row 1 `search: ` field, items `► echo hello` with `echo` in command color and `► ` in default color
Derived from source; not observed.

### PG-49 — alt-p is not the pager
**Behavior.** `alt-p` runs `__fish_paginate`, which appends ` &| <pager>` to the commandline (the pager comes from `__fish_anypager`). It has nothing to do with the completion pager and is out of scope here.
**Source.** `share/functions/__fish_shared_key_bindings.fish:88-91`, `share/functions/__fish_paginate.fish:2-10`.
**Test.** n/a.

---

### Notes for zsh implementers

- **Layout algorithm (port verbatim).** Citations: `src/pager.rs:937-980`, `src/pager.rs:164-345`, `src/pager.rs:465-655`, `src/pager.rs:1139-1175`.
  ```
  n = len(items)                         # after -merge (only if prefix == "-") and after search filter
  avail = term_rows - commandline_screen_lines          (>= 1)
  if term_cols < 16 or avail < 4: draw nothing (pager still logically open)
  for cols in 6..1:
      rows = ceil(n/cols)                # 0 if n == 0
      if cols > 1 and ceil(n/rows) < cols: continue
      usable = avail - 1 - (search_shown ? 1 : 0)
      if not fully_disclosed: usable = min(usable, max(usable // 2, 4))
      remaining = (not fully_disclosed and rows > usable) ? rows - usable : 0
      if remaining == 1: usable += 1; remaining = 0          # never "...and 1 more row"
      for c in 0..5:                     # all 6 slots; empty slots have width 0
          items_c = items[c*rows : (c+1)*rows]
          max_comp = max(comp_width), max_desc = max(desc_width ? desc_width+4 : 0)
          width[c] = min(max_comp + max_desc, term_cols); desc_align[c] = max_comp + 2
      if sum(width) + 2*(cols-1) > term_cols: continue        # cols==1 always fits
      start = rows <= usable ? 0 : min(suggested_start, rows - usable)
      stop  = rows <= usable ? rows : start + usable
      for row in start..stop: line = join(item(c*rows+row) [+ "  " if c < cols-1]) for each existing item
      progress = remaining > 1 ? "…and %d more rows"
               : (start > 0 or stop < rows) ? "rows %d to %d of %d" % (start+1, stop, rows)
               : (search_shown and n == 0) ? "(no matches)" : ""
      break
  ```
  Here `comp_width` = Σ over merged strings of (`width(prefix)` if shown + `width(str)`), plus 2 per extra string. Widths use wcwidth after mapping C0 controls to U+2400+c.
- **Item drawing.** Citation: `src/pager.rs:477-652`.
  ```
  if comp_width + punct(desc) <= W: cb = comp_width
  else: cb = min(comp_width, floor((W-4)*2/3)); if W > punct: cb = max(cb, W - punct)
  print strings with prefix into cb cells (print_max; "  " between merged strings)
  r = W - cb + unused_cb
  if desc and r > 4:
      "  "; spaces(r_after - max(W - desc_align, desc_w + 2)); "("; print_max(desc, r-1); ")"; pad to W
  else: pad to W with spaces
  ```
  `print_max(text, n, has_more)` works as follows. Skip zero-width-undefined characters. Stop, without an ellipsis, at a character wider than what remains. If a character exactly fills the remainder and anything follows it (or `has_more`), print `…` in its place and stop.
- The **prefix string** is `tok + common_prefix` (raw text), abbreviated with `…` when longer than 9 code points (PG-13). Completion strings are displayed with printables unescaped (PG-11). Do not reuse the commandline's escaped text for the pager.
- **Navigation** is a 2-D grid over column-major indices. The stored index may exceed `n` ("column memory"); clamp only for display (PG-27). Up on (0,0) deselects. Up with no selection selects the **last** item. Tab steps through the linear index (down columns).
- The **commandline while navigating** is always "pre-selection line + this completion applied". Implement it as a single replaceable edit so that Escape restores exactly, and Enter/typing keeps it.
- **Scroll/disclose rule**: South or East off the bottom of a partially disclosed pager means "disclose fully". Every other off-screen move scrolls minimally (PG-20/21). PageUp/PageDown step `avail-1` rows, not the visible count (PG-26).
- The PG-40 stale search-line quirk and the PG-41 off-screen selection after resize are genuine fish 4.9.3 behaviors. Decide explicitly whether to replicate them; side-by-side tests will detect the difference.

---

## 3. History

This section covers the up/down (and ctrl-p/ctrl-n) line search, the alt-up/alt-down token search, and the ctrl-r history pager. It also covers what gets written to the history file, deduplication, leading-space (ephemeral) commands, and how concurrent sessions do and do not merge. It uses the same harness and markings as Section 1.

### HS-01 — Bindings
**Behavior.** All of the following are bindings:
- `up` and `ctrl-p` → `up-or-search` (a fish function)
- `down` and `ctrl-n` → `down-or-search` (a fish function)
- `alt-up` and `alt-.` → `history-token-search-backward`
- `alt-down` → `history-token-search-forward`
- `pageup` → `beginning-of-history`
- `pagedown` → `end-of-history`
- `ctrl-r` → `history-pager`
- `ctrl-s` → `pager-toggle-search`
- `shift-delete` → `history-delete or backward-delete-char`

The iTerm2 sequences `\e[1;9A` and `\e[1;9B` are also bound to the token searches. `history-prefix-search-*` and `history-last-token-search-*` exist but are unbound.
**Source.** `share/functions/__fish_shared_key_bindings.fish:25-26,36,39,41-42,57-64`, `share/functions/fish_default_key_bindings.fish:33-34,58`, `src/input/binding.rs:241-252`.
**Test.** `bind up` should print `bind --preset up up-or-search` (and likewise for each key above).
**Source only.**

### HS-02 — `up-or-search` / `down-or-search` decide between moving the cursor and searching
**Behavior.** For `up-or-search`, in order:
1. If a history search is already active, run `history-search-backward`.
2. Else if the pager is showing (`commandline --paging-mode`, meaning the pager is non-empty), run `up-line`, which navigates the pager.
3. Else if the cursor is on line 1 of the buffer, start `history-search-backward`.
4. Otherwise run `up-line`, moving the cursor up one line and keeping the visual column with indentation adjusted.

`down-or-search` mirrors this. It searches forward only when the cursor is on the LAST line (line number == `count (commandline)`), and otherwise runs `down-line`.
**Source.** `share/functions/up-or-search.fish:3-28`, `share/functions/down-or-search.fish:2-28`, `src/builtins/commandline.rs:645-660`, `src/reader/reader.rs:1534`, `:1552`, `:3883-3945` (up-line/down-line).
**Test.**
    setup: HIST 'echo old'
    keys:  send-keys -l 'a'; M-Enter; send-keys -l 'b'; Up
    expect: cursor moves to row1 after "a"; buffer unchanged
    keys:  Up      expect: buffer replaced by `echo old`
**Source only.**

### HS-03 — Line search: search string, match type, case
**Behavior.** The search string is the ENTIRE buffer at the moment the search starts, including newlines. History is matched by **substring** ("contains"), not prefix. Smartcase applies: if the search string equals its own lowercase, the match is case-insensitive; otherwise it is case-sensitive. An empty buffer matches every entry. History is walked newest to oldest.
**Source.** `src/reader/reader.rs:3426`, `:3443-3451`, `src/reader/history_search.rs:13-22` (smartcase), `:161-194` (`SearchType::Contains` unless Prefix mode), `src/history/history.rs:211-224`.
**Test.**
    setup: HIST 'echo one' 'ls -la' 'my echo thing' 'echo one' 'printf ECHO' 'echo two' 'pwd'
    keys:  Up ×7 on an empty line
    expect: in order `pwd`, `echo two`, `printf ECHO`, `echo one`, `my echo thing`, `ls -la`, `ls -la` (stuck at the oldest; the older duplicate "echo one" is skipped)
**Observed.** Exactly.

### HS-04 — Line search deduplication, and skipping the current text
**Behavior.** A result is shown only if its exact text has not been seen in this search. The "seen" set starts out holding the original search string, so an entry identical to the current buffer is skipped. Each new distinct match is appended to a match list. Moving back and forth walks that list.
**Source.** `src/reader/history_search.rs:173-174`, `:207-211`, `:227-229`, `:261-295`.
**Test.**
    setup: HIST 'echo x' 'echo x' 'true'
    keys:  send-keys -l 'echo x'; Up
    expect: flash (no other match); buffer stays `echo x`
**Source only** (the dedup part was observed in HS-03).

### HS-05 — Line search skips the visible autosuggestion
**Behavior.** When a line search starts, the current autosuggestion's full text is added to the skip set. This happens only for Line mode (not Prefix), only if the suggestion is non-empty, and only if it was NOT truncated on screen (AS-18). So the first Up never shows the entry that is already displayed as the suggestion.
**Source.** `src/reader/reader.rs:3452-3459`.
**Test.**
    setup: HIST as HS-03
    keys:  send-keys -l 'echo'; Up
    expect: `printf ECHO`, not `echo two`, because "echo two" was the suggestion
    keys:  Escape; C-u; send-keys -l 'echo t'; Up
    expect: `my echo thing` ("echo two" was the suggestion and is skipped)
**Observed.** Exactly.

### HS-06 — Line search cursor position
**Behavior.** In Line (contains) mode the whole buffer is replaced by the result, and the cursor goes to the END of the result. In Prefix mode (unbound by default) the cursor goes to `len(search string)`, when that is non-empty. Each step first undoes the previous step's replacement, then applies the new one. The search is a single "transient edit".
**Source.** `src/reader/reader.rs:2174-2200`, `src/editable_line.rs:338-342`.
**Test.**
    setup: HIST as HS-03
    keys:  send-keys -l 'echo'; Up
    expect: `printf ECHO`, cursor col 27 (16 + 11)
**Observed.** Yes.

### HS-07 — Highlighting the match
**Behavior.** While a search result is shown (not at the start position), the FIRST occurrence of the search string in the result is highlighted. For token search it is the occurrence within the replaced token. The search is case-insensitive when smartcase says so. Its length is the length of the search string. The background always becomes `fish_color_search_match`. The foreground becomes `fish_color_search_match` only if that variable sets a foreground color; otherwise the syntax foreground is kept, along with fish's rule that a different background role contributes only its reverse attribute. The default is `white --background=brblack --bold`, which renders as `ESC[1m ESC[37m ESC[100m`. With an empty search string nothing is highlighted.
**Source.** `src/reader/history_search.rs:125-139`, `:215-229`, `src/reader/reader.rs:1867-1889`, `src/highlight/highlight.rs:154-185`, `share/themes/default.theme:22`.
**Test.**
    setup: HIST as HS-03
    keys:  send-keys -l 'echo'; Up; Up; Up
    expect: `my echo thing`, with "echo" drawn as `␛[1m␛[37m␛[100mecho␛[0m`, "my" in fish_color_error (91), "thing" in param color (36)
**Observed.** Exactly. After Up on `printf ECHO`, the "ECHO" portion was highlighted too (case-insensitive).

### HS-08 — Reaching the oldest match
**Behavior.** When there is no older match, the line flashes for 100 ms in search_match foreground and background. For line search the flash covers the whole current result; for token search, the token's range. The search stays active at the oldest match. If the very first Up finds nothing at all, it flashes the whole buffer and the search is NOT left active. An empty buffer gives an empty flash range, so nothing visible happens. Flashes closer than 50 ms apart are dropped.
**Source.** `src/reader/reader.rs:3474-3490`, `:4637-4676`.
**Test.**
    setup: HIST 'echo one'
    keys:  Up; Up
    expect: buffer stays `echo one` (the flash is too brief to capture reliably)
**Observed.** The "stays at oldest" part (HS-03).

### HS-09 — Going back down
**Behavior.** Down (`history-search-forward`) walks toward newer matches. Stepping onto index 0 (the start position) undoes the transient edit. That restores the exact original buffer and its original cursor position, and the autosuggestion comes back. Pressing Down while already at the start position flashes, since there is nothing newer, and keeps the search active. Down on a fresh prompt (no search active) on the last line starts a search that immediately fails: the whole buffer flashes and the search is reset.
**Source.** `src/reader/history_search.rs:261-269`, `src/reader/reader.rs:2174-2181`, `src/editable_line.rs:200-227` (undo restores `cursor_position_before_edit`), `src/reader/reader.rs:3474-3490`.
**Test.**
    setup: HIST as HS-03
    keys:  send-keys -l 'echo'; Up; Up; Up; Down; Down; Down
    expect: buffer `echo` + suggestion ` two`, cursor col 20
**Observed.** Exactly.

### HS-10 — Escape (`cancel`) restores the original line; pagedown also does
**Behavior.** Escape or `ctrl-g` during a history search undoes the transient edit, restoring the original buffer and cursor, and ends the search. `pagedown` (`end-of-history`) jumps to the start position, which also restores the original, but the search stays active, so the next Up continues the same search. `pageup` (`beginning-of-history`) jumps to the oldest match found SO FAR. These two keys do nothing when no search is active and no pager is being navigated.
**Source.** `src/reader/reader.rs:2852-2861`, `:3863-3882`, `src/reader/history_search.rs:101-112`, `:6325-6326` (begin/end-of-history do not end the search), `doc_src/interactive.rst:680`.
**Test.**
    setup: HIST as HS-03
    keys:  send-keys -l 'echo'; Up; Up; Escape (then sleep 0.2)
    expect: `echo` + suggestion ` two`, cursor col 20
**Observed.** Exactly.

### HS-11 — ctrl-c during a search clears the line; it does not restore
**Behavior.** `ctrl-c` (`clear-commandline`) ends the search without undoing, and empties the buffer. No `^C` is printed and no new prompt is drawn.
**Source.** `src/reader/reader.rs:3081-3131`, `:2852-2861`.
**Test.**
    setup: HIST as HS-03
    keys:  Up; C-c
    expect: empty prompt on the same row (row 2)
**Observed.** Yes.

### HS-12 — Any other command ends the search and keeps the result
**Behavior.** Every input function other than these ends the search and keeps the displayed result as normal buffer text:
- the history-search functions;
- `history-delete` / `history-pager-delete`;
- `beginning-of-history` / `end-of-history`;
- `scrollback-push`, `clear-screen`, `repaint`, `force-repaint`.

`ctrl-l` does not end it. The function itself then acts on that text: Left moves the cursor, Enter executes. Typing a character also ends the search and inserts the character at the cursor, which is the end of the line in Line mode.
**Source.** `src/reader/reader.rs:6309-6332`, `:2852-2861`, `:2870-2886`, CHANGELOG.rst:217.
**Test.**
    setup: HIST 'echo one'
    keys:  Up; send-keys -l 'X'
    expect: `echo oneX`; then Up searches for "echo oneX" (a fresh search)
**Source only.**

### HS-13 — No autosuggestion while a result is shown
**Behavior.** Suggestions are computed only when the search is at its start position (AS-13).
**Source.** `src/reader/reader.rs:5540`.
**Test.** See HS-07: there is no grey text after `my echo thing`.
**Observed.** Yes.

### HS-14 — Token search (alt-up / alt-down / alt-.)
**Behavior.** The search string is the token under the cursor. `get_token_extent` searches within the cursor's command substitution: if the cursor is inside a string token or at its end, that token; if it is between tokens, the empty string at the cursor. Only that token's range is replaced.
- Matching is contains plus smartcase.
- For each history entry, newest first, the entry is tokenized and every string token containing the needle is collected.
- The tokens are offered last token first, so the rightmost token of the newest entry comes first. Each distinct token text is offered once; the "seen" set starts with the original token.
- After a replacement the cursor goes to the end of the inserted token.

An empty token matches every token. `history-last-token-search-*` offers only the last matching token of each entry.
**Source.** `src/reader/reader.rs:3434-3442`, `src/parse_util.rs:453-500`, `src/reader/history_search.rs:230-256`, `src/reader/reader.rs:2183-2184`, `:2165-2171`.
**Test.**
    setup: HIST as HS-03
    keys:  send-keys -l 'ls -la /tmp '; M-Up
    expect: `ls -la /tmp pwd`
    keys:  M-Up      expect: `ls -la /tmp two` (from "echo two", last token first)
**Observed.** Exactly.

### HS-15 — ctrl-r history pager: opening
**Behavior.** fish records the buffer and cursor as the "cycle" state that Escape will return to. It opens the pager with the search field shown and the item prefix `► `. The search field is pre-filled as follows:
- if a history search is active with a non-empty search string, that string is reused;
- otherwise, the text of the command substitution under the cursor, or just the cursor's line if that text contains a newline;
- either way, with `*`, `?` and `\` backslash-escaped.

The first item is selected and the buffer immediately shows it. Keyboard focus goes to the search field. Rendering:
- row `search: <text padded with spaces to 12 columns, underlined>`, placed above the item list;
- items shown multi-column, column-major, newest first, each with prefix `► `;
- the selected item is drawn in reverse video and the others are syntax-highlighted;
- newlines inside items appear as `␤` (U+2424) and tabs as `␉`;
- the cursor sits in the search field.
**Source.** `src/reader/reader.rs:3492-3533`, `src/parse_util.rs:624-640` (`escape_wildcards`), `src/pager.rs:79-85`, `:307-342`, `:1269-1295`, `crates/common/src/lib.rs:172-189`.
**Test.**
    setup: HIST 'echo one' 'ls -la' 'my echo thing' 'echo one' 'printf ECHO' 'echo two' 'pwd' plus entry $'begin\necho multi\nend' (newest)
    keys:  send-keys -l 'echo'; C-r
    expect: buffer rows `begin` / `    echo multi` / `end`;
            `search: echo        ` (underlined);
            `► begin␤echo multi␤end  ► echo two  ► printf ECHO  ► echo one  ► my echo thing` (first item ESC[7m); cursor (12, search row)
**Observed.** Exactly.

### HS-16 — History pager filter semantics
**Behavior.** The search field text is matched against history entries. Each change to the field re-runs the search from the newest entry.
1. Glob "contains" first: the text, wrapped in implicit `*…*`, is matched with wildcard rules. Smartcase applies. Results are deduplicated.
2. If nothing matches and the text has no wildcards, a subsequence match is used instead: the characters must appear in order, not necessarily adjacent.

The page size is `max(term_height/2 - 2, 12)` entries. If the window is past the newest/oldest boundary and empty, it re-searches from the oldest end, selecting the last item.
**Source.** `src/reader/reader.rs:5861-5933`, `:1507-1515`, `src/history/history.rs:230-239`, `:247`.
**Test.**
    setup: HIST as HS-15
    keys:  C-r; send-keys -l 'ehg'
    expect: one item `► my echo thing` (subsequence e…h…g), and the buffer shows it
**Observed.** Exactly.

### HS-17 — History pager navigation and paging
**Behavior.**
- Arrow keys move the selection: `up-or-search`/`down-or-search` fall through to `up-line`/`down-line` because the pager is showing. Each selection change replaces the cycle text's command substitution, or the cursor line if multi-line, with the item.
- `ctrl-r` again moves to the next older page. If the window already reaches past the oldest entry, it flashes.
- `ctrl-s` moves to the next newer page. On the first page, it flashes.
- The progress row reads `Items A to B of N`, where A..B are history indexes of the window and N is the history size. It is shown only when not all history fits.
**Source.** `src/reader/reader.rs:3493-3504`, `:3214-3226`, `:5936-5974`, `:5978-6014` (progress text :5990-6003), `:4681-4711`, `:6785-6794`.
**Test.**
    setup: HIST as HS-15
    keys:  send-keys -l 'echo'; C-r; Down
    expect: the selection moves to `echo two`; the buffer shows `echo two`
**Observed.** Yes (Down → `echo two`).

### HS-18 — History pager: Enter, Escape, ctrl-c
**Behavior.**
- **Enter** while the pager is open never executes.
  - If an item is selected, the pager closes and the buffer keeps the item, with the cursor at the end of the inserted text.
  - If nothing matched (no selection), the search field text replaces the cursor's line, and the pager closes.
- **Escape** (`cancel`) undoes the pager's transient edit, restoring the buffer that existed when the pager opened, and closes the pager.
- **ctrl-g** behaves like Escape.
- **ctrl-c** closes the pager without undoing, then clears the buffer.
**Source.** `src/reader/reader.rs:4490-4513`, `:2837-2848`, `:6227-6230`, `:3081-3131`.
**Test.**
    setup: HIST as HS-15
    keys:  send-keys -l 'echo'; C-r; Down; Enter     expect: buffer `echo two`, cursor col 24, nothing executed
    keys:  C-u; C-r; send-keys -l 'ehg'; Escape        expect: empty buffer
    keys:  C-r; send-keys -l 'zzzz'; Enter            expect: buffer `zzzz`
**Observed.** All three exactly.

### HS-19 — Delete an entry from the pager or from line search (shift-delete)
**Behavior.**
- In the ctrl-r pager: removes every entry with the selected text, saves (rewriting the file), and refreshes from the current window, keeping the selection index.
- During up-arrow search: removes every entry with the current result's text, saves, drops the result from the match list, and moves to the next older match (or flashes if none). The search stays active.
**Source.** `src/reader/reader.rs:3535-3576`, `src/reader/history_search.rs:152-158`, `src/history/history.rs:830-848`.
**Test.**
    setup: HIST 'echo a' 'echo b'
    keys:  Up; S-DC
    expect: buffer `echo a`; the history file no longer contains "echo b"
**Source only.**

### HS-20 — ctrl-r started from an active up-arrow search
**Behavior.** The pager reuses the up-search's string as its filter. The up-search ends without undo, so the cycle text, which Escape restores, is the result that was being shown, not the original line.
**Source.** `src/reader/reader.rs:3506-3531`, `:2852-2861`.
**Test.**
    setup: HIST as HS-03
    keys:  send-keys -l 'ech'; Up; C-r
    expect: search field `ech`; then Escape gives the buffer the up-search result (`echo two`)
**Source only.**

### HS-21 — Which commands are saved: leading space gives an ephemeral entry
**Behavior.** If no function `fish_should_add_to_history` exists, a command whose first character is a space is added as *ephemeral*. It is kept in memory only, never written to disk, and is recallable with Up until the next execution. Every execution, including an empty or all-spaces line, first removes trailing ephemeral entries. If `fish_should_add_to_history` exists, it is called with the escaped text (non-interactively), and a non-zero status makes the entry ephemeral.
**Source.** `src/reader/reader.rs:6489-6501`, `:6520-6533`, `src/history/history.rs:507-520`, `:84-85`, `doc_src/interactive.rst:682`.
**Test.**
    setup: START (empty history)
    keys:  send-keys -l ' echo secret'; Enter; Up
    expect: buffer ` echo secret`; the history file does NOT contain "secret"
    keys:  C-c; Enter; Up
    expect: no entry (flash); the ephemeral entry is gone
**Source only.**

### HS-22 — Text normalization before saving
**Behavior.** Trailing spaces and newlines are stripped one at a time, as long as the character is not backslash-escaped (an even count of preceding backslashes). An empty result is not saved. Private mode (`fish_private_mode` non-empty) gives an in-memory entry. Entries are stored with `\` → `\\` and newline → `\n`, plus `when:` (epoch seconds), and `paths:` when applicable.
**Source.** `src/reader/reader.rs:6509-6524`, `:6526-6535`, `src/history/yaml_backend.rs:11-20`, `:37-40`.
**Test.**
    setup: START
    keys:  send-keys -l 'echo hi   '; Enter
    expect: the history file has `- cmd: echo hi`
**Source only.** (The multi-line storage `begin\necho hi\nend` was observed in AS-03.)

### HS-23 — Deduplication rules (memory and file)
**Behavior.**
- (a) Adding a command identical, and with the same persistence, to the previous new entry of this session merges into it: there is one entry and its timestamp is updated.
- (b) Before every save, older duplicates among this session's new entries are dropped, keeping the latest.
- (c) A normal save APPENDS, so the file can contain duplicates across sessions.
- (d) About every 25 saves (the countdown starts at a random 0-24), and whenever deletions are pending, the file is rewritten. Duplicates are collapsed through an LRU keyed on the exact text (the newest timestamp wins), the file is capped at 262144 entries, and entries are sorted by last-used timestamp.
- (e) Searches deduplicate at read time anyway (HS-04, HS-16; autosuggest's HistorySearch dedups).
**Source.** `src/history/history.rs:389-417`, `:280-292`, `:479-502`, `:633-693`, `:743-775`, `:523-589`, `:137-154`.
**Test.**
    setup: START
    keys:  send-keys -l 'echo a'; Enter; send-keys -l 'echo a'; Enter
    expect: the history file contains a single `- cmd: echo a`
**Source only.**

### HS-24 — Concurrent sessions do not share history automatically
**Behavior.** Each session sees file entries whose added time (`added_when`, otherwise `when`) is ≤ its start time (the "boundary"), plus its own new entries. Commands written by other sessions after this one started are invisible to Up, ctrl-r, autosuggestions and `$history` until `history merge` runs. `history merge` advances the boundary to now: it saves, then drops its in-memory new entries and rereads everything from the file, interleaved by file order. Private mode refuses `history merge`.
**Source.** `src/history/history.rs:339-343` (boundary semantics), `:462` (file decoded with the boundary cutoff), `src/history/yaml_backend.rs:283-308`, `src/history/history.rs:916-939`, `src/builtins/history.rs:330-341`.
**Test.**
    setup: two panes on the same $H: start fish in both; in pane 2 run `echo from2`
    keys (pane 1):  Up       expect: NOT `echo from2`
    keys (pane 1):  send-keys -l 'history merge'; Enter; Up; Up   expect: `echo from2` is reachable
**Source only.**

### HS-25 — When an entry becomes visible and when it is written
**Behavior.** An executed command is added as "pending": it is written to disk right away (or after background path detection), but hidden from history searches and `$history` until the command finishes. The entry is visible again at the next prompt. Path detection (AS-10) delays the save. Commands named `exit`, `reboot`, `restart` or `echo`, and `exec …`, are saved synchronously.
**Source.** `src/history/history.rs:1300-1341`, `:1015-1034`, `src/reader/reader.rs:888-889`.
**Test.**
    setup: START
    keys:  send-keys -l 'echo a'; Enter; Up
    expect: `echo a`
**Observed (implicitly)** in AS-10's run.

### HS-26 — History file location and session name
**Behavior.** The file is `$XDG_DATA_HOME/fish/<session>_history`, default `~/.local/share/fish/fish_history`. `<session>` is `$fish_history`, default `fish`. An empty `fish_history` means in-memory (private) history. An invalid variable name logs an error and falls back to `fish`.
**Source.** `src/history/history.rs:355-383`, `:1679-1707`, `doc_src/interactive.rst:684-687`.
**Test.** In the harness, the seeded file is `$H/.local/share/fish/fish_history`.
**Observed** (every run used it).

### Notes for zsh implementers (History)
- Up/Down is a **substring, smartcase** search over the whole buffer, with a per-search "seen" set that also contains the original text and the visible suggestion. It is not zsh's prefix `history-beginning-search-*`, and not plain `up-line-or-history`. Port the logic in `src/reader/history_search.rs:161-295`.
  ```
  start: needle = buffer; matches=[(buffer,0)]; seen={buffer} ∪ ({suggestion} if line-mode && suggestion && !truncated)
         icase = (needle == lower(needle)); idx = 0
  back:  if idx+1 < len(matches): idx++ ; else walk history older; first item containing needle
         (icase→lowercase compare) whose text ∉ seen → push, seen.add, idx++ ; none → flash
  fwd:   idx>0 ? idx-- : flash
  show:  idx==0 → restore original text+cursor; else buffer = matches[idx], cursor = end,
         highlight [first occurrence of needle, len(needle)) with fish_color_search_match
  ```
- Escape restores the original; ctrl-c clears; typing appends to the shown result and ends the search.
- The ctrl-r pager is a *selection list*, not an incremental search. Enter only inserts. Wildcards are active (glob contains), with a subsequence fallback.

---

## 4. Syntax highlighting & theme defaults

fish highlights the commandline by parsing it into an AST, assigning a *highlight role* to every character (`src/highlight/highlight.rs`), and resolving each role to a text face through `fish_color_*` / `fish_pager_color_*` variables with a fixed one-level fallback chain. Path checks (underlines, `cd` errors, redirection targets) are done with filesystem I/O on a background thread. Default colors come from `share/themes/default.theme`, which `share/config.fish` applies as **global** variables at interactive startup. That theme uses only the 16 named ANSI colors, so with defaults the emitted SGR codes do not depend on truecolor/256-color support. The terminal background query (OSC 11) only matters for themes that have `[light]`/`[dark]` sections, and the default theme does not.

Conventions: `\e` = ESC. Every "Observed" SGR string was captured with `tmux -L fishspec-hl capture-pane -p -e`, using the standard fixture (TERM=xterm-256color, clean HOME, tmux 3.6a, detached). The prompt prefix `\e[92mdarin\e[39m@echo \e[32m~/w\e[39m> ` is left out of the commandline expectations. **tmux re-encodes SGR**: capture-pane emits attribute codes before color codes (`\e[4m\e[36m`, never `\e[36;4m`), merges attributes (`\e[1;4m`), and clears attributes with `\e[0m`. fish's raw bytes differ (see HL-11). Tests should therefore compare per-cell attributes (fg, bg, bold, underline, reverse, italics, dim) taken from the captures of both shells, not raw byte strings. "Derived" means the behavior was read from source and not run.

Test helper used below (`hl`): `send-keys C-e C-u` (clears a one-line commandline: ctrl-u = backward-kill-line, `share/functions/__fish_shared_key_bindings.fish:73`), then `send-keys -l '<text>'`, sleep 0.8 s, then `capture-pane -p -e` of the last non-empty line. A clean HOME has no history, but **completion-based autosuggestions still appear** (gray `\e[90m` text after the cursor). Expectations below include them where they were observed.

---

### Part A: where colors come from

### HL-01 — Default color variables exist only in interactive shells
**Behavior.** `share/config.fish` runs `fish_config theme choose default --no-override` only `if status is-interactive || set -qgx __fish_force_load_default_theme`. In a non-interactive `fish -c '…'` with a clean HOME, no `fish_color_*` or `fish_pager_color_*` variable exists, so every role resolves to the terminal default (HL-05). For interactive fish, the theme is applied before conf.d files are sourced (config.fish:153-165), so conf.d snippets and config.fish can override it.
**Source.** `share/config.fish:146-151` (theme migration, then theme choose, only when interactive or forced). `share/config.fish:155-165` (conf.d sourced afterwards).
**Test.**
    setup: clean HOME
    keys:  (shell) env -i HOME=$H PATH=... fish -c 'set -n | string match "fish_*color*"'
    expect: only `fish_terminal_color_theme` is printed (an electric var, unset in this case; see HL-04). With `__fish_force_load_default_theme=1` in the env, the 26 variables of HL-02 appear (22 `fish_color_*` + 4 `fish_pager_color_*`).
**Observed.** Yes, both cases.

### HL-02 — Default theme values (4.9.3, `default.theme`)
**Behavior.** Interactive startup sets each of these variables in **global scope, unexported**. Each value list ends with an extra element `--theme=default`. For example, `fish_color_redirection` = `cyan` `--bold` `--theme=default` (3 elements).

| variable | value (before `--theme=default`) | effective face | SGR (tmux capture) |
|---|---|---|---|
| fish_color_normal | `--reset` | terminal default | none / `39` |
| fish_color_autosuggestion | `brblack` | fg idx 8 | `90` |
| fish_color_cancel | `-r` | reverse | `7` |
| fish_color_command | `--reset` | terminal default | none |
| fish_color_comment | `red` | fg 1 | `31` |
| fish_color_cwd | `green` | fg 2 | `32` |
| fish_color_cwd_root | `red` | fg 1 | `31` |
| fish_color_end | `green` | fg 2 | `32` |
| fish_color_error | `brred` | fg 9 | `91` |
| fish_color_escape | `brcyan` | fg 14 | `96` |
| fish_color_history_current | `--bold` | bold | `1` |
| fish_color_host | `--reset` | terminal default | none |
| fish_color_host_remote | `yellow` | fg 3 | `33` |
| fish_color_operator | `brcyan` | fg 14 | `96` |
| fish_color_param | `cyan` | fg 6 | `36` |
| fish_color_quote | `yellow` | fg 3 | `33` |
| fish_color_redirection | `cyan --bold` | fg 6 + bold | `1` + `36` |
| fish_color_search_match | `white --background=brblack --bold` | fg 7, bg 8, bold | `1` `37` `100` |
| fish_color_selection | `white --background=brblack --bold` | fg 7, bg 8, bold | `1` `37` `100` |
| fish_color_status | `red` | fg 1 | `31` |
| fish_color_user | `brgreen` | fg 10 | `92` |
| fish_color_valid_path | `--underline` | underline modifier | `4` |
| fish_pager_color_description | `yellow --italics` | fg 3 + italic | `33` `3` |
| fish_pager_color_prefix | `--bold --underline` | bold+underline | `1;4` |
| fish_pager_color_progress | `brwhite --background=cyan --bold` | fg 15, bg 6, bold | `97` `46` `1` |
| fish_pager_color_selected_background | `-r` | reverse | `7` |

These variables are **not set** by default and resolve through fallbacks (HL-05): `fish_color_builtin`, `fish_color_function`, `fish_color_keyword` (→ command), `fish_color_option` (→ param), `fish_pager_color_background`, `fish_pager_color_completion` (→ normal), and all `fish_pager_color_secondary_*` and `fish_pager_color_selected_{prefix,completion,description}` (→ their non-secondary/non-selected variable).
**Source.** `share/themes/default.theme:1-30` (the values; there are no `[light]`/`[dark]` sections). `share/functions/fish_config.fish:344-371` (each line is read with `read -lat`, so tokens are split fish-style; the variable is set to `$toks[2..]` plus `--theme=$theme_name` when scope ≠ -U). `share/functions/fish_config.fish:258` (scope `-g` for `choose`).
**Test.**
    setup: clean HOME, interactive fish in tmux
    keys:  send-keys 'set -S fish_color_redirection' Enter
    expect: `$fish_color_redirection: set in global scope, unexported, with 3 elements` / `[1]: |cyan|` / `[2]: |--bold|` / `[3]: |--theme=default|`
**Observed.** Yes. The full dump matched the table, and the SGR column matches the tmux captures in HL-13.

### HL-03 — `--no-override`: defaults never clobber user values
**Behavior.** At startup the theme sets a variable only if it is unset, **or** if its current value matches the regex `--theme=.*`, which marks a value that a theme set earlier. A user value without a `--theme=` element (set in any scope, e.g. a universal var or a global from a previous conf.d) is left alone. Run without `--no-override`, `fish_config theme choose X` overrides everything and also erases (sets to an empty list) any theme variable still marked with a *different* `--theme=` name.
**Source.** `share/functions/fish_config.fish:365-371` (override condition), `:373-382` (erase variables from other themes when overriding), `:384-392` (`__fish_override` is set only without `--no-override`).
**Test.**
    setup: before starting the tmux session, run `env -i HOME=$H PATH=... fish -c 'set -U fish_color_param magenta'` (a universal var with no --theme= marker; theme migration is a no-op because __fish_initialized is unset, config.fish:147 + __fish_theme_migrate.fish:8-10)
    keys:  start interactive fish; hl 'echo x'
    expect: `x` is magenta (`\e[35m`), not cyan
**Observed.** No (derived).

### HL-04 — Terminal background query → `$fish_terminal_color_theme`
**Behavior.** At the first interactive reader push, if querying is allowed (feature `query-term` is on, TERM≠dumb, `MC_SID` is unset, stdout is a tty), fish writes `\e[?u` (kitty keyboard query; skipped for TERM=st-256color), `\e[>0q` (XTVERSION), `\e]11;?\e\\` (OSC 11 background query), XTGETTCAP queries, and `\e[0c` (DA1). It then blocks until the DA1 reply arrives. After 10 s without one, it prints a warning and lowers later query timeouts to 30 ms (`src/input/decode.rs:24`, `src/reader/reader.rs:302-322`). The first OSC 11 reply is kept. The global read-only electric variable `fish_terminal_color_theme` is set to `dark` if the background's CIE L\* (perceived lightness / 100) < 0.5, `light` if ≥ 0.5, and `unknown` if no reply came. Lightness formula (xterm-color 1.0.2): channel c = v/65535; linearize with `c ≤ 0.04045 ? c/12.92 : ((c+0.055)/1.055)^2.4`; Y = 0.2126 R + 0.7152 G + 0.0722 B; L\* = `Y ≤ 216/24389 ? Y·24389/27 : 116·cbrt(Y) − 16`; compare L\*/100 with 0.5. fish re-queries OSC 11 (together with the cursor position) **at every new prompt**, and also when the terminal sends the DEC 2031 notification `CSI ? 997 ; n n`. fish enables that notification with `\e[?2031h` except under tmux < 3.7. The variable is set again (firing `--on-variable` handlers) only when the value changes. This affects colors **only** for themes with `[dark]`/`[light]`/`[unknown]` sections, which install an `--on-variable fish_terminal_color_theme` hook. The 4.9.3 `default` theme has no such sections, so it never changes with the background.
**Source.** `src/reader/reader.rs:236-247` (querying_allowed), `:272-281` (initial query bytes), `:296-299` (first BackgroundColor reply kept), `:404` (set_color_theme). `src/parser.rs:1268-1292` (threshold 0.5, dark/light/unknown, no-op if unchanged). `src/terminal.rs:325` (`\e]11;?\e\\`). `src/reader/reader.rs:2612-2617` (re-query on each prompt), `:2908-2913` (NewColorTheme → re-query), `:2974-2977` (apply result). `src/input/decode.rs:438-444` (`CSI ?997;…n`). `src/tty_handoff.rs:188-193` (2031 enabled unless tmux < 3.7). `src/env/impl/var.rs:125` (electric var). External: xterm-color-1.0.2 `src/lib.rs:184-217` (lightness, not in the checkout). `share/functions/fish_config.fish:293-303` (hook only for color-theme-aware themes), `share/themes/default.theme:1-30` (not aware).
**Test.**
    setup: standard fixture (detached tmux)
    keys:  send-keys 'set -S fish_terminal_color_theme' Enter
    expect: `$fish_terminal_color_theme: set in global scope, unexported, with 1 elements (read-only)` / `[1]: |unknown|`
**Observed.** Yes. A detached tmux 3.6a does not answer OSC 11, so the value is `unknown`. Observing `dark`/`light` needs an attached client whose terminal answers OSC 11. Not observed.

### HL-05 — Role → variable map and fallback chain
**Behavior.** Each character carries a `HighlightSpec {foreground role, background role, valid_path, force_underline}`. A role resolves by trying, in order, `[role, fallback(role), normal]` (adjacent duplicates removed). A variable is skipped if it is unset or **empty** (`get_unless_empty`), or if parsing it yields a completely unspecified face: no color, no style, no reset, e.g. a value that is only `--theme=default` or only unknown color names. The first variable that parses wins. If none parses, the result is the terminal default (fg/bg/underline-color "normal", all styles off). There is only one level of fallback before `normal`.

| role | variable | fallback |
|---|---|---|
| Normal | fish_color_normal | (terminal default) |
| Error | fish_color_error | normal |
| Command | fish_color_command | normal |
| Builtin | fish_color_builtin | **command** |
| Function | fish_color_function | **command** |
| Keyword | fish_color_keyword | **command** |
| StatementTerminator | fish_color_end | normal |
| Param | fish_color_param | normal |
| Option | fish_color_option | **param** |
| Comment | fish_color_comment | normal |
| SearchMatch | fish_color_search_match | normal |
| Operat | fish_color_operator | normal |
| Escape | fish_color_escape | normal |
| Quote | fish_color_quote | normal |
| Redirection | fish_color_redirection | normal |
| Autosuggestion | fish_color_autosuggestion | normal |
| Selection | fish_color_selection | normal |
| PagerProgress | fish_pager_color_progress | normal |
| PagerBackground | fish_pager_color_background | normal |
| PagerPrefix | fish_pager_color_prefix | normal |
| PagerCompletion | fish_pager_color_completion | normal |
| PagerDescription | fish_pager_color_description | normal |
| PagerSecondaryBackground | fish_pager_color_secondary_background | pager_color_background |
| PagerSecondaryPrefix | fish_pager_color_secondary_prefix | pager_color_prefix |
| PagerSecondaryCompletion | fish_pager_color_secondary_completion | pager_color_completion |
| PagerSecondaryDescription | fish_pager_color_secondary_description | pager_color_description |
| PagerSelectedBackground | fish_pager_color_selected_background | **fish_color_search_match** |
| PagerSelectedPrefix | fish_pager_color_selected_prefix | pager_color_prefix |
| PagerSelectedCompletion | fish_pager_color_selected_completion | pager_color_completion |
| PagerSelectedDescription | fish_pager_color_selected_description | pager_color_description |

Variables that are **not** highlight roles (`fish_color_cwd`, `cwd_root`, `user`, `host`, `host_remote`, `status`, `history_current`, `cancel`, `valid_path`) are read directly by fish script or by special code (HL-07, HL-45, HL-47, HL-48), with no fallback chain. The docs say valid_path and cancel are "roles", but the code treats them as special cases.
**Source.** `src/highlight/highlight.rs:1279-1318` (enum), `:1320-1327` (HighlightSpec), `:1204-1237` (variable names), `:1239-1277` (fallback table), `:154-173` (resolution loop with dedup and `get_unless_empty`), `:214-229` (an unspecified face returns None). Tests `:1909-1932` (a keyword var holding only `--theme=default` falls back to command). `doc_src/interactive.rst:158-166`, `:205` (docs agree).
**Test.**
    setup: interactive fish
    keys:  send-keys ' set -g fish_color_command --theme=default; set -g fish_color_keyword; set -g fish_color_param' Enter; then hl 'if ls x'
    expect: whole line default colors (`if ls x`, no SGR): keyword → command (only --theme → unspecified) → normal (`--reset`); param empty → normal
    keys:  send-keys ' set -g fish_color_normal magenta; set -e fish_color_command' Enter; then hl 'if ls x ; y'
    expect: `\e[35mif ls x \e[32m;\e[35m \e[91my` (spaces are magenta too, see HL-49)
**Observed.** Yes, both lines exactly (the second also had a gray autosuggestion `\e[90maa`).

### HL-06 — Combining foreground and background roles
**Behavior.** If a spec's background role equals its foreground role, the face is the resolved fg-role face as is. Otherwise the result is the fg-role face with **bg color** replaced by the bg-role face's bg, and **reverse** taken from the bg-role face unless the fg-role face already has reverse on. Every other style (bold, underline, italics…) of the bg role is ignored. Normal commandline text uses bg role = Normal.
**Source.** `src/highlight/highlight.rs:174-185`, `:39-58` (with_fg sets bg=Normal; with_both sets both).
**Test.**
    setup: interactive fish; `set -g fish_color_search_match --background=blue` (no fg); history entry `echo hello`
    keys:  hl 'hel'; send-keys Up
    expect: `hel` keeps its normal fg (cyan for a param) on blue bg, **not bold** (see HL-42)
**Observed.** No (derived).

### HL-07 — `fish_color_valid_path` is a modifier merged on top of the role face
**Behavior.** For characters marked valid_path, fish reads `fish_color_valid_path` with `vars.get` (unlike roles, an empty value is not skipped, it just changes nothing) and parses it. Each of fg, bg and underline-color is replaced **only if specified**. Styles are merged with union-prefer-right: bold/dim are OR-ed, and underline/italics/reverse/strikethrough take valid_path's value when it is set (on or off). Default `--underline` turns `cyan` params into cyan+underline. Error-colored characters inside a valid path token are underlined too.
**Source.** `src/highlight/highlight.rs:187-202`, `src/text_face.rs:96-107` (union_prefer_right).
**Test.**
    setup: `touch $W/foo`
    keys:  hl 'echo foo '
    expect: `echo \e[4m\e[36mfoo\e[0m`
**Observed.** Yes. Also observed: `ls "fo` (cursor at the end, file `foo` exists) → `ls \e[4m\e[91m"\e[33mfo\e[0m\e[90mo" ` (the error-colored quote is underlined too).

### HL-08 — `force_underline` (pager search field)
**Behavior.** A spec with `force_underline` gets single underline added regardless of the variables. The only use is the pager search field text (after the search prompt, padded with spaces to the field width), which uses roles Normal/Normal + force_underline.
**Source.** `src/highlight/highlight.rs:204-207`, `src/pager.rs:320-339`.
**Test.**
    setup: interactive fish
    keys:  send-keys -l 'ls '; send-keys Tab Tab; send-keys C-s; send-keys -l 'f'
    expect: the search field `f` + padding is underlined (`\e[4m`), default fg
**Observed.** No (derived).

### HL-09 — Parsing a color variable (`parse_text_face`)
**Behavior.** The value list is parsed like `set_color` arguments, but unknown color names are **silently dropped** instead of being errors. Options: `-f/--foreground=C`, `-b/--background=C`, `--underline-color=C`, `-o/--bold`, `-d/--dim`, `-i/--italics[=on|off]`, `-r/--reverse[=on|off]`, `-s/--strikethrough[=on|off]`, `-u/--underline[=single|double|curly|dotted|dashed|off]`, `--reset`, `--theme=X` (ignored). An unknown option, a bad `=value`, or mixing `-f` with positional colors makes the **whole variable** parse as unspecified, which triggers the fallback of HL-05. Color names (case-insensitive): black 0, red 1, green 2, yellow 3, blue 4, magenta 5, cyan 6, white 7, brblack 8, brred 9, brgreen 10, bryellow 11, brblue 12, brmagenta 13, brcyan 14, brwhite 15. Hidden aliases: purple=5, brown=3, grey=7, brgrey=8, brbrown=11, brpurple=13. `normal` = the special "default" color, and a positional `normal` also sets reset. RGB forms: `RGB`, `RRGGBB`, optionally with **one** leading `#`, hex case-insensitive (`F3A` = ff33aa). With several colors for one channel, fish picks one with `best_color`: the first RGB color if term256 support is on (or if there is no named color), else the first named color, else the first color.
**Source.** `src/text_face.rs:209-220`, `:259-431` (options, `--theme` at `:276`/`:317`, unknown color → `Ok(None)` at `:286-295`, best_color at `:384-388`/`:423`, `normal` → reset at `:416-418`). `crates/color/src/lib.rs:43-47`, `:137-198`, `:216-241` (name table). `src/terminal.rs:621-645` (best_color).
**Test.**
    setup: interactive fish
    keys:  send-keys ' set -g fish_color_command red ff0000' Enter; hl 'ls'
    expect: `\e[38;2;255;0;0mls` (truecolor detected; RGB preferred because term256 is on)
**Observed.** Yes (see HL-10).

### HL-10 — Color capability detection (`fish_term256`, `fish_term24bit`)
**Behavior.** fish recomputes this whenever TERM, COLORTERM, fish_term256 or fish_term24bit changes, then repaints.
- term256 = `fish_term256` parsed as a bool if that variable is set; otherwise true unless `TERM` is exactly `xterm-16color`.
- term24bit = `fish_term24bit` parsed as a bool if set. Otherwise false if `$STY` is set (GNU screen). Otherwise, if `COLORTERM` is set, true iff it is `truecolor` or `24bit`. Otherwise true unless TERM=`xterm-16color` or `TERM_PROGRAM=Apple_Terminal`.
So in the standard fixture (TERM=xterm-256color, no COLORTERM, no TERM_PROGRAM because of `env -i`), **truecolor is on**.
**Source.** `src/env_dispatch.rs:58-60` (dispatch on change), `:173-178`, `:360-439`, `:444-461` (init_terminal also sets IS_DUMB / ONLY_GRAYSCALE).
**Test.**
    setup: interactive fish
    keys:  ' set -g fish_color_command ff0000' Enter; hl 'ls' | ' set -g fish_term24bit 0' Enter; hl 'ls' | ' set -g fish_term256 0' Enter; hl 'ls' | ' set -g fish_term256 1; set -g fish_term24bit 1; set -g fish_color_command red ff0000' Enter; hl 'ls' | ' set -g fish_term256 0' Enter; hl 'ls'
    expect: `\e[38;2;255;0;0mls` | `\e[38;5;196mls` | `\e[91mls` | `\e[38;2;255;0;0mls` | `\e[31mls`
**Observed.** Yes, all five, in that order.

### HL-11 — How a face becomes SGR bytes
**Behavior.** fish keeps the last emitted face and writes only the differences, packing parameters into one `CSI … m` (at most 16 parameters, otherwise it splits). Order within a change: an optional full reset (`\e[m`, empty parameter) if bold or dim must turn off, since they have no individual off code; then fg; then bg; then underline color; then bold `1`; underline (`4` single, `4:2` double, `4:3` curly, `4:4` dotted, `4:5` dashed, off `24`); dim `2`; italics `3`/`23`; reverse `7`/`27`; strikethrough `9`/`29`. Colors: "normal" fg/bg/underline → `39`/`49`/`59`. A named color, or any color when term256 is off, uses the palette index: idx 0-7 → `30+i` (bg `40+i`), 8-15 → `90+(i-8)` (bg `100+…`), ≥16 → `38;5;i` (bg `48;5;i`), underline color `58:5:i`. An RGB color with term24bit → `38;2;r;g;b` / `48;2;r;g;b` / `58:2::r:g:b`. RGB without 24-bit but with term256 → nearest xterm-256 entry (indices 16-255, squared RGB distance). Without either → nearest of the 16-color table (0x000000, 800000, 008000, 808000, 000080, 800080, 008080, c0c0c0, 808080, ff0000, 00ff00, ffff00, 0000ff, ff00ff, 00ffff, ffffff). Named colors are never converted to RGB. "Salvage unreadable": when fg == bg and bg is a concrete color, fg becomes black (if bg is white) or white.
**Source.** `src/terminal.rs:376-523` (set_text_face_internal), `:414-420` (salvage), `:234-239` (index_for_color), `:653-792` (param packing, codes), `:729-745` (palette codes), `:747-779` (rgb vs palette). `crates/color/src/lib.rs:245-321` (nearest-color tables).
**Test.**
    setup: interactive fish; ' set -g fish_color_command --dim red' Enter
    keys:  hl 'ls x'
    expect: `ls` red+dim, then `x` without dim (tmux shows `\e[0m` before the cyan)
**Observed.** No (derived). Byte-level ordering cannot be observed through tmux capture.

### HL-12 — TERM=dumb and monochrome TERMs
**Behavior.** With TERM=`dumb`, no SGR (or any other terminal command) is written, and the commandline is printed as `\r` + prompt + text, without the autosuggestion. With TERM in {`ansi-m`, `linux-m`, `xterm-mono`} ("only grayscale"), palette colors are written only for grayscale indices (0, 7, 8, 15, 16, 232-255). Surprising: for 24-bit RGB, the check is inverted, so RGB colors that **are** gray (r=g=b) are suppressed and non-gray RGB colors are written.
**Source.** `src/env_dispatch.rs:452-453`, `src/terminal.rs:286-289`, `:675-677`, `:725-731`, `:755-757`, `src/screen.rs:319-330`, `crates/color/src/lib.rs:79-86`.
**Test.**
    setup: fixture with TERM=dumb
    keys:  hl 'echo foo'
    expect: no SGR at all on the line
**Observed.** No (derived).

### HL-13 — Reference capture: default-theme SGR per syntactic element
**Behavior.** With defaults, under TERM=xterm-256color in tmux (cursor at end of line in every case):
**Source.** Composite of HL-02, HL-05, HL-15 to HL-40.
**Test.** Each row: `hl '<input>'` → expected capture (prompt stripped).
    'echo hello'               → `echo \e[36mhello\e[39m`
    'echo -n --foo -- -bar'    → `echo \e[36m-n\e[39m \e[36m--foo\e[39m \e[36m--\e[39m \e[36m-bar\e[39m`  (option and param are both cyan by default)
    'if true; echo; end'       → `if true\e[32m;\e[39m echo\e[32m;\e[39m end\e[90m \e[39m`
    'echo a | cat; and true && false || true &' → `echo \e[36ma\e[39m \e[32m|\e[39m cat\e[32m;\e[39m \e[96mand\e[39m true \e[96m&&\e[39m false \e[96m||\e[39m true \e[32m&\e[39m`
    'echo # comment'           → `echo \e[31m# comment\e[39m`
    'nonexistentcmd'           → `\e[91mnonexistentcmd\e[39m`
    'echo > out 2>&1 < foo'    → `echo \e[1m\e[36m>\e[0m \e[1m\e[36mout\e[0m \e[1m\e[36m2>&1\e[0m \e[1m\e[36m<\e[0m \e[1;4m\e[36mfoo\e[0m\e[90m \e[39m`  (needs file foo)
    'echo (pwd) $(pwd) "q$(pwd)q"' → `echo \e[96m(\e[39mpwd\e[96m)\e[39m \e[96m$(\e[39mpwd\e[96m)\e[39m \e[33m"q\e[96m$(\e[39mpwd\e[96m)\e[33mq"\e[39m`
**Observed.** Yes, all rows exactly.

### HL-14 — Repaint on color variable change
**Behavior.** Setting a global or universal variable whose name starts with `fish_color_` or `fish_pager_color_` schedules a prompt repaint (the prompt is re-executed too). Colors are resolved again on every screen update through a per-update cache, so the new value applies immediately to the current commandline. A local or function-scoped change does not trigger the repaint.
**Source.** `src/env_dispatch.rs:150-171` (suppress_repaint unless global/universal), `src/screen.rs:1008-1015` (fresh HighlightColorResolver per update), `src/highlight/highlight.rs:124-153`.
**Test.**
    setup: interactive fish
    keys:  send-keys -l 'echo x'; then from another pane (or a bind) run `set -U fish_color_param red`. Simpler: send-keys ' set -g fish_color_param red' Enter; hl 'echo x'
    expect: `echo \e[31mx`
**Observed.** Partially. The same mechanism was used in the HL-10 sequence, where every `set -g` took effect on the next line.

---

### Part B: what role each character gets

### HL-15 — Highlighting is asynchronous; new characters inherit the previous character's color
**Behavior.** After each edit, fish re-highlights the whole line on a background thread, with I/O allowed (command lookup and path checks) and with the current cursor position. Until the result arrives, inserted characters take the spec of the character just before the insertion point (Normal if inserting at offset 0). A result is applied only if the text has not changed since the request. On Enter, if the highlight is stale, fish waits up to 250 ms for the in-flight one and otherwise does a quick highlight **without I/O** (every command shown as Command, no path or redirection checks). So the error coloring of a prefix such as `ech` updates live: typing `ech` shows red, and adding `o` turns it to the builtin color after the async pass.
**Source.** `src/editable_line.rs:40-55` (apply_edit copies `colors[start-1]`), `src/reader/reader.rs:5750-5768` (performer with `Some(position)`), `:5771-5781` (apply only if text matches), `:5784-5799`, `:5803-5843`, `:1335` (250 ms).
**Test.**
    setup: clean fixture
    keys:  hl 'ech'; then send-keys -l 'o'; sleep 0.8; capture
    expect: `\e[91mech\e[90mo \e[39m` then `echo\e[90m \e[39m`
**Observed.** Yes (both states, captured separately).

### HL-16 — Command role algorithm
**Behavior.** For the command word of a plain statement:
1. If I/O is not allowed → Command.
2. If the word looks like a variable assignment (`NAME=…`) → Command.
3. Otherwise expand it the way it would be for execution (variables, braces, wildcards; command substitutions **fail**). If expansion fails, or the result still contains reserved expansion characters → **Error**.
4. Otherwise check, in order, filtered by decoration: **builtin** (Builtin role) → **function**, loaded or autoloadable from `fish_function_path` or embedded, not tombstoned (Function role) → **abbreviation** with command position matching the word (Command role) → **executable in $PATH** (Command role). A word containing `/` is tested directly: `access(X_OK)` and it must be a regular file. Last comes **implicit cd** (Command role): after tilde expansion the word starts with `/`, `./` or `../`, ends with `/`, or equals `..`, and resolves (via CDPATH) to a directory. If nothing matches → **Error**.
Decorations: `command` and `exec` allow only $PATH executables. `builtin` allows only builtins. The decoration keyword itself gets the Keyword role.
Then the command word is colored with `color_string_internal` using the role as base, so quotes, escapes, `$var`, `*` and braces inside the command word get Quote/Escape/Operator colors (HL-23 to HL-28). Command substitutions inside the command word are not recursed.
**Source.** `src/highlight/highlight.rs:1038-1081`, `:231-288` (command_role), `:1192-1202` (expand_to_command_and_args), `:804-813`. `src/function.rs:233-256` (exists_no_autoload). `src/path.rs:247-278` (X_OK + is_file, slash rule), `:385-399` (implicit-cd shape), `:315-331`.
**Test.** See HL-17 and HL-18.
**Observed.** Yes (via HL-17 cases).

### HL-17 — Command coloring cases
**Behavior / expected captures** (clean fixture, `touch foo bar; mkdir dir sub; touch sub/file.txt`):
- `echo` (builtin), `ls` (fish ships an `ls` function), `fish_prompt` (function), `command echo x`, `exec ls`, `builtin echo`: command words in the default color (no SGR).
- `ech` → `\e[91mech` (not a builtin, function or command; prefixes are **not** accepted).
- `command ech` → `command \e[91mech`; `builtin ls` → `builtin \e[91mls` (ls is not a builtin).
- `dir` (a directory name without a slash) → `\e[91mdir` (**Error**: implicit cd needs a path shape). `dir/` and `./dir` → default color (implicit cd). `..` → Command (derived).
- `sub/file.txt` (exists, not executable) → `\e[91msub/file.txt`.
- `$EMPTYVAR` → `\e[91m$EMPTYVAR` (the whole token is error-colored, including `$`).
- `(echo ls)` as command → `\e[91m(echo ls)` (cmdsub in command position → expansion fails).
- `FOO=bar echo $FOO` → `\e[36mFOO\e[96m=\e[36mbar\e[39m echo \e[96m$FOO` (HL-32).
**Source.** `src/highlight/highlight.rs:1053-1081`, `:231-288`. Tests `:1489` (`/bin/definitely_not_a_command` → Error), `:1829-1830` (`$EMPTY_VARIABLE`, `"$EMPTY_VARIABLE"` → Error), `:1808-1827` (wildcard/variable command words that expand to `/usr/bin/env` → Command with `*`/`$VAR` Operator).
**Test.**
    setup: as above
    keys:  hl each input above
    expect: as listed
**Observed.** Yes for every listed case except `..` (derived).

### HL-18 — Abbreviation as command word is valid
**Behavior.** A word that matches an abbreviation usable in command position (`abbr` without `--position anywhere` restrictions that exclude command position) gets the Command role, not Error, even if no such command exists. This applies only without the `command`/`exec`/`builtin` decorations.
**Source.** `src/highlight/highlight.rs:272-275`, `:245-260`.
**Test.**
    setup: interactive fish; send-keys ' abbr -a gco git checkout' Enter
    keys:  hl 'gco'
    expect: `gco` default color (no `\e[91m`)
**Observed.** No (derived).

### HL-19 — Keywords and keyword-like operators
**Behavior.** Keyword role (→ fish_color_keyword → command): `begin builtin case command else end exec for function if in switch while`, plus the brace-statement braces `{` `}` when parsed as a brace block. Operator role (brcyan): `and or not ! time`. Strings in block headers (the `for` variable, the `function` name and its args, the `switch` value, `case` patterns) are Param.
**Source.** `src/highlight/highlight.rs:889-913` (keyword table), `:914-933` (LeftBrace/RightBrace → Keyword, AndAnd/OrOr → Operator, block-header strings → Param). Tests `:1724-1741`.
**Test.**
    keys:  hl 'time ls'; hl 'not true'; hl '! true'; hl 'for x in a b; end'; hl 'function f; end'; hl 'switch x; case y; end'
    expect: `\e[96mtime\e[39m ls…`; `\e[96mnot\e[39m true…`; `\e[96m!\e[39m true…`; `for \e[36mx\e[39m in \e[36ma\e[39m \e[36mb\e[32m;\e[39m end`; `function \e[36mf\e[32m;\e[39m end`; `switch \e[36mx\e[32m;\e[39m case \e[36my\e[32m;\e[39m end`
**Observed.** Yes (each line also had a gray autosuggestion `\e[90m ` at the end).

### HL-20 — Misplaced block keywords are errors; unterminated blocks are not
**Behavior.** `end` outside a block, `else` outside `if`, and `case` outside `switch` are colored Error: the parser records the token range as an error, and error ranges are painted last (HL-40). An unfinished block (`begin`, `if true`, `while …` without `end`) is **not** an error while typing (the parse is done with `leave_unterminated`). `if … end end` → the second `end` is Error.
**Source.** `src/ast.rs:2161-2211` (excess-token errors), `src/highlight/highlight.rs:754-763` (flags incl. leave_unterminated), `:784-787`. Tests `:1657-1662`.
**Test.**
    keys:  hl 'end'; hl 'else'; hl 'case'; hl 'begin'
    expect: `\e[91mend`; `\e[91melse`; `\e[91mcase`; `begin` (no SGR)
**Observed.** Yes.

### HL-21 — Statement separators and pipes
**Behavior.** `;`, newline, `|`, `&` (background), `&|`, `|&`, and extra semicolons (`;;`) → StatementTerminator (fish_color_end, green). `&&` and `||` → Operator (brcyan). With feature `ampersand-nobg-in-token` (on by default), `&` inside a word (`foo&bar`) is part of the word (Param).
**Source.** `src/highlight/highlight.rs:914-923`, `:1032-1037`, `:776-782` (extra semis), `src/ast.rs:2097-2102`. Tests `:1473-1480`, `:1750-1769`. `crates/feature-flags/src/lib.rs:97-103`.
**Test.**
    keys:  hl 'echo a | cat; and true && false || true &'
    expect: see HL-13 row
**Observed.** Yes.

### HL-22 — Params vs options
**Behavior.** An argument whose first source character is `-` is an Option (→ fish_color_option → param), until an argument whose source is exactly `--` is seen in the same statement. The `--` itself is still an Option, and everything after it is Param. "First character" means the raw source, so `"-x"` (quoted) is a Param and `\-x` is a Param. A lone `-` is an Option. Arguments in a redirection with a cmdsub target are colored with options allowed (HL-33).
**Source.** `src/highlight/highlight.rs:815-836`, `:1086-1101`. Tests `:1534-1549`, `:1782-1786`.
**Test.**
    setup: `set -g fish_color_option magenta` (to make option distinct)
    keys:  hl 'echo -a -- -b "-c"'
    expect: `-a` magenta, `--` magenta, `-b` cyan, `"-c"` yellow (quote)
**Observed.** No for the custom-color version. With defaults: `echo -n --foo -- -bar` gave all cyan (HL-13).

### HL-23 — Unquoted operator characters inside words
**Behavior.** In unquoted parts of a word (command or argument), the role is the base role (Param/Option/Command/…) except:
- `~` at offset 0 of the token → Operator. `~` elsewhere (`a~b`) → base.
- `*` → Operator (each char, so `**` is two). `?` → base (Param), because feature `qmark-noglob` is on by default. It would be Operator if the feature were off.
- `(` `)` → Operator. Brace characters `{` `}` → Operator, and `,` → Operator only while inside braces (a running count). Unbalanced `{` is not an error.
- The whole token exactly `%self` → Operator. `%` elsewhere → base.
- `$…` → variable rules (HL-28).
- `'` / `"` open quote modes (HL-25, HL-26).
**Source.** `src/highlight/highlight.rs:491-495` (%self), `:596-637`. `crates/feature-flags/src/lib.rs:81-87` (qmark-noglob default true).
**Test.**
    keys:  hl 'echo *.txt ? ~ %self {a,b}'; hl 'echo a~b ~root %b a%self'; hl 'echo ** {'
    expect: `echo \e[96m*\e[36m.txt\e[39m \e[36m?\e[39m \e[4m\e[96m~\e[0m \e[96m%self\e[39m \e[96m{\e[36ma\e[96m,\e[36mb\e[96m}` (+ autosuggestion); `echo \e[36ma~b\e[39m \e[4m\e[96m~\e[36mroot\e[0m \e[36m%b\e[39m \e[36ma%self`; `echo \e[96m**\e[39m \e[96m{`
**Observed.** Yes. (`~` and `~root` are underlined because they are valid paths, HL-35.)

### HL-24 — Backslash escapes (unquoted)
**Behavior.** For a backslash at index b in an unquoted region, with escaped char e:
- end of token (`\` last) → the backslash is **Error**.
- `~` or `%` → Escape for `\`+e **only if b == 0** (token start). Otherwise not colored (base).
- `,` → Escape for 2 chars only if inside braces. Otherwise base.
- any of `a b e f n r t v * ? $ ( ) { } [ ] ' " < > ^ space \ # ; | &` → Escape for 2 chars.
- `c` → Escape for 2 chars (`\c` only; the control letter after it stays base, despite the code comment saying 3).
- `u` (up to 4 hex digits, max 0xFFFF), `U` (up to 8 hex, max 0x10FFFF), `x`/`X` (up to 2 hex, max 0xFF), octal digit `0-7` (up to 3 octal digits, max 0x7F, **ASCII_MAX**) → Escape over `\` + letter + the digits actually consumed. Error over the same span if the value exceeds the max (`\U110000`, `\777`, `\400`). `\x` with no digits → Escape for 2 chars. `\x100` → `\x10` Escape, `0` base.
- any other char (`\q`, `\8`) → not colored at all (base role for both chars).
**Source.** `src/highlight/highlight.rs:511-595`. Tests `:1832-1843`.
**Test.**
    keys:  hl 'echo \u12 \uZ \U10FFFF \U110000 \xff \x100 \777 \400'
    expect: `echo \e[96m\u12\e[39m \e[96m\u\e[36mZ\e[39m \e[96m\U10FFFF\e[39m \e[91m\U110000\e[39m \e[96m\xff\e[39m \e[96m\x10\e[36m0\e[39m \e[91m\777\e[39m \e[91m\400\e[39m`
    keys:  hl 'echo \x \xZZ \101 \8 \cA \e \\ \  \~a \%a ~\~ a\,b {a\,b} \q'
    expect: `\e[96m\x` `\e[96m\x\e[36mZZ` `\e[96m\101` `\e[36m\8` `\e[96m\c\e[36mA` `\e[96m\e` `\e[96m\\` `\e[96m\ ` `\e[96m\~\e[36ma` `\e[96m\%\e[36ma` `\e[96m~\e[36m\~` `\e[36ma\,b` `\e[96m{\e[36ma\e[96m\,\e[36mb\e[96m}` `\e[36m\q`; and hl 'echo \' → `echo \e[91m\`
**Observed.** Yes, all of these. (Send these with `send-keys -l` from a file or a quoted heredoc: some harness shells rewrite `é` before tmux sees it.)

### HL-25 — Single-quoted strings
**Behavior.** From the opening `'` through the closing `'`, everything is Quote. Inside, only `\\` and `\'` are Escape (both chars). Other backslashes (`\n`) stay Quote. `$var` inside single quotes is Quote.
**Source.** `src/highlight/highlight.rs:625-629`, `:640-655`. Tests `:1664-1669`.
**Test.**
    keys:  hl "echo 'a\'b\\c\nd'"   (literal text: echo 'a\'b\\c\nd')
    expect: `echo \e[33m'a\e[96m\'\e[33mb\e[96m\\\e[33mc\nd'`
**Observed.** Yes.

### HL-26 — Double-quoted strings
**Behavior.** From `"` through the closing `"`, the base is Quote. `\\`, `\"`, `\$` and backslash-newline are Escape (2 chars), and other backslashes stay Quote. `$var` (and slices) inside double quotes get variable coloring (HL-28). `$(…)` inside double quotes is a command substitution: `$(` and `)` Operator, recursive highlighting inside (HL-30). A plain `(` inside double quotes is just Quote.
**Source.** `src/highlight/highlight.rs:630-634`, `:657-684`, `:837-872`. Tests `:1556-1573`, `:1671-1687`.
**Test.**
    keys:  hl 'echo "a\"b\$c\\d\ne"'; hl 'echo "a $HOME b"'; hl 'echo "$(echo "x")"'
    expect: `echo \e[33m"a\e[96m\"\e[33mb\e[96m\$\e[33mc\e[96m\\\e[33md\ne"`; `echo \e[33m"a \e[96m$HOME\e[33m b"`; `echo \e[33m"\e[96m$(\e[39mecho \e[33m"x"\e[96m)\e[33m"`
**Observed.** Yes.

### HL-27 — Unclosed quote: only the opening quote is an error
**Behavior.** If a token ends inside a single- or double-quoted region, the **opening quote character** becomes Error and the rest stays Quote. Nothing else on the line is affected.
**Source.** `src/highlight/highlight.rs:689-692`. Tests `:1664-1676`.
**Test.**
    keys:  hl 'echo "unclosed'; hl "echo 'unclosed"
    expect: `echo \e[91m"\e[33munclosed`; `echo \e[91m'\e[33munclosed`
**Observed.** Yes.

### HL-28 — Variable expansion coloring (`color_variable`)
**Behavior.** At a `$`:
1. Leading run of `$`s: each `$` followed by another `$` or a valid variable-name char (alphanumeric or `_`) → Operator. A `$` followed by `(` → Operator, and it starts a cmdsub, so stop. Any other `$` (end of token, `$` followed by `{`, space, etc.) → **Error**.
2. Then valid name chars (and backslash-newline pairs) → Operator.
3. Then up to one slice `[…]` per leading `$`: the `[` and the matching `]` → Operator. Slice contents are not validated: they get the base role (Param, or Quote inside double quotes). An unterminated slice `[` → the whole `$name[` span is Error.
4. After the variable, scanning continues normally, so `$foo$bar` is all Operator and `a$b` is `a` base + `$b` Operator.
The variable's *existence* is not checked (`$undefined` is Operator), except as a command word, where an empty expansion is an Error (HL-17), and as a redirection target (HL-33). `${HOME}` is **not** fish syntax: `$` Error, `{` `}` Operator (brace), `HOME` Param.
**Source.** `src/highlight/highlight.rs:408-471`, `:602-607`, `:677-681`. Tests `:1678-1706`, `:1800-1805`.
**Test.**
    keys:  hl 'echo $HOME ${HOME} $'; hl 'echo $foo[1] "$foo[1..2]" $foo[ $$foo[1][2]'; hl 'echo $foo$bar a$b $'
    expect: `echo \e[96m$HOME\e[39m \e[91m$\e[96m{\e[36mHOME\e[96m}\e[39m \e[91m$`; `echo \e[96m$foo[\e[36m1\e[96m]\e[39m \e[33m"\e[96m$foo[\e[36m1..2\e[96m]\e[33m"\e[39m \e[91m$foo[\e[36m \e[96m$$foo[\e[36m1\e[96m][\e[36m2\e[96m]`; `echo \e[96m$foo$bar\e[39m \e[36ma\e[96m$b\e[39m \e[91m$`
**Observed.** Yes.

### HL-29 — Slices inside double quotes are not overwritten
**Behavior.** In double-quoted mode, a character that variable coloring already colored ahead of the scan position keeps that color, and is not repainted as Quote.
**Source.** `src/highlight/highlight.rs:657-662`.
**Test.**
    keys:  hl 'echo "$foo[1..2]"'
    expect: `\e[33m"\e[96m$foo[\e[36m1..2\e[96m]\e[33m"`
**Observed.** Yes (in HL-28's line).

### HL-30 — Command substitutions
**Behavior.** In arguments (and redirection targets containing a cmdsub), every `(…)` / `$(…)` found by `locate_cmdsubst_range` (incomplete ones accepted) gets: opening `(` or `$(` → Operator, closing `)` → Operator (if present), and the contents highlighted **recursively** as a full commandline, with the same cursor (shifted) and the same I/O permission. So inner commands can be Error, inner paths underlined, and so on. Works inside double quotes. An unmatched `)` is a tokenizer error → Error. An unclosed `(` is not an error while typing.
**Source.** `src/highlight/highlight.rs:837-872`, `:991-994`. Tests `:1534-1573`, `:1771-1774`.
**Test.**
    keys:  hl 'echo a(echo b)c'; hl 'echo )'; hl 'echo ('; hl 'echo $('
    expect: `echo \e[36ma\e[96m(\e[39mecho \e[36mb\e[96m)\e[36mc`; `echo \e[91m)`; `echo \e[96m(`; `echo \e[96m$(`
**Observed.** Yes.

### HL-31 — Command word quoting/escapes are colored too
**Behavior.** The command word is colored with the same string colorer, using its role as base: `"echo"` shows as Quote (yellow) if it resolves to a valid command, or as Error (all red) if invalid. An invalid command word is painted entirely Error, with no inner coloring.
**Source.** `src/highlight/highlight.rs:1076-1081`, `:804-813`, `:475-487`.
**Test.**
    keys:  hl '"echo" x'
    expect: `\e[33m"echo"\e[39m \e[36mx`
**Observed.** No (derived).

### HL-32 — Variable assignments (`NAME=value cmd`)
**Behavior.** A leading `NAME=value` word is colored like an argument (options allowed), and then the `=` is recolored as Operator. NAME is pushed as a *pending variable* (HL-33). `set NAME …`: the first argument after `set` that is a valid variable name becomes pending. `for NAME in`: NAME is pending inside the loop body. A bare `FOO=bar` with no command: same coloring, no error.
**Source.** `src/highlight/highlight.rs:1022-1031`, `:1086-1097`, `:1107-1123`. Tests `:1648-1655`, `:1756-1769`, `:1795-1798`.
**Test.**
    keys:  hl 'FOO=bar echo $FOO'; hl 'FOO=bar'
    expect: `\e[36mFOO\e[96m=\e[36mbar\e[39m echo \e[96m$FOO`; `\e[36mFOO\e[96m=\e[36mbar`
**Observed.** Yes.

### HL-33 — Redirections and their targets
**Behavior.**
- If the operator parses but is invalid (fd overflow, e.g. `99999999999999999999>&2`) → the whole redirection is Error.
- Otherwise the operator (`>`, `>>`, `<`, `2>`, `&>`, `>?`, `2>&`, …) → Redirection (cyan bold).
- Target containing a cmdsub → colored as an argument (Param, cmdsub recursion), with no validation.
- I/O not allowed → target Redirection, no underline.
- Target mentions a pending variable as `$NAME` (not followed by a name char) → Redirection, no check.
- Otherwise the target is expanded (failure → **Error**: e.g. an undefined variable expands to nothing, `> $v` → Error), then checked by mode:
  - **fd** (`>&`, `<&`): `-` or an integer ≥ 0 → Redirection. Otherwise **Error** (`2>&LO` → `LO` red).
  - **input** (`<`, and `<?` "try input"): readable and not a directory → Redirection **+ valid_path underline**. Otherwise **Error**, even for `<?`.
  - **output** (`>`, `>>`, `>?` noclobber): target ending in `/` → Error. If it exists: writable and not a directory → Redirection + underline. If it does not exist (ENOENT): Redirection without underline if the parent directory is writable, else Error. Any other stat error (e.g. ENOTDIR) → Error. With `>?`, an existing file → Error.
- A missing target (`echo >` while typing) → just the operator colored, no error.
- A redirection with no command (`> echo`) → Error over both tokens.
- Targets longer than PATH_MAX → Error.
**Source.** `src/highlight/highlight.rs:968-1020`, `:1141-1162` (pending-variable match). `src/highlight/file_tester.rs:132-223`, `src/ast.rs:2222-2230`. Tests `:1575-1655`, `:1845-1848`.
**Test.**
    setup: `touch foo; mkdir dir`
    keys:  hl 'echo > /nonexistent/x'; hl 'echo > dir/'; hl 'cat < nofile'; hl 'echo 2>&LO'; hl 'echo 2>&-'; hl 'echo >? foo'; hl 'echo >? newf'; hl 'echo >> foo'; hl 'echo > $v'; hl 'set v x; echo > $v'; hl 'echo > (echo x)'; hl 'echo >'
    expect: `echo \e[1m\e[36m>\e[0m \e[91m/nonexistent/x`; `… \e[91mdir/`; `cat \e[1m\e[36m<\e[0m \e[91mnofile`; `echo \e[1m\e[36m2>&\e[0m\e[91mLO`; `echo \e[1m\e[36m2>&-\e[0m`; `… \e[1m\e[36m>?\e[0m \e[91mfoo`; `… \e[1m\e[36m>?\e[0m \e[1m\e[36mnewf\e[0m`; `… \e[1m\e[36m>>\e[0m \e[1;4m\e[36mfoo\e[0m`; `… \e[91m$v`; `set \e[36mv\e[39m \e[36mx\e[32m;\e[39m echo \e[1m\e[36m>\e[0m \e[1m\e[36m$v\e[0m`; `echo \e[1m\e[36m>\e[0m \e[96m(\e[39mecho \e[36mx\e[96m)`; `echo \e[1m\e[36m>\e[0m`
**Observed.** Yes, all (several captures also had gray autosuggestion text after them). Also `echo ^ foo` → `^` is a plain Param (cyan): stderr-nocaret.

### HL-34 — Comments
**Behavior.** A `#` that begins a token (start of line or after whitespace) starts a comment running to the end of the line. The comment is painted Comment (red) after the AST pass, so it overrides any other color. A `#` inside a word (`a#b`) is part of the word.
**Source.** `src/tokenizer.rs:322-341`, `src/highlight/highlight.rs:770-774`. Test `:1776-1780`.
**Test.**
    keys:  hl 'echo # comment'; hl 'echo a#b'
    expect: `echo \e[31m# comment`; `echo \e[36ma#b`
**Observed.** First yes, second derived.

### HL-35 — Valid-path underline algorithm (arguments of non-`cd` commands)
**Behavior.** Only for argument tokens (not the command word; redirection targets have their own rules in HL-33), and only if I/O is allowed. `at_cursor` = the cursor lies within the token's range **inclusive of its end** (so the cursor right after the last char counts). Algorithm (`test_path`):
1. If the raw token is longer than PATH_MAX → no.
2. Unescape the token in script style with "special" chars (quotes removed, escapes resolved). Failure → no. A leading home-directory marker becomes `~` again.
3. Tilde-expand. If the result contains any expansion magic (`$` variable, `%self`, braces, `?` wildcard char, `*`, `**`) → no. That is, tokens with variables or globs are **never** underlined. Slice markers become `[`/`]`. Internal separators are dropped. Empty → no.
4. `abs = wd + fragment` (unless absolute). Let `must_be_dir` = abs ends with `/`.
5. If `must_be_dir` or not `at_cursor`: stat(abs). If it succeeds and (not `at_cursor`, or it is a directory) → **yes**. Note that not-at-cursor accepts any file type.
6. Else (at cursor, no trailing slash): split into dirname/basename. If both are `/` → yes. Open dirname and iterate its entries (**excluding `.` and `..`**). Any entry whose name has basename as a prefix → yes. On a case-insensitive filesystem (macOS `_PC_CASE_SENSITIVE == 0`), a case-insensitive prefix also counts.
7. Otherwise no.
Effects: while typing, a *prefix* of an existing path is underlined (`echo fo` with file `foo`). Once the cursor leaves the token (a space was typed), only exact existing paths stay underlined (`echo fo ` loses the underline).
**Source.** `src/highlight/highlight.rs:934-966` (is_prefix, call), `src/highlight/file_tester.rs:66-104`, `:226-366`, `:424-450`. `src/wutil/dir_iter.rs:209-223`, `:287` (dots skipped). Tests `:1717-1722`, file_tester tests `:482-530`.
**Test.**
    setup: `touch foo`
    keys:  hl 'echo fo'; hl 'echo fo '; hl 'cat /dev/nu'; hl 'cat /dev/nu '; hl 'ls f*'; hl 'ls $HOME'; hl "ls 'foo'"; hl 'ls dir/'; hl 'ls foo/'
    expect: `echo \e[4m\e[36mfo\e[0m\e[90mo \e[39m`; `echo \e[36mfo`; `cat \e[4m\e[36m/dev/nu\e[0m\e[90mll \e[39m`; `cat \e[36m/dev/nu`; `ls \e[36mf\e[96m*` (no underline); `ls \e[96m$HOME` (no underline); `ls \e[4m\e[33m'foo'\e[0m`; `ls \e[4m\e[36mdir/\e[0m`; `ls \e[36mfoo/` (file + trailing slash → no)
**Observed.** Yes, all.

### HL-36 — `.` / `..` as arguments are not underlined while the cursor is on them
**Behavior.** Consequence of HL-35 step 6: for `ls .` with the cursor at the end, fish looks for an entry in the working directory starting with `.`. Since `.`/`..` are skipped, the token is underlined only if a dotfile exists. After a space, step 5 stats it and it is underlined. Same for `..` (needs an entry starting with `..`). `cd .` and `cd ..` are not affected, because cd paths are normalized first (HL-37).
**Source.** `src/highlight/file_tester.rs:320-363`, `src/wutil/dir_iter.rs:287`.
**Test.**
    setup: W contains only non-dot entries
    keys:  hl 'ls .'; hl 'ls . '; hl 'ls ..'
    expect: `ls \e[36m.` (no underline) + autosuggestion `\e[90m/`; `ls \e[4m\e[36m.\e[0m`; `ls \e[36m..`
**Observed.** Yes.

### HL-37 — `cd` arguments: underline if valid, Error if invalid
**Behavior.** For a statement whose expanded command is exactly `cd` and which has no `complete --wraps` override for `cd`, each argument:
- If it is a prefix of one of `--help -h --logical -L --physical -P` → no check. This includes `-` and `--`, and it is colored Option because it starts with `-`.
- Otherwise expand it (cmdsub → skip, no color change). Then directories to try = just the working directory if the arg starts with `./`; otherwise each `$CDPATH` entry (empty → `.`, relative entries made absolute) plus `.` if none was `.`. For each, run the HL-35 step 4-6 algorithm with **require_dir** (step 6 only counts directory entries) and with the absolute path **normalized** (`foo/../x`, trailing `.`, …). Valid → valid_path underline. **Invalid → the whole argument is Error.**
Quirk (follows from step 5): when the cursor is not in the token, a successful stat suffices even for a regular file. So `cd foo` (foo a file) is red while the cursor is at its end, but `cd foo ` becomes **underlined** instead of red. `cd di` (prefix of dir) is underlined while typing.
**Source.** `src/highlight/highlight.rs:332-347`, `:1085`, `:947-953`, `:964`. `src/highlight/file_tester.rs:106-130`, `:368-414`, `:298-300`, `:320-324`. Tests `:1504-1531`.
**Test.**
    setup: `touch foo; mkdir dir`
    keys:  hl 'cd dir'; hl 'cd di'; hl 'cd foo'; hl 'cd foo '; hl 'cd nonexist'; hl 'cd --help'; hl 'cd -'; hl 'cd ..'; hl 'cd .'; hl 'cd ~'
    expect: `cd \e[4m\e[36mdir\e[0m\e[90m/`; `cd \e[4m\e[36mdi\e[0m\e[90mr/`; `cd \e[91mfoo`; `cd \e[4m\e[36mfoo\e[0m`; `cd \e[91mnonexist`; `cd \e[36m--help`; `cd \e[36m-` (+`\e[90mh `); `cd \e[4m\e[36m..\e[0m…`; `cd \e[4m\e[36m.\e[0m…`; `cd \e[4m\e[96m~\e[0m…`
**Observed.** Yes, all.

### HL-38 — Case-insensitive prefix matching on case-insensitive filesystems
**Behavior.** On macOS volumes that report case-insensitivity, `ls FOO` with file `foo` is underlined, both at the cursor (prefix match, case-folded) and after a space (stat succeeds). On Linux (no `_PC_CASE_SENSITIVE`), matching is always case-sensitive.
**Source.** `src/highlight/file_tester.rs:335-358`, `:424-450`.
**Test.**
    setup: `touch foo` on APFS (case-insensitive)
    keys:  hl 'ls FOO'
    expect: `ls \e[4m\e[36mFOO\e[0m`
**Observed.** Yes (macOS). Platform-dependent: a zsh port running on the same machine must match it.

### HL-39 — Error ranges from the parser override everything
**Behavior.** After the AST walk, comments are painted, then extra semicolons, and then every parse-error range as Error, so these win over all earlier colors. Error sources include: a stray `)` or `}` (`echo }` → `}` red; inside a word `{a,b}` is fine), a trailing lone backslash (via the string colorer), misplaced `end`/`else`/`case`, a redirection without a command, and a pipe/`&&`/`||`/`&` with nothing before it. After an error, the parser skips (and paints Error) all following non-string tokens until the next string/end token, then resumes.
**Source.** `src/highlight/highlight.rs:770-789`, `src/ast.rs:1679-1715`, `:2161-2253`, `:2310-2340`.
**Test.**
    keys:  hl 'echo }'; hl '> echo'; hl '| cat'
    expect: `echo \e[91m}`; `\e[91m> echo` (both tokens); `|` red (derived)
**Observed.** `echo }` yes. `> echo` is a unit-test fact (`:1845-1848`). `| cat` derived.

### HL-40 — Spaces and unrecognized characters use `fish_color_normal`
**Behavior.** Characters with no specific role (spaces between tokens, trailing spaces) have role Normal and render with `fish_color_normal`. They do not inherit the command's underline (test asserts trailing spaces after an underlined command are not underlined).
**Source.** `src/highlight/highlight.rs:751-752` (default spec), tests `:1852-1907`.
**Test.**
    keys:  ' set -g fish_color_normal magenta' Enter; hl 'if ls x ; y'
    expect: spaces magenta: `\e[35mif ls x \e[32m;\e[35m \e[91my`
**Observed.** Yes.

---

### Part C: overlays (autosuggestion, search, selection, flash, cancel) and non-commandline uses

### HL-41 — Autosuggestion color
**Behavior.** The autosuggested tail (text after the typed portion) is painted with spec fg=Autosuggestion (fish_color_autosuggestion → normal), bg Normal. Default: brblack `\e[90m`. During the "flash" after deleting a non-history autosuggestion, it is painted with SearchMatch fg+bg instead.
**Source.** `src/reader/reader.rs:1844-1861`, `:1900-1912`, `:3535-3545`.
**Test.**
    setup: history `echo hello`
    keys:  hl 'echo h'
    expect: `echo \e[36mh\e[90mello\e[39m`
**Observed.** Yes.

### HL-42 — History search match coloring
**Behavior.** While a history search is active (e.g. Up after typing), the matched range in the commandline gets **bg role = SearchMatch**. If `fish_color_search_match` (non-empty) specifies a foreground color, the fg role is also set to SearchMatch. Otherwise the original syntax fg is kept, and only the bg color and reverse from search_match apply (HL-06), so its bold is dropped. With the default (`white --background=brblack --bold`): white, bold, on brblack. Not applied in silent (password) mode. Docs say "background only", but the code also uses the foreground when one is set.
**Source.** `src/reader/reader.rs:1867-1889`, `doc_src/interactive.rst:154` (discrepancy).
**Test.**
    setup: history `echo hello`
    keys:  send-keys -l 'hel'; send-keys Up
    expect: `echo \e[1m\e[37m\e[100mhel\e[0m\e[36mlo\e[39m`
**Observed.** Yes.

### HL-43 — Selection color
**Behavior.** Characters in the active selection get spec fg=bg=Selection, which **replaces** syntax colors entirely. The face is fish_color_selection (→ normal). Default: white bold on brblack. Applies to any selection (begin-selection, vi visual), not only vi visual mode as the docs say.
**Source.** `src/reader/reader.rs:1891-1898`, `doc_src/interactive.rst:143`.
**Test.**
    setup: interactive fish; ' bind f6 begin-selection' Enter
    keys:  send-keys -l 'echo hello'; send-keys Left; send-keys F6; send-keys Left Left Left
    expect: `echo \e[36mh\e[1m\e[37m\e[100mell\e[0m\e[36mo\e[39m`
**Observed.** Yes. Note: the selection stayed active after ctrl-c (clear-commandline) and colored later lines. That belongs to the selection-lifetime section.

### HL-44 — Flash
**Behavior.** On "nothing found" style failures, fish repaints a range with fg=bg=SearchMatch (default: white bold on brblack), sleeps 100 ms, then repaints with the saved colors. The failures: history search with no further match (flashes the search-result range, or the whole line), undo/redo with nothing to undo, completion with no candidates (flashes the token, or the whole line if the token is empty), a wildcard expansion overflow, and history-pager boundaries. Flashes within 50 ms of the previous one are dropped. An empty range does not flash unless it is the autosuggestion flash.
**Source.** `src/reader/reader.rs:4636-4676`. Call sites `:3217`, `:3479-3483`, `:3495`, `:4351`, `:6980`, `:7095-7097`.
**Test.**
    setup: clean HOME (no history)
    keys:  send-keys -l 'zzz'; send-keys Up; capture within ~50 ms
    expect: `zzz` momentarily `\e[1m\e[37m\e[100m`, then back to `\e[91mzzz`
**Observed.** No (timing-sensitive, derived).

### HL-45 — `^C` cancel indicator uses `fish_color_cancel` (no fallback)
**Behavior.** The readline function `cancel-commandline` (not bound by default in 4.9.3: default ctrl-c is `clear-commandline`, which prints nothing) moves to the end of the line, clears the autosuggestion, repaints, then writes `^C` in the face from `fish_color_cancel`. That variable is read with `get`, with **no role fallback**: if it is unset or unparseable, nothing is set (unset) or the terminal default is used. fish then resets attributes, prints `\n`, and starts a fresh line. Default `-r` → reverse video.
**Source.** `src/reader/reader.rs:3081-3131`. `share/functions/__fish_shared_key_bindings.fish:72` (ctrl-c → clear-commandline). `src/input/binding.rs:445` (only the bare fallback bindings use cancel-commandline).
**Test.**
    setup: interactive fish; ' bind f5 cancel-commandline' Enter
    keys:  send-keys -l 'echo hi'; send-keys F5
    expect: line 1: `echo \e[36mhi\e[7m\e[39m^C`; next line starts with `\e[0m` and a new prompt
**Observed.** Yes.

### HL-46 — Pager roles (completion pager and history pager)
**Behavior.** Unselected rows alternate: odd rows (`row % 2 != 0`) use the *secondary* roles. The selected item uses the *selected* roles. The row background uses spec bg=…Background, while the prefix/completion/description use fg=…Prefix (or …Completion when the prefix is not highlighted) / …Completion / …Description with bg=…Background. The description's opening `(` uses (Selected)Completion. The progress line uses fg=bg=PagerProgress. History-pager and other line-replacing completions are syntax-highlighted with **no I/O and an empty environment** (commands always the Command role, no path underlines or command errors), except for the selected row, which is not syntax-highlighted. With defaults, the selected row is reversed (`-r` from selected_background; fg falls back to normal), the prefix is bold+underline, descriptions are yellow italic, and progress is brwhite bold on cyan.
**Source.** `src/pager.rs:436-448`, `:499-524`, `:553-562`, `:600-607`, `:294-305`, `:1287-1296`. `src/highlight/highlight.rs:1265-1275`.
**Test.**
    setup: `touch $W/foo1 $W/foo2`
    keys:  send-keys -l 'ls foo'; send-keys Tab
    expect: pager row shows `foo` prefix `\e[1;4m` then `1`/`2` default; after a second Tab the selected item is `\e[7m`
**Observed.** No (pager details belong to the pager section; derived).

### HL-47 — Default prompt colors
**Behavior.** `fish_prompt` prints `prompt_login` + space + cwd + vcs + status + suffix:
- `prompt_login`: `(set_color yellow)$__fish_machine(set_color --reset) ` first if in a Debian chroot. Then `$USER` in fish_color_user (brgreen `\e[92m`), `@`, the hostname in fish_color_host, or in fish_color_host_remote if `$SSH_TTY` is set and that variable exists (default host `--reset`, no color; remote yellow).
- cwd (`prompt_pwd`) in fish_color_cwd (green `\e[32m`). For root (`fish_is_root_user`) it uses fish_color_cwd_root (red) if set, and the suffix becomes `#` instead of `>`.
- After a failure (last status not 0 or 141): ` [` + pipestatus joined by `|` + `]` in fish_color_status (red). The numbers are **bold** only if `$status_generation` changed since the previous prompt, i.e. a command actually ran.
**Source.** `share/functions/fish_prompt.fish:4-32`, `share/functions/prompt_login.fish:2-29`, `share/functions/__fish_print_pipestatus.fish:2-38`.
**Test.**
    setup: standard fixture
    keys:  (none) capture; then send-keys 'false' Enter; capture
    expect: `\e[92m<user>\e[39m@<host> \e[32m~/w\e[39m> `; after `false`: `<user>@<host> ~/w [1]> ` where `[` and `]` are red (31, not bold), `1` is red **bold**, and the space before `[` and the `> ` are default (`__fish_print_pipestatus.fish:26-36`: brace color = arg4 = non-bold status color, number color = arg5 = bold status color). Pressing Enter on an empty line afterwards re-prints `[1]` with `1` **not** bold (status_generation unchanged).
**Observed.** First line yes (`\e[92mdarin\e[39m@echo \e[32m~/w\e[39m>`). Status form derived.

### HL-48 — `fish_color_history_current` (dirh / cdh)
**Behavior.** `dirh` (and `cdh`) prints the current directory line with `set_color $fish_color_history_current` (default `--bold`). It is not used in commandline highlighting.
**Source.** `share/functions/dirh.fish:22`, `share/functions/cdh.fish`.
**Test.**
    keys:  send-keys 'dirh' Enter
    expect: the current-directory line is bold (`\e[1m`)
**Observed.** No (derived).

---

### Notes for zsh implementers
- **Role resolution** (port exactly): `for v in [var(role), var(fallback(role)), var(normal)] (adjacent dups removed): if v non-empty and parses to a face that specifies anything (color, style, or reset) → use it; else terminal default` (`highlight.rs:154-173`). Then: bg role ≠ fg role → take only the bg color and reverse from the bg role (`:176-185`). Then valid_path: overlay any specified fg/bg/ul-color and styles from `fish_color_valid_path` (`:188-202`). `--theme=*` tokens are ignored. Unknown color names are dropped silently, but an unknown *option* invalidates the whole variable (`text_face.rs:286-295`, `:366-374`).
- **Default theme = 16 named colors only.** Defaults never emit `38;5`/`38;2`, whatever the truecolor detection says. The targets are: cyan=36, brcyan=96, brred=91, brblack=90, white on brblack bg = `37;100`, brgreen=92. UNVERIFIED (zsh side, not checked): how zsh's `region_highlight` `fg=8..15` specs are emitted (fish emits `90-97`/`100-107` for indices 8-15, never `38;5;8-15`). Verify zsh's output in tmux. tmux capture shows `38;5;N` distinctly from `9x`.
- **Highlighting runs on every keystroke, asynchronously, with the cursor position.** Prefix-of-path underlining exists **only** for the token containing the cursor (inclusive end) (`highlight.rs:943-945`). Command validity has **no** prefix leniency (`ech` is red).
- **valid-path pseudo-code** (`file_tester.rs:231-366`):
  ```
  frag = tilde_expand(unescape(token)); if magic(frag) or empty: false
  for wd in dirs:                       # [cwd] or CDPATH entries + "." for cd
      abs = join(wd, frag); if for_cd: abs = normalize(abs)
      if abs ends with "/" or not at_cursor:
          if stat(abs) ok and (not at_cursor or isdir(abs)): return true
      else:
          d, b = dirname(abs), basename(abs)
          if d == "/" and b == "/": return true
          for e in readdir(d) excluding . and ..:
              if require_dir and not isdir(e): continue
              if e.name startswith b (or casefold-startswith on case-insensitive FS): return true
  return false
  ```
  For `cd`, a false result means the argument is **Error** (red), not just "no underline". Arguments that are prefixes of `--help/-h/--logical/-L/--physical/-P` are exempt.
- **Command validity**: builtin → function (loaded or autoloadable) → abbreviation (command position) → $PATH executable (a word with `/` is checked directly: X_OK and regular file) → implicit cd (path shape `/…`, `./…`, `../…`, `…/`, `..` resolving to a dir). Otherwise Error. Decorations narrow the set (`highlight.rs:231-288`).
- **Error overlays are applied last** (comments, then extra semis, then parse errors) and override everything (`highlight.rs:770-787`). An unclosed quote colors **only the opening quote** red (`:689-692`).
- **Overlay order in the final render** (`reader.rs:1863-1912`): syntax colors → history-search bg (and fg if search_match has a fg) → selection (replaces fully) → the autosuggestion inserted after the typed text in fish_color_autosuggestion.
- **tmux capture normalization:** both shells must be compared through tmux's re-encoded SGR (attributes first, `\e[0m` resets), so compare cell attributes rather than raw bytes.

---

## 5. Keybindings & line-editing commands (default emacs mode)

This section covers fish 4.9.3's default emacs-mode bindings: the complete key → input-function table, how keys are decoded from the terminal (legacy bytes, modifyOtherKeys/kitty, escape timing), and what each editing command does exactly: word/token/path-component motion, kill ring, undo/redo, case and transpose commands, ctrl-c, Enter, and the helper-script bindings (alt-s, alt-p, alt-#, alt-e, alt-l, alt-w, alt-h). All paths are relative to `/Users/darin/vendor/github.com/fish-shell/fish-4.9.3`. History search, the pager, abbreviation expansion and autosuggestion computation are only touched where a key's behavior depends on them.

**How each behavior was checked.** Every behavior has source citations. A behavior marked **Observed** was also run in tmux 3.6a (`tmux -L fishspec-kb`). Everything else comes from reading the source.

**Harness caveats (these affect every section's tests):**
- **The Nix fish is not clean under `env -i`.** It always sources `/etc/fish/nixos-env-preinit.fish`, which runs `fenv source /nix/store/…-set-environment`. That file exports `PAGER="less -R"` and `EDITOR="nano"`, and replaces `PATH` with `/opt/homebrew/bin:…`. To keep the fixture clean, add **`__NIX_DARWIN_SET_ENVIRONMENT_DONE=1`** to the `env -i` line, since the preinit is guarded by `if [ -z "$__NIX_DARWIN_SET_ENVIRONMENT_DONE" ]`. **Observed**: without it, `set -S PAGER` showed `less -R` and alt-p appended `&| less -R`. With it, PAGER/EDITOR/VISUAL were unset and PATH was the fixture PATH. All recipes below assume `EXTRA=__NIX_DARWIN_SET_ENVIRONMENT_DONE=1` is on the env line.
- **tmux eats a trailing `;`.** `tmux send-keys` treats an argument ending in `;` as a command separator, so the `;` is silently dropped (**Observed**). Send `\;`, or keep literal text free of semicolons.
- **Script bindings repaint asynchronously.** Bindings that run a script (alt-p, alt-s, alt-#, alt-d, alt-l, …) repaint after the script finishes. Wait ≥0.5 s before `capture-pane` (**Observed**: a 0.2 s capture showed stale text).
- **Burst typing changes undo/insert granularity** (KB-42). For undo tests, type one character per `send-keys` with about 40 ms between them.
- **`capture-pane -p` mixes in other text.** It drops trailing spaces and includes the grey autosuggestion text. Use `-e` to tell autosuggestion apart from buffer text, and `#{cursor_x}` to find the cursor. With the default prompt `darin@echo ~/w> ` (16 columns), buffer offset = `cursor_x − 16` on a single-line command line.

---

### KB-01 — Binding resolution order and the generic fallback
**Behavior.**
- Bindings live in two lists: **user** bindings (`bind`) and **preset** bindings (`bind --preset`, which is what `fish_default_key_bindings` installs). Each list is sorted by sequence length, longest first.
- Lookup walks the user list, then the preset list, and skips bindings whose mode is not `$fish_bind_mode` (default `default`). The first binding whose every key matches with quality `Exact` wins at once.
- Weaker matches are kept as a deferred candidate. A weaker match is one that matches only modulo shift or base-layout, or is the binding for the lone `escape` key. The best deferred candidate is used when no exact match is found. The `escape` binding is always deferred, so longer `alt-…`/escape sequences take precedence.
- The empty-sequence binding (`bind --preset '' self-insert`) is the generic fallback. It applies when nothing else matches.
- If nothing matches at all, the key is dropped ("no generic found, ignoring char").
- A binding's commands run in order. A name in the input-function table is a readline command, and any other string is run as fish script. If any command is script, a `CheckExit` event is queued first.
- `and`/`or` between commands skip the following commands depending on the previous function's status (e.g. `history-delete or backward-delete-char`).

**Source.** `src/input/binding.rs:340-346` (sorted insert), `src/input/binding.rs:694-765` (`find_binding`: user then preset, defer generic/escape, exact match returns immediately), `src/input/binding.rs:867-894` (execute or drop), `src/input/binding.rs:917-943` (`binding_execute`), `src/input/binding.rs:830-838` (and/or), `share/functions/__fish_shared_key_bindings.fish:106`.
**Test.**
    setup: fixture
    keys:  send-keys 'echo x'; send-keys Escape
    expect: line still `echo x` (escape=cancel does nothing here; no stray char inserted)

### KB-02 — Complete default (emacs) binding table
**Behavior.** After `fish_default_key_bindings` runs (via `__fish_config_interactive` → `__fish_reload_key_bindings`), the following preset bindings exist in mode `default`. There are no user bindings in a clean HOME.

**Observed**: `bind` printed a header comment plus exactly these 96 bindings, the generic `''` binding included. `bind --user` printed nothing, and `bind --list-modes` printed `default`. Bindings listed under the shared file are printed first. Where a key is bound in both files (right, left, home, end), the later `fish_default_key_bindings` line overwrites the earlier one with the same command.

| Key (fish notation) | Input function(s) / script | Defined at |
|---|---|---|
| `''` (generic) | `self-insert` | `__fish_shared_key_bindings.fish:106` |
| `space` `;` `\|` `&` `>` `<` `)` | `self-insert expand-abbr` | `:110-115`, `:119` |
| `enter`, `ctrl-j`, `ctrl-m`, `ctrl-enter` | `execute` | `:124-128` |
| `shift-enter`, `alt-enter` | `commandline -i \n [--search-field]` then `expand-abbr` | `:116-118` |
| `ctrl-space` | `test -n "$(commandline)" && commandline -i " " [--search-field]` (no expand-abbr) | `:120` |
| `shift-space` | `commandline -i " " [--search-field]` then `expand-abbr` | `:122` |
| `tab`, `ctrl-i` | `complete` | `:34-35` |
| `shift-tab` | `complete-and-search` | `:38` |
| `escape`, `ctrl-[` | `cancel` | `:32-33` |
| `ctrl-g` | `cancel` | `fish_default_key_bindings.fish:38` |
| `right`, `ctrl-f` | `forward-char` | `fish_default_key_bindings.fish:20,35` (also shared `:18`) |
| `left`, `ctrl-b` | `backward-char` | `:21,36` (also shared `:19`) |
| `home`, `ctrl-a` | `beginning-of-line` | `:27,30` (also shared `:77`) |
| `end`, `ctrl-e` | `end-of-line` | `:28,31` (also shared `:76`) |
| `alt-<` / `alt->` | `beginning-of-buffer` / `end-of-buffer` | `:55-56` |
| `delete` | `delete-char` | `:23` |
| `backspace`, `shift-backspace`, `ctrl-h` | `backward-delete-char` | `:24-25,32` |
| `ctrl-d` | `delete-or-exit` | shared `:80` |
| `shift-delete` | `history-delete or backward-delete-char` | shared `:39` |
| `alt-b`, `alt-left`, `\e[1;9D` | `prevd-or-backward-word` | shared `:47,53-55` |
| `alt-f`, `alt-right`, `\e[1;9C` | `nextd-or-forward-word` | shared `:48,50-52` |
| `shift-left` / `shift-right` | `backward-bigword` / `forward-bigword` | shared `:44-45` |
| `ctrl-left` / `ctrl-right` | `backward-token` / `forward-token` | shared `:22-23` |
| `ctrl-w` | `backward-kill-path-component` | shared `:75` |
| `alt-backspace`, `ctrl-alt-h` | `backward-kill-word` | `fish_default_key_bindings.fish:49-50` |
| `ctrl-backspace` | `backward-kill-token` | `:51` |
| `alt-delete` | `kill-word` | `:52` |
| `ctrl-delete` | `kill-token` | `:53` |
| `alt-d` | `if test "$(commandline; printf .)" = \n.; __fish_echo dirh; else; commandline -f kill-word; end` | shared `:79` |
| `ctrl-u` / `ctrl-k` | `backward-kill-line` / `kill-line` | shared `:73-74` |
| `ctrl-y` / `alt-y` | `yank` / `yank-pop` | shared `:13,15` |
| `ctrl-t` / `alt-t` | `transpose-chars` / `transpose-words` | `:37,44` |
| `alt-u` / `alt-c` | `upcase-word` / `capitalize-word` (no default `downcase-word`) | `:45,47` |
| `ctrl-/`, `ctrl-_`, `ctrl-z` | `undo` | `:39-41` |
| `ctrl-shift-z`, `alt-/` | `redo` | `:42-43` |
| `ctrl-c` | `clear-commandline` | shared `:72` |
| `ctrl-l` | `status test-terminal-feature scroll-content-up && commandline -f scrollback-push`, then `clear-screen` | shared `:69-71` |
| `ctrl-x` / `ctrl-v` | `fish_clipboard_copy` / `fish_clipboard_paste` | shared `:29-30` |
| `ctrl-s` | `pager-toggle-search` | shared `:36` |
| `ctrl-r` | `history-pager` | `fish_default_key_bindings.fish:58` |
| `up`, `ctrl-p` / `down`, `ctrl-n` | `up-or-search` / `down-or-search` (functions) | shared `:41-42`; `:33-34` |
| `pageup` / `pagedown` | `beginning-of-history` / `end-of-history` | shared `:25-26` |
| `alt-up`, `alt-.`, `\e[1;9A` | `history-token-search-backward` | shared `:57,60,64` |
| `alt-down`, `\e[1;9B` | `history-token-search-forward` | shared `:58,61` |
| `alt-l` | `__fish_list_current_token` | shared `:66` |
| `alt-o` | `__fish_preview_current_file` | shared `:67` |
| `alt-w` | `__fish_whatis_current_token` | shared `:68` |
| `f1`, `alt-h` | `__fish_man_page` | shared `:85-86` |
| `alt-p` | `__fish_paginate` | shared `:91` |
| `alt-#` | `__fish_toggle_comment_commandline` | shared `:95` |
| `alt-e`, `alt-v` | `edit_command_buffer` | shared `:98-99` |
| `alt-s` | `for cmd in sudo doas please run0; if command -q $cmd; fish_commandline_prepend $cmd; break; end; end` | shared `:82` |
| `\e\x20ep` (only if `$TERM` = `xterm-256color`) | `fish_clipboard_paste` (ConEmu) | `fish_default_key_bindings.fish:61-66` |

Keys with **no** default binding: `ctrl-o`, `ctrl-q`, `ctrl-\`, `ctrl-]`, `insert`, `f2`–`f12`, alt-letters other than those listed, and so on. They hit the generic `self-insert`, which inserts nothing for modified or control keys (KB-09).

**Source.** `share/functions/fish_default_key_bindings.fish:1-67`, `share/functions/__fish_shared_key_bindings.fish:7-129`, `share/functions/__fish_config_interactive.fish:62-111`.
**Test.**
    setup: fixture
    keys:  send-keys 'bind > $HOME/b.txt' Enter
    expect: $H/b.txt has 97 lines (1 header comment + 96 bindings) matching the table (first line `# Defined in embedded:functions/fish_default_key_bindings.fish:`)
**Observed.** Yes.

### KB-03 — Built-in fallback bindings (no binding function loaded)
**Behavior.** If the preset list is empty when input is initialized, Rust installs these bindings, each with `sets_mode default`:
- `''` → self-insert, `enter` → execute, `tab` → complete
- `ctrl-c` → **cancel-commandline**, `ctrl-d` → **exit**, `ctrl-e` → **bind**
- `ctrl-s` → pager-toggle-search, `ctrl-u` → backward-kill-line, `backspace` → backward-delete-char
- `up`/`ctrl-p` → up-line, `down`/`ctrl-n` → down-line
- `right`/`ctrl-f` → forward-char, `left`/`ctrl-b` → backward-char
- raw `\e[A`, `\e[B`, `\e[C`, `\e[D`

This is what `fish -ic bind` lists, because `-c` never reaches the first prompt where the key bindings get loaded. **Observed**: `fish -ic bind` printed exactly this set.

**Source.** `src/input/binding.rs:415-480`.
**Test.**
    setup: fixture env
    keys:  (shell) env -i … fish -ic bind
    expect: 21 lines incl. `bind --preset ctrl-c cancel-commandline`, `bind --preset ctrl-d exit`
**Observed.** Yes.

### KB-04 — Legacy byte → key canonicalization
**Behavior.** For single bytes, without CSI-u:
- `0x0d` → `enter`, `0x09` → `tab`, `0x20` → `space`.
- The tty's startup **VERASE** byte (normally `0x7f`) → `backspace`. `0x7f`, when it is not VERASE, → `delete`.
- `0x1b` → `escape`.
- `0x00` → `ctrl-space`.
- `0x01`–`0x1a` → `ctrl-a`…`ctrl-z`. This includes `0x08` → `ctrl-h` (distinct from backspace) and `0x0a` → `ctrl-j`.
- `0x1c`–`0x1f` → `ctrl-\`, `ctrl-]`, `ctrl-^`, `ctrl-_`.

Consequences:
- `ctrl-/` (sent by terminals as `0x1f`) arrives as **ctrl-_**.
- `ctrl-[`, `ctrl-i` and `ctrl-m` arrive as escape/tab/enter. Their own bindings match only when the terminal sends a CSI-u/modifyOtherKeys encoding.
- `ESC` + byte, when not a CSI/SS3/OSC/DCS introducer, adds `alt` to the decoded key. `ESC ESC` → `alt-escape`.

**Source.** `src/key.rs:169-180`, `src/key.rs:186-209`, `src/key.rs:211-226`, `src/input/decode.rs:92-115`, `src/input/decode.rs:150-189`, tests `src/input/decode.rs:889-919`.
**Test.**
    setup: fixture
    keys:  send-keys 'fish_key_reader -c -V' Enter; send-keys C-h; send-keys BSpace; send-keys C-/
    expect: `bind ctrl-h`, `bind backspace` (decoded from \x7f), `bind ctrl-_` (decoded from \x1f)
**Observed.** Yes.

### KB-05 — Keyboard-protocol negotiation (what fish asks the terminal for)
**Behavior.**
- **At startup**, fish writes:
  - `CSI ? u` (kitty progressive-enhancement query)
  - `CSI > 0 q` (XTVERSION)
  - `OSC 11 ; ? ST`
  - XTGETTCAP for `indn` and `query-os-name`, wrapped in `\e[?1049h`/`\e[?1049l`, and skipped when `$STY` is set or `TERM` is `screen*`
  - `CSI 0 c`
- **Protocol choice:**
  - A reply to `CSI ? u` → kitty: enable with `\e[=5u`, disable with `\e[=0u`.
  - No reply → "other": `\e[>4;1m` (modifyOtherKeys 1) plus `\e=` (DECKPAM). WezTerm gets only `\e=`.
  - Midnight Commander → none.
  - iTerm2 < 3.5.12 and Konsole → "other".
- **Always added:**
  - Bracketed paste (`\e[?2004h`).
  - Focus reporting (`\e[?1004h`) only under tmux.
  - Color-theme reporting (`\e[?2031h`), except under tmux < 3.7.
- Protocols are enabled while fish reads a command line, and disabled before running commands, bind scripts, and while computing completions.

**Under tmux 3.6a** (**Observed** via `fish -d reader`): XTVERSION `tmux 3.6a` and DA1 replies arrive, with no kitty reply and no XTGETTCAP reply. fish logs "Enabling other extended keys", i.e. modifyOtherKeys 1 + DECKPAM, and `scroll-content-up` is unsupported.

**Source.** `src/reader/reader.rs:272-284`, `src/reader/reader.rs:2992-3006`, `src/tty_handoff.rs:79-96`, `src/tty_handoff.rs:155-174`, `src/tty_handoff.rs:177-227`, `src/terminal.rs:306-333`, `src/reader/reader.rs:2619-2628`, `src/reader/reader.rs:2689-2697`, `src/reader/reader.rs:3207-3211`.
**Test.**
    setup: fixture with `fish -d reader -o $H/log`
    keys:  (none)
    expect: log contains `Received XTVERSION response: tmux 3.6a` and `Enabling other extended keys`
**Observed.** Yes.

### KB-06 — Escape vs. alt disambiguation (timeouts)
**Behavior.**
- **Decoder.** After reading `0x1b`, the decoder waits **1 ms** for the next byte. If none arrives, it emits `escape`. If the next byte is `[`, `O`, `]` or `P`, it parses CSI/SS3/OSC/DCS; later bytes of a sequence each get a 30 ms timeout (300 ms during a paste or a terminal query). Any other byte becomes `alt-<key>`.
- **Binding matcher.** When the matcher sees a lone `escape` event (seq `\e`) while trying an `alt-X` binding, it waits up to **`fish_escape_delay_ms`** for the next key. The default is **30 ms**; valid values are 10 ≤ v < 5000, and anything else is rejected with the message `ignoring fish_escape_delay_ms: value '…' is not an integer or is < 10 or >= 5000 ms`. If X arrives in time, the pair matches `alt-X`. So ESC typed and then `x` within 30 ms = `alt-x`.
- **A lone Escape** therefore costs one ≤30 ms wait. It then runs the deferred `escape` binding (`cancel`).
- Feature flag `omit-term-workarounds` replaces the 30/300 ms timeouts with 10 s.

tmux `send-keys M-x` writes `\ex` atomically, so it decodes as `alt-x`, and `send-keys Escape` writes a lone `\e` (**Observed** with fish_key_reader).

**Source.** `src/input/input.rs:291-323` (default 30, range check), `src/input/input.rs:520-522`, `src/input/input.rs:703-741` (1 ms / 30 ms / 300 ms), `src/input/decode.rs:150-189`, `src/input/binding.rs:540-578` (delayed-escape alt match), `src/input/binding.rs:728-747` (escape deferred).
**Test.**
    setup: fixture
    keys:  send-keys 'echo aaa bbb'; send-keys Escape; sleep 0.01; send-keys -l b
    expect: cursor moves to start of `bbb` (ESC+b within 30 ms acts as alt-b); with `sleep 0.2` instead, `b` is inserted (`echo aaa bbbb`)

### KB-07 — `fish_sequence_key_delay_ms` (multi-key bindings)
**Behavior.** When a binding has several keys (e.g. user `bind ctrl-x,ctrl-e …`), the matcher waits for the next key forever by default. If `fish_sequence_key_delay_ms` is set (10 ≤ v < 5000), it waits only that long, then falls back to shorter matches. No default emacs binding has more than one key except the raw iTerm2 workarounds `\e[1;9A`–`\e[1;9D`, and the ConEmu `\e\x20ep`.
**Source.** `src/input/input.rs:297-298`, `src/input/input.rs:325-348`, `src/input/input.rs:524-530`, `src/input/binding.rs:556-565`.
**Test.**
    setup: fixture; run `bind ctrl-x,ctrl-e 'commandline -i X'` and `set -g fish_sequence_key_delay_ms 100`
    keys:  send-keys C-x; sleep 0.3; send-keys C-e
    expect: no `X` inserted (sequence timed out); C-x then C-e within 100 ms inserts `X`

### KB-08 — What tmux 3.6a actually delivers (extended-keys on, fish requesting modifyOtherKeys)
**Behavior.** The decoded key names, as printed by `fish_key_reader -c -V`:

| tmux key | bytes | fish key |
|---|---|---|
| `C-Space` | `\x00` | `ctrl-space` |
| `M-Enter` | `\e\r` | `alt-enter` |
| `S-Enter` | `\e[27;2;13~` | `shift-enter` |
| `C-Enter` | `\e[27;5;13~` | `ctrl-enter` |
| `S-Space` | `\e[27;2;32~` | `shift-space` |
| `C-BSpace` | `\e[27;5;127~` | `ctrl-backspace` |
| `M-BSpace` | `\e\x7f` | `alt-backspace` |
| `C-h` | `\x08` | `ctrl-h` |
| `C-M-h` | `\e\x08` | `ctrl-alt-h` |
| `DC` | `\e[3~` | `delete` |
| `C-DC` | `\e[3;5~` | `ctrl-delete` |
| `M-DC` | `\e[3;3~` | `alt-delete` |
| `S-DC` | `\e[3;2~` | `shift-delete` |
| `C-/`, `C-_` | `\x1f` | `ctrl-_` |
| **`C-S-z`** | **`\x1a`** | **`ctrl-z`** (redo via ctrl-shift-z is unreachable in tmux; use `M-/`) |
| `M-/` | `\e/` | `alt-/` |
| `C-Left`/`C-Right` | `\e[1;5D`/`\e[1;5C` | `ctrl-left`/`ctrl-right` |
| `M-Left`/`M-Right` | `\e[1;3D`/`\e[1;3C` | `alt-left`/`alt-right` |
| `S-Left`/`S-Right` | `\e[1;2D`/`\e[1;2C` | `shift-left`/`shift-right` |
| `M-Up`/`M-Down` | `\e[1;3A`/`\e[1;3B` | `alt-up`/`alt-down` |
| `Home`/`End` | `\e[1~`/`\e[4~` | `home`/`end` |
| `PPage`/`NPage` | `\e[5~`/`\e[6~` | `pageup`/`pagedown` |
| `F1` | `\eOP` | `f1` |
| `Escape`, `C-[` | `\e` | `escape` |
| `BTab` | `\e[Z` | `shift-tab` |
| `Tab`, `C-i` | `\t` | `tab` |
| `C-m` | `\r` | `enter` |
| `C-j` | `\n` | `ctrl-j` |
| `M-x` (any letter / `.` `#` `<` `>`) | `\ex` | `alt-x` |

`S-Enter`, `C-Enter`, `S-Space` and `C-BSpace` are distinguishable only because `extended-keys on` lets tmux honor fish's modifyOtherKeys request. Without it, they degrade to `\r`, `\r`, ` ` and `\x7f`/`\x08`.

**Source.** decoding paths `src/input/decode.rs:388-414` (`CSI 27;mod;key ~`), `src/input/decode.rs:546-591` (SS3), `src/input/decode.rs:534` (`CSI Z`).
**Test.**
    setup: fixture
    keys:  send-keys 'fish_key_reader -c -V' Enter; send-keys C-S-z
    expect: `# decoded from: \x1a` / `bind ctrl-z 'do something'`
**Observed.** Yes, the whole table.

### KB-09 — self-insert: what gets inserted; read-ahead batching
**Behavior.**
- **What a key inserts.** A key inserts text only if it has no modifiers left after shift is applied to a shifted codepoint. Space, enter and tab map to ` `, `\n` and `\t`. Codepoints ≤ 27 and private-use (named) keys insert nothing. A kitty "associated text" overrides all of this.
- **Unbound modified keys** (`alt-z`, `ctrl-o`, `ctrl-q`, `f5`, …) therefore insert **nothing** and do nothing else.
- **Read-ahead batching.** While more input is immediately readable, ordinary characters are batched, up to 256, into **one** `insert_string`. The batch ends:
  - at the first event that is not a character, such as the readline commands queued after `space`/`;`/`|`/… because of `expand-abbr`;
  - or when the character just read is the last one available, which is then inserted separately.
- After any insertion, `last_cmd` is cleared. This breaks kill-append chains (KB-30) and yank-pop (KB-32).

**Source.** `src/input/input.rs:210-246` (`text_to_insert`/`codepoint_text`), `src/input/binding.rs:789-829`, `src/reader/reader.rs:1324` (`READAHEAD_MAX = 256`), `src/reader/reader.rs:2714-2764` (`read_normal_chars`), `src/reader/reader.rs:2870-2890`.
**Test.**
    setup: fixture
    keys:  send-keys 'ab'; send-keys M-z; send-keys C-o
    expect: line `ab`, cursor at end, nothing else inserted

### KB-10 — forward-char (`right`, `ctrl-f`)
**Behavior.**
- **Pager navigation:** select the completion to the east.
- **Cursor at the autosuggestion** (cursor offset == end of the suggestion's search range, i.e. end of the typed line): accept the **entire** autosuggestion. The search range is replaced by the full suggestion text, and the cursor moves to its end.
- **Otherwise,** if not at the end, move right by one codepoint (not grapheme). At the end with no suggestion, nothing happens.

**Source.** `src/reader/reader.rs:3593-3608`, `src/reader/reader.rs:5627-5648`, `src/reader/reader.rs:5679-5683`.
**Test.**
    setup: history has `echo hello` (fixture)
    keys:  send-keys 'ec'; send-keys Right
    expect: line `echo hello`, cursor at col 26 (end)

### KB-11 — backward-char (`left`, `ctrl-b`)
**Behavior.** In the pager, select west. Otherwise, if the position is not 0, move left by one codepoint. This never touches the autosuggestion, which stays displayed only while the cursor is at its anchor.
**Source.** `src/reader/reader.rs:3577-3584`.
**Test.**
    setup: fixture
    keys:  send-keys 'abc'; send-keys Left Left
    expect: cursor_x = 17 (offset 1)

### KB-12 — beginning-of-line (`home`, `ctrl-a`) in single/multi-line buffers
**Behavior.** Moves left until position 0 or until the previous character is `\n`, i.e. to the start of the **current logical line**, never the whole buffer. Indentation on continuation lines is display-only (KB-46), so the cursor lands right after the indent.
**Source.** `src/reader/reader.rs:3028-3041`.
**Test.**
    setup: fixture
    keys:  send-keys 'if true' Enter; send-keys 'echo x'; send-keys C-a
    expect: cursor at col 20 row of `echo x` (line start; 16 prompt-width offset + 4 indent)
**Observed.** Yes (cursor 20,3).

### KB-13 — end-of-line (`end`, `ctrl-e`) and autosuggestion
**Behavior.**
- **Cursor at the autosuggestion anchor:** accept the suggestion **only up to its first newline** (`AutosuggestionPortion::Line`). If the remaining suggestion starts with `\n`, nothing is accepted.
- **Otherwise,** if not at the end, move right until the end of the buffer or until the character under the cursor is `\n`, i.e. to the end of the current logical line.

**Source.** `src/reader/reader.rs:3042-3066`, `src/reader/reader.rs:5697-5710`.
**Test.**
    setup: fixture
    keys:  send-keys 'if true' Enter 'echo x'; send-keys Up; send-keys C-e
    expect: cursor at col 23 on the `if true` row (end of line 1)
**Observed.** Yes (23,2).

### KB-14 — beginning-of-buffer / end-of-buffer (`alt-<`, `alt->`)
**Behavior.** `alt-<` sets the cursor to offset 0 of the whole command line. `alt->` accepts the **whole** autosuggestion if the cursor is at its anchor. Otherwise it moves the cursor to the end of the buffer.
**Source.** `src/reader/reader.rs:3067-3080`.
**Test.**
    setup: fixture
    keys:  send-keys 'if true' Enter 'echo x'; send-keys 'M-<'; (check) send-keys 'M->'
    expect: after M-<: cursor 16 on row of `if true`; after M->: cursor 26 on `echo x` row
**Observed.** Yes.

### KB-15 — Word character classes (used by word motions)
**Behavior.** `WordCharClass::from_char(c)` works as follows:
- **Latin-1 (`c < U+0100`):**
  - `\n` → Newline.
  - space, `\t`, NUL, NBSP (U+00A0) → Blank.
  - ASCII alphanumerics and `À`..`ÿ` except `×` and `÷` → Word.
  - **everything else → Punctuation.** That includes `_ - . / = , : @ # ' " ~ $ * ( ) [ ] { }`, and Latin-1 symbols like `§ © « ª µ º`.
  - Note: **underscore is Punctuation.**
- **Above Latin-1:**
  - an emoji table lookup → Emoji.
  - otherwise a sorted interval table (from vim's `mbyte.c`): Unicode spaces U+1680, U+2000–200B, U+2028–2029, U+202F, U+205F, U+3000 → Blank; many punctuation/symbol ranges → Punctuation; plus Superscript, Subscript, Braille, Hiragana, Katakana, Cjk and Hangul ranges.
  - anything else → Word.
- **"Bigword"** classes: `\n` → Newline, Blank as above, everything else → Word.

**Source.** `crates/widestring/src/word_char.rs:7-20`, `crates/widestring/src/word_char.rs:28-65`, `crates/widestring/src/word_char.rs:102-178`, `crates/widestring/src/word_char.rs:181-328`, `src/reader/word_motion.rs:132-140`.
**Test.**
    setup: fixture
    keys:  send-keys 'echo foo_bar'; send-keys M-b
    expect: cursor offset 9 (start of `bar`; `_` is its own word)
**Observed.** Yes (see KB-17).

### KB-16 — Word-motion state machine (shared by word/bigword commands)
**Behavior.** A state machine consumes one character at a time. `last` is the previous character's class, absent at first. The **first** character is always consumed. After that, with `cur` = this character's class:

- **Machine direction Left:**
  - `last` = Blank → never stop.
  - `last` = Newline → stop only if `cur` = Newline.
  - otherwise → stop if `cur` is Blank, Newline, or a different class.
- **Machine direction Right:**
  - `last` = Blank → stop if `cur` is not Blank/Newline.
  - `last` = Newline → stop if `cur` is not Blank.
  - otherwise → stop only if `cur` is a different non-blank, non-newline class.

The "stopping" character is not consumed.

`move_word(dir, erase, style, newv, to_word_end)` runs the machine in direction `dir`, or the **opposite** direction when `to_word_end` is set. With `b` = start position and `len` = buffer length:

- **Right, plain:** while `b != len`: consume `text[b]`, then `b++`.
- **Right, to_word_end:** while `b != len-1`: consume `text[b+1]`, then `b++`. `b` ends **on** the last character of the word.
- **Left, plain:** while `b != 0`: consume `text[b-1]`, then `b--`.
- **Left, to_word_end:** starts on the character under the cursor. If `b == len` it first steps to `len-1`; it consumes `text[b]`, then `b--`, and an underflow means 0.
- **No erase:** set the cursor to `b`.
- **Erase, Right:** kill `start..b(+1 if to_word_end)`, appending.
- **Erase, Left:** kill `b..start(+1 if to_word_end)`, prepending.
- If the cursor is already at the boundary (0 going left, `len` going right), it does nothing.

**Source.** `src/reader/word_motion.rs:161-221`, `src/reader/reader.rs:2239-2336`; unit tests `src/reader/word_motion.rs:474-519`.
**Test.** (see KB-17..KB-20)

### KB-17 — backward-word / prevd (`alt-b`, `alt-left`)
**Behavior.**
- **Empty command line:** run `prevd` (cd to the previous directory in `$dirprev`), then repaint. The prompt redraws in place on the same row with the new PWD, and nothing is printed.
- **Otherwise:** `move_word(Left, no erase, Punctuation, to_word_end=false)`. It skips blanks to the left, then moves over one run of same-class characters, so every punctuation run is its own word.
- **Observed stops** going left from the end of `echo foo_bar/baz.txt  --opt=val` (offsets): 28 27 24 22 17 16 13 12 9 8 5 0.

**Source.** `src/reader/reader.rs:3802-3832`, `src/reader/reader.rs:3808-3812` (prevd), `src/reader/word_motion.rs:201-206`.
**Test.**
    setup: fixture
    keys:  send-keys 'echo foo_bar/baz.txt  --opt=val'; repeat send-keys M-b, reading cursor_x-16 each time
    expect: 28 27 24 22 17 16 13 12 9 8 5 0 0
    (empty-line variant) setup: mkdir $W/sub; keys: 'cd sub' Enter; M-Left → prompt shows `~/w>`; M-Right → back to `~/w/sub>`
**Observed.** Yes, both.

### KB-18 — forward-word / nextd (`alt-f`, `alt-right`): emacs "to end of word"
**Behavior.**
- **Empty command line:** run `nextd`, then repaint.
- **Cursor at the autosuggestion anchor:** accept the next word of the suggestion. The machine runs Left-direction starting at the first unaccepted suggestion character: blanks first, then one class run.
- **"At word end":** `pos+1 < len`, and `class(text[pos])` is not Blank/Newline, and `class(text[pos+1]) != class(text[pos])`. Then move just one character right.
- **Otherwise:** `move_word(Right, to_word_end=true)` puts the cursor **on** the last character of the next word, then the cursor goes one further, to just past the word (if `< len`). The net effect is emacs-style: the cursor ends just after the end of the current/next word.
- **Observed stops** from 0 on `echo foo_bar/baz.txt  --opt=val`: 4 8 9 12 13 16 17 20 24 27 28 31.

**Source.** `src/reader/reader.rs:3617-3680`, `src/reader/reader.rs:5711-5733`.
**Test.**
    setup: fixture
    keys:  send-keys 'echo foo_bar/baz.txt  --opt=val'; send-keys C-a; repeat M-f
    expect: offsets 4 8 9 12 13 16 17 20 24 27 28 31 31
**Observed.** Yes.

### KB-19 — backward-bigword (`shift-left`)
**Behavior.** Same as KB-17 but with bigword classes: only blanks and newlines separate words. There is no prevd behavior.
**Source.** `src/reader/reader.rs:3815-3831` (style Whitespace), `src/reader/word_motion.rs:132-151`.
**Test.**
    setup: fixture
    keys:  send-keys 'echo foo_bar/baz.txt  --opt=val'; repeat S-Left
    expect: offsets 22 5 0
**Observed.** Yes.

### KB-20 — forward-bigword (`shift-right`)
**Behavior.** Same as KB-18 (to end of the bigword, then +1; accepts one bigword of the autosuggestion), with Whitespace classes and no nextd behavior.
**Source.** `src/reader/reader.rs:3617-3680` (ForwardBigwordEmacs → Whitespace).
**Test.**
    setup: fixture
    keys:  send-keys 'echo foo_bar/baz.txt  --opt=val'; C-a; repeat S-Right
    expect: offsets 4 20 31
**Observed.** Yes.

### KB-21 — backward-token (`ctrl-left`)
**Behavior.** Tokens are the tokenizer's **String** tokens inside the innermost command substitution around the cursor. Pipes, `;`, `&` and redirection operators are not tokens.
- Get `(tok, prev)` from `get_token_extent(text, pos)`. The cursor counts as inside a token when `tok.start ≤ pos ≤ tok.end`. Between tokens, `tok` is the empty range at `pos`.
- If `pos == 0`, do nothing.
- If `tok.start != pos`, go to `tok.start`.
- Otherwise, if there is a previous token (`prev.start != pos`), go to `prev.start`.
- Otherwise go to `cmdsubst_start − 1`, i.e. onto the `(`, or 0 if not in a command substitution.

Quotes stay part of a token: `"d e/f"` is one token.

**Source.** `src/reader/reader.rs:3759-3765`, `src/reader/reader.rs:4404-4426`, `src/parse_util.rs:453-510`, `src/parse_util.rs:155-188`.
**Test.**
    setup: fixture
    keys:  send-keys 'echo foo_bar/baz.txt  --opt=val'; repeat C-Left
    expect: offsets 22 5 0
**Observed.** Yes.

### KB-22 — forward-token (`ctrl-right`)
**Behavior.**
- **Cursor at the autosuggestion anchor:** use buffer+suggestion. Find the first String token end greater than `pos`, and accept suggestion characters up to it.
- **Otherwise, if not at the end:** move to the first String-token end greater than `pos` inside the current command substitution. If there is none, move to the end of the buffer.

**Source.** `src/reader/reader.rs:3784-3801`, `src/reader/reader.rs:4428-4464`.
**Test.**
    setup: fixture
    keys:  send-keys 'echo foo_bar/baz.txt  --opt=val'; C-a; repeat C-Right
    expect: offsets 4 20 31
**Observed.** Yes.

### KB-23 — backward-kill-path-component (`ctrl-w`)
**Behavior.** It kills to the left, using a path-component state machine that consumes `text[pos-1]`, `text[pos-2]`, ….

Each character first gets a transition:
- An **unescaped `\`** is skipped transparently: consumed, state unchanged.
- An **unescaped blank** (Blank class: space, tab, NUL, NBSP, Unicode spaces; *not* `\n`) → **B**.
- An **escaped character** (odd number of preceding backslashes), or a *path character* → **C**. A path character is any tokenizer string character (not NUL, space, `\n`, `|`, `\t`, `;`, `\r`, `<`, `>`, `&`) that is also not one of `/ = { , } ' " : @ #`.
- Anything else → **P**: `/ = { , } ' " : @ # | ; < > &`, and `\n`.

States:
- **Initial:** B → Space; C → PathComponent; P → Punctuation.
- **Punctuation:** B → stop; C → EndPathComponent; P → Punctuation.
- **PathComponent:** B → stop; C → EndPathComponent; P → stop.
- **Space:** B → Space; C → PathComponent; P → EndPunctuation.
- **EndPathComponent:** C → EndPathComponent; B or P → stop.
- **EndPunctuation:** P → EndPunctuation; B or C → stop.

The net effect: a trailing separator (`/`) is killed **together with** the component before it; blanks before the cursor are killed with the preceding word; `-`, `.`, `_`, `~`, `*`, `$`, `(`, `)`, `[`, `]` are path characters. Quotes are not understood: an unescaped space inside `"…"` still stops.

Kill-ring: each `ctrl-w` press creates a **new** kill-ring entry, even when pressed repeatedly. `newv` is false only if the previous command was `backward-kill-word` or `backward-kill-bigword` (KB-30).

Observed sequences (repeated `ctrl-w`; `|` marks end of line):
- `echo foo_bar/baz.txt  --opt=val`: kills `val`, `--opt=`, `baz.txt  `, `foo_bar/`, `echo `.
- `ls a\ b/c "d e/f" g@h:i#j`: kills `j`, `i#`, `h:`, `g@`, `" `, `f`, `e/`, `d `, `"`, `c `, `a\ b/`, `ls `.

**Source.** `src/reader/reader.rs:3681-3702`, `src/reader/word_motion.rs:223-255`, `src/reader/word_motion.rs:304-367`, `src/reader/reader.rs:6663-6678` (`is_backslashed`), `src/tokenizer.rs:867-881`; unit tests `src/reader/word_motion.rs:450-463`.
**Test.**
    setup: fixture
    keys:  send-keys 'ls a\ b/c "d e/f" g@h:i#j'; repeat C-w, capturing the line each time
    expect: successive lines `ls a\ b/c "d e/f" g@h:i#`, `…g@h:`, `…g@`, `ls a\ b/c "d e/f" `, `ls a\ b/c "d e/f`, `ls a\ b/c "d e/`, `ls a\ b/c "d `, `ls a\ b/c "`, `ls a\ b/c `, `ls a\ b/`, `ls `, ``
**Observed.** Yes.

### KB-24 — backward-kill-word (`alt-backspace`, `ctrl-alt-h`)
**Behavior.** Kills exactly the span backward-word would move over: `move_word(Left, erase, Punctuation)`. The text is **prepended** to the current kill item when the previous command was `backward-kill-word` or `backward-kill-bigword`. Otherwise it starts a new kill-ring entry. It suppresses the autosuggestion.
**Source.** `src/reader/reader.rs:3681-3702`, `src/reader/reader.rs:2312-2332`.
**Test.**
    setup: fixture
    keys:  type 'echo aaa bbb ccc'; send-keys M-BSpace; send-keys M-BSpace; send-keys C-y
    expect: after 2 kills line `echo aaa ` (cursor 25); after C-y `echo aaa bbb ccc` (merged entry `bbb ccc`)
**Observed.** Yes.

### KB-25 — kill-word (`alt-delete`; `alt-d` on a non-empty line)
**Behavior.**
- **"At word end"** (same test as KB-18): delete just the one character under the cursor with `delete_char`. **This is not added to the kill ring.**
- **Otherwise:** kill from the cursor to just past the end of the next word (`move_word(Right, erase, Punctuation, to_word_end=true)`), **appending** to the kill item if the previous command was also kill-word. Leading blanks are included.
- `alt-d` runs the script `commandline -f kill-word`. That sets `last_cmd = kill-word`, so repeated alt-d presses chain, and the skipped single-character deletes are missing from the chained kill item.
- **Empty command line** (exactly `""`): `alt-d` runs `__fish_echo dirh`. The directory history is printed below the prompt line, as ` N) dir` lines, then the current dir indented 4 spaces in `fish_color_history_current`, then an empty line. A fresh prompt follows; the old prompt line stays on screen.

**Source.** `src/reader/reader.rs:3617-3680`, `share/functions/__fish_shared_key_bindings.fish:79`, `share/functions/__fish_echo.fish:2-10`, `share/functions/dirh.fish:12-31`, `src/reader/reader.rs:2205-2229`.
**Test.**
    setup: fixture
    keys:  type 'echo foo_bar/baz.txt  --opt=val'; C-a; repeat M-d 12×; then C-y
    expect: successive lines ` foo_bar/…`, `_bar/…`, `bar/…`, `/baz…`, `baz.txt…`, `.txt…`, `txt…`, `  --opt=val`, `opt=val`, `=val`, `val`, ``; C-y yields `echo foobarbaztxt  --optval`
**Observed.** Yes, including the dirh output for an empty line.

### KB-26 — backward-kill-token (`ctrl-backspace`)
**Behavior.** Kills from the backward-token target (KB-21) to the cursor. It prepends when the previous command was also backward-kill-token, and suppresses the autosuggestion.
**Source.** `src/reader/reader.rs:3741-3758`.
**Test.**
    setup: fixture (extended-keys on is required; C-BSpace → `\e[27;5;127~`)
    keys:  type 'echo foo/bar baz'; send-keys C-BSpace; send-keys C-BSpace
    expect: `echo foo/bar ` then `echo `

### KB-27 — kill-token (`ctrl-delete`)
**Behavior.** Kills from the cursor to the forward-token target (KB-22; buffer only, never the suggestion). It appends when the previous command was also kill-token, and suppresses the autosuggestion. At the end of the buffer it does nothing.
**Source.** `src/reader/reader.rs:3766-3783`, `src/reader/reader.rs:4428-4464`.
**Test.**
    setup: fixture
    keys:  type 'echo foo/bar baz'; C-a; send-keys C-DC
    expect: ` foo/bar baz`

### KB-28 — backward-kill-line (`ctrl-u`)
**Behavior.**
- At position 0: nothing.
- Otherwise, kill from the start of the current logical line (just after the previous `\n`, or 0) up to the cursor, at least 1 character. The text is prepended to the kill item if the previous command was also backward-kill-line, otherwise it is a new entry.
- Suppresses the autosuggestion.
- In a multi-line buffer, only the current line's prefix is killed.

**Source.** `src/reader/reader.rs:3262-3295`.
**Test.**
    setup: fixture
    keys:  send-keys 'if true' Enter; type 'echo x'; send-keys Up C-e Down; send-keys C-u
    expect: second line becomes `o x` (cursor was at column 3 of `echo x` after Down; see KB-65)
**Observed.** Yes.

### KB-29 — kill-line (`ctrl-k`)
**Behavior.** Kills from the cursor to just before the next `\n`, or to the end of the buffer. If that range is empty and a character follows (the cursor sits on a `\n`), the newline itself is killed. The text is appended if the previous command was also kill-line.
**Source.** `src/reader/reader.rs:3237-3261`.
**Test.**
    setup: fixture
    keys:  type 'echo aaa bbb ccc'; M-b M-b; send-keys C-k
    expect: `echo aaa ` cursor 25
**Observed.** Yes.

### KB-30 — Kill ring structure and append/prepend rules
**Behavior.**
- **Structure.** The kill ring is an unbounded deque, newest first, shared by all kill commands. It is separate from the system clipboard: kills do **not** call `fish_clipboard_copy`.
- **New kill** (`newv` true): the killed text becomes the current kill item and is pushed to the front, unless it is empty.
- **Continued kill:** the item is extended. Append is used by forward kills (kill-line, kill-word, kill-token). Prepend is used by backward kills (backward-kill-line, backward-kill-word, backward-kill-token). The old string is then removed from the ring and the extended one pushed to the front.
- **When a kill continues** (`newv` false):
  - kill-line, backward-kill-line, kill-word, kill-token, backward-kill-token: only when the previous command was the **same** command.
  - backward-kill-word and backward-kill-bigword: when the previous command was either of those two.
  - **backward-kill-path-component (ctrl-w): never.** A ctrl-w after alt-backspace *does* prepend to the alt-backspace item, but ctrl-w after ctrl-w does not.
- **"Previous command"** is `last_cmd`. It is cleared by any character insertion. It is not changed by script-binding events themselves, but is set by `commandline -f` (KB-69). Rendering-only commands (repaint, clear-screen) don't change it.

**Source.** `src/kill.rs:28-53`, `src/reader/reader.rs:1950-1973`, `src/reader/reader.rs:3258`, `:3293`, `:3669`, `:3689-3692`, `:3756`, `:3781`, `src/reader/reader.rs:2759-2760`, `src/reader/reader.rs:2863-2865`, `src/reader/reader.rs:6334-6341`.
**Test.**
    setup: fixture
    keys:  type 'echo aaa/bbb/ccc'; C-w; C-w; C-y
    expect: after 2×C-w `echo aaa/`; C-y → `echo aaa/bbb/` (separate entries: ring = [`bbb/`,`ccc`])
**Observed.** Yes.

### KB-31 — yank (`ctrl-y`)
**Behavior.** Inserts the front kill-ring entry at the cursor (an empty string if the ring is empty) and leaves the cursor after it. The inserted length is remembered as `yank_len`, for yank-pop. The insertion coalesces into undo like typed text only if it is a single character (KB-42).
**Source.** `src/reader/reader.rs:3346-3356`, `src/kill.rs:45-47`.
**Test.**
    setup: fixture
    keys:  type 'echo aaa bbb ccc'; M-b M-b; C-k; C-u; C-y
    expect: `echo aaa ` cursor 25
**Observed.** Yes.

### KB-32 — yank-pop (`alt-y`)
**Behavior.** Works only if `yank_len != 0`. `yank_len` is reset to 0 by any readline command whose predecessor was not yank/yank-pop, and character insertion clears `last_cmd`, so alt-y must directly follow ctrl-y or alt-y. It rotates the ring left by one, so the front entry moves to the back, then replaces the previously yanked text immediately left of the cursor with the new front entry. It suppresses the autosuggestion.
**Source.** `src/reader/reader.rs:3357-3374`, `src/reader/reader.rs:2828-2834`, `src/kill.rs:50-53`.
**Test.**
    setup: fixture
    keys:  type 'echo aaa/bbb/ccc'; C-w C-w C-y; M-y; M-y
    expect: `echo aaa/bbb/` → `echo aaa/ccc` → `echo aaa/bbb/`
**Observed.** Yes.

### KB-33 — backward-delete-char (`backspace`, `shift-backspace`, `ctrl-h`)
**Behavior.** At position 0: nothing. Otherwise it deletes one codepoint left of the cursor, then keeps deleting further left while the deleted codepoint has wcwidth 0 and the position is > 0. This fakes grapheme deletion for combining marks. The deletion is a non-coalescing edit (each press is its own undo step) and suppresses the autosuggestion.
**Source.** `src/reader/reader.rs:3375-3377`, `src/reader/reader.rs:2205-2229`.
**Test.**
    setup: fixture
    keys:  send-keys -l $'é'; send-keys BSpace
    expect: empty line (both codepoints removed)

### KB-34 — delete-char (`delete`) and delete-or-exit (`ctrl-d`)
**Behavior.**
- If the cursor is before the end, delete the codepoint under it, plus any zero-width codepoints before it (same loop as KB-33, from `pos+1`).
- `ctrl-d` at the end of a **non-empty** line: nothing.
- `ctrl-d` on an **empty** line: exit with status 0. If there are background jobs that need a warning, the warning is printed instead and a second exit request is required.
- `delete` never exits.
- Both end paging.

**Source.** `src/reader/reader.rs:3384-3396`, `src/reader/reader.rs:6540-6582`, `src/reader/reader.rs:6227`.
**Test.**
    setup: fixture
    keys:  type 'echo abc'; Left Left; C-d; C-e; C-d
    expect: `echo ac`; second C-d no change; then C-u, C-d → shell exits (pane closes)
**Observed.** Yes (the delete parts).

### KB-35 — shift-delete
**Behavior.** Runs `history-delete`. If a history search is active, or the cursor is at an autosuggestion that came wholly from history, that history item is deleted from history and saved, and status is true. A suggestion that did not come wholly from history just flashes, with status true. Otherwise status is false, and `or backward-delete-char` then deletes the character left of the cursor.
**Source.** `share/functions/__fish_shared_key_bindings.fish:39`, `src/reader/reader.rs:3535-3576`.
**Test.**
    setup: fixture (history `echo hello`)
    keys:  send-keys 'abc'; send-keys S-DC
    expect: `ab`

### KB-36 — transpose-chars (`ctrl-t`)
**Behavior.**
- Fewer than 2 characters: nothing.
- At the end: first move back one, so the last two characters swap.
- Then, if `pos > 0`: swap `text[pos-1]` and `text[pos]` and put the cursor at `pos+1`.
- At `pos == 0` (not at the end): nothing.

**Source.** `src/reader/reader.rs:3960-3982`.
**Test.**
    setup: fixture
    keys:  type 'abc'; C-t   → `acb` cursor 19;  C-a; C-t → unchanged cursor 16;  Right; C-t → `cab` cursor 18
**Observed.** Yes.

### KB-37 — transpose-words (`alt-t`)
**Behavior.**
1. Advance the cursor over characters that are not alphanumeric (`char::is_alphanumeric`).
2. Get `(tok, prev)` from `get_token_extent`. Tokens are shell tokens, so `foo/bar` is one.
3. If `tok.start == len`, retry from `prev.end`.
4. If both are non-empty and `tok.start > prev.start`, the buffer becomes `text[..prev.start] + tok + text[prev.end..tok.start] + prev + text[tok.end..]`, with the cursor at `tok.end`.
5. Otherwise nothing changes, though the cursor may have moved in step 1.

**Source.** `src/reader/reader.rs:3983-4021`.
**Test.**
    setup: fixture
    keys:  type 'echo aaa bbb'; M-t
    expect: `echo bbb aaa` cursor 28; then C-a M-t → unchanged, cursor 16
**Observed.** Yes.

### KB-38 — upcase-word (`alt-u`)
**Behavior.**
- The range is cursor → `move_word(Right, Punctuation, plain)`. That uses the **Right** machine (vi `w`): through the current class run, then through blanks, stopping at the start of the next word.
- Every character in the range is uppercased with Unicode `to_uppercase`; one character may become several. The cursor ends at the range end.
- On a blank followed by a word, the range is only the blank(s), so `alt-u` just **moves the cursor to the next word's start** without changing case.

**Source.** `src/reader/reader.rs:4103-4151`, `src/reader/word_motion.rs:207-215`.
**Test.**
    setup: fixture
    keys:  type 'echo hello world'; C-a; M-f (cursor 4); M-u; M-u
    expect: after 1st M-u text unchanged, cursor 21 (offset 5); after 2nd `echo HELLO world`, cursor 27 (offset 11)
**Observed.** Yes.

### KB-39 — capitalize-word (`alt-c`)
**Behavior.** Same range as KB-38. The first `is_alphanumeric` character in the range is uppercased, and every other character in the range is lowercased. There is no default `downcase-word` key: `alt-l` is `__fish_list_current_token`.
**Source.** `src/reader/reader.rs:4103-4151`, `share/functions/fish_default_key_bindings.fish:45-47`, `share/functions/__fish_shared_key_bindings.fish:66`.
**Test.**
    setup: fixture
    keys:  type 'echo hELLO world'; move cursor to offset 5; M-c
    expect: `echo Hello world`, cursor 27
**Observed.** Yes.

### KB-40 — undo (`ctrl-z`, `ctrl-_`, `ctrl-/`)
**Behavior.**
- **What one undo does.** It reverts the most recent edit, or every edit in the most recent edit group (begin/end-undo-group; a bracketed paste is one group, KB-53). The cursor goes back to where it was before that edit. Typing more after an undo discards the redo branch.
- **Undo is per edit line.** In the pager search field it undoes the search field.
- **Undo is not limited to typing.** Kills, yank, clear-commandline (ctrl-c), history-search replacements, completions and transpose are all undoable.
- **Nothing to undo:** the command line flashes (KB-66).
- On success it clears the pager and re-enables the autosuggestion.
- **ctrl-z is never SIGTSTP at the prompt.** VSUSP is disabled while fish reads (KB-67).

**Source.** `src/reader/reader.rs:4343-4359`, `src/editable_line.rs:200-236`, `src/reader/reader.rs:2140-2146`, `src/reader/reader.rs:4778-4791`.
**Test.**
    setup: fixture
    keys:  type 'echo abc def'; C-c; C-z
    expect: line restored `echo abc def`, cursor 28
**Observed.** Yes.

### KB-41 — redo (`alt-/`, `ctrl-shift-z`)
**Behavior.** Re-applies the next undone edit or group. The cursor goes to where it was just before that undo. If there is nothing to redo, the line flashes. In tmux, `C-S-z` arrives as `ctrl-z` (KB-08), so tests must use `M-/`.
**Source.** `src/editable_line.rs:239-262`, `src/reader/reader.rs:4343-4359`.
**Test.**
    setup: fixture
    keys:  type 'echo abc  def'; C-z ×4; M-/; M-/
    expect: after redo×2 `echo abc` (offset 8)
**Observed.** Yes.

### KB-42 — Undo grouping granularity (coalescing rules)
**Behavior.** A new insertion is merged into the previous undo entry only if **all** of these hold:
- the previous edit was an insertion that allows coalescing, i.e. a pure insertion of exactly 1 character, or inside an edit group;
- the new insertion is exactly 1 character;
- it is not a space, unless inside a group;
- the previous edit deleted nothing;
- the cursor has not moved since.

Insertions made while a history search is active never coalesce. Every other edit (kills, deletes, replacements, multi-character inserts) is its own undo step.

So typing `echo abc  def` one key at a time gives the undo steps `echo` | ` abc` | ` ` | ` def`: each space starts a new step and the characters after it join that step. **Observed**: undo gave `echo abc ` → `echo abc` → `echo` → ``.

**Burst caveat.** Characters that arrive together (paste-like, or one `send-keys 'echo abc def'`) are batched by read-ahead (KB-09) into multi-character inserts. Those never coalesce, and the last available character is inserted alone. **Observed**: undo steps after a burst were `f`, `de`, `abc `, `echo `.

**Source.** `src/editable_line.rs:152-197`, `src/editable_line.rs:299-322`, `src/reader/reader.rs:1978-1990`, `src/reader/reader.rs:2714-2764`; unit test `src/editable_line.rs:411-426`.
**Test.**
    setup: fixture
    keys:  type 'echo abc  def' one char at a time (≈40 ms apart); C-z ×4
    expect: `echo abc ` (cursor 25), `echo abc` (24), `echo` (20, autosuggestion ` hello` shown), `` (16)
**Observed.** Yes.

### KB-43 — clear-commandline (`ctrl-c`)
**Behavior.**
- **Empty command line:** nothing. No event fires and the screen does not change.
- **Otherwise:**
  - The whole buffer is replaced by `""` as one undoable edit, so ctrl-z restores it.
  - The cursor goes to offset 0.
  - The prompt stays on the **same row**. **No `^C` is printed, no newline, no new prompt.**
  - The line is **not** added to history.
  - The pager is closed, any history search ends, and the `fish_cancel` event fires.
- **How the key arrives.** ISIG stays on while reading, so ctrl-c reaches fish as SIGINT. The handler queues a `ctrl-c` key event (the VINTR byte), which runs this binding. Under kitty CSI-u it arrives directly as a key.

**Source.** `share/functions/__fish_shared_key_bindings.fish:72`, `src/reader/reader.rs:3081-3131` (the `CancelCommandline`-only branches are skipped), `src/reader/reader.rs:6228-6230`, `src/reader/input.rs:34-52`, `src/input/input.rs:673-688`, `src/reader/reader.rs:4758-4791` (ISIG not cleared). Docs `doc_src/interactive.rst:345` describe ctrl-c only as "interrupts/kills whatever is running"; at the prompt the code runs clear-commandline.
**Test.**
    setup: fixture
    keys:  type 'echo abc def'; C-c; (then) Up
    expect: after C-c: row 2 is exactly `darin@echo ~/w>` with cursor 16,2 (no ^C, no extra row); Up recalls `echo hello` (not `echo abc def`)
**Observed.** Yes.

### KB-44 — cancel-commandline (not bound by default; reference)
**Behavior.** For reference, in case a user binds it.
- Moves the cursor to the end and clears the autosuggestion.
- Repaints, then writes `^C` in the face given by `$fish_color_cancel`. That variable is `-r` (reverse video) in the default theme; if it is unset, the terminal default is used.
- Resets the text face, writes `\n`, clears the buffer (undoable), abandons the screen line so a new prompt is drawn on the next row, and fires `fish_cancel`.

It is the default ctrl-c binding only in the Rust fallback set (KB-03).

**Source.** `src/reader/reader.rs:3091-3127`, `share/themes/default.theme:5`.
**Test.**
    setup: fixture; `bind ctrl-c cancel-commandline`
    keys:  type 'echo x'; C-c
    expect: `darin@echo ~/w> echo x^C` with `^C` in SGR 7, new prompt on next row

### KB-45 — cancel (`escape`, `ctrl-[`, `ctrl-g`)
**Behavior.**
- Closes the completion or history pager, and ends a history search, restoring the pre-search text by undoing the transient edit.
- If the previous command was `complete`/`complete-and-search` and it inserted a unique completion, that completion is undone.
- In the pager, the transient edit from the selected completion is undone first.
- Otherwise it does nothing; the text and cursor are unchanged.
- A lone Escape waits ≤`fish_escape_delay_ms` first (KB-06).

**Source.** `src/reader/reader.rs:3132-3149`, `src/reader/reader.rs:2837-2861`, `src/reader/reader.rs:6230`.
**Test.**
    setup: fixture
    keys:  send-keys Up (recalls `echo hello`); send-keys Escape
    expect: empty line (search cancelled, original empty text restored)

### KB-46 — execute (`enter`, `ctrl-j`, `ctrl-m`, `ctrl-enter`): complete vs. incomplete lines
**Behavior.**
1. **Pager navigation:** Enter only accepts the selection / closes the pager.
2. **Backslash continuation:** if the cursor is at the end and the text ends with an odd number of backslashes (and does not end in a comment), insert `\n`. If the cursor is mid-line, insert `\n` when the character before the cursor is an escaping `\` and the character at the cursor is whitespace. If instead the buffer ends with an escaping `\`, move to the end and insert `\n`.
3. **Syntax check:**
   - **Error:** prints `\n` + the error backtrace to stderr, fires `fish_posterror`, and abandons the line. The text is kept for editing.
   - **Incomplete** (unclosed quote, block, or `(`): insert a literal `\n` at the cursor. No spaces are inserted, because indentation is display-only.
4. Abbreviations at the cursor expand.
5. The command runs and is added to history.

**Observed rendering:** continuation lines are drawn starting at the prompt-width column (16), plus 4 columns per indent level. So `if true⏎echo x` shows `echo x` at column 20, and `echo 'ab⏎` puts the cursor at column 16 of the next row.

**Source.** `src/reader/reader.rs:3397-3407`, `src/reader/reader.rs:4486-4569`, `src/reader/reader.rs:4574-4601`, `src/reader/reader.rs:6449-6464`, `src/reader/reader.rs:4468-4479`.
**Test.**
    setup: fixture
    keys:  send-keys "echo 'ab" Enter
    expect: two rows: `darin@echo ~/w> echo 'ab` and an empty continuation row, cursor 16 on it; nothing executed
**Observed.** Yes (also `if true`/`echo x` at col 20).

### KB-47 — alt-enter / shift-enter: insert a newline
**Behavior.** Runs `commandline -i \n`, with `--search-field` when the pager search field is active, then `expand-abbr`. A newline is always inserted at the cursor without executing, even if the line is complete. `shift-enter` needs a terminal that encodes it distinctly: tmux with `extended-keys on` sends `\e[27;2;13~`. Otherwise it arrives as plain Enter and executes.
**Source.** `share/functions/__fish_shared_key_bindings.fish:116-118`, `src/input/decode.rs:409-414`.
**Test.**
    setup: fixture
    keys:  send-keys 'echo a'; send-keys M-Enter; send-keys 'echo b'
    expect: two-line buffer `echo a` / `echo b` (second row starts at col 16), nothing executed

### KB-48 — ctrl-space and shift-space
**Behavior.** `ctrl-space` inserts one space at the cursor **only if the command line is non-empty**, and never expands abbreviations. `shift-space` always inserts a space and then runs `expand-abbr`, like a normal space. Both target the search field when it is active. In tmux, `C-Space` arrives as NUL → `ctrl-space`, and `S-Space` needs extended keys.
**Source.** `share/functions/__fish_shared_key_bindings.fish:120-122`, `src/key.rs:211-216`.
**Test.**
    setup: fixture
    keys:  send-keys C-Space; send-keys 'ls'; send-keys C-Space
    expect: first C-Space inserts nothing (cursor 16); final line `ls ` cursor 19

### KB-49 — Abbreviation-triggering characters
**Behavior.** `space`, `;`, `|`, `&`, `>`, `<` and `)` run `self-insert expand-abbr`. The character is inserted first, then any abbreviation ending just before it expands (see the abbreviation section). All other printable characters use the generic `self-insert` only. Enter (via execute → `expand_for_execute`) also expands. Because `expand-abbr` is a readline event, typing one of these characters ends a read-ahead batch (KB-09).
**Source.** `share/functions/__fish_shared_key_bindings.fish:110-119`, `src/reader/reader.rs:4336-4342`, `src/reader/reader.rs:4592`.
**Test.**
    setup: `abbr -a gs git status`
    keys:  send-keys 'gs '
    expect: `git status `

### KB-50 — clear-screen (`ctrl-l`)
**Behavior.**
1. If the terminal answered XTGETTCAP `indn` (`status test-terminal-feature scroll-content-up`), `scrollback-push` first scrolls the lines above the prompt into scrollback (`ScrollContentUp` by the prompt's viewport row, then cursor up).
2. `clear-screen` writes `\e[H\e[2J`, sets the viewport row to 0, repaints the old prompt plus command line at the top, re-runs the prompt, and repaints again.
3. The buffer, cursor, autosuggestion and history-search state are preserved. It doesn't change `last_cmd`.

Under tmux 3.6a there is no `indn` reply, so only step 2 runs.

**Source.** `share/functions/__fish_shared_key_bindings.fish:69-71`, `src/reader/reader.rs:4368-4373`, `src/reader/reader.rs:4381-4402`, `src/screen.rs:560-576`, `src/terminal.rs:298`, `src/reader/reader.rs:6327-6339`.
**Test.**
    setup: fixture
    keys:  send-keys Enter Enter; type 'echo keep'; send-keys C-l
    expect: row 0 = `darin@echo ~/w> echo keep`, rows below blank, cursor 25,0
**Observed.** Yes.

### KB-51 — fish_clipboard_copy (`ctrl-x`)
**Behavior.**
1. **What is copied:** the current selection, or the whole command line if there is no selection, re-indented with `fish_indent --only-indent`.
2. **Where it goes:** to the first available of `pbcopy`, `wl-copy` (only if WAYLAND_DISPLAY is set), `xsel --clipboard` / `xclip -selection clipboard` (only if DISPLAY is set), `clip.exe`.
3. **OSC 52 as well:** if `base64` exists and `TERM` is not `dumb`, it also writes `\e]52;c;<base64>\a` to stdout. Inside tmux (`$TMUX` set) it writes the same sequence to `#{client_tty}`.
4. The command line is unchanged.

**Source.** `share/functions/fish_clipboard_copy.fish:1-50`.
**Test.**
    setup: fixture (macOS: pbcopy present)
    keys:  type 'echo clip'; send-keys C-x
    expect: `pbpaste` (outside) prints `echo clip`; buffer unchanged

### KB-52 — fish_clipboard_paste (`ctrl-v`)
**Behavior.**
1. Reads the clipboard: `pbpaste`, `wl-paste -n`, `xsel`, `xclip`, or `powershell.exe Get-Clipboard`. Empty contents → return 1, nothing inserted.
2. Passes the data to `__fish_paste`, which:
   - splits on `\r` and `\n` and deletes control characters;
   - if the current token has an open single quote, escapes `'` and `\`;
   - otherwise, if outside double quotes and the paste has several lines, strips leading whitespace from lines 2+;
   - if the text before the cursor is empty, left-trims line 1;
   - inserts with `commandline --insert-smart`, or `--insert` when running as root.

**Source.** `share/functions/fish_clipboard_paste.fish:1-27`, `share/functions/__fish_paste.fish:2-55`.
**Test.**
    setup: outside: `printf '  echo pasted' | pbcopy`
    keys:  send-keys C-v
    expect: `echo pasted` (leading spaces trimmed at line start)

### KB-53 — Bracketed paste
**Behavior.** fish enables `\e[?2004h` while reading. `\e[200~` queues `begin-undo-group` and starts buffering raw bytes; bindings do not fire, so a pasted `\n` doesn't execute. `\e[201~` queues `end-undo-group` and runs `__fish_paste <escaped bytes>` (KB-52 processing). The whole paste is a **single undo step**.
**Source.** `src/input/decode.rs:424-431`, `src/input/decode.rs:50-53`, `src/reader/input.rs:64-81`, `src/tty_handoff.rs:186-187`.
**Test.**
    setup: fixture; `tmux set-buffer $'echo a\necho b'`
    keys:  tmux paste-buffer -p -t t; then C-z
    expect: two-line buffer `echo a`/`echo b`, not executed; one C-z empties it

### KB-54 — pager-toggle-search (`ctrl-s`)
**Behavior.**
- **History pager open:** at the newest page, the line flashes. Otherwise it goes to newer entries.
- **Completion pager open:** toggles the search field, fully discloses the pager, and selects the first item if the search was just shown.
- **No pager:** nothing.
- Flow control is disabled, so ctrl-s never freezes the terminal (KB-67).

**Source.** `src/reader/reader.rs:3214-3236`. Detail: pager section.
**Test.**
    setup: fixture
    keys:  send-keys 'abc'; send-keys C-s
    expect: no change (no pager)

### KB-55 — complete / complete-and-search (`tab`, `shift-tab`), mentioned only
**Behavior.** `tab` runs `complete`. Pressing tab again after an ambiguous result discloses or cycles the pager. `shift-tab` runs `complete-and-search`: complete, then search mode; repeated, it cycles backwards. TTY protocols are disabled while completions compute, so ctrl-c raises SIGINT. Full semantics: completion/pager sections.
**Source.** `src/reader/reader.rs:3183-3213`.
**Test.**
    setup: touch $W/alpha
    keys:  send-keys 'ls al' Tab
    expect: `ls alpha `

### KB-56 — History keys (binding facts only)
**Behavior.**
- **`up`/`ctrl-p`** run `up-or-search`. In search mode they continue `history-search-backward`. In the pager they run `up-line`. On logical line 1 they start a history search. Otherwise they run `up-line` (KB-65).
- **`down`/`ctrl-n`** mirror this, using the last line.
- **`pageup`/`pagedown`:** in the pager they page north/south. During a history search they jump to the oldest entry / the present. Otherwise nothing.
- **`alt-up`, `alt-.`** run history-token-search-backward on the token under the cursor; `alt-down` searches forward.
- **`ctrl-r`** opens the history pager. Its search field is seeded with the current command-substitution text, or the current line if that contains `\n`, with wildcards escaped; or with the active history-search string.
- Full semantics: history section.

**Source.** `share/functions/up-or-search.fish:3-28`, `share/functions/down-or-search.fish:2-28`, `src/reader/reader.rs:3863-3882`, `src/reader/reader.rs:3408-3491`, `src/reader/reader.rs:3492-3533`.
**Test.**
    setup: fixture (history `echo hello`)
    keys:  send-keys Up
    expect: `echo hello`
**Observed.** Yes.

### KB-57 — Man page for the current command (`alt-h`, `f1`)
**Behavior.**
- **Arguments:** take the tokens of the current process up to the cursor (`commandline -cpx`) plus the current token (`commandline -t`). Drop any that start with `-` or are empty.
- **Nothing left:** print BEL (`\a`) and return.
- **Skip leading wrappers** while ≥2 arguments remain and the first matches `^(and|begin|builtin|caffeinate|command|doas|entr|env|exec|if|mosh|nice|not|or|pipenv|please|prime-run|run0|setsid|sudo|systemd-nspawn|time|watch|while|xargs|.*=.*)$`.
- **Choose the page:** with `maincmd = basename(arg1)`, if a second argument exists without `/` and `man maincmd-arg2` succeeds, open that page. Otherwise open `man maincmd`, or print BEL if it fails.
- **Afterwards:** `commandline -f repaint`. The buffer is unchanged.

**Source.** `share/functions/__fish_man_page.fish:2-39`.
**Test.**
    setup: fixture
    keys:  send-keys 'sudo git commit -m x'; send-keys M-h
    expect: man page `git-commit` opens (alt screen); `q` returns to the same buffer

### KB-58 — List current token (`alt-l`)
**Behavior.** `val` = current token with a leading `~` replaced by `$HOME`.
- If `val` is a directory: `ls val`.
- Otherwise, if `dirname val` is not `.` and is a directory: `ls dirname`.
- Otherwise: plain `ls`.

The output goes through `__fish_echo`:
1. Emit enough `\n` to get below the command line, then `\e[J`, all to stderr.
2. Run the command with output to stderr.
3. Emit `(prompt_lines−1)` newlines and `(line−1)` newlines.
4. Repaint.

The old prompt line stays above the output, a new prompt with the same buffer is drawn after it, and the cursor offset is unchanged.

**Source.** `share/functions/__fish_list_current_token.fish:5-19`, `share/functions/__fish_echo.fish:2-10`.
**Test.**
    setup: mkdir $W/sub; touch $W/sub/file1; cd sub (or token `sub/`)
    keys:  send-keys 'ls '; send-keys M-l
    expect: rows: `…> ls`, `file1`, `…> ls ` (new prompt, cursor after `ls `)
**Observed.** Yes (in ~/w/sub: `file1` listed, prompt redrawn, cursor 23).

### KB-59 — Preview current file (`alt-o`)
**Behavior.**
1. **Command position:** if the cursor is on the command token, the command resolves to a readable `text/*` file, and an editor is set (`VISUAL`, then `EDITOR`), open that file in the editor.
2. **Otherwise,** `file` = current token, multiline-joined. If it is empty, use the last token before the cursor, with shell metacharacters backslash-escaped.
3. Strip a leading `-opt=`, then expand the result with `eval set`/`set`.
4. If the first result is a regular file, run `__fish_echo <pager> <files>`. The pager is `__fish_anypager`: `$PAGER` if that command exists, else the first of `less lv most more`, else `cat`.

**Source.** `share/functions/__fish_preview_current_file.fish:2-33`, `share/functions/__fish_edit_command_if_at_cursor.fish:2-24`, `share/functions/__fish_anypager.fish:2-32`.
**Test.**
    setup: printf 'hi\n' > $W/f.txt
    keys:  send-keys 'cat f.txt'; send-keys M-o
    expect: less shows `hi`; `q` returns, buffer unchanged

### KB-60 — whatis for current token (`alt-w`)
**Behavior.** Uses the current process's current token (`commandline -pt`); if it is empty, does nothing.
- Function: `token - <description>`, if the function has a description.
- Builtin: line 4 of `__fish_print_help`, trimmed.
- External file: `whatis token` output, if `whatis` succeeds.
- Otherwise: `token: nothing appropriate.`

The text is printed via `__fish_echo` (KB-58 layout). Output depends on the system's whatis database.
**Source.** `share/functions/__fish_whatis_current_token.fish:4-31`.
**Test.**
    setup: fixture
    keys:  send-keys 'nosuchcmdxyz'; send-keys M-w
    expect: line `nosuchcmdxyz: nothing appropriate.` below old prompt, prompt redrawn
**Observed.** Partially (`ls` printed `ls -`, which depends on the whatis database).

### KB-61 — Edit command line in an external editor (`alt-e`, `alt-v`)
**Behavior.**
1. **Editor:** `$VISUAL`, else `$EDITOR`, split on whitespace with `read -at`. If neither is set, it prints `External editor requested but $VISUAL or $EDITOR not set.` and `Please set VISUAL or EDITOR to your preferred editor.` via `__fish_echo` and returns 1, leaving the buffer unchanged.
2. **Temp file:** `$TMPDIR/fish.XXXXXX/command-line.fish` (`TMPDIR` defaults to `/tmp`). The file contains the buffer indented with `fish_indent --only-indent`.
3. **Cursor line/column:** computed from `commandline --cursor` and passed in an editor-specific way (vi/vim/nvim, emacs/emacsclient/gedit, kak, nano, joe/ee, code/code-oss, subl, micro, helix/hx), also following `complete --wraps`.
4. **Editor exits 0 with a non-empty file:** the buffer is replaced with the unindented file contents and the cursor goes to the end. For vim/nvim/kak, the cursor is set from the position the editor reports.
5. **Otherwise:** prints a blank line, then `Ignoring the output of your editor since its exit status was non-zero` and `or the file was empty`.
6. Finally the temp dir is removed and the line repaints.

**Source.** `share/functions/edit_command_buffer.fish:2-117`, `share/functions/__fish_anyeditor.fish:2-16`, `share/functions/__fish_mktemp_relative.fish:2-12`.
**Test.**
    setup: fixture (VISUAL/EDITOR unset; requires EXTRA guard, else EDITOR=nano)
    keys:  send-keys 'echo a'; send-keys M-e
    expect: two message lines below old prompt; new prompt `darin@echo ~/w> echo a`
**Observed.** Yes.

### KB-62 — Prepend/remove sudo (`alt-s`)
**Behavior.**
1. Use the first of `sudo`, `doas`, `please`, `run0` found by `command -q`; if none exists, do nothing.
2. Call `fish_commandline_prepend cmd`:
   - If the command line is empty, it is first replaced by `$history[1]`, the most recent history entry.
   - The prefix is `"cmd "`, or `" cmd"` if the current process text starts with a space, as the 2nd+ process of a pipeline does.
   - If the current process already starts with that prefix, it is removed (toggle). Otherwise it is inserted at the start of the current process.
   - The cursor keeps its relative position, clamped at ≥0.

**Source.** `share/functions/__fish_shared_key_bindings.fish:82`, `share/functions/fish_commandline_prepend.fish:1-26`.
**Test.**
    setup: fixture (history `echo hello`; /usr/bin/sudo exists)
    keys:  send-keys M-s; sleep 0.5; send-keys M-s
    expect: `sudo echo hello` (cursor 31), then `echo hello` (cursor 26)
**Observed.** Yes.

### KB-63 — Append/remove pager pipe (`alt-p`)
**Behavior.**
1. `cmd` = `__fish_anypager` (KB-59). If no pager exists, return 1.
2. The suffix is `" &| <cmd…>"`, or `"&| <cmd…>"` when the current job text ends in `" \n"`. A multi-word `$PAGER` is joined with spaces.
3. `fish_commandline_append`: an empty command line is first replaced by `$history[1]`. If the job already ends with the suffix, it is removed. Otherwise it is appended to the job with `commandline -aj`.
4. The cursor offset stays put; it does not move to the end.

The docs say it adds `&| less;`, but the code adds no `;` and does add a leading space.

**Source.** `share/functions/__fish_paginate.fish:2-11`, `share/functions/fish_commandline_append.fish:1-15`, `share/functions/__fish_anypager.fish:2-32`; docs `doc_src/interactive.rst:376`.
**Test.**
    setup: fixture with EXTRA guard (PAGER unset)
    keys:  send-keys 'ls'; send-keys M-p; sleep 0.5; send-keys M-p
    expect: `ls &| less` with cursor 18 (offset 2); after second press `ls`
**Observed.** Yes, verified with a `commandline` dump. Without the guard, PAGER=`less -R` gives `ls &| less -R`.

### KB-64 — Toggle comment (`alt-#`)
**Behavior.**
1. `lines` = `commandline -b`, split into lines. If it is empty, use the newest history entry starting with `#` (`history search -p "#" --max=1`).
2. Each line gets `#` prepended, then a leading `##` is replaced by nothing. This uncomments lines that were already commented.
3. The buffer is replaced with the result.
4. If the first resulting line starts with `#`, it **executes** immediately. The comment is added to history and a new prompt is drawn. Uncommenting does not execute.

**Source.** `share/functions/__fish_toggle_comment_commandline.fish:12-21`.
**Test.**
    setup: fixture
    keys:  send-keys 'echo x'; send-keys 'M-#'; sleep 0.5
    expect: `darin@echo ~/w> #echo x` then a fresh empty prompt on the next row; then `M-#` on the empty prompt yields `echo x` (not executed)
**Observed.** Yes (the comment/execute part).

### KB-65 — up-line / down-line inside a multi-line buffer
**Behavior.** Used when up-or-search/down-or-search is not on the first/last line.
- Target line = current line ± 1, which must exist.
- New column = old column − 4·(indent(new line) − indent(old line)), where the indent is `compute_indents` at each line start. So the cursor keeps its *visual* column across lines with different indentation.
- `get_offset` clamps to the target line's length.
- Moving across a newline suppresses the autosuggestion until the next insertion.

**Source.** `src/reader/reader.rs:3883-3945`, `src/reader/reader.rs:1605-1615`.
**Test.**
    setup: fixture
    keys:  send-keys 'if true' Enter; type 'echo x'; Up; C-e; Down
    expect: cursor at offset 3 within `echo x` (visual col 23 = 20+3)
**Observed.** Yes (inferred from the C-u result `o x`).

### KB-66 — Flash feedback on failure
**Behavior.** These failures flash a range:
- undo/redo with nothing to do → the whole line;
- a history search with no match → the match range or the whole line;
- ctrl-s / ctrl-r at the end of the history pager → the whole line;
- shift-delete on a suggestion not wholly from history → the suggestion.

Flashing paints the range with the `search_match` role for fore- and background, sleeps 100 ms, then repaints. The default `fish_color_search_match` is `white --background=brblack --bold`. Flashes are skipped when an empty range is given (unless flashing the autosuggestion) or when less than 50 ms has passed since the last flash.
**Source.** `src/reader/reader.rs:4637-4676`, `share/themes/default.theme:22`.
**Test.**
    setup: fixture
    keys:  type 'abc'; C-z (undo to empty); send-keys C-z; immediately capture-pane -e
    expect: no flash for empty line (range empty); with text present and nothing to undo, a 100 ms SGR bold/brblack-bg flash

### KB-67 — Terminal modes while reading (signals, flow control)
**Behavior.**
- While fish reads a command line, ICANON, ECHO, IEXTEN, ICRNL and INLCR are off, and **VSUSP and VQUIT are disabled**. So ctrl-z → key `ctrl-z` (undo) and ctrl-\ → key `ctrl-\` (unbound, ignored).
- **ISIG stays on**, so ctrl-c raises SIGINT and is converted to a ctrl-c key event (KB-43).
- **IXON/IXOFF are cleared at startup.** ctrl-s and ctrl-q reach fish; ctrl-q is unbound.

**Source.** `src/reader/reader.rs:4758-4791`, `src/reader/reader.rs:998-1002`, `src/reader/reader.rs:1027-1028`.
**Test.**
    setup: fixture
    keys:  type 'ab'; send-keys C-z; send-keys 'C-\'
    expect: fish not suspended; `ab` undone to `` ; C-\ no effect

### KB-68 — ConEmu paste sequence (TERM=xterm-256color only)
**Behavior.** With `TERM=xterm-256color`, which is the fixture's TERM, `bind --preset \e\x20ep fish_clipboard_paste` is added. It is displayed by `bind` as `\eep`, i.e. alt-space followed by `e`, `p`.
**Source.** `share/functions/fish_default_key_bindings.fish:60-66`, `src/key.rs:344-372`.
**Test.**
    setup: fixture
    keys:  send-keys 'bind | string match -e F50E' Enter
    expect: `bind --preset \eep fish_clipboard_paste`
**Observed.** Yes (in the `bind` dump).

### KB-69 — Script bindings vs. readline state
**Behavior.**
- Bindings whose command is fish script run with TTY protocols disabled. Afterwards fish restores shell modes and invalidates its cached terminal size.
- The script event itself does **not** modify `last_cmd` or `yank_len`.
- Each `commandline -f X` inside the script executes X **immediately**, as if it were a key, and sets `last_cmd = X`. Exceptions: repaint/clear-screen requests are queued instead.
- That is why the `alt-d` script chains kill-append like a direct `kill-word` binding (KB-25).

**Source.** `src/reader/reader.rs:2689-2710`, `src/reader/reader.rs:2867-2869`, `src/builtins/commandline.rs:466-486`, `src/reader/reader.rs:1157-1186`.
**Test.**
    setup: fixture
    keys:  type 'aaa bbb'; C-a; M-d; M-d; C-y
    expect: after M-d×2 empty line; C-y → `aaa bbb` (one appended kill item)

### KB-70 — Autosuggestion acceptance by key (summary)
**Behavior.** Only applies when the cursor is at the suggestion anchor (end of the typed text on that line).

| Keys | Amount accepted |
|---|---|
| `right`/`ctrl-f`, `alt->` | the whole suggestion |
| `end`/`ctrl-e` | up to the first newline of the remaining suggestion |
| `alt-f`/`alt-right` | one word (Punctuation style, to word end) |
| `shift-right` | one bigword |
| `ctrl-right` | up to the end of the next shell token in buffer+suggestion |

Any other motion leaves the suggestion unaccepted. `ctrl-c`, kills and deletes suppress or clear it.
**Source.** `src/reader/reader.rs:3043-3044`, `:3072-3073`, `:3596-3603`, `:3651-3655`, `:3785-3793`, `src/reader/reader.rs:5669-5739`.
**Test.**
    setup: history `echo hello world` (seed via HIST)
    keys:  send-keys 'ech'; send-keys M-f
    expect: buffer `echo` with suggestion ` hello world` still shown; then M-f again → `echo hello`

---

### Notes for zsh implementers
- **Word classes:** port KB-15 exactly. `_` is punctuation, Latin-1 letters `À`–`ÿ` (minus `×` `÷`) are word characters, other Latin-1 symbols are punctuation, and NUL/NBSP are blanks. zsh's `WORDCHARS` cannot express per-class runs: in fish, `--` and `/` are separate words, each a run of one class. You need a custom widget.
- **Word state machine, verbatim** (`src/reader/word_motion.rs:176-221`):
  ```
  consume(dir, last, cur):           # last=None for first char -> always consume
    if last is None: return CONTINUE
    if dir == Left:
      if last == Blank:   return CONTINUE
      if last == Newline: return STOP if cur == Newline else CONTINUE
      return STOP if cur in {Blank, Newline} or cur != last else CONTINUE
    else: # Right
      if last == Blank:   return STOP if cur not in {Blank, Newline} else CONTINUE
      if last == Newline: return STOP if cur != Blank else CONTINUE
      return STOP if (cur not in {Blank, Newline} and cur != last) else CONTINUE
  ```
- **The movers, built on `consume`** (`src/reader/reader.rs:2239-2336`, `:3617-3680`, `:3802-3832`, `:4103-4151`):
  ```
  backward_word:   b=pos; while b>0 and consume(Left, text[b-1]): b-=1          -> cursor=b ; kill [b,pos) prepend
  forward_word:    if empty and nextd variant: nextd; return
                   if at_suggestion: accept via Left-machine from first unaccepted char
                   elif pos+1<len and cls(t[pos]) not in {Blank,Newline} and cls(t[pos+1])!=cls(t[pos]): pos+=1 (kill: delete 1 char, NOT to killring)
                   else: b=pos; while b!=len-1 and consume(Left, text[b+1]): b+=1
                         move: cursor=min(b+1,len) ; kill: [pos,b+1) append
  upcase/capitalize range: b=pos; while b!=len and consume(Right, text[b]): b+=1 ; range [pos,b)
  ```
- **Path components:** port the 6-state backward machine in KB-23 (`src/reader/word_motion.rs:304-367`) together with the escape handling (an unescaped `\` is transparent; escaped characters count as path characters). zsh's `backward-kill-word` with `WORDCHARS` tweaks cannot reproduce `g@ ` vs `" ` or the `EndPunctuation` state.
- **Tokens:** ctrl-left, ctrl-right, ctrl-backspace, ctrl-delete and alt-t use *shell tokens* (fish tokenizer String tokens inside the innermost `(...)`), not words. zsh's `(z)` split is close, but you must drop operator tokens (`|`, `;`, `&`, redirections) and keep quoted strings whole.
- **Kill ring:** unbounded, newest first, with yank-pop rotating the whole ring left. The append/prepend continuation rules (KB-30) are per-command, and **ctrl-w never continues**. Single-character deletes done by kill-word at a word end are not in the ring. zsh's kill ring (size 8, `killring` array + CUTBUFFER, auto-append for consecutive kills of any kind) differs. Implement the "previous command" test explicitly with `$LASTWIDGET`.
- **Undo:** single-character inserts coalesce until a space, a cursor move, a deletion or a multi-character insert. Every other edit is one step, including clear-commandline and a whole bracketed paste. zsh's undo groups per widget call, so typed characters must be merged manually to match.
- **ctrl-c:** clear in place (undoable), no `^C`, no newline, not in history. zsh's default `send-break`/TRAPINT behavior prints a new prompt line, so it must be overridden.
- **ctrl-z** is undo and must not suspend (fish disables VSUSP while reading). **ctrl-s** is safe because flow control is off.
- **Escape timing:** fish uses a 1 ms decoder gap plus a 30 ms (`fish_escape_delay_ms`) alt-merge window. zsh's `KEYTIMEOUT` is in 10 ms units (default 40 = 400 ms). Set `KEYTIMEOUT=3` to approximate it.

---

### Unverified or surprising (summary)
- **Fixture contamination (all agents):** the Nix-built fish sources `/etc/fish/nixos-env-preinit.fish`, which sets PAGER=`less -R`, EDITOR=`nano` and a different PATH. Fix: `env -i … __NIX_DARWIN_SET_ENVIRONMENT_DONE=1 …`.
- **tmux drops a trailing `;`** in `send-keys` arguments; escape it as `\;`.
- **Repeated ctrl-w makes separate kill-ring entries**, while alt-backspace chains.
- **kill-word (alt-d) at a word end deletes one character without killing it**, so chained yanks lack those characters.
- **alt-u/alt-c use vi-`w` ranges**: on a space, they only move the cursor.
- **forward-word is emacs-style**: it ends just past the word end, not at the next word's start.
- **ctrl-shift-z cannot be produced in tmux** (it arrives as ctrl-z → undo). The `ctrl-/`, `ctrl-[`, `ctrl-i` and `ctrl-m` bindings only fire under CSI-u encodings.
- **Docs vs. code:**
  - ctrl-c at the prompt runs clear-commandline (`doc_src/interactive.rst:345`).
  - ctrl-w also stops at `= { , } ' " #` and blanks, not only `/ : @` (`:354`).
  - ctrl-delete kills a *token* and alt-delete kills a *word*, on all OSes (`:360-364`, superseded by CHANGELOG 4.8.1).
  - alt-p appends ` &| less` with no `;` (`:376`).
- **UNVERIFIED in tmux:** the exact flash rendering (KB-66), the bracketed-paste undo group (KB-53), alt-o/alt-h pager interaction (KB-57, KB-59), ctrl-x OSC 52 output (KB-51), and `fish_sequence_key_delay_ms` (KB-07). These are derived from source only.

---

## 6. Abbreviations

How fish 4.9.3 expands abbreviations interactively: which keys trigger expansion, which token is examined, what counts as "command position", how the token gets replaced (cursor, undo), and how abbreviations show up in highlighting, autosuggestions and the completion pager.
Every claim cites the 4.9.3 checkout. **Observed** means I confirmed it in tmux (socket `fishspec-mi`, standard fixture, `extended-keys on`). Items without an Observed line are derived from source only.

Fixture shorthand used in the recipes: "std" means the standard BRIEF fixture (clean HOME, `cd $W`, `TERM=xterm-256color`). "define" lines are typed into fish and run with Enter before the test keys. The prompt is `darin@echo ~/w> ` (16 columns) in every observation.

### AB-01 — No abbreviations exist by default
**Behavior.** With a clean HOME, `abbr` (which is `abbr --show`) and `abbr --list` print nothing. fish defines no default abbreviations. Running `abbr` with no arguments means `--show`; with arguments it means `--add`.
**Source.** `src/builtins/abbr.rs:71-76` (no subcommand: show if there are no args, otherwise add); `src/abbrs.rs:174-182` (the set starts empty, `Default`); no `abbr` calls in `share/config.fish` or `share/functions/__fish_config_interactive.fish`.
**Test.**
    setup: std
    keys:  send-keys 'abbr; abbr --list; echo END' Enter
    expect: the only output line is `END`
**Observed.** Output was just `END`.

### AB-02 — Trigger keys that insert themselves and then expand: space ; | & > < )
**Behavior.** In the default (emacs) bindings these seven keys run `self-insert expand-abbr`: `space`, `;`, `|`, `&`, `>`, `<`, `)`. The character is inserted at the cursor first. Then `expand-abbr` looks at the token at (cursor − 1), which is the position just before the inserted character (AB-08). So `gc` + `;` gives `git checkout;`. `)` is meant for closing a command substitution: `echo (gc)` gives `echo (git checkout)`. A bare `gc)` does not expand (observed). The likely reason is that the unbalanced `)` stops the parse from producing a `gc` leaf containing pos 2, but the exact tokenizer/AST path is UNVERIFIED. These are the only self-inserting triggers. Every other printable character goes through the generic `"" self-insert` binding and never expands, including `(`, `=`, `,`, letters, `"` and `'`.
**Source.** `share/functions/__fish_shared_key_bindings.fish:106` (generic self-insert), `:109-115` (space ; | & > < bound to `self-insert expand-abbr`), `:119` (`)`); `src/input/binding.rs:225` (`expand-abbr` maps to `ReadlineCmd::ExpandAbbr`); `src/reader/reader.rs:4336-4342` (ExpandAbbr calls `expand_abbreviation_at_cursor(1)`: backtrack 1 and sets the function status).
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`
    keys:  for each K in: space ; | & > < ) ( x = ,  →  send-keys -l "gc$K"; capture; send-keys C-u
           (for ';' send it as 'gc\;' because tmux treats a trailing ';' as a command separator)
    expect: space→`git checkout `, ;→`git checkout;`, |→`git checkout|`, &→`git checkout&`, >→`git checkout>`,
            <→`git checkout<`, )→`gc)`, (→`gc(`, x→`gcx`, =→`gc=`, ,→`gc,`; and `echo (gc)` → `echo (git checkout)`
**Observed.** Exactly as listed.

### AB-03 — shift-space expands; ctrl-space inserts a space without expanding (and does nothing on an empty line)
**Behavior.** `shift-space` runs `commandline -i " "` and then `expand-abbr`, so it behaves like space. `ctrl-space` runs `test -n "$(commandline)" && commandline -i " "` with no `expand-abbr`. It inserts a literal space without expanding. On a completely empty command line it inserts nothing. When the pager search field is active, both insert into the search field instead (`--search-field`).
**Source.** `share/functions/__fish_shared_key_bindings.fish:116` (`$maybe_search_field`), `:120` (ctrl-space), `:121-122` (shift-space with expand-abbr).
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`; tmux `extended-keys on` (required for S-Space)
    keys:  send-keys -l gc; send-keys C-Space; send-keys -l Q          → expect `gc Q`
           send-keys C-c; send-keys C-Space; send-keys -l Q             → expect `Q` (no leading space)
           send-keys C-c; send-keys -l gc; send-keys S-Space; send-keys -l Q → expect `git checkout Q`
**Observed.** `gc Q`, `Q`, `git checkout Q`.

### AB-04 — shift-enter / alt-enter insert a newline, then expand the token before it
**Behavior.** `shift-enter` and `alt-enter` run `commandline -i \n` followed by `expand-abbr`. The newline is inserted first, and the token just before it is then expanded (backtrack 1). The command line becomes multi-line and is not executed. Distinguishing `shift-enter` from `enter` needs a keyboard protocol (kitty or modifyOtherKeys). In tmux, `M-Enter` arrives as ESC CR.
**Source.** `share/functions/__fish_shared_key_bindings.fish:117-118`; `src/reader/reader.rs:4336-4342`.
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`; extended-keys on
    keys:  send-keys -l gc; send-keys M-Enter; send-keys -l Q
    expect: line 1 `git checkout`, line 2 starts at column 16 with `Q` (same result with S-Enter)
**Observed.** `darin@echo ~/w> git checkout` / `                Qlmanage` (where `lmanage` is an autosuggestion), for both M-Enter and S-Enter.

### AB-05 — Enter (execute) expands the token at the cursor, then runs the expanded text
**Behavior.** `enter`, `ctrl-j`, `ctrl-m` and `ctrl-enter` are bound to `execute`. Unless the line is backslash-continued (MI-17), execute does the following:
1. Syntax-check the line. A hard syntax error prints the error and keeps the line (MI-19). Abbreviations are not expanded in that case.
2. Expand at most one abbreviation: the token containing the cursor, with no backtrack. This happens even if the line is incomplete.
3. Re-check the syntax. If the line is incomplete, insert a newline at the cursor. Otherwise, add the (expanded) text to history and execute it.

The expanded text is what ends up in history.
**Source.** `share/functions/__fish_shared_key_bindings.fish:124-128`; `src/reader/reader.rs:4548-4559` (handle_execute uses the expand_for_execute result), `:4574-4601` (syntax check, `expand_abbreviation_at_cursor(0)`, then re-test), `:4564` (add_to_history after expansion).
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`
    keys:  send-keys -l gc; send-keys Enter; send-keys 'history | head -1' Enter
    expect: the executed line displays as `git checkout`; history's newest entry is `git checkout`
**Observed.** The line was redrawn as `git checkout` before running (git printed "fatal: not a git repository"). History listed `git checkout`.

### AB-06 — Which token gets examined (the exact algorithm)
**Behavior.** Let `pos` be the cursor minus the backtrack (1 for the self-insert triggers and `expand-abbr`, 0 for execute), clamped at 0. The line is parsed into an AST with error recovery. Every leaf node with non-empty source becomes a candidate token, with two exceptions:
- A leaf containing a command substitution is replaced by the tokens inside the substitution (recursively).
- Keywords and operators such as `;`, `|` and `&&` are leaves too.

A token is "command" if it is the `command` child of a decorated statement. The search walks the tokens from last to first:
- `token` becomes the last-visited token whose range contains `pos` inclusively (`start <= pos <= end`). Because the walk is backwards, the earliest such token wins. For `gc;` with pos 2, both `gc` [0,2] and `;` [2,3] contain 2, and `gc` wins.
- After a token is found, the walk continues backwards to the first command token at or before it. That is the "command" for `--command` matching (AB-13).

The token's raw source text, with quotes and backslashes intact, is matched against the abbreviations using position Command if the token is a command, otherwise Anywhere. At most one abbreviation is expanded.
**Source.** `src/reader/reader.rs:6074-6139` (extract_tokens: AST leaves, cmdsub recursion, `is_cmd` = DecoratedStatement.command), `:6145-6190` (backwards walk, contains_inclusive, position and command selection, first successful replacer), `:6196-6210` (`pos = position − backtrack` via `saturating_sub`; only when `expand_abbrev_ok` and the active line is the command line); `src/parse_constants.rs:188-190` (contains_inclusive).
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`; `abbr -a g G`
    keys:  send-keys -l gc; send-keys Left; send-keys Space    (cursor between g and c)
    expect: the space splits the token into `g c`; pos = 1 falls in token `g` [0,1], which expands → `G c`
    (by the algorithm; the plain `gc;` case is in AB-02)
**Observed.** The `gc;` case was observed (AB-02). The `g c` split case is derived from source.

### AB-07 — A space between the cursor and the token blocks expansion (ctrl-space then Enter runs the literal word)
**Behavior.** A token only matches if `pos` lies inside it or touches one of its ends. After typing `gc`, then `ctrl-space` (cursor at 3), then Enter (pos 3), no token contains 3: `gc` is [0,2]. So nothing expands and the literal `gc` runs. Likewise, typing a second space after an already-expanded word never re-expands anything.
**Source.** `src/reader/reader.rs:6155-6168` (no containing token returns `None`); `src/parse_constants.rs:188-190`.
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`
    keys:  send-keys -l gc; send-keys C-Space; send-keys Enter
    expect: executes `gc` → `fish: Unknown command: gc` (unless a gc command exists); history entry `gc` (trailing space trimmed, MI-14)

### AB-08 — The raw token text must equal the name exactly: quoting, escaping and case all prevent expansion
**Behavior.** A literal abbreviation matches only when the raw token text equals its name, case-sensitively. `'gc'`, `"gc"`, `\gc` and `GC` do not expand `gc`. Inside an unterminated quote (`echo "gc ` or `echo 'gc `), the token is the whole quoted string including the quote character, so nothing expands.
**Source.** `src/abbrs.rs:110-115` (literal: `self.key == token`; regex: `is_match` on the same raw text); `src/reader/reader.rs:6182-6183` (token_str is the raw source slice).
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`
    keys:  send-keys -l "'gc' "; capture; C-u; send-keys -l '\gc '; capture; C-u; send-keys -l 'GC '; capture; C-u;
           send-keys -l 'echo "gc '; capture; C-u; send-keys -l "echo 'gc "; capture
    expect: none of these expand: `'gc'`, `\gc`, `GC`, `echo "gc`, `echo 'gc`
**Observed.** None expanded.

### AB-09 — What counts as command position (command abbreviations expand here)
**Behavior.** An abbreviation with the default position (`command`) expands only when the token is the command word of a statement. These all count as command position (word `gc` after the shown prefix):
- start of line
- after `;`, `|`, `&` (background), `&&`, `||`
- after `and`, `or`, `not`, `time`, `not time`
- after the decorators `command`, `builtin`, `exec`
- after variable assignments like `A=b gc`
- after `if`, `while`, `begin`, `{`, `else` (and after `if true; else`)
- inside `(` … `)`, `$(` … `)`, and `"$(` … `)"`

`case gc` typed at top level outside a `switch` also expands: error recovery parses it as a new statement.
**Source.** `src/reader/reader.rs:6127-6134` (is_cmd = node is DecoratedStatement.command), `:6102-6125` (recursion into command substitutions); `src/abbrs.rs:118-121` (Anywhere abbrs match in both positions; Command abbrs only in Command position); CHANGELOG.rst 4.0.0 "Command abbreviations ... now also expand after decorators like `command`" and "Abbreviations now expand after process separators like `;` and `|`".
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`
    keys:  for each prefix P in: 'true; ' 'true | ' 'true && ' 'true || ' 'true & ' 'and ' 'or ' 'not ' 'if ' 'while ' 'begin ' '{ '
           'command ' 'builtin ' 'exec ' 'time ' 'A=b ' 'else ' 'if true; else ' 'not time A=1 ' 'echo (' 'echo $(' 'echo "$('
           → send-keys -l "${P}gc "; capture; send-keys C-u
    expect: each shows `${P}git checkout`
**Observed.** All listed prefixes expanded. `case gc ` also expanded.

### AB-10 — Not command position: arguments, block headers, and words after wrappers like sudo
**Behavior.** A command abbreviation does not expand in any of these:
- arguments: `echo gc`, `sudo gc`, `env gc`. Wrappers are ordinary commands, so the word after them is an argument.
- the name after a block keyword that takes an argument: `function gc`, `for gc`, `switch gc`
- `case gc` inside a real switch (`switch x; case gc `)
**Source.** `src/reader/reader.rs:6129-6134` (only DecoratedStatement.command counts), `:6170-6174` (other tokens use Position::Anywhere); `src/abbrs.rs:118-121`.
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`
    keys:  for each in: 'sudo gc ' 'env gc ' 'echo gc ' 'function gc ' 'for gc ' 'switch gc ' 'switch x; case gc ' → send-keys -l; capture; C-u
    expect: none expand
**Observed.** None expanded.

### AB-11 — `--position anywhere` expands in any token (command or argument)
**Behavior.** `abbr -a -p anywhere AW anyw` expands `AW` as a command (`AW ` → `anyw `) and as any argument (`echo a AW ` → `echo a anyw `, `git AW ` → `git anyw `). `-p` and `--position` accept only `command` or `anywhere`. Anything else gives the error `Invalid position '<x>'` plus `Position must be one of: command, anywhere`.
**Source.** `src/abbrs.rs:118-121`; `src/builtins/abbr.rs:525-550`.
**Test.**
    setup: std; define `abbr -a -p anywhere AW anyw`
    keys:  send-keys -l 'AW '; capture; C-u; send-keys -l 'echo a AW '; capture
    expect: `anyw`, `echo a anyw`
**Observed.** Yes.

### AB-12 — `--command CMD`: expand only as an argument of CMD
**Behavior.** `abbr -a --command git back 'reset --hard'`:
- `--command` implies `--position anywhere`. Combining it with `--position command` is an error: `--command cannot be combined with --position=command`.
- It expands only when the command word found by AB-06 is textually equal to one of the listed commands. The comparison uses the raw source text, so `'git' back ` does not expand.
- Options in between are fine: `git -C x back ` → `git -C x reset --hard`. Decorators are fine: `command git back ` expands. `echo back ` does not.
- Quirk: a command substitution earlier on the line hides the outer command, because its inner command token is found first in the backward walk. So `git (echo) back ` does not expand.
- `--command ''` (empty) matches when the token is itself in command position, or when no command token precedes it.
- Several `--command` options can be given. Names must be unique per command set: re-adding the same name with the same command list replaces it, while a different command list adds a separate entry.
**Source.** `src/abbrs.rs:101-108` (command filter), `:210-227` (replace only when name and commands are equal); `src/builtins/abbr.rs:399-412` (default position, error); `src/reader/reader.rs:6161-6166,6175-6180` (the first command token at or before the token; `None` gives `""`).
**Test.**
    setup: std; define `abbr -a --command git back 'reset --hard'`
    keys:  each of 'git back ' 'git -C x back ' 'command git back ' 'echo back ' "'git' back " 'git (echo) back ' 'git (echo back ' → send-keys -l; capture; C-u
    expect: first three expand to `... reset --hard`; the last four stay unchanged
**Observed.** Exactly so. `abbr` showed `abbr -a --position anywhere --command git -- back 'reset --hard'`.

### AB-13 — `--regex PATTERN`: the whole raw token must match (PCRE2, case-sensitive)
**Behavior.** The pattern is compiled with PCRE2, case-sensitive, with `(*UTF)` blocked, and then wrapped so that it must match the entire token. The NAME is only an identifier. The position rules still apply: default `command`.
- With `abbr -a -r '^x[0-9]+$' rx -f fa`: `x12 ` expands, `x1a ` does not, and `echo x12 ` does not (argument position).
- An invalid regex prints a PCRE2 error followed by two lines: `abbr: <pattern>` and `abbr: ` + spaces + `^` pointing at the error offset.
- Regex abbreviations are never offered as completions (AB-24).
**Source.** `src/builtins/abbr.rs:337-367` (compile, error with caret, anchored rebuild); `src/abbrs.rs:110-113`.
**Test.**
    setup: std; define `function fa; echo "F:$argv"; end; abbr -a -r '^x[0-9]+$' rx -f fa`
    keys:  send-keys -l 'x12 '; capture; C-c; send-keys -l 'x1a '; capture; C-c; send-keys -l 'echo x12 '; capture
    expect: `F:x12`, `x1a`, `echo x12`
**Observed.** Yes.

### AB-14 — Precedence: the most recently added matching abbreviation wins; a failing function falls through to the next
**Behavior.** All abbreviations matching the token are tried from newest to oldest, and the first one that produces a replacement is used. Re-adding an existing name (with the same `--command` set) deletes the old entry and appends the new one, so it becomes the newest. If a `--function` abbreviation's function returns a non-zero status, the next older match is tried. If none succeeds, the token stays unchanged.
**Source.** `src/abbrs.rs:185-201` (walk in reverse), `:210-227` (remove old, push new); `src/reader/reader.rs:6183-6189` (first `Some` wins), `:6049-6058` (function error gives `None`); `src/exec.rs:1542-1545` (non-zero status is `Err`).
**Test.**
    setup: std; define `function no; return 1; end; abbr -a -r 'z.*' A1 ONE; abbr -a -r 'z.*' A2 -f no`
    keys:  send-keys -l 'zz '
    expect: `ONE ` (A2 is newer but its function fails, so A1 is used)

### AB-15 — `--function`: how the function is called and how its output becomes the replacement
**Behavior.**
- The function is called as `FUNC <escaped token>` (one argument, the raw token).
- It runs non-interactively (`status is-interactive` is false), with the command line read-only (`commandline` cannot modify it), and the caller's `$status` is preserved.
- Its stdout is split into lines and re-joined with `\n`. The final trailing newline disappears, while interior newlines remain and produce a multi-line command line.
- Status 0 means the token is replaced by that output (which may be empty). Non-zero means no replacement (AB-14).
- The function name must be a valid function name with no whitespace. Giving an expansion as well as `-f` is an error (`Too many arguments`). With `-f`, a NAME alone is enough.
**Source.** `src/reader/reader.rs:6040-6071` (cmd = `escape(func) + ' ' + escape(token)`; `is_interactive=false`, `readonly_commandline=true`; `exec_subshell(apply_exit_status=false)`; outputs joined by `'\n'`); `src/builtins/abbr.rs:312-317,374-387`.
**Test.**
    setup: std; define `function fa; echo "F:$argv"; end; function ff; return 1; end; function fm; printf "%s\n" one two; end;
           abbr -a fa1 -f fa; abbr -a ff1 -f ff; abbr -a fm1 -f fm`
    keys:  send-keys -l 'fa1 '; capture; C-c; send-keys -l 'ff1 '; capture; C-c; send-keys -l 'fm1 '; capture
    expect: `F:fa1 `; `ff1 `; two lines `one` / `two ` (the second line rendered at column 16)
**Observed.** `F:fa1`, `ff1`, and `one`/`two` on two lines with `two` indented to column 16.

### AB-16 — Replacement text and where the cursor ends up
**Behavior.**
- The edit replaces exactly the token's range. Surrounding text, including the trailing space or `;` just typed, is untouched.
- A literal expansion is all positional words after NAME joined with single spaces: `abbr e emacs -nw` expands to `emacs -nw`. Options after the second positional word are treated as part of the expansion.
- Without a cursor marker, the cursor position after the edit is computed as follows. `c` is the cursor before the edit, `[s,e)` the token range, `R` the replacement length:
  - if `c >= s`, the new cursor is `c + R − min(e−s, c−s)`. So a cursor inside or at either end of the token lands at `s+R` (end of the replacement), and a cursor after the token shifts by `R − (e−s)`.
  - if `c < s`, the cursor stays at `c`.
- In practice, after `gc` + space the cursor sits after the trailing space.
**Source.** `src/reader/reader.rs:6204-6205` (push_edit then `update_buff_pos(None)` keeps the edit's cursor); `src/editable_line.rs:185-188` (cursor_position_before_edit and set_position), `:325-342` (formula); `src/builtins/abbr.rs:388-396` (join with spaces), `:508-521` (args after the 2nd positional belong to the expansion).
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`
    keys:  send-keys -l 'gc '; send-keys -l Q
    expect: `git checkout Q` (Q typed right after the space)

### AB-17 — `--set-cursor[=MARKER]`: cursor goes to the first marker, and the marker is deleted
**Behavior.**
- The default marker is `%`. `--set-cursor` takes an optional argument, so the marker must be attached with `=` (`--set-cursor=@@`). An empty marker is an error: `--set-cursor argument cannot be empty`.
- After expansion, the first occurrence of the marker in the replacement (literal, or the function's output) is removed. The cursor is placed where the marker was, measured from the token start.
- If the marker does not occur, the replacement is inserted verbatim and the cursor follows AB-16.
- The trailing trigger character (for example the space) is still after the replaced token. With `L` = `% | less` and the input `echo foo L `, the result is `echo foo ` + cursor + ` | less` + ` `.
**Source.** `src/abbrs.rs:153-171` (find first window, remove, cursor = start + range.start); `src/builtins/abbr.rs:563-574` (default `%`), `:94-100` (empty marker error); `src/reader/reader.rs:6067-6071` (applied to function output too).
**Test.**
    setup: std; define `abbr -a -p anywhere L --set-cursor "% | less"; abbr -a SC --set-cursor=@@ "echo @@ end"; abbr -a NOM --set-cursor "no marker here"`
    keys:  send-keys -l 'echo foo L '; send-keys -l Q; capture; C-c; send-keys -l 'SC '; send-keys -l Q; capture; C-c; send-keys -l 'NOM '; send-keys -l Q
    expect: `echo foo Q | less ` ; `echo Q end ` ; `no marker here Q`
**Observed.** All three exactly so.

### AB-18 — Undo: the expansion is its own undo step and restores the pre-expansion cursor
**Behavior.** For `gc` + space, three edits happen: typing `gc` (coalesced into one undo step), inserting the space (a separate step), and the expansion (its own step). Then:
- ctrl-z once gives `gc ` with the cursor after the space (the expansion is undone and its pre-edit cursor restored).
- ctrl-z twice gives `gc`.
- ctrl-z three times gives an empty line.
- Redo (`ctrl-shift-z`, `alt-/`) re-applies the edits.
**Source.** `src/editable_line.rs:152-197` (push_edit; single-character insertions coalesce, while a replacement edit always starts a new entry), `:200-236` (undo restores `cursor_position_before_edit`); `share/functions/fish_default_key_bindings.fish:41-43`.
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`
    keys:  send-keys -l 'gc '; send-keys C-z; send-keys -l Q     → `gc Q`
           C-c; send-keys -l 'gc '; send-keys C-z C-z; send-keys -l Q → `gcQ`
           C-c; send-keys -l 'gc '; send-keys C-z C-z C-z; send-keys -l Q → `Q`
**Observed.** `gc Q`, `gcQ`, `Q` (followed by autosuggestion text).

### AB-19 — No expansion in the pager search field, in `read`, or from pasted text
**Behavior.**
- Expansion only happens when the active edit line is the main command line. While the completion-pager or history-pager search field has focus, the triggers just insert text.
- `read` prompts do not expand abbreviations (`expand_abbrev_ok` defaults to false and is only set true for the interactive shell reader).
- Bracketed paste inserts text through `__fish_paste`/`commandline`, not through key bindings, so pasting `gc ` leaves `gc ` unexpanded.
- `commandline -i` itself never expands.
**Source.** `src/reader/reader.rs:6198` (requires `expand_abbrev_ok` and `EditableLineTag::Commandline`), `:479-480` (field; `Default` is false), `:830` (true only in read_i); `src/reader/input.rs:72-81`; `share/functions/__fish_paste.fish:46-53`.
**Test.**
    setup: std; define `abbr -a gc 'git checkout'`
    keys:  printf 'gc ' | tmux load-buffer -; tmux paste-buffer -p -t t
    expect: line shows `gc ` (no expansion)
**Observed.** `gc` with no expansion.

### AB-20 — Syntax highlighting: an abbreviation name in command position is colored as a valid command
**Behavior.** If the command word is not a builtin or function but matches an abbreviation usable in command position, it gets `fish_color_command`. In the default theme that is `--reset`, i.e. the terminal default color, not the error color. This covers command abbreviations, regex abbreviations matching the word, and `anywhere` abbreviations. `--command`-restricted abbreviations do not count. Under the `command` or `exec` decorators, or `builtin`, abbreviations are not considered (`command gc` is highlighted as an error if no `gc` executable exists). An unknown word such as `zqnotcmd` is colored `fish_color_error` (`brred`, SGR 91).
**Source.** `src/highlight/highlight.rs:231-288` (abbreviation check after builtins and functions, `has_match(cmd, Position::Command, "")`, disabled by decorations), `:1066-1080`; `share/themes/default.theme:6,11`.
**Test.**
    setup: std; define `abbr -a zqabbr 'echo hi'`
    keys:  send-keys -l zqabbr; capture -e; C-c; send-keys -l zqnotcmd; capture -e
    expect: `zqabbr` has no SGR color (default); `zqnotcmd` is wrapped in `ESC[91m … ESC[39m`
**Observed.** `> zqabbr` was uncolored. `> ^[[91mzqnotcmd^[[39m`.

### AB-21 — Autosuggestions can complete abbreviation names (command position)
**Behavior.** Completion-based autosuggestions include abbreviation names in command position, so typing a prefix of an abbreviation name shows the rest in `fish_color_autosuggestion` (`brblack`, SGR 90). This happens only when the prefix is in command position and nothing better comes from history. The typed prefix itself is still highlighted as an error until it is complete.
**Source.** `src/complete.rs:849-867` (command token: `complete_abbr` then `complete_cmd`; not gated on autosuggest, unlike the empty-token case at `:803-811`).
**Test.**
    setup: std; define `abbr -a zqabbr 'echo hi'`
    keys:  send-keys -l zqab; capture -e
    expect: `ESC[91mzqab` followed by `ESC[90mbr`
**Observed.** `^[[91mzqab^[[90mbr^[[39m`.

### AB-22 — Tab completion lists abbreviations in command position, with the description "Abbreviation: …"
**Behavior.**
- In command position (including an empty token right after `;`, `|`, etc.), all literal (non-regex) abbreviations whose name matches are offered. This includes `--position anywhere` and even `--command` ones, because there is no position or command filter at this step.
- The description is `Abbreviation: <expansion>`. With `--description=D` it is `Abbreviation: <expansion> # D`. For function abbreviations, `<expansion>` is the function name.
- The completion is inserted without a trailing space (NO_SPACE), so the next space you type expands it.
- Abbreviations are not offered in argument position (removed again in 4.8.1).
- The pager renders entries as `name  (description)`.
**Source.** `src/complete.rs:62-63` (`ABBR_DESC "Abbreviation: %s"`), `:1310-1341` (non-regex only, `"%s # %s"` with description, `CompleteFlags::NO_SPACE`), `:803-812` and `:849-867` (only called for the command token); CHANGELOG.rst 4.9.0 ("Abbreviations can now be given a description…"), 4.8.1 regression note.
**Test.**
    setup: std; define `abbr -a qqds --description=hello "desc thing"; abbr -a qqdt other; abbr -a -p anywhere qqany yy`
    keys:  send-keys -l qqd; send-keys Tab; capture; C-c; send-keys -l 'echo qqa'; send-keys Tab; capture
    expect: pager row `qqds  (Abbreviation: desc thing # hello)  qqdt  (Abbreviation: other)`; `echo qqa` gets no abbreviation completion
**Observed.** Exactly that pager row. `echo qqa` + Tab offered nothing.

### AB-23 — `--description` needs `=`; `--description TEXT` silently becomes part of the expansion
**Behavior.** `--description` (`-d`) is declared with an optional argument, so only `--description=TEXT` (or `-d=TEXT`) sets the description. With `--description world x`, the description stays unset and `world x` becomes the expansion. The `-d=TEXT` form works because the short `-d` is not a declared short option, and the argument parser matches it to the long option `description`. **There is no `--trigger` option in 4.9.3.** The CHANGELOG for 4.9.0 only adds descriptions. The full option set is: `-a -c -f -r -s -e -q -g -U -h --position --set-cursor --description --rename --list --color`.
**Source.** `src/builtins/abbr.rs:478` (short options `-ac:f:r:seqgUh`), `:480-501` (longopts; `description` is OptionalArgument), `:560-562`.
**Test.**
    setup: std
    keys:  send-keys 'abbr -a ds --description=hello "desc thing"; abbr -a ds2 --description world x; abbr -d=xyz foo2 bar2; abbr' Enter
    expect: lines `abbr -a --description=hello -- ds 'desc thing'`, `abbr -a -- ds2 'world x'`, `abbr -a --description=xyz -- foo2 bar2`
**Observed.** Exactly those lines.

### AB-24 — `abbr` / `abbr --show` output format
**Behavior.** One line per abbreviation, in definition order (oldest first), in this format:
`abbr -a [--regex PAT] [--position anywhere] [--set-cursor=M] [--description=D] [--function F] [--command C]... -- NAME [EXPANSION]`
- Values are escaped with script-style escaping. A word that needs quoting gets single quotes, so a marker of `%` shows as `--set-cursor='%'`.
- `--position anywhere` is printed only when the position is not `command`. That means `--command` abbreviations always print it.
- Abbreviations imported from legacy universal variables get the suffix `# imported from a universal variable, see `help abbr``.
- When stdout is a terminal (`--color=auto`), the output is syntax-highlighted.
- `abbr --list` prints only the names, one per line.
**Source.** `src/builtins/abbr.rs:123-189` (show), `:191-209` (list).
**Test.**
    setup: std; define `abbr -a gc 'git checkout'; abbr -a -p anywhere AW anyw; abbr -a --command git back 'reset --hard'; abbr -a -p anywhere L --set-cursor '% | less'`
    keys:  send-keys 'abbr | cat' Enter
    expect: `abbr -a -- gc 'git checkout'` / `abbr -a --position anywhere -- AW anyw` /
            `abbr -a --position anywhere --command git -- back 'reset --hard'` / `abbr -a --position anywhere --set-cursor='%' -- L '% | less'`
**Observed.** These exact lines (with `abbr` printing to the tty).

### AB-25 — Error messages from the abbr builtin that users hit interactively
**Behavior.** Exact messages:
- `abbr -a 'a b' x` prints `abbr --add: Abbreviation 'a b' cannot have spaces in the word`
- `abbr -a onlyname` prints `abbr --add: Requires at least two arguments`

Both return status 2 (invalid args).
**Source.** `src/builtins/abbr.rs:20-21,312-333`.
**Test.**
    setup: std
    keys:  send-keys "abbr -a 'a b' x; abbr -a onlyname" Enter
    expect: the two lines above
**Observed.** Exactly those two lines.

### AB-26 — `expand-abbr` is an ordinary bindable input function and sets the function status
**Behavior.** `bind X expand-abbr` (or `commandline -f expand-abbr`) expands the token at cursor − 1. It sets the input-function status to true if something expanded and false otherwise, so it can be chained with `and` / `or` in bindings. The command line is changed but not repainted until the binding finishes.
**Source.** `src/reader/reader.rs:4336-4342`, `:6193-6196` (doc: "does NOT repaint"); `src/input/binding.rs:830-838` (and/or use function_status).
**Test.**
    setup: std; define `abbr -a gc 'git checkout'; bind ctrl-g expand-abbr`
    keys:  (a) send-keys -l gc; send-keys C-g; capture
           (b) send-keys C-c; send-keys -l gc; send-keys C-Space; send-keys C-g; capture
           (c) send-keys C-c; send-keys -l gc; send-keys C-Space C-Space; send-keys C-g; capture
    expect: (a) `git checkout` (pos = 2−1 = 1 lies in [0,2]);
            (b) `git checkout ` (pos = 3−1 = 2 equals the end of `gc`, and the end counts);
            (c) `gc  ` unchanged (pos = 4−1 = 3 is outside [0,2])

### Notes for zsh implementers (abbreviations)
- Port AB-06 verbatim. In pseudo-code:
  ```
  pos = max(0, cursor - backtrack)          # backtrack = 1 for space/;|&><)/shift-space/shift-enter/alt-enter/expand-abbr, 0 for Enter
  toks = leaf tokens of the parse (cmdsub contents replace the token holding them); is_cmd = statement command word
  token = cmdtok = None
  for t in reversed(toks):
      if t.start <= pos <= t.end: token = t
      if token and t.is_cmd: cmdtok = t; break
  if not token: return
  position = Command if token.is_cmd else Anywhere
  command  = "" if token.is_cmd else (raw(cmdtok) if cmdtok else "")
  for abbr in reversed(definition_order):
      if (abbr.position == Anywhere or position == Command) and (not abbr.commands or command in abbr.commands)
         and (abbr.regex.fullmatch(raw(token)) if abbr.regex else abbr.name == raw(token)):
          repl = abbr.text if not abbr.func else run(func, raw(token))   # non-zero status → continue
          replace raw(token) range with repl; cursor per AB-16/AB-17; return
  ```
  (`src/reader/reader.rs:6145-6190`, `src/abbrs.rs:100-121,185-201`.)
- The self-insert happens before the expansion, so the triggering character is already in the buffer when the token is examined. In zsh terms, insert the char, then expand the word that ends at CURSOR−1.
- Enter expands before history is written, so history contains the expansion (AB-05).
- "Command position" is decided by fish's parser. A cheap zsh approximation (previous token is a separator, keyword or decorator) has to reproduce every case in AB-09/AB-10, including `A=b gc`, `time gc`, `else gc`, `{ gc`, `echo (gc`, and the non-expansion after `sudo`/`env`/`function`/`for`/`switch`.

---

## 7. Misc interactive behavior

Startup screen, the default prompt and title, the ⏎ omitted-newline marker, multi-line editing and indentation, Enter on incomplete or invalid input, implicit cd, paste handling, job messages, and the terminal escape sequences fish 4.9.3 emits (OSC 0/1/7/133, keyboard protocols, bracketed paste, focus reporting).
The raw byte captures quoted below come from running fish under `script -F` and `tmux pipe-pane -O` inside tmux 3.6a, 100×30, with the standard fixture (user `darin`, host `echo`).

### MI-01 — Clean-HOME startup screen: greeting text and colors; the first prompt only uses `\r`
**Behavior.**
- On the first prompt, fish writes just `\r` instead of the ⏎ sequence (MI-12). So startup output does not get a ⏎ marker, and text left on the line before fish started may be overwritten.
- Then the `fish_prompt` event fires. Its handler `__fish_on_interactive` runs `__fish_config_interactive` once, which calls `fish_greeting` (unless running inside `read`). The greeting prints exactly two lines:
  `Welcome to fish, the friendly interactive shell`
  `Type help for instructions on how to use fish`
  `help` is wrapped in `set_color green` (SGR 32) and `set_color --reset` (`ESC[m`).
- If `$SHELL_WELCOME` is set, its elements are printed next, joined by spaces.
- If `fish_greeting` is set to an empty string, nothing is printed. In private mode, the line `fish is running in private mode, history will not be persisted.` is appended.
- The first interactive start also launches `fish_update_completions` in the background, if `$__fish_cache_dir/generated_completions` is missing.
- If the history is empty and is the default history, fish imports `$HISTFILE` or `~/.bash_history` when that file exists.
**Source.** `src/reader/reader.rs:2592-2602` (first prompt: trusted_width None, so `abandon_line_string(None)` = `\r`), `:2604-2607`; `src/screen.rs:681-686`; `share/config.fish:117-122`; `share/functions/__fish_config_interactive.fish:18-25,31-42`; `share/functions/fish_greeting.fish:1-17`; `src/reader/reader.rs:6469-6487` (bash history import).
**Test.**
    setup: std (fresh HOME, no config)
    keys:  (none) wait 1s; capture -p and capture -e
    expect: row1 `Welcome to fish, the friendly interactive shell`, row2 `Type help for instructions on how to use fish` with `help` green, row3 the prompt
**Observed.** Raw bytes: `␛[0c\rWelcome to fish, the friendly interactive shell\r\nType ␛[32mhelp␛[m for instructions on how to use fish\r\n`, followed by the OSC 7, title and prompt (MI-03).

### MI-02 — Default prompt layout and exact bytes
**Behavior.**
- `fish_prompt` prints:
  `(prompt_login) ' ' (set_color $fish_color_cwd)(prompt_pwd)(set_color --reset)(fish_vcs_prompt)(set_color --reset)` + `" "$prompt_status` + `>` + `' '`
- `prompt_login` is `(set_color $fish_color_user)$USER(set_color --reset)@(set_color $color_host)(prompt_hostname)(set_color --reset)`:
  - It is prefixed by a yellow `(chroot:NAME) ` when `/etc/debian_chroot` or `$debian_chroot` is set.
  - The host uses `fish_color_host_remote` (yellow) when `$SSH_TTY` is set.
  - `prompt_hostname` is `$hostname` truncated at the first `.`.
- Default theme colors: user `brgreen` (SGR 92), host `--reset`, cwd `green` (SGR 32).
- `$prompt_status` is an empty list when there is nothing to show, so no extra space appears.
- `fish_vcs_prompt` (jj, git, hg, darcs) prints nothing outside a repository.
- The prompt is wrapped in OSC 133 A/B marks (MI-24).
**Source.** `share/functions/fish_prompt.fish:4-32`; `share/functions/prompt_login.fish:2-29`; `share/functions/prompt_hostname.fish:2-4`; `share/functions/fish_vcs_prompt.fish:1-13`; `share/themes/default.theme:8,14,15,25`.
**Test.**
    setup: std
    keys:  capture -e of the prompt row
    expect: on screen `darin@echo ~/w> ` (16 cols); colors: `darin` SGR 92, `~/w` SGR 32, the rest default
**Observed.** Raw: `␛]133;A;click_events=1␛\␛[92mdarin␛[m@␛[mecho␛[m ␛[32m~/w␛[m␛[m> ␛]133;B␛\␛[K\r␛[16C`. tmux `capture-pane -e` shows the resets as `^[[39m`.

### MI-03 — `prompt_pwd` abbreviation rules
**Behavior.**
1. Replace a leading `$HOME` (only when it is followed by `/` or the end of the string) with `~`.
2. Strip control characters.
3. With the defaults `fish_prompt_pwd_dir_length=1` and `fish_prompt_pwd_full_dirs=1`, shorten every path component except the last N=1 to its first character. A leading `.` is kept plus one character, so `.config` becomes `.c`. The last component is kept in full.
- Examples: `/Users/darin/src/personal` with HOME `/Users/darin` → `~/s/personal`; `/private/tmp/x` → `/p/t/x`; `$HOME` → `~`; `/` → `/`.
- `fish_prompt_pwd_dir_length=0` disables shortening. `fish_prompt_pwd_full_dirs=N` keeps the last N components in full.
**Source.** `share/functions/prompt_pwd.fish:2-51` (the regex `(\.?[^/]{N})[^/]*/` → `$1/` applied to the prefix before the last N components); `share/functions/__fish_unexpand_tilde.fish:2-5`.
**Test.**
    setup: std; mkdir -p $W/alpha/.beta/gamma
    keys:  send-keys 'cd alpha/.beta/gamma' Enter
    expect: prompt `darin@echo ~/w/a/.b/gamma> `  ($PWD = $H/w/alpha/.beta/gamma; `~` and `w` are already 1 char, `alpha`→`a`, `.beta`→`.b`, last component `gamma` kept)

### MI-04 — Exit status in the prompt: ` [N]`, bold only when fresh, pipestatus, signal names, 141 hidden
**Behavior.** When `$status` is not 0 and not 141 (SIGPIPE), the prompt inserts ` [` … `]` before `>`:
- The contents are `$pipestatus` joined by `|`. Each value above 128 is converted to the signal name: 130 → `SIGINT`, 143 → `SIGTERM`.
- If `$status` differs from the last pipestatus element (for example after `not true`), ` <status>` is appended after `]`.
- Brackets and `|` are drawn in `fish_color_status` (red, SGR 31). The numbers are drawn in red plus bold (`ESC[31;1m`) only if a new command ran since the last prompt (`$status_generation` changed). After an empty Enter, or a job launched with `&`, the same status is shown without bold.
- `true | false` → `[0|1]`. `false | true` → nothing, because `$status` is 0.
**Source.** `share/functions/fish_prompt.fish:19-29`; `share/functions/__fish_print_pipestatus.fish:2-38`; `share/functions/fish_status_to_signal.fish:1-17`; `src/reader/reader.rs:876-878` (STATUS_COUNT increments only when the eval produced a status).
**Test.**
    setup: std
    keys:  send-keys false Enter; capture -e; send-keys Enter; capture -e; send-keys 'sleep 5' Enter; send-keys C-c; capture
    expect: `darin@echo ~/w [1]> ` with bold 1; after the empty Enter `[1]` not bold; after ctrl-c `darin@echo ~/w [SIGINT]> `
**Observed.** Raw after `false`: `~/w␛[m␛[m ␛[m␛[31m[␛[31;1m1␛[m␛[31m]␛[m␛[m> `. After ctrl-c killed `sleep 5`, the prompt was `[SIGINT]` with bold `SIGINT`. After a following `sleep 1 &`, it showed `[SIGINT]` not bold.

### MI-05 — Root prompt
**Behavior.** If `fish_is_root_user` succeeds, the suffix is `#` instead of `>`, and the cwd uses `$fish_color_cwd_root` (default theme: red) when that is set. `fish_is_root_user` succeeds if `$EUID` = 0 or `$USER` is one of `root`, `toor`, `Administrator`.
**Source.** `share/functions/fish_prompt.fish:9-17`; `share/functions/fish_is_root_user.fish:4-14`; `share/themes/default.theme:9`.
**Test.**
    setup: std plus env `USER=root` in the env -i list
    keys:  capture -e
    expect: `root@echo ` + red `~/w` + `# `

### MI-06 — No right prompt by default; right-prompt layout rules
**Behavior.**
- fish ships no `fish_right_prompt`, so nothing is drawn on the right.
- When the function is defined, its output lines are concatenated (it is a single line) and drawn right-aligned on the last prompt line, ending at the last column.
- It is drawn only if `left_prompt_width + width_of_first_commandline_line + width_of_first_line_autosuggestion + right_prompt_width <= screen_width`. Otherwise it is hidden while the line is too long.
- After drawing it, fish moves back and issues `\r`.
**Source.** `src/reader/reader.rs:5211-5222`; `src/screen.rs:2007-2023` (fit rule), `:1283-1305` (drawing at `screen_width − right_prompt_width`); `ls share/functions` has no fish_right_prompt.fish.
**Test.**
    setup: std; define `function fish_right_prompt; echo RP; end`
    keys:  capture; send-keys -l (95 x's); capture
    expect: `RP` at columns 98-99 of the prompt row; hidden once 16 + len + 2 > 100

### MI-07 — SHELL_PROMPT_PREFIX / SHELL_PROMPT_SUFFIX and the fallback prompt
**Behavior.** When non-empty, `$SHELL_PROMPT_PREFIX` is prepended and `$SHELL_PROMPT_SUFFIX` appended to the left prompt output. If `fish_prompt` has been erased, fish uses `echo -n "$USER@$hostname $PWD "'> '`: the full `$PWD`, uncolored.
**Source.** `src/reader/reader.rs:5182-5208`, `:1304` (DEFAULT_PROMPT).
**Test.**
    setup: std plus env `SHELL_PROMPT_PREFIX=[P]`
    keys:  capture; send-keys 'functions -e fish_prompt' Enter; capture
    expect: `[P]darin@echo ~/w> `; then `[P]darin@echo /…/fishhome.XXXX/w > `

### MI-08 — Transient prompt (off by default)
**Behavior.**
- If `fish_transient_prompt` is set to any value other than `0` (an empty value counts as on), then after Enter is accepted and before the command runs, fish re-runs `fish_mode_prompt`, `fish_prompt` and `fish_right_prompt`, each with the extra argument `--final-rendering`. It then repaints the accepted line with that prompt.
- Changes to the variable take effect immediately.
- Unset by default, so nothing re-renders.
**Source.** `src/reader/reader.rs:832`, `:1108-1112` (check_bool_var: `!= "0"`), `:1127-1131`, `:2630-2632`, `:5140-5149` (appends ` --final-rendering` only if the function exists); `src/env_dispatch.rs:82`; CHANGELOG.rst 4.1.0.
**Test.**
    setup: std; define `function fish_prompt; contains -- --final-rendering $argv; and echo -n '$ '; or echo -n 'LONG> '; end; set -g fish_transient_prompt 1`
    keys:  send-keys 'echo hi' Enter
    expect: the executed line in scrollback reads `$ echo hi`; the new prompt reads `LONG> `

### MI-09 — What happens on screen when Enter is accepted
**Behavior.**
- The autosuggestion is deleted and the cursor is moved to the end of the command line.
- The line is repainted with final highlighting (abbreviation expanded, no autosuggestion).
- A `\n` is written, unless the cursor already sits alone at the start of a soft-wrapped new line.
- fish emits `ESC[m`, then OSC 133 C (MI-24), the title for the command (MI-21), and `ESC[m\r`. The command then runs.
**Source.** `src/reader/reader.rs:4561-4567`, `:2630-2650`, `:864-874`, `:6407-6411`.
**Test.**
    setup: std; seed history `echo hello`
    keys:  send-keys -l 'echo h'; (autosuggestion `ello` shown) send-keys Enter
    expect: scrollback row reads `darin@echo ~/w> echo h` (no gray `ello`); output `h`
**Observed.** Raw for `printf foo`: `\r␛[30C␛[10Dprintf ␛[36mfoo␛[39m\r␛[30C\r\n␛[m␛]133;C;cmdline_url=printf%20foo␛\␛]0;printf foo ~/w␛\␛[m\r`.

### MI-10 — The ⏎ omitted-newline marker (PROMPT_SP), exact bytes
**Behavior.** Before every prompt except the first, fish writes:
`ESC[2m` + `⏎` (U+23CE) + `ESC[m` + (W−1) spaces + `\r` + `⏎` + one space + `\r` + `ESC[K`, where W is the terminal width.
- If the previous output ended without a newline (cursor at column c > 0), the dim ⏎ lands right after the output and the spaces wrap to a fresh line. That line is then cleared, so the screen shows e.g. `foo⏎` and the prompt starts on the next row.
- If the cursor was at column 0, the dim ⏎ and spaces fill exactly one row without wrapping. `\r⏎ \r ESC[K` then erases them and nothing is visible.
- After ctrl-c kills a command, the tty driver echoes `^C` (fish doesn't print it), so the row reads `^C⏎`.
- The same sequence is used after a syntax error (MI-15), after `reader_pop`, and so on.
- The symbol is `¶` on WSL and `^J` on a Linux virtual console. If W ≤ 1, the dim part is skipped.
**Source.** `src/screen.rs:668-725` (reset_abandoning_line / abandon_line_string); `src/common.rs:65-83` (symbol choice); `src/terminal.rs:667-671,680-682` (`ESC[m`, `ESC[2m`); `src/reader/reader.rs:2598-2601`.
**Test.**
    setup: std
    keys:  send-keys 'printf foo' Enter; capture -e
    expect: row `foo⏎` with ⏎ dim (SGR 2); next row the prompt
**Observed.** Screen `foo⏎`. Raw: `foo␛]133;D;0␛\␛[?25h␛[2m⏎␛[m` + 99 spaces + `\r⏎ \r␛[K`. After `sleep 5` + ctrl-c the screen showed `^C⏎`.

### MI-11 — Enter on an empty line, and whitespace-only commands
**Behavior.**
- Enter on an empty command line writes `\n` and draws a new prompt.
- The empty command is not executed: no `fish_preexec`/`fish_postexec`, no OSC 133 C/D, no history entry, `$status` unchanged (shown non-bold, MI-04).
- A whitespace-only line such as `   ` is not empty, so it is evaluated and gets the events and OSC marks. History drops it because trailing spaces and newlines are trimmed, leaving nothing.
**Source.** `src/reader/reader.rs:860-862` (`if command.is_empty() { continue }` before preexec and 133 C), `:6509-6524` (trim trailing ' '/'\n' unless backslash-escaped; empty is not added).
**Test.**
    setup: std
    keys:  send-keys false Enter; send-keys Enter; capture -e
    expect: second prompt `darin@echo ~/w [1]> ` with a non-bold 1; `history` has no blank entry

### MI-12 — History filter: a leading space makes a command ephemeral; `fish_should_add_to_history`
**Behavior.**
- Trailing unescaped spaces and newlines are trimmed before saving.
- If no `fish_should_add_to_history` function exists, a command whose first character is a space is added as **ephemeral**. It can be recalled with up-arrow until the next command is entered, then it is removed, and it is never written to disk.
- If the function exists, it is called as `fish_should_add_to_history <escaped text>`, non-interactively. Status 0 saves normally; non-zero makes the command ephemeral.
- In private mode (`fish_private_mode`), entries are kept in memory only.
**Source.** `src/reader/reader.rs:6489-6501`, `:6503-6536` (remove_ephemeral_items on each add; Ephemeral / Memory / Disk).
**Test.**
    setup: std
    keys:  send-keys -l ' echo secret'; send-keys Enter; send-keys Up; capture; send-keys C-c; send-keys 'true' Enter; send-keys Up Up; capture
    expect: first Up shows ` echo secret`; after `true`, Up Up never reaches it

### MI-13 — Enter on an incomplete line inserts a newline at the cursor
**Behavior.** If the line parses as incomplete, Enter inserts `\n` at the cursor position (not at the end), and the command line becomes multi-line. Incomplete means one of:
- an unclosed `'` or `"` quote
- an unclosed `(` or `$(` command substitution, including inside double quotes
- an unclosed block: `if`, `while`, `for`, `function`, `begin`, `switch`, or `{` without `end` / `}`
- a trailing `|`
- a trailing `&&` or `||`

Backslash continuation is MI-14. The abbreviation at the cursor is still expanded first (AB-05). The final command, once complete, keeps its embedded newlines in history.
**Source.** `src/reader/reader.rs:4550-4557` (incomplete → `insert_char('\n')` at the cursor); `src/parse_util.rs:1084-1108` (unterminated quote or subshell → INCOMPLETE), `:1150-1243` (unclosed block, brace statement, pipe, conjunction → incomplete).
**Test.**
    setup: std
    keys:  for each S in: 'echo "abc' "echo 'abc" 'echo (abc' 'echo $(abc' 'if true' 'begin' 'while true' 'for i in 1 2' 'function f' 'switch a' '{' 'true |' 'true &&' 'true ||' 'echo "$(echo'
           → send-keys -l "$S"; send-keys Enter; capture; send-keys C-c
    expect: in every case the line is kept and the cursor moves to a new continuation row (nothing executes)
**Observed.** All 15 kept the line and opened a continuation row.

### MI-14 — Backslash line continuation rules
**Behavior.**
- If the cursor is at the end and the character before it is an unescaped `\`, Enter inserts a newline, unless the line ends inside a comment (`echo foo #\` executes).
- If the cursor is mid-line, there are two cases:
  - a `\` before the cursor followed by whitespace at the cursor inserts the newline at the cursor.
  - otherwise, if the whole line ends with an unescaped `\` (and not in a comment), the cursor jumps to the end and a newline is inserted there.
- A continuation line gets one extra indent level (MI-17).
**Source.** `src/reader/reader.rs:4523-4546`.
**Test.**
    setup: std
    keys:  send-keys -l 'echo foo \'; send-keys Enter; send-keys -l bar; capture; send-keys C-c; send-keys -l 'echo foo #\'; send-keys Enter; capture
    expect: row 2 `bar` at column 20 (16 + 4); the comment case executes and prints `foo`
**Observed.** `bar` rendered at column 20. `echo foo #\` printed `foo`.

### MI-15 — Enter on a syntax error: the error is printed, the line is kept, `$status` is untouched
**Behavior.** When the pre-execution syntax check finds a hard error (not mere incompleteness):
- fish prints `\n` + the error to stderr. The error is `fish: <message>`, followed by the offending source line and a caret line.
- Caret line format: `^` under the start column; if the error spans 2 or more columns, `~` repeated (width − 2) and a closing `^`.
- When interactive, the source line and caret are omitted if the error starts at offset 0.
- Then fish fires the `fish_posterror` event with the command line, writes the ⏎ sequence, and redraws the prompt with the same command line, cursor where it was.
- Nothing executes, nothing is added to history, and `$status` keeps its old value.
- Some malformed lines are not caught by this check and run instead, failing at runtime. `true; and` executes and prints `fish: Expected a command, but found end of the input`, giving status 123.
**Source.** `src/reader/reader.rs:6449-6465` (reader_shell_test: `eprintf!("\n%s")`), `:3397-3407` (posterror and reset_abandoning_line), `:4581-4588`; `src/parse_constants.rs:302-409` (caret format, interactive skip).
**Test.**
    setup: std
    keys:  send-keys true Enter; send-keys -l 'echo {a,b'; send-keys Enter; capture
    expect: rows: `darin@echo ~/w> echo {a,b` / `fish: Unexpected end of string, incomplete parameter expansion` / `echo {a,b` / `     ^` / `darin@echo ~/w> echo {a,b` (cursor at col 25)
**Observed.** Exactly those rows, cursor at (25,5). `true; and` executed and printed the runtime error, after which the prompt showed `[123]`.

### MI-16 — Rendering of continuation lines: prompt width plus 4 spaces per indent level
**Behavior.**
- Each line after a hard newline starts with `P + 4×L` spaces. P is the display width of the left prompt's last line, or 0 when that line is exactly as wide as the screen. L is the indent level of the newline character (MI-17).
- These spaces exist only on screen. The buffer, `commandline` output and history contain no indentation.
- Lines that soft-wrap (MI-18) continue at column 0 with no indentation.
**Source.** `src/screen.rs:382-387` (commandline_indent), `:760-786` (newline → indentation = prompt_width + indent×INDENT_STEP), `:1567-1568` (INDENT_STEP = 4); `src/parse_util.rs:769` (SPACES_PER_INDENT = 4).
**Test.**
    setup: std
    keys:  send-keys -l 'if true'; send-keys Enter; tmux display -p '#{cursor_x}'
    expect: 20
**Observed.** Cursor x = 20 after `if true` + Enter. Full example in MI-17.

### MI-17 — Indentation levels (fish's AST-driven algorithm), with a worked example
**Behavior.** Indentation is recomputed from the whole buffer on every repaint, so typing `end` immediately dedents its line. Worked example (columns observed with prompt width 16):
```
if true          (prompt line)
    echo a |     col 20 (L1: body of if)
        cat &&   col 24 (L2: pipe continuation with newline adds +1)
        true     col 24 (L2: && continuation with newline adds +1, same level)
    switch x     col 20
        case y   col 24 (case item list +1)
            echo z col 28 (case body +1)
    end          col 20
    echo "multi  col 20
line"            col 16 (inner lines of a multi-line string are not indented: L0)
    echo foo \   col 20
        bar      col 24 (backslash continuation +1)
end              col 16
```
The algorithm is given as pseudo-code in the notes at the end. In short, levels come from:
- nested job lists
- `if`/`while` conditions
- pipe or `&&`/`||` continuations that contain a newline
- case lists
- line continuations

Newline characters take the indent of the next non-newline character. Command substitutions are indented one level deeper than the enclosing token.
**Source.** `src/parse_util.rs:697-765` (compute_indents: newline post-pass and continuation +1), `:948-1060` (IndentVisitor increment rules), `:856-946` (quotes, cmdsubs, unclosed); `src/reader/reader.rs:1914-1915` (computed per layout).
**Test.**
    setup: std
    keys:  type the example line by line with send-keys -l '<line>'; send-keys Enter (last line `end` without Enter); capture
    expect: the column positions listed above
**Observed.** Exactly the listed columns.

### MI-18 — Soft-wrapped long command lines
**Behavior.**
- A line longer than the terminal wraps at the last column, and the remainder starts at column 0 of the next row with no indentation.
- If a character would not fit (a wide character at the last column), the wrap happens before it.
- When the text exactly fills the last column, fish moves its cursor to column 0 of the next row and adds an empty row.
- On Enter in that state, no extra `\n` is written (MI-09).
- Control characters in the buffer (other than `\n`) are displayed as Unicode Control Pictures, U+2400 + code (e.g. a tab shows as `␉`).
**Source.** `src/screen.rs:791-826` (soft-wrap: x=0, `is_soft_wrapped`), `:453-460` (empty line after an exactly-full line), `:2056-2062` (rendered_character); `src/reader/reader.rs:2646-2650`.
**Test.**
    setup: std (width 100)
    keys:  send-keys -l "$(printf 'x%.0s' $(seq 90))"; capture
    expect: row 1 = prompt + 84 x's (to col 99), row 2 starts at col 0 with the remaining 6 x's

### MI-19 — Implicit cd: typing a directory path as the command
**Behavior.** If the command word is not a function, builtin or executable on `$PATH`, and the statement has no decorator, no arguments and no redirections, fish tries an implicit cd. It applies when the word, after tilde expansion:
- starts with `/`, `./` or `../`, or
- ends with `/`, or
- equals `..`

and the word resolves to an existing directory. Resolution: absolute paths as-is; `./`, `../` and `..` relative to `$PWD`; any other name (e.g. `foo/`) through `$CDPATH` entries and then `.`.

When it applies, fish runs `cd -- <word>`. It uses the `cd` function if one is defined, and fish ships one that maintains dir history (MI-22). So `~`, `~/x`, `..`, `../x`, `sub/` and `/tmp` work. `.` and a bare `sub` (no slash) do not: they produce command-not-found.
**Source.** `src/path.rs:383-399` (prefix/suffix rules after expand_tilde), `:315-381` (CDPATH resolution, PWD appended); `src/parse_execution.rs:751-807` (only when not found, undecorated, no args/redirs; runs `cd --`, function if it exists); `share/functions/cd.fish:5-52`.
**Test.**
    setup: std; mkdir -p $W/sub/deep
    keys:  send-keys 'sub/deep/' Enter; send-keys '..' Enter; send-keys '~' Enter; capture
    expect: prompts `~/w/s/deep>`, `~/w/sub>`, then `~>`
**Observed.** The final prompt was `darin@echo ~> `. `sub` without a slash gave `fish: Unknown command: sub`.

### MI-20 — Implicit-cd highlighting and `...`
**Behavior.** A command word that would implicit-cd is highlighted as a valid command (`fish_color_command`, default color). Otherwise an unknown word is `fish_color_error` (brred). The check only happens when no builtin, function, abbreviation or command matched, and it is skipped under the `command`, `exec` and `builtin` decorators. `...` (and `....`) is not special in 4.9.3. No `...` function ships, so it is an unknown command.
**Source.** `src/highlight/highlight.rs:244-285`; `src/path.rs:388-393` (only `..` is allowed exactly).
**Test.**
    setup: std; mkdir -p $W/sub/deep
    keys:  send-keys -l 'sub/'; capture -e; send-keys C-c; send-keys -l '...'; capture -e
    expect: `sub/` uncolored, followed by the autosuggestion `deep/` in SGR 90; `...` in SGR 91
**Observed.** `sub/` uncolored, with `^[[90mdeep/` after it. The `...` case is derived from source.

### MI-21 — Terminal title (OSC 0): `~/w` at the prompt, `<cmd> ~/w` while a command runs
**Behavior.**
- fish writes `ESC ] 0 ; <title> ESC \`, terminated by ST, not BEL.
- It is written each time the prompt is drawn, with no argument. It is also written just before a command runs, with the command line as its argument.
- The default `fish_title` prints:
  - `[host]` (hostname truncated to 10 characters, only when `$SSH_TTY` is set)
  - then the first 20 characters of the command line, or at the prompt `status current-command` (which is `fish` there, so it is suppressed)
  - then `prompt_pwd -d 1 -D 1`
  - all joined by single spaces.
- So the title is `~/w` at the prompt and `echo hi ~/w` while running `echo hi`.
- If `fish_title` is erased, fish falls back to `echo (status current-command) " " $PWD`.
- The title is emitted unconditionally, for any terminal.
**Source.** `src/reader/reader.rs:5060-5138` (write_title; OSC 0 plus OSC 1, `\r` only when reset requested), `:5225-5228` (at the prompt), `:6407` (before the command), `:1319` (DEFAULT_TITLE); `src/terminal.rs:175-182`; `share/functions/fish_title.fish:1-18`.
**Test.**
    setup: std
    keys:  tmux display -p '#{pane_title}'; send-keys 'sleep 2' Enter; tmux display -p '#{pane_title}'
    expect: `~/w`, then `sleep 2 ~/w`
**Observed.** Raw: `␛]0;~/w␛\` at each prompt; `␛]0;echo hi ~/w␛\` and `␛]0;printf foo ~/w␛\` before those commands.

### MI-22 — Directory history: prevd/nextd on alt-left/alt-right (empty line), `cd -`, dirh
**Behavior.**
- The `cd` function appends the old `$PWD` to `$dirprev` after each successful directory change, keeping at most 25 entries. It clears `$dirnext`.
- On an empty command line:
  - `alt-left` / `alt-b` run `prevd`, and `alt-right` / `alt-f` run `nextd`, each followed by a repaint so the prompt shows the new directory. On a non-empty line they move by word instead.
  - `alt-d` prints `dirh`.
- `cd -` goes back or forward depending on `$__fish_cd_direction`.
- `dirh` prints the previous dirs as `%2d) path` (oldest at the top, highest number), then the current `$PWD` indented by three spaces in `fish_color_history_current` (bold), then the next dirs, then a blank line.
**Source.** `share/functions/__fish_shared_key_bindings.fish:47-55,79`; `src/input/binding.rs:270,273`; `src/reader/reader.rs:3807-3812` (prevd), `:3621-3626` (nextd); `share/functions/cd.fish:5-52`; `share/functions/prevd.fish:2-45`; `share/functions/dirh.fish:2-32`.
**Test.**
    setup: std; mkdir $W/a
    keys:  send-keys 'cd a' Enter; send-keys M-Left; capture; send-keys M-Right; capture
    expect: prompt `~/w>` after M-Left, `~/w/a>` after M-Right (command line stays empty)

### MI-23 — Command-not-found message
**Behavior.** For an unknown command, fish calls `fish_command_not_found <cmd> <args…>` with stdout redirected to stderr. The default handler prints `fish: Unknown command: <escaped cmd>`. On macOS, and anywhere without a known distro handler, that is all for a command at offset 0. If the command is not at the start of the line, fish follows with `fish:`, the source line, and a caret/tilde line under the command. Status is 127. `$status` from before the handler is restored. A file that exists but is not executable reports `Unknown command. '<path>' exists but is not an executable file.` with status 126.
**Source.** `src/parse_execution.rs:259-365`; `share/functions/fish_command_not_found.fish:4-6` (default, with distro overrides `:22-80`); `share/functions/__fish_default_command_not_found_handler.fish:2-4`; `src/parse_constants.rs:363-407`.
**Test.**
    setup: std
    keys:  send-keys anyw Enter; send-keys 'cd .; sub' Enter; capture
    expect: `fish: Unknown command: anyw`, prompt `[127]`; then `fish: Unknown command: sub` / `fish:` / `cd .; sub` / `      ^~^`
**Observed.** Both outputs, the second with `cd w; sub` and `      ^~^`.

### MI-24 — OSC 133 shell-integration marks (and kitty click_events)
**Behavior.** Unless the `mark-prompt` feature flag is off, or the terminal is Konsole (and `omit-term-workarounds` is off):
- before the prompt: `ESC]133;A;click_events=1 ESC\`
- after the prompt text, before the command line: `ESC]133;B ESC\`
- when a command starts, after the final redraw and newline: `ESC]133;C;cmdline_url=<URL-escaped command line> ESC\`
- after it finishes, before the ⏎ sequence: `ESC]133;D;<exit status> ESC\` followed by `ESC[?25h` (show cursor)

A and B wrap every prompt. C and D are not emitted for an empty command line.
**Source.** `src/terminal.rs:189-227`; `src/screen.rs:1083-1116` (A/B around the prompt); `src/reader/reader.rs:868` (C), `:884-892` (D, show cursor), `:860-862`.
**Test.**
    setup: std, with fish run under `script -F -q raw.out fish` inside tmux
    keys:  send-keys 'false' Enter; then inspect raw.out
    expect: `␛]133;C;cmdline_url=false␛\` … `␛]133;D;1␛\␛[?25h␛[2m⏎…`
**Observed.** Exactly so, including `cmdline_url=echo%20hi` for `echo hi`.

### MI-25 — OSC 7 working-directory report on every prompt and on every PWD change
**Behavior.** fish writes `ESC]7;file://<host><PWD> BEL`. Host and PWD are URL-escaped. The host is empty under Konsole, and nothing is sent when `TERM=dumb`. It is sent once at startup, on every `fish_prompt` event, and whenever `$PWD` changes. The terminator is BEL (`\a`), unlike the title.
**Source.** `share/functions/__fish_config_interactive.fish:140-162`; CHANGELOG.rst 4.3.0 ("working directory is now reported on every fresh prompt").
**Test.**
    setup: std under `script -F`
    keys:  send-keys 'echo hi' Enter; inspect raw.out
    expect: `␛]7;file://echo/private/tmp/.../w\a` before each prompt's title sequence
**Observed.** Yes (the hostname `echo` precedes the path).

### MI-26 — Startup terminal queries
**Behavior.** Before the first prompt, fish writes:
1. `ESC[?u` (kitty keyboard query; skipped for `TERM=st-256color`)
2. `ESC[>0q` (XTVERSION)
3. `ESC]11;? ESC\` (background color)
4. `ESC[?1049h`, then XTGETTCAP queries `ESC P+q696e646e ESC\` ("indn") and `ESC P+q71756572792d6f732d6e616d65 ESC\` ("query-os-name"), then `ESC[?1049l`
5. `ESC[0c` (Primary DA)

It then blocks until the DA1 reply arrives. At every new prompt it re-sends `ESC]11;? ESC\`, `ESC[6n` (cursor position) and `ESC[0c`.
**Source.** `src/reader/reader.rs:272-300` (initial queries; wait for DA1), `:2612-2617` and `:1733-1736` (per-prompt queries); `src/terminal.rs:163-173,306-325`.
**Test.**
    setup: std under `script -F`
    keys:  none; inspect the first bytes of raw.out
    expect: `␛[?u␛[>0q␛]11;?␛\␛[?1049h␛P+q696e646e␛\␛P+q71756572792d6f732d6e616d65␛\␛[?1049l␛[0c`
**Observed.** Exactly that prefix.

### MI-27 — Keyboard protocol, bracketed paste and focus reporting are on only while editing
**Behavior.**
- Right before reading input, fish enables:
  - focus reporting `ESC[?1004h`, only under tmux
  - bracketed paste `ESC[?2004h`
  - color-theme reporting `ESC[?2031h`, except under tmux older than 3.7
  - one keyboard mode:
    - kitty progressive enhancements `ESC[=5u`, if the terminal answered the `ESC[?u` query
    - otherwise modifyOtherKeys `ESC[>4;1m` plus application keypad `ESC=`
    - nothing under Midnight Commander
    - modifyOtherKeys only (never kitty) under iTerm2 < 3.5.12 and under Konsole unless `omit-term-workarounds`
    - only `ESC=` under WezTerm
- Before running a command or a key-binding script, and before the prompt function runs, fish sends the matching disable sequence: `ESC[?1004l ESC[?2004l ESC[>4;0m ESC>` (or `ESC[=0u`).
- Under tmux 3.6a, fish detects tmux from XTVERSION, gets no kitty reply, and uses modifyOtherKeys. Distinguishing shift-space, shift-enter and alt-enter therefore needs tmux `extended-keys on`.
**Source.** `src/tty_handoff.rs:77-97` (quirks), `:153-174` (protocol choice), `:177-226` (byte sequences), `:266-305`; `src/terminal.rs:311-333`; `src/reader/reader.rs:2619-2628,5160-5162,2689-2697`.
**Test.**
    setup: std under `script -F`
    keys:  send-keys 'echo hi' Enter; inspect raw.out
    expect: before each prompt `␛[?1004h␛[?2004h␛[>4;1m␛=`; after Enter `␛[?1004l␛[?2004l␛[>4;0m␛>`
**Observed.** Exactly those sequences under tmux 3.6a.

### MI-28 — Focus events
**Behavior.** With focus reporting active (tmux only, by default), `ESC[I` fires the `fish_focus_in` event and `ESC[O` fires `fish_focus_out`. Nothing is displayed by default.
**Source.** `src/input/decode.rs:536-539`; `src/reader/reader.rs:2896-2901`.
**Test.**
    setup: std; define `function f --on-event fish_focus_in; echo FOCUS; end`; tmux `set -g focus-events on`
    keys:  tmux select-pane / switch windows away and back
    expect: `FOCUS` printed

### MI-29 — Bracketed paste never executes; pasted text is one undo step
**Behavior.**
- Bytes between `ESC[200~` and `ESC[201~` are buffered without running any binding, so pasted newlines do not execute.
- At the end, fish calls `__fish_paste <escaped text>` (MI-30) between BeginUndoGroup and EndUndoGroup, so a single ctrl-z removes the whole paste.
- There is no paste bind mode in 4.x.
- Pasted text never expands abbreviations (AB-19).
**Source.** `src/input/decode.rs:44-58` (non-ESC bytes go to the paste buffer), `:424-431`; `src/reader/input.rs:64-81`; CHANGELOG.rst 4.0.0 (paste bind mode removed).
**Test.**
    setup: std
    keys:  printf 'echo a\necho b\n' | tmux load-buffer -; tmux paste-buffer -p -t t; capture; tmux display -p '#{cursor_x},#{cursor_y}'
    expect: rows `echo a`, `echo b` (at column 16), cursor at (16, row 3) on an empty third line; nothing executed
**Observed.** Exactly that. The trailing newline was kept as an empty third line, cursor at (16,2).

### MI-30 — `__fish_paste` text transformations
**Behavior.** In order:
1. Split the text on `\r` and `\n` into lines, then delete every `[[:cntrl:]]` character from each line (tabs included: `xa\tb\001c` → `xabc`).
2. If the pager search field is active, insert there and stop.
3. If the current token has an unclosed single quote, escape every `'` and `\` in the paste with a backslash (`echo '` + `it's \x` → `echo 'it\'s \\x`).
4. Otherwise, if not inside double quotes and there are two or more lines, strip leading whitespace from lines 2+ that start outside quotes (fish re-indents them itself).
5. If the cursor is at the very start of the buffer, strip leading whitespace from line 1 so the command is not made ephemeral (`   ls` → `ls`).
6. Join the lines with `\n` and insert them with `commandline --insert-smart` (plain `--insert` for root). `--insert-smart` removes a `$ ` prompt prefix at the start of each pasted command line (`$ echo hi\n$ echo there` → `echo hi\necho there`).

A trailing newline in the paste is kept as an empty last line (MI-29).
**Source.** `share/functions/__fish_paste.fish:2-55`; `src/builtins/commandline.rs:81-91,102-138` (strip_dollar_prefixes: only at a statement start that begins a line), `:814` (args joined with `\n`).
**Test.**
    setup: std
    keys:  paste (via load-buffer/paste-buffer -p) each of: '$ echo hi\n$ echo there' ; '   ls' ; (after typing `echo '`) "it's \\x" ; 'xa\tb\001c' ; 'if true\n    echo x\nend'
    expect: `echo hi`/`echo there`; `ls`; `echo 'it\'s \\x`; `xabc`; `if true` / `    echo x` (col 20) / `end` (col 16)
**Observed.** All five exactly. A paste of `it's` after `echo "` stayed `echo "it's` (no escaping inside double quotes).

### MI-31 — ctrl-v (`fish_clipboard_paste`) uses the same pipeline
**Behavior.** ctrl-v reads the clipboard (`pbpaste`, `wl-paste -n`, `xsel --clipboard`, `xclip -selection clipboard -o`, or `powershell.exe Get-Clipboard`, the first one available) and feeds it through `__fish_paste`. It returns 1 and does nothing if the clipboard is empty. If stdout is not a tty, it prints the data as-is.
**Source.** `share/functions/fish_clipboard_paste.fish:1-27`; `share/functions/__fish_shared_key_bindings.fish:30`.
**Test.**
    setup: std (macOS); `printf '$ echo x' | pbcopy`
    keys:  send-keys C-v; capture
    expect: `echo x`

### MI-32 — No auto-pairing of quotes or brackets
**Behavior.** Typing `(`, `[`, `{`, `"` or `'` inserts only that character. fish 4.9.3 has no auto-pairing binding or feature: these keys hit the generic `self-insert` binding, and `)` only adds `expand-abbr`.
**Source.** `share/functions/__fish_shared_key_bindings.fish:106,119`; `share/functions/fish_default_key_bindings.fish:1-67` (no bindings for these keys); no auto-pair entry in CHANGELOG.rst.
**Test.**
    setup: std
    keys:  send-keys -l 'echo "('; capture
    expect: `echo "(` exactly, cursor at the end
**Observed.** `echo "gc ` stayed as typed (no closing quote added).

### MI-33 — Cursor shape: never changed in the default (emacs) bindings
**Behavior.** fish sends no DECSCUSR (`ESC[N q`) sequences unless vi mode is enabled. In vi mode, `fish_vi_key_bindings` calls `fish_vi_cursor`. In default mode the terminal's cursor shape is left alone.
**Source.** `share/functions/fish_vi_key_bindings.fish:668,681-685`; `grep -l fish_vi_cursor` finds only vi files; CHANGELOG.rst 4.0.1 (no cursor shape commands in non-interactive shells).
**Test.**
    setup: std under `script -F`
    keys:  type and run a few commands; grep raw.out for ` q`
    expect: no `ESC[<digit> q`
**Observed.** No DECSCUSR in the raw capture.

### MI-34 — Exiting with background jobs: a warning first, the second attempt exits
**Behavior.**
- `exit` (or ctrl-d on an empty line) with running background jobs does not exit the first time. It prints:
  `There are still jobs active:` / (blank) / `   PID  Command` / one `%6d  %s` row per job / (blank) / `A second attempt to exit will terminate them.` / `Use 'disown PID' to remove jobs from the list without terminating them.`
  and redraws the prompt.
- A second exit attempt right away exits, sending SIGHUP to the jobs. Running any other command in between resets the warning.
**Source.** `src/reader/reader.rs:6540-6582`, `:894-902` (reset after another command), `:3380-3395` (ctrl-d exit path); `src/proc.rs:993-1026`.
**Test.**
    setup: std
    keys:  send-keys 'sleep 30 &' Enter; send-keys exit Enter; capture
    expect: the warning above with the sleep's PID right-aligned in 6 columns and command `sleep 30 &`; fish still running
**Observed.** `There are still jobs active:` / `   PID  Command` / ` 84229  sleep 30 &` / `A second attempt…` / `Use 'disown PID'…` (blank lines filtered in capture).

### MI-35 — Background jobs: no launch message; "has ended" notice; stop/signal messages
**Behavior.**
- Launching `cmd &` prints nothing (no `[1] PID`) and leaves `$status` unchanged.
- When a background job finishes, fish prints `fish: Job N, '<cmd>' has ended` (cmd shortened to 32 columns) via `__fish_echo`. The notice appears below the current command line and the prompt and command line are redrawn under it. This happens at the next input wakeup.
- A stopped job (ctrl-z) prints `fish: Job N, '<cmd>' has stopped` to stderr.
- A process killed by a signal other than SIGPIPE prints `fish: Job N, '<cmd>' terminated by signal SIGXXX (<description>)`. For multi-process jobs it prints `fish: Process PID, '<name>' from job N, '<cmd>' terminated by signal …`.
- SIGINT on a foreground job prints nothing.
- `fg` prints `Send job N (<cmd>) to foreground` to stderr.
**Source.** `src/proc.rs:1390-1437` (when a summary is emitted), `:1452-1497` (fish_job_summary args), `:1502-1525`; `share/functions/fish_job_summary.fish:1-51`; `share/functions/__fish_echo.fish:2-10`; `src/builtins/shared/misc.rs:25-26` (FG_MSG).
**Test.**
    setup: std
    keys:  send-keys 'sleep 1 &' Enter; wait 2s; send-keys -l x; capture
    expect: no output after launch; then `fish: Job 1, 'sleep 1 &' has ended` followed by a fresh prompt containing `x`
**Observed.** No launch output. `fish: Job 1, 'sleep 1 &' has ended` appeared after the old prompt row, followed by a redrawn prompt.

### MI-36 — ctrl-c during a foreground command
**Behavior.** The child gets SIGINT from the tty, and the tty echoes `^C` if `echoctl` is on. fish prints nothing extra: the SIGINT job summary is suppressed. The next prompt starts after the ⏎ sequence, so the row shows `^C⏎`, and the status `[SIGINT]` (exit 130) appears in bold red. ctrl-c at the prompt is the separate `clear-commandline` binding, which clears the line without printing `^C`.
**Source.** `share/functions/fish_job_summary.fish:23-25`; `share/functions/fish_status_to_signal.fish:4-10`; `share/functions/__fish_shared_key_bindings.fish:72`.
**Test.**
    setup: std
    keys:  send-keys 'sleep 5' Enter; send-keys C-c; capture
    expect: row `^C⏎`; next prompt `darin@echo ~/w [SIGINT]> `
**Observed.** Exactly so.

### MI-37 — Command duration: `$CMD_DURATION` only, never displayed by default
**Behavior.** After every non-empty command line, fish sets the unexported global `CMD_DURATION` to the wall-clock milliseconds the command took. The default prompt does not display it.
**Source.** `src/reader/reader.rs:6413-6427`; `share/functions/fish_prompt.fish:4-32` (no reference).
**Test.**
    setup: std
    keys:  send-keys 'sleep 1; echo $CMD_DURATION' Enter; send-keys 'echo $CMD_DURATION' Enter
    expect: the second value is about 1000-1100

### MI-38 — Window resize
**Behavior.**
- On a width change, the next repaint moves to the start of the prompt, clears to the end of the screen, and redraws everything.
- In addition, the `__fish_winch_handler` (on SIGWINCH) runs `commandline -f repaint` when `fish_handle_reflow` is 1. The default is 1, except 0 when `status terminal` reports VTE, Konsole or WezTerm, when `$KONSOLE_VERSION` ≥ 210400, or when `TERM` is `alacritty*`. Under tmux it is 1.
- Since 4.6, SIGWINCH no longer interrupts builtin output.
**Source.** `src/screen.rs:1036-1047`; `share/functions/__fish_config_interactive.fish:113-138`; CHANGELOG.rst 4.6.0, 4.2.0.
**Test.**
    setup: std
    keys:  send-keys -l 'echo abc'; tmux resize-window -x 60; capture
    expect: a single prompt row `darin@echo ~/w> echo abc` (no duplicated prompt)

### MI-39 — 4.x interactive CHANGELOG entries in this area, mapped to behaviors and code
**Behavior.** Each relevant 4.0–4.9.3 entry is listed with where it is implemented or specified above:
- 4.0.0: OSC 133 marks → MI-24. OSC 7 unconditional → MI-25. OSC 0 title unconditional → MI-21. kitty/modifyOtherKeys → MI-27. Paste bind mode removed → MI-29. Focus reporting in tmux → MI-27/28. `fish_should_add_to_history` → MI-12. ctrl-v strips control characters → MI-30/31. Abbreviations after decorators and separators → AB-09. `--command` → AB-12. shift-enter inserts a newline → AB-04.
- 4.0.1: OSC 133 C carries the command line (`src/terminal.rs:211-220`). No cursor-shape commands in non-interactive shells → MI-33.
- 4.1.0:
  - transient prompt → MI-08
  - `$ ` paste stripping → MI-30
  - braces as compound commands (`{` is incomplete until `}`) → MI-13
  - ctrl-l pushes text to scrollback via `scrollback-push`, only if the terminal reports `indn` through XTGETTCAP (`share/functions/__fish_shared_key_bindings.fish:69-71`, `src/reader/reader.rs:4371-4373`, `src/screen.rs:560`)
  - kitty `click_events=1` in OSC 133 A → MI-24
- 4.2.0: `fish_tab_title` sets OSC 1 (`src/reader/reader.rs:5123-5130`; no default function, so no OSC 1 is emitted by default). Scrolled-out multi-line prompt lines are hidden (`src/screen.rs:1059-1060`, visible_prompt_lines). Mouse capture is no longer force-disabled. VTE does not redraw on resize → MI-38.
- 4.3.0: OSC 7 on every fresh prompt → MI-25. OSC 133 prompt end (B) → MI-24. `omit-term-workarounds` flag (`src/terminal.rs:184-187`). The first prompt renders correctly when typing during startup → MI-01.
- 4.6.0: `SHELL_PROMPT_PREFIX`/`SUFFIX`/`SHELL_WELCOME` → MI-07/MI-01. Intermediate ⏎ artifact fixed → MI-10.
- 4.7.0: `prompt_pwd` strips control characters → MI-03.
- 4.8.0/4.8.1: abbr anywhere completions added, then removed for argument position → AB-22. OSC 133 disabled on Konsole → MI-24.
- 4.9.0: abbreviation descriptions → AB-22/AB-23. kitty protocol not requested on Konsole → MI-27. shift-space mappable separately from space → AB-03.
**Source.** CHANGELOG.rst:1-1000 (sections 4.9.3 back to 4.0.0), with the code cited in each referenced behavior.
**Test.**
    setup: std
    keys:  see the referenced behaviors
    expect: see the referenced behaviors

### Notes for zsh implementers (misc)
- Byte-level fidelity for screen tests: fish writes `ESC[m` for resets, and tmux `capture-pane -e` re-encodes them (e.g. `ESC[39m`). Compare rendered cells and colors, not raw bytes. Use `script -F` or `pipe-pane -O` captures only for OSC, DEC mode and title checks (MI-21, MI-24 to MI-27).
- The ⏎ algorithm (MI-10) must be reproduced exactly: dim ⏎, W−1 spaces, `\r⏎ \r`, `ESC[K`. It differs from zsh's PROMPT_SP/PROMPT_EOL_MARK, which prints `%` in reverse video. Set `PROMPT_EOL_MARK` to a dim ⏎ (`%{\e[2m%}⏎%{\e[m%}`) and keep PROMPT_SP on, then verify `printf foo` shows `foo⏎` and nothing on clean lines. fish also skips this on the very first prompt.
- Indentation (MI-16/17) is display-only. In pseudo-code:
  ```
  if '\n' not in src: all 0
  parse with error recovery; walk AST depth-first with indent=-1, last_indent=-1:
    JobList/AndorJobList: +1 for children
    JobConjunction whose parent is IfClause/WhileHeader: +1
    JobContinuation (| stmt) whose newlines part contains '\n': +1
    JobConjunctionContinuation (&&/|| job) with '\n': +1
    CaseItemList: +1 (not undone if the switch has no `end` yet)
    the optional '\n' token ending a `begin` header: +1
    if an increment happened: last_indent = indent
    for each non-empty leaf: chars since the previous leaf end get last_indent; the leaf and its leading spaces get indent
       (inside the leaf: cmdsub contents use compute_indents(contents, indent+1); text inside a quoted string after its first line keeps 0)
       last_indent = indent
  chars after the last leaf get last_indent
  right-to-left pass: each '\n' takes the indent of the next non-'\n' char, except an empty middle line ("\n\n")
     and a final '\n' inside an unclosed quote/cmdsub
  each backslash-newline (not after '#' on that gap): that '\n' and the rest of its line get +1
  render: after each '\n', pad with prompt_last_line_width + 4*indent['\n'] spaces
  ```
  (`src/parse_util.rs:697-1060`, `src/screen.rs:383-387,760-786`.) zsh's `PS2` cannot express this. Each continuation line's indentation has to be computed and drawn by your own widget/redisplay code, and must not be inserted into `$BUFFER`.
- Enter on an incomplete line inserts the newline at the cursor, not at the end (MI-13). A hard syntax error keeps the buffer and prints `\nfish: …` with caret rules (MI-15). zsh's default `accept-line` either executes or shows a PS2 continuation; both differ.
- Implicit cd (MI-19) is stricter than zsh `AUTO_CD`: it requires a `/` prefix or suffix, `./`, `../`, `..`, or `~`, and no arguments. A bare `sub` must not cd.
- Paste (MI-29/30) needs zsh's `bracketed-paste` widget replaced with a port of `__fish_paste`: control-character stripping, single-quote escaping, `$ ` stripping, leading-whitespace trimming, no execution, one undo step.
