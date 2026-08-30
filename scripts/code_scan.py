#!/usr/bin/env python3
"""code_scan.py — match a build script's REAL CODE against the lane regexes.

Comments are stripped first, because that is where the false positives live.
Measured across 224 real build scripts: 23 of them match SRC_ALARM only through
a URL sitting in a comment (the whole `icu_*_data` family, `portable-atomic`,
`radium`), and a bare-URL fetch rule matched 61 of the most-downloaded crates in
the ecosystem for the same reason. A build script that merely *links to a blog
post* is not calling the network.

The `//` inside `http://` is preserved (only a `//` not preceded by `:` starts a
comment), so a genuine in-code URL still counts.

One process emits every fact the callers need, so lib.sh does not pay a
subprocess per pattern and the stripping logic exists in exactly one place.

Env: SRC_ALARM, SRC_FETCH, SRC_EXEC (regexes, from lib.sh)
Usage: code_scan.py <build_script>
Prints: alarm<TAB>0|1 and fetch_exec<TAB>0|1
"""
import os
import re
import sys


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)   # block comments
    s = re.sub(r"(?<!:)//[^\n]*", " ", s)          # line comments, not URL schemes
    return s


def main():
    # Windows python translates "\n" to CRLF on a text-mode stdout, which would
    # put a stray CR in every fact value that lib.sh then compares as a string.
    # It happened to survive because Git Bash's awk tolerates the CR; do not
    # rely on that. LF only, on every platform.
    try:
        sys.stdout.reconfigure(newline="\n")
    except AttributeError:  # pragma: no cover - python < 3.7
        pass
    try:
        raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    except (OSError, IndexError):
        return 1
    code = strip_comments(raw)

    def hit(name):
        rx = os.environ.get(name)
        return bool(rx) and bool(re.search(rx, code, re.I))

    print("alarm\t%d" % hit("SRC_ALARM"))
    print("fetch_exec\t%d" % (hit("SRC_FETCH") and hit("SRC_EXEC")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
