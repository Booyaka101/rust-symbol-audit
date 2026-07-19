#!/usr/bin/env python3
"""read_reviews.py — normalize the review ledger into flat lines.

The ledger turns rust-symbol-audit from a per-PR nag into a ratchet: you sign off
a dependency version once, and future bumps only alarm on the UNREVIEWED
capability delta. Ledger file (default `.rust-symbol-audit/reviews.toml`):

    [[review]]
    crate = "reqwest"
    version = "0.12.0"
    reviewed_by = "alice"
    notes = "http client; network capability expected"
    # optional: accept only these capability patterns for this version; anything
    # else still alarms. Omit `accept` to sign off the whole version.
    accept = ["TcpStream", "hyper", "rustls"]

Output (tab-separated) consumed by run_audit.sh, one record per line:

    REVIEW<TAB><crate><TAB><version><TAB>ALL<TAB><reviewed_by>      # whole version signed off
    REVIEW<TAB><crate><TAB><version><TAB>ACCEPT<TAB><regex>         # only this capability accepted

Prefers stdlib `tomllib` (Python >= 3.11); falls back to a minimal parser that
understands the `[[review]]` array-of-tables shape above.
"""
import sys


def _load_tomllib(path):
    import tomllib
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def _parse_array(v):
    inner = v.strip()
    if inner.startswith("["):
        inner = inner[1:]
    if inner.endswith("]"):
        inner = inner[:-1]
    return [p.strip().strip('"').strip("'") for p in inner.split(",") if p.strip()]


def _minimal_parse(path):
    """Minimal parser for a file that is a sequence of [[review]] blocks."""
    reviews = []
    cur = None
    pend_key = None
    pend_val = ""
    depth = 0
    with open(path, encoding="utf-8") as fh:
        raw = fh.read().splitlines()

    # strip # comments outside quotes
    lines = []
    for line in raw:
        out, in_str = [], False
        for ch in line:
            if ch == '"':
                in_str = not in_str
            elif ch == "#" and not in_str:
                break
            out.append(ch)
        lines.append("".join(out))

    def commit_val(key, val):
        if cur is None:
            return
        if val.strip().startswith("["):
            cur[key] = _parse_array(val)
        else:
            cur[key] = val.strip().strip('"').strip("'")

    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            continue
        if depth > 0:
            pend_val += " " + line
            depth += line.count("[") - line.count("]")
            if depth <= 0:
                commit_val(pend_key, pend_val)
                pend_key, pend_val, depth = None, "", 0
            continue
        if line.startswith("[[") and line.endswith("]]"):
            cur = {}
            reviews.append(cur)
            continue
        if line.startswith("["):        # any other table — ignore
            cur = None
            continue
        if "=" in line and cur is not None:
            k, _, v = line.partition("=")
            k, v = k.strip().strip('"'), v.strip()
            ad = v.count("[") - v.count("]")
            if ad > 0:
                pend_key, pend_val, depth = k, v, ad
                continue
            commit_val(k, v)
    return {"review": reviews}


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

    for r in (data.get("review") or []):
        crate = r.get("crate")
        version = r.get("version")
        if not crate or not version:
            continue
        accept = r.get("accept")
        if isinstance(accept, str):
            accept = [accept]
        if accept:
            for pat in accept:
                print("REVIEW\t%s\t%s\tACCEPT\t%s" % (crate, version, pat))
        else:
            by = r.get("reviewed_by", "") or ""
            print("REVIEW\t%s\t%s\tALL\t%s" % (crate, version, by))
    return 0


if __name__ == "__main__":
    sys.exit(main())
