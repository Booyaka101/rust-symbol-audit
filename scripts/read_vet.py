#!/usr/bin/env python3
"""read_vet.py — import cargo-vet certifications as review-ledger sign-offs.

Teams already running cargo-vet keep a `supply-chain/audits.toml` of the crate
versions a human has certified. Rather than make them re-review here, we treat
each cargo-vet audit as a sign-off, so those versions are suppressed by the same
ratchet as `.rust-symbol-audit/reviews.toml`.

cargo-vet shape:

    [[audits.serde]]
    version = "1.0.203"
    criteria = "safe-to-deploy"
    who = "Alice <alice@example.com>"

    [[audits.foo]]
    delta = "1.0.0 -> 1.0.1"     # a reviewed change; the *target* is certified
    criteria = ["safe-to-run"]

Emits the same normalized lines as read_reviews.py (so run_audit treats them
identically):

    REVIEW<TAB><crate><TAB><version><TAB>ALL<TAB>vet:<who|criteria>

Only `[[audits.<crate>]]` entries are imported; `wildcard-audits` / `trusted`
(publisher-range trust, not a specific version) are intentionally ignored.
Prefers stdlib `tomllib` (>=3.11); minimal fallback handles the shape above.
"""
import sys


def _load_tomllib(path):
    import tomllib
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def _strip_comment(line):
    out, in_str = [], False
    for ch in line:
        if ch == '"':
            in_str = not in_str
        elif ch == "#" and not in_str:
            break
        out.append(ch)
    return "".join(out)


def _minimal_parse(path):
    """Handle a sequence of `[[audits.<crate>]]` blocks with key = value lines."""
    audits = {}
    cur = None
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = _strip_comment(raw).strip()
            if not line:
                continue
            if line.startswith("[[audits.") and line.endswith("]]"):
                name = line[len("[[audits."):-2].strip().strip('"')
                cur = {}
                audits.setdefault(name, []).append(cur)
            elif line.startswith("[") or line.startswith("[["):
                cur = None            # some other table/array — ignore
            elif "=" in line and cur is not None:
                k, _, v = line.partition("=")
                cur[k.strip()] = v.strip().strip('"').strip("'")
    return {"audits": audits}


def _target_version(entry):
    """The certified version: `version`, or the RHS of a `delta = "a -> b"`."""
    v = entry.get("version")
    if v:
        return str(v).strip()
    d = entry.get("delta")
    if d:
        d = str(d)
        return d.split("->")[-1].strip() if "->" in d else d.strip()
    return None


def _label(entry):
    who = entry.get("who")
    if isinstance(who, list):
        who = who[0] if who else None
    crit = entry.get("criteria")
    if isinstance(crit, list):
        crit = crit[0] if crit else None
    return str(who or crit or "cargo-vet")[:40]


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

    audits = data.get("audits") or {}
    for crate, entries in audits.items():
        if isinstance(entries, dict):
            entries = [entries]
        for e in (entries or []):
            if not isinstance(e, dict):
                continue
            ver = _target_version(e)
            if not ver:
                continue
            print("REVIEW\t%s\t%s\tALL\tvet:%s" % (crate, ver, _label(e)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
