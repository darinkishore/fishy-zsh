# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Side-by-side fish vs zsh screen harness (termctrl / Ghostty terminal core).

Starts fish (reference) and zsh (with ./zdotdir) in identical sandboxes as
termctrl sessions, with the exact environment Ghostty gives a login shell
(shell integration included), feeds both the same physical keystrokes, and
diffs the resulting screens cell by cell: text, colors, attributes, cursor.

Step syntax (one CLI arg per step):
  =text          type literal text
  tab enter escape backspace delete up down left right home end
  page-up page-down shift-tab   plain keys
  ctrl-a .. ctrl-z, ctrl-space, ctrl-_          control keys
  alt-<c>        ESC + char (what an Option-as-Alt key sends)
  opt-left/opt-right     Ghostty default: ESC b / ESC f
  cmd-left/cmd-right/cmd-backspace   Ghostty default: ^A / ^E / ^U
  ctrl-left/ctrl-right/shift-left/shift-right/alt-up/alt-down   xterm CSI
  @0.5           sleep 0.5s on top of the automatic settle
  !cmd           type cmd + enter (setup steps)

Examples:
  uv run harness/fz.py shot '=git ch' tab
  uv run harness/fz.py shot --only zsh '=cd Dow' tab
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEPS = ROOT / "deps"
SANDBOX = ROOT / ".sandbox"
COLS, ROWS = 100, 30
SHELLS = ("fish", "zsh")
PREFIX = "fishy-"  # termctrl session name prefix

GHOSTTY = Path("/Applications/Ghostty.app/Contents")
GHOSTTY_RES = GHOSTTY / "Resources" / "ghostty"
GHOSTTY_SI = GHOSTTY_RES / "shell-integration"

PALETTE: list[str] = json.loads((ROOT / "harness" / "palette.json").read_text())
PALETTE_NAME = {rgb: str(i) for i, rgb in reversed(list(enumerate(PALETTE)))}
DEFAULT_FG, DEFAULT_BG = "c9d1d9", "0d1117"  # termctrl's default fg/bg

# Shared fixture history (oldest first). Mirrored into both shells' history files.
HISTORY: list[str] = [
    "ls -la",
    "git status",
    "git checkout main",
    "cd projects/alpha",
    "cd projects/beta",
    "echo hello world",
    "cat notes.txt",
    "cat missing-file.txt",
    "vim Documents/report.md",
    "git commit -m 'wip'",
    "make build",
    "git checkout -b feature/thing",
]

# Fixture filesystem relative to $HOME; trailing / means directory.
TREE: list[str] = [
    "projects/alpha/src/",
    "projects/alpha/README.md",
    "projects/beta/",
    "projects/gamma-ray/",
    "Documents/report.md",
    "Documents/Notes/",
    "Downloads/archive.tar.gz",
    "Downloads/photo.JPG",
    "notes.txt",
    "Makefile",
    "my file with spaces.txt",
    ".hidden/",
    ".dotfile",
]

# Physical key -> bytes, as Ghostty sends them in legacy (non-kitty) encoding.
KEYS: dict[str, bytes] = {
    "tab": b"\t",
    "shift-tab": b"\x1b[Z",
    "enter": b"\r",
    "escape": b"\x1b",
    "backspace": b"\x7f",
    "delete": b"\x1b[3~",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "right": b"\x1b[C",
    "left": b"\x1b[D",
    "home": b"\x1b[H",
    "end": b"\x1b[F",
    "page-up": b"\x1b[5~",
    "page-down": b"\x1b[6~",
    "ctrl-space": b"\x00",
    "ctrl-_": b"\x1f",
    "ctrl-left": b"\x1b[1;5D",
    "ctrl-right": b"\x1b[1;5C",
    "shift-left": b"\x1b[1;2D",
    "shift-right": b"\x1b[1;2C",
    "alt-up": b"\x1b[1;3A",
    "alt-down": b"\x1b[1;3B",
    "alt-left": b"\x1b[1;3D",
    "alt-right": b"\x1b[1;3C",
    "alt-enter": b"\x1b\r",
    "alt-backspace": b"\x1b\x7f",
    # Ghostty macOS default keybinds (see `ghostty +list-keybinds --default`).
    "opt-left": b"\x1bb",
    "opt-right": b"\x1bf",
    "cmd-left": b"\x01",
    "cmd-right": b"\x05",
    "cmd-backspace": b"\x15",
}
for _c in "abcdefghijklmnopqrstuvwxyz":
    KEYS[f"ctrl-{_c}"] = bytes([ord(_c) - 96])


