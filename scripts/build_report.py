#!/usr/bin/env python3
"""build_report.py — assemble the machine-readable audit evidence report.

Reads each audited crate's per-lane finding files from <work>/crates/<name>/ and
emits one JSON object to stdout: the overall verdict plus every finding, grouped
by crate and lane. This is the artifact a compliance / SLSA process keeps as the
record that the dependency change was reviewed.

Usage: build_report.py <crates_dir>
Env:   OVERALL FAIL_ON RECOMMENDATION AUDITED FLAGGED
"""
import json
import os
import sys
from datetime import datetime, timezone


def read_cols(path, ncols):
    """Yield tuples of the first ncols tab-separated fields of each non-empty line."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                parts += [""] * (ncols - len(parts))
                yield tuple(parts[:ncols])
    except FileNotFoundError:
        return


def crate_record(cdir):
    meta = next(read_cols(os.path.join(cdir, "meta.tsv"), 5), None)
    if not meta:
        return None
    name, old, new, tier, reviewed = meta
    rec = {
        "crate": name,
        "old": old or None,
        "new": new,
        "tier": tier or "none",
        "reviewed": reviewed == "1",
        "advisories": [{"tier": t, "detail": d}
                       for (t, _k, d) in read_cols(os.path.join(cdir, "advisory.filtered"), 3)],
        "provenance": [{"tier": t, "kind": k, "detail": d}
                       for (t, k, d) in read_cols(os.path.join(cdir, "provenance.filtered"), 3)
                       if t != "none"],
        "compile_time": [{"tier": t, "kind": k, "detail": d}
                         for (t, k, d) in read_cols(os.path.join(cdir, "source_findings.filtered"), 3)],
        "dependencies": [{"tier": t, "name": n}
                         for (t, n) in read_cols(os.path.join(cdir, "dep_findings.filtered"), 2)],
        "new_dependencies": [{"tier": t, "kind": k, "crate": d or None, "version": v or None,
                              "detail": det}
                             for (t, k, d, v, det) in read_cols(os.path.join(cdir, "newdep.filtered"), 5)],
        "symbols": [{"tier": t, "symbol": s}
                    for (t, s) in read_cols(os.path.join(cdir, "risk.filtered"), 2)],
    }
    return rec


def main():
    crates_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    crates = []
    if os.path.isdir(crates_dir):
        for name in sorted(os.listdir(crates_dir)):
            cdir = os.path.join(crates_dir, name)
            if os.path.isdir(cdir):
                rec = crate_record(cdir)
                if rec:
                    crates.append(rec)

    flagged = [c.strip() for c in (os.environ.get("FLAGGED", "") or "").split(",") if c.strip()]
    try:
        generated = datetime.now(timezone.utc).isoformat()
    except Exception:
        generated = None

    report = {
        "tool": "rust-symbol-audit",
        "schema": 1,
        "generated": generated,
        "overall_tier": os.environ.get("OVERALL", "none"),
        "fail_on": os.environ.get("FAIL_ON", "none"),
        "recommendation": os.environ.get("RECOMMENDATION", "review"),
        "audited": int(os.environ.get("AUDITED", "0") or 0),
        "flagged": flagged,
        "crates": crates,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
