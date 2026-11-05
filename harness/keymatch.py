# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""fishy's find_binding (fishy/input.zsh) vs fish's, input by input.

In fish, every preset binding of the default mode is rebound, in place, to
insert its own index (`commandline -i "N;"`); the generic binding still
inserts text. The command line fish shows after each input is the oracle. The
zsh side is harness/keymatch.zsh: fishy's decoder and matcher over the same
bytes, printing the same thing. Inputs are harness/keys.py's cases.

  uv run --no-project python harness/keymatch.py [-v]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fz
import keys

NAME = f"{fz.PREFIX}keymatch-fish"
CLEAR = b"\x1b[57383u"  # F20: bound to clear the command line

SETUP = r"""
set -g fish_autosuggestion_enabled 0
function fish_prompt; printf '> '; end
function fish_right_prompt; end
fish_default_key_bindings
set -l i 0
for line in (bind --preset | string match -rv -- ' -M ' | string match -r '^bind .*')
    set i (math $i + 1)
    set -l key (string split ' ' -- $line)[3]
    test "$key" = "''"; and continue
    eval "bind --preset $key 'commandline -i \"$i;\"'"
end
bind \e\[57383u 'commandline -r ""'
"""


def cmdline() -> str:
    s = fz.capture(NAME)
    lines = s.text(mark_cursor=False)
    out = ""
    for i, ln in enumerate(lines):
        if ln.startswith(">"):
            out = ln[2:].rstrip()
            out += "".join(x.rstrip() for x in lines[i + 1:])
            break
    return out


def fish_side(inputs: list[bytes]) -> list[str]:
    home = fz.build_home("fish", "keymatch")
    env = fz.shell_env("fish", home)
    fz.termctrl("stop", NAME, check=False)
    rec = fz.SANDBOX / "keymatch" / "fish.termctrl"
    rec.unlink(missing_ok=True)
    fz.RECORDINGS[NAME] = rec  # fz.capture reads screens from the recording
    fz.termctrl(
        "start", NAME, "--record", str(rec), "--cols", "200", "--rows", "40", "--cwd", str(home), "--",
        "/usr/bin/env", "-i", *(f"{k}={v}" for k, v in env.items()),
        str(fz.DEPS / "bin" / "fish"), "--private", "--no-config", "-C", SETUP,
    )
    t0 = time.monotonic()
    while not any(ln.startswith(">") for ln in fz.capture(NAME).text(mark_cursor=False)):
        if time.monotonic() - t0 > 10:
            raise SystemExit("fish never showed its prompt")
        time.sleep(0.05)
    time.sleep(0.3)
    results: list[str] = []
    for data in inputs:
        fz.termctrl("send", NAME, "--stdin", stdin=data)
        time.sleep(0.08)
        fz.settle(NAME, quiet=0.05, limit=2)
        results.append(cmdline())
        fz.termctrl("send", NAME, "--stdin", stdin=CLEAR)
        t0 = time.monotonic()
        while cmdline():
            if time.monotonic() - t0 > 5:
                raise SystemExit(f"command line never cleared after {data!r}")
            time.sleep(0.01)
    fz.termctrl("stop", NAME, check=False)
    return results


def zsh_side(inputs: list[bytes]) -> list[str]:
    res = subprocess.run(
        [str(fz.DEPS / "bin" / "zsh"), "-f", str(fz.ROOT / "harness" / "keymatch.zsh"), *(keys.esc(b) for b in inputs)],
        check=False, capture_output=True, text=True, env={"LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"},
    )
    if res.returncode:
        raise SystemExit(res.stderr)
    out = res.stdout.split("\n--\n")
    return [x.rstrip("\n") for x in out[: len(inputs)]]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    # The generic binding inserts text: leave out inputs whose text fish would
    # also expand or treat specially on the command line (none of the cases'
    # text does), and the sentinel itself.
    inputs = [c for c in keys.cases() if CLEAR not in c]
    z = zsh_side(inputs)
    f = fish_side(inputs)
    bad = 0
    for data, fl, zl in zip(inputs, f, z, strict=True):
        if fl == zl.rstrip():
            if args.verbose:
                print(f"ok   {data!r}: {fl}")
            continue
        bad += 1
        print(f"DIFF {data!r}\n  fish: {fl!r}\n  zsh:  {zl!r}")
    print(f"{len(inputs) - bad}/{len(inputs)} identical")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