def key_bytes(step: str) -> bytes:
    if step in KEYS:
        return KEYS[step]
    if step.startswith("alt-") and len(step) == 5:
        return b"\x1b" + step[4].encode()
    raise SystemExit(f"unknown key: {step}")


def termctrl(*args: str, stdin: bytes | None = None, check: bool = True) -> str:
    res = subprocess.run(["termctrl", *args], input=stdin, capture_output=True)
    if check and res.returncode != 0:
        raise RuntimeError(f"termctrl {args}: {res.stderr.decode().strip()}")
    return res.stdout.decode()


# ---------------------------------------------------------------- sandbox


def build_home(shell: str) -> Path:
    """Fresh $HOME per shell per run, so history/state never leak between shots."""
    home = SANDBOX / shell / "home"
    if home.exists():
        shutil.rmtree(home)
    for entry in TREE:
        p = home / entry
        if entry.endswith("/"):
            p.mkdir(parents=True, exist_ok=True)
        else:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(f"{entry}\n")

    # Both shells get the same fish config + fish history: zsh's fishy server
    # is a (non-interactive) fish that reads them exactly like the reference.
    base = 1_760_000_000
    cfg = home / ".config" / "fish"
    cfg.mkdir(parents=True)
    shutil.copy(ROOT / "harness" / "fish-config.fish", cfg / "config.fish")
    data = home / ".local" / "share" / "fish"
    data.mkdir(parents=True)
    lines = []
    for i, cmd in enumerate(HISTORY):
        esc = cmd.replace("\\", "\\\\")
        lines.append(f"- cmd: {esc}\n  when: {base + i}\n")
    (data / "fish_history").write_text("".join(lines))
    if shell == "zsh":
        (home / ".zsh_history").write_text("".join(f"{c}\n" for c in HISTORY))
    return home


def shell_env(shell: str, home: Path) -> dict[str, str]:
    """The environment Ghostty 1.3.1 gives a shell (read from a live Ghostty fish)."""
    env = {
        "HOME": str(home),
        "USER": os.environ.get("USER", "darin"),
        "LOGNAME": os.environ.get("USER", "darin"),
        "SHELL": str(DEPS / "bin" / shell),
        "LANG": "en_US.UTF-8",
        "PATH": f"{DEPS / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin",
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "FISHY_ROOT": str(ROOT),
        # Patched fish for zsh's server: the nix build, or a dev cargo build.
        "FISHY_FISH": os.environ.get("FISHY_DEV_FISH", str(DEPS / "bin" / "fishy-fish")),
        "FISHY_LOG": os.environ.get("FISHY_LOG", ""),
        # Ghostty-provided
        "TERM": "xterm-ghostty",
        "TERMINFO": str(GHOSTTY / "Resources" / "terminfo"),
        "COLORTERM": "truecolor",
        "TERM_PROGRAM": "ghostty",
        "TERM_PROGRAM_VERSION": "1.3.1",
        "GHOSTTY_RESOURCES_DIR": str(GHOSTTY_RES),
        "GHOSTTY_BIN_DIR": str(GHOSTTY / "MacOS"),
        "GHOSTTY_SHELL_FEATURES": "cursor:blink,path,title",
    }
    match shell:
        case "fish":
            env |= {
                "XDG_DATA_HOME": str(home / ".local" / "share"),
                "GHOSTTY_SHELL_INTEGRATION_XDG_DIR": str(GHOSTTY_SI),
                "XDG_DATA_DIRS": f"{GHOSTTY_SI}:/usr/local/share:/usr/share:{GHOSTTY_RES}/..",
            }
        case "zsh":
            # Ghostty's zsh injection: ZDOTDIR -> its integration dir, which
            # restores GHOSTTY_ZSH_ZDOTDIR and then sources the user's files.
            env |= {
                "XDG_DATA_HOME": str(home / ".local" / "share"),
                "ZDOTDIR": str(GHOSTTY_SI / "zsh"),
                "GHOSTTY_ZSH_ZDOTDIR": str(ROOT / "zdotdir"),
                "NOSYSZSHRC": "1",
                "HISTFILE": str(home / ".zsh_history"),
            }
    return env


