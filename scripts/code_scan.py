#!/usr/bin/env python3
"""code_scan.py — match a build script's REAL CODE against the lane regexes.

Comments are stripped first, because that is where the false positives live.
Measured across 224 real build scripts: 23 of them match SRC_ALARM only through
a URL sitting in a comment (the whole `icu_*_data` family, `portable-atomic`,
`radium`), and a bare-URL fetch rule matched 61 of the most-downloaded crates in
the ecosystem for the same reason. A build script that merely *links to a blog
post* is not calling the network.

String and character literals are preserved, including URLs and comment-like
text. Rust block comments can nest.

One process emits every fact the callers need, so lib.sh does not pay a
subprocess per pattern and the stripping logic exists in exactly one place.

Env: SRC_ALARM, SRC_FETCH, SRC_EXEC (regexes, from lib.sh)
Usage: code_scan.py <build_script>
Prints: alarm<TAB>0|1 and fetch_exec<TAB>0|1
"""
import os
import re
import sys


TOKENS = re.compile(
    r'r(?P<hashes>\#*)"|"(?:\\.|[^"\\])*(?:"|\Z)'
    r"|'(?:\\(?:u\{[0-9a-fA-F_]+\}|x[0-9a-fA-F]{2}|.)|[^'\\\n])'"
    r"|/\*|//",
    re.S,
)
BLOCK_MARKERS = re.compile(r"/\*|\*/")


def strip_comments(s):
    parts = []
    pos = 0
    while True:
        token = TOKENS.search(s, pos)
        if token is None:
            parts.append(s[pos:])
            return "".join(parts)
        parts.append(s[pos:token.start()])
        text = token.group()
        end = token.end()
        if token.group("hashes") is not None:
            terminator = '"' + token.group("hashes")
            close = s.find(terminator, end)
            end = len(s) if close == -1 else close + len(terminator)
        elif text == "//":
            end = s.find("\n", end)
            if end == -1:
                end = len(s)
        elif text == "/*":
            depth = 1
            while depth:
                marker = BLOCK_MARKERS.search(s, end)
                if marker is None:
                    end = len(s)
                    break
                depth += 1 if marker.group() == "/*" else -1
                end = marker.end()
        if text in ("//", "/*"):
            parts.append(" ")
        else:
            parts.append(s[token.start():end])
        pos = end


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
