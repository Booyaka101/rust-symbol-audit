#!/usr/bin/env python3
"""fetch_exec.py — does a build script both FETCH something remote and EXECUTE
something? Exit 0 if yes, 1 if no.

The regexes come from the environment (SRC_FETCH / SRC_EXEC) so lib.sh stays the
single source of truth. Comments are stripped first, because the whole reason a
bare-URL fetch rule is wrong is that real build scripts carry blog/issue/license
URLs in comments and error strings; a network CLIENT being invoked is the actual
signal. The // inside http:// is preserved (only a // not preceded by : starts a
comment) so a genuine fetch in code still counts.
"""
import os
import re
import sys


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)   # block comments
    s = re.sub(r"(?<!:)//[^\n]*", " ", s)          # line comments, not URL schemes
    return s


def main():
    try:
        raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    except OSError:
        return 1
    code = strip_comments(raw)
    fetch = re.compile(os.environ["SRC_FETCH"], re.I)
    exec_ = re.compile(os.environ["SRC_EXEC"], re.I)
    return 0 if (fetch.search(code) and exec_.search(code)) else 1


if __name__ == "__main__":
    sys.exit(main())