# ---------------------------------------------------------------- screen model


@dataclass(frozen=True)
class Style:
    fg: str = ""  # palette index or #rgb; "" = default foreground
    bg: str = ""
    bold: bool = False
    faint: bool = False
    italic: bool = False
    underline: str = ""

    def label(self) -> str:
        parts = []
        if self.fg:
            parts.append(f"fg={self.fg}")
        if self.bg:
            parts.append(f"bg={self.bg}")
        for flag in ("bold", "faint", "italic"):
            if getattr(self, flag):
                parts.append(flag)
        if self.underline:
            parts.append(f"ul={self.underline}")
        return " ".join(parts) or "plain"


PLAIN = Style()


def color_name(rgb: dict[str, int], default: str) -> str:
    hexv = "%02x%02x%02x" % (rgb["r"], rgb["g"], rgb["b"])
    if hexv == default:
        return ""
    return PALETTE_NAME.get(hexv, f"#{hexv}")


@dataclass
class Screen:
    rows: list[list[tuple[str, Style]]]
    cursor: tuple[int, int]
    cursor_style: str
    sig: str  # change-detection signature

    def text(self, mark_cursor: bool = True) -> list[str]:
        out = []
        cx, cy = self.cursor
        for y, row in enumerate(self.rows):
            chars = [c for c, _ in row]
            if mark_cursor and y == cy and cx < len(chars):
                chars[cx] = "█" if chars[cx] == " " else chars[cx] + "̲"
            out.append("".join(chars).rstrip())
        return out

    def segments(self, y: int) -> list[tuple[int, int, Style]]:
        """Runs of identical visible non-plain style on row y."""
        segs: list[tuple[int, int, Style]] = []
        row = self.rows[y]
        start = 0
        for x in range(1, len(row) + 1):
            if x == len(row) or row[x][1] != row[start][1]:
                st = row[start][1]
                blank = all(c == " " for c, _ in row[start:x])
                visible = not blank or st.bg or st.underline
                if st != PLAIN and visible:
                    segs.append((start, x, st))
                start = x
        return segs


def parse_json(doc: dict) -> Screen:
    rows: list[list[tuple[str, Style]]] = [[(" ", PLAIN)] * COLS for _ in range(ROWS)]
    for c in doc["cells"]:
        a = c["attributes"]
        st = Style(
            fg=color_name(c["foreground"], DEFAULT_FG),
            bg=color_name(c["background"], DEFAULT_BG),
            bold=a["bold"],
            faint=a["faint"],
            italic=a["italic"],
            underline=a["underline"] or "",
        )
        text = c["text"] or " "
        x, y = c["x"], c["y"]
        if y < ROWS and x < COLS:
            rows[y][x] = (text, st)
            for k in range(1, c.get("width", 1)):  # wide char continuation
                if x + k < COLS:
                    rows[y][x + k] = ("", st)
    cur = doc["cursor"]
    sig = json.dumps([doc["cells"], cur], sort_keys=True)
    return Screen(rows=rows, cursor=(cur["x"], cur["y"]), cursor_style=cur.get("style", ""), sig=sig)


def capture(name: str) -> Screen:
    return parse_json(json.loads(termctrl("show", name, "--format", "json")))


def settle(name: str, quiet: float = 0.3, limit: float = 5.0) -> Screen:
    """Poll until the screen (cells + cursor) is unchanged for `quiet` seconds."""
    t0 = time.monotonic()
    last = capture(name)
    stable_since = time.monotonic()
    while time.monotonic() - t0 < limit:
        time.sleep(0.04)
        cur = capture(name)
        if cur.sig != last.sig:
            last, stable_since = cur, time.monotonic()
        elif time.monotonic() - stable_since >= quiet:
            return cur
    return last


# ---------------------------------------------------------------- driving


