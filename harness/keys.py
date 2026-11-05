# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""fishy's key decoder (fishy/input.zsh) vs fish's own, input by input.

fish's oracle is `fish_key_reader -cV` in a termctrl terminal: for every key
event it prints the input it was decoded from and the key in `bind` notation
(plus kitty's shifted and physical keys, and associated text). The zsh side is
harness/keydecode.zsh, which feeds the same bytes through fishy's port and
prints the same lines. Each case is sent as one burst; the pause after it is a
read timeout on both sides.

  uv run --no-project python harness/keys.py [-v]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
import fz

NAME = f"{fz.PREFIX}keys-fish"

# Bytes fish_key_reader (or the pty) reacts to on its own: ^C/^D twice exit,
# ^Z/^\ are signals, ^Q/^S flow control. The `exit`/`quit` words also exit.
SKIP = {0x03, 0x04, 0x0F, 0x11, 0x13, 0x16, 0x19, 0x1A, 0x1C}


def cases() -> list[bytes]:
    out: list[bytes] = []
    add = out.append
    # Every single byte, then ESC + each byte (legacy alt).
    for b in range(0x80):
        if b in SKIP:
            continue
        add(bytes([b]))
        if b != 0x1B:
            add(b"\x1b" + bytes([b]))
    add(b"\x1b\x1b")
    add(b"\x1b\x1b\x1b")
    add(b"\x1b\x1bb")
    add(b"\x1b\x1b[D")
    add(b"\x1b\x1bOD")
    add(b"\x1b\x1b[97;1u")
    add(b"\x1b\x1b[97;3u")
    add(b"\x1b\x1b[97;5u")
    # UTF-8 text, alone and with legacy alt.
    for t in ("é", "ß", "€", "😀", "с", "ä"):
        add(t.encode())
        add(b"\x1b" + t.encode())
    # CSI letters and ~ keys with every xterm modifier value.
    for final in "ABCDEFHPQS":
        add(f"\x1b[{final}".encode())
        for m in range(1, 17):
            add(f"\x1b[1;{m}{final}".encode())
    for code in (1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34):
        add(f"\x1b[{code}~".encode())
        for m in (2, 3, 5, 6, 7, 8, 9):
            add(f"\x1b[{code};{m}~".encode())
    add(b"\x1b[23$")
    add(b"\x1b[24$")
    add(b"\x1b[Z")
    add(b"\x1b[1;5Z")
    add(b"\x1b[[A")
    add(b"\x1b[[E")
    # SS3, with modifiers.
    for code in " ABCDFHIMPQRSXjklmnopqrstuvwxy":
        add(f"\x1bO{code}".encode())
        add(f"\x1bO5{code}".encode())
    # xterm modifyOtherKeys.
    for k in (9, 13, 27, 32, 44, 49, 97, 105, 127):
        for m in (2, 3, 5, 6):
            add(f"\x1b[27;{m};{k}~".encode())
    # kitty CSI u: plain, modified, with shifted / base-layout keys, text.
    for k in (9, 13, 27, 32, 97, 122, 127, 47, 45, 35, 49, 1089, 0x4E2D, 57376, 57399, 57408, 57409, 57414, 57417, 57425, 57426, 57361, 57363):
        add(f"\x1b[{k}u".encode())
        for m in (2, 3, 4, 5, 6, 7, 8, 9, 13, 65, 66, 70, 129):
            add(f"\x1b[{k};{m}u".encode())
    add(b"\x1b[97:65;2u")
    add(b"\x1b[97:65;6u")
    add(b"\x1b[122:90;6u")
    add(b"\x1b[51:35;4u")
    add(b"\x1b[45:95;6u")
    add(b"\x1b[1089::99;5u")
    add(b"\x1b[1089:1057:99;6u")
    add(b"\x1b[97;1;97u")
    add(b"\x1b[97;2;65u")
    add(b"\x1b[97;;97:98u")
    add(b"\x1b[97;5;1u")
    add(b"\x1b[127;1:3u")
    add(b"\x1b[97;1:2u")
    add(b"\x1b[57441;2u")
    add(b"\x1b[57358;65u")
    add(b"\x1b[99999999999u")
    # Replies and reports fish drops: each is followed by `a` to show
    # whether anything was left over.
    for seq in (b"\x1b[?5u", b"\x1b[?62;22c", b"\x1b[12;40R", b"\x1b[?997;1n", b"\x1b[?2004;1$y",
                b"\x1b]11;rgb:0d0d/1111/1717\x1b\\", b"\x1b]11;rgb:0/0/0\x07", b"\x1bP1+r696e646e\x1b\\",
                b"\x1bP>|ghostty 1.3.1\x1b\\", b"\x1b[<0;5;3M", b"\x1b[<0;5;3m", b"\x1b[<2;5;3M",
                b"\x1b[<4;5;3M", b"\x1b[M #$", b"\x1b[I", b"\x1b[O", b"\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17u",
                b"\x1b[1:2:3:4:5u", b"\x1b[;;;u", b"\x1b[9;5x", b"\x1b[?1;2y"):
        add(seq + b"a")
    return out


def esc(b: bytes) -> str:
    """bytes -> a printf format string for keydecode.zsh."""
    return "".join(f"\\x{c:02x}" if c < 0x20 or c >= 0x7F or c in b"\\%" else chr(c) for c in b)


def fish_side(inputs: list[bytes]) -> list[list[str]]:
    home = fz.build_home("fish", "keys")
    env = fz.shell_env("fish", home)
    fz.termctrl("stop", NAME, check=False)
    fz.termctrl(
        "start", NAME, "--cols", "200", "--rows", "50", "--cwd", str(home), "--",
        "/usr/bin/env", "-i", *(f"{k}={v}" for k, v in env.items()),
        str(fz.DEPS / "bin" / "fish"), "--no-config", "-c", "fish_key_reader -cV",
    )
    fz.termctrl("wait", NAME, "Press a key")
    time.sleep(0.5)

    # The exact output stream (the readable log keeps only so many lines),
    # minus the terminal control sequences fish_key_reader writes.
    ctl = re.compile(r"\x1b(\[[0-9;?=<>]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|P[^\x1b]*\x1b\\|[=>])")

    def logs() -> list[str]:
        raw = subprocess.run(["termctrl", "logs", "--ansi", NAME], check=False, capture_output=True).stdout
        return ctl.sub("", raw.decode("utf-8", "replace")).replace("\r\n", "\n").replace("\r", "").split("\n")

    # After each case (and a pause longer than any read timeout), a sentinel
    # key whose line marks where the case's output ends.
    sentinel, mark = b"\x1b[57383u", "bind \\uE027 'do something'"
    results: list[list[str]] = []
    for seen, data in enumerate(inputs):
        fz.termctrl("send", NAME, "--stdin", stdin=data)
        time.sleep(0.06)
        fz.termctrl("send", NAME, "--stdin", stdin=sentinel)
        t0 = time.monotonic()
        while True:
            lines = logs()
            marks = [i for i, ln in enumerate(lines) if ln.rstrip() == mark]
            if len(marks) > seen:
                break
            if time.monotonic() - t0 > 5:
                raise SystemExit(f"fish_key_reader stopped answering at {data!r}")
            time.sleep(0.01)
        start = marks[seen - 1] + 1 if seen else 0
        end = marks[seen] - 1  # the sentinel's own "# decoded from" line
        # (fish_key_reader's notice when a key is its interrupt character)
        results.append([
            ln.rstrip() for ln in lines[start:end]
            if ln.strip() and not ln.startswith(("Press ctrl-", "Press a key", "To terminate", "or press"))
        ])
    fz.termctrl("stop", NAME, check=False)
    return results


def zsh_side(inputs: list[bytes]) -> list[list[str]]:
    res = subprocess.run(
        [str(fz.DEPS / "bin" / "zsh"), "-f", str(fz.ROOT / "harness" / "keydecode.zsh"), *(esc(b) for b in inputs)],
        check=False, capture_output=True, text=True, env={"LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"},
    )
    if res.returncode:
        raise SystemExit(res.stderr)
    groups: list[list[str]] = [[]]
    for ln in res.stdout.splitlines():
        if ln == "--":
            groups.append([])
        else:
            groups[-1].append(ln.rstrip())
    return groups[:-1]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    inputs = cases()
    z = zsh_side(inputs)
    f = fish_side(inputs)
    assert len(z) == len(inputs) and len(f) == len(inputs), (len(z), len(f), len(inputs))
    bad = 0
    for data, fl, zl in zip(inputs, f, z, strict=True):
        if fl == zl:
            if args.verbose:
                print(f"ok   {data!r}: {' | '.join(fl)}")
            continue
        bad += 1
        print(f"DIFF {data!r}\n  fish: {fl}\n  zsh:  {zl}")
    print(f"{len(inputs) - bad}/{len(inputs)} identical")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
