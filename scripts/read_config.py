#!/usr/bin/env python3
"""read_config.py — normalize .rust-symbol-audit.toml into flat lines.

The config lets a repo tune out its own known-benign signals (the direct
antidote to false-positive fatigue). Supported keys:

    ignore_crates = ["libc", "windows-sys"]   # never flag these crates at all

    [allow]
    # per crate: suppress any finding whose text matches one of these regexes
    reqwest = ["TcpStream", "hyper", "rustls", "http"]
    ring    = ["mmap", "libc::"]

Output (tab-separated, one record per line) consumed by run_audit.sh:

    IGNORE<TAB><crate>
    ALLOW<TAB><crate><TAB><regex>

Parsing prefers the stdlib `tomllib` (Python >= 3.11); if unavailable it falls
back to a minimal parser covering exactly the subset above. Unknown keys are
ignored, so the file can carry comments and future options without breaking.
"""
import sys


def _load_tomllib(path):
    import tomllib  # 3.11+
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def _parse_value(v):
    v = v.strip()
    if v.startswith("["):
        inner = v[1:]
        if inner.endswith("]"):
            inner = inner[:-1]
        parts = [p.strip().strip('"').strip("'") for p in inner.split(",")]
        return [p for p in parts if p]
    return v.strip().strip('"').strip("'")


def _minimal_parse(path):
    """Tiny TOML-subset parser: top-level scalars/arrays and single-level
    tables of scalars/arrays, with # comments and multi-line arrays."""
    data = {"ignore_crates": [], "allow": {}}
    with open(path, encoding="utf-8") as fh:
        raw_lines = fh.read().splitlines()

    # strip comments (respecting double-quoted strings)
    lines = []
    for line in raw_lines:
        out, in_str, i = [], False, 0
        while i < len(line):
            ch = line[i]
            if ch == '"':
                in_str = not in_str
            elif ch == "#" and not in_str:
                break
            out.append(ch)
            i += 1
        lines.append("".join(out))

    section = None
    pend_key = pend_val = None
    depth = 0

    def store(sect, key, value):
        items = _parse_value(value)
        if sect is None:
            if key == "ignore_crates":
                data["ignore_crates"] = items if isinstance(items, list) else [items]
        elif sect == "allow":
            data["allow"][key] = items if isinstance(items, list) else [items]

    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if depth > 0:                      # inside a multi-line array
            pend_val += " " + line
            depth += line.count("[") - line.count("]")
            if depth <= 0:
                store(section, pend_key, pend_val)
                pend_key = pend_val = None
                depth = 0
            continue
        if line.startswith("["):           # table header
            section = line.strip("[]").strip()
            continue
        if "=" in line:
            k, _, v = line.partition("=")
            k, v = k.strip().strip('"'), v.strip()
            ad = v.count("[") - v.count("]")
            if ad > 0:                      # array continues on later lines
                pend_key, pend_val, depth = k, v, ad
                continue
            store(section, k, v)
    return data


def main():
    if len(sys.argv) < 2:
        return 0
    path = sys.argv[1]
    try:
        try:
            data = _load_tomllib(path)
        except Exception:
            data = _minimal_parse(path)
    except FileNotFoundError:
        return 0

    for crate in (data.get("ignore_crates") or []):
        print("IGNORE\t%s" % crate)

    allow = data.get("allow") or {}
    for crate, pats in allow.items():
        if isinstance(pats, str):
            pats = [pats]
        for p in (pats or []):
            print("ALLOW\t%s\t%s" % (crate, p))
    return 0


if __name__ == "__main__":
    sys.exit(main())