def start(shell: str) -> str:
    name = PREFIX + shell
    termctrl("stop", name, check=False)
    home = build_home(shell)
    env = shell_env(shell, home)
    # Ghostty launches the shell as a login shell via /usr/bin/login (argv0 "-fish").
    argv = [str(DEPS / "bin" / shell), "-l"]
    termctrl(
        "start", name, "--cols", str(COLS), "--rows", str(ROWS), "--cwd", str(home),
        "--", "/usr/bin/env", "-i", *(f"{k}={v}" for k, v in env.items()), *argv,
    )
    return name


def wait_prompt(name: str) -> None:
    """Wait for the neutral "> " prompt with the cursor right after it."""
    t0 = time.monotonic()
    s = capture(name)
    while time.monotonic() - t0 < 10:
        s = capture(name)
        cx, cy = s.cursor
        if cx == 2 and s.text(mark_cursor=False)[cy].startswith(">"):
            settle(name, quiet=0.3)
            return
        time.sleep(0.05)
    raise RuntimeError(f"{name}: prompt never appeared:\n" + "\n".join(s.text()))


def send(name: str, step: str) -> None:
    if step.startswith("@"):
        time.sleep(float(step[1:]))
        return
    if step.startswith("="):
        data = step[1:].encode()
    elif step.startswith("!"):
        data = step[1:].encode() + b"\r"
    else:
        data = key_bytes(step)
    termctrl("send", name, "--stdin", stdin=data)


def run_all(shells: list[str], steps: list[str]) -> dict[str, Screen]:
    names = {sh: start(sh) for sh in shells}
    for n in names.values():
        wait_prompt(n)
    for step in steps:
        for n in names.values():
            send(n, step)
        for n in names.values():
            settle(n)
    screens = {sh: settle(n) for sh, n in names.items()}
    for n in names.values():
        termctrl("stop", n, check=False)
    return screens


# ---------------------------------------------------------------- reporting


def last_used_row(*screens: Screen) -> int:
    n = 0
    for s in screens:
        for y, line in enumerate(s.text()):
            if line.strip():
                n = max(n, y + 1)
        n = max(n, s.cursor[1] + 1)
    return max(n, 1)


def fmt_segs(segs: list[tuple[int, int, Style]]) -> str:
    return "  ".join(f"[{a}-{b}) {st.label()}" for a, b, st in segs) or "plain"


def report(screens: dict[str, Screen]) -> int:
    """Print screens, style maps, and differences. Returns number of differences."""
    names = list(screens)
    height = last_used_row(*screens.values())
    for name in names:
        s = screens[name]
        print(f"── {name} (cursor x={s.cursor[0]} y={s.cursor[1]} {s.cursor_style}) " + "─" * 30)
        for y, line in enumerate(s.text()[:height]):
            print(f"{y:2}│{line}")
        for y in range(height):
            if segs := s.segments(y):
                print(f"   style {y:2}: {fmt_segs(segs)}")
    if len(names) != 2:
        return 0

    a, b = (screens[n] for n in names)
    diffs = 0
    print("── diff " + "─" * 60)
    if a.cursor != b.cursor or a.cursor_style != b.cursor_style:
        print(f"cursor: {names[0]}={a.cursor} {a.cursor_style}  {names[1]}={b.cursor} {b.cursor_style}")
        diffs += 1
    for y in range(height):
        ta = "".join(c for c, _ in a.rows[y]).rstrip()
        tb = "".join(c for c, _ in b.rows[y]).rstrip()
        if ta != tb:
            diffs += 1
            print(f"text  {y:2}: {names[0]}: {ta!r}")
            print(f"          {names[1]}: {tb!r}")
            continue
        sa, sb = a.segments(y), b.segments(y)
        if sa != sb:
            diffs += 1
            print(f"style {y:2}: {names[0]}: {fmt_segs(sa)}")
            print(f"          {names[1]}: {fmt_segs(sb)}")
    print("IDENTICAL" if diffs == 0 else f"{diffs} difference(s)")
    return diffs


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    shot = sub.add_parser("shot", help="run steps in both shells and diff")
    shot.add_argument("--only", choices=SHELLS)
    shot.add_argument("steps", nargs="*")
    args = ap.parse_args()

    match args.cmd:
        case "shot":
            shells = [args.only] if args.only else list(SHELLS)
            screens = run_all(shells, args.steps)
            sys.exit(1 if report(screens) else 0)


if __name__ == "__main__":
    main()
