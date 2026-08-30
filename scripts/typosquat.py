#!/usr/bin/env python3
"""typosquat.py — is a newly-pulled crate's name a near-miss of one already in
the tree?

The 2026-08-20 attack is named for this: RustSec filed it as "Malware: arrayref
0.3.10 executes a remote payload at build time via typosquatted proc-macro1".
`proc-macro1` is one character from `proc-macro2`, which was already sitting in
the victim's dependency tree. That is the signal, and it needs no network and no
bundled top-crates list: compare the new name against the names the *old*
lockfile already resolved.

crates.io normalises `-` and `_` when enforcing name uniqueness, so `serde-json`
and `serde_json` cannot both exist. Names are normalised here for the same
reason: a pair differing only by separator is the same crate, not a squat.

Usage: typosquat.py <candidate> <names_file> [max_distance]
  names_file: one crate name per line (the tree the new dependency is joining).
Prints "<distance>\\t<nearest name>" and exits 0 when a neighbour is found
within max_distance (default 1); exits 1 when there is none.
"""
import sys


def norm(name):
    return name.strip().lower().replace("_", "-")


def within(a, b, limit):
    """Levenshtein distance between a and b, or limit+1 once it provably exceeds
    limit. Banded: anything further apart in length than limit cannot qualify."""
    if abs(len(a) - len(b)) > limit:
        return limit + 1
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1,          # deletion
                           cur[j - 1] + 1,       # insertion
                           prev[j - 1] + (ca != cb)))  # substitution
        if min(cur) > limit:
            return limit + 1
        prev = cur
    return prev[-1]


def nearest(candidate, names, limit=1):
    """Closest name within `limit` edits, ignoring the candidate itself.
    Returns (distance, name) or None."""
    c = norm(candidate)
    best = None
    for raw in names:
        n = norm(raw)
        if not n or n == c:
            continue  # same crate (or separator-only variant, which cannot coexist)
        d = within(c, n, limit)
        if d <= limit and (best is None or d < best[0]):
            best = (d, raw.strip())
            if d == 1:
                break
    return best


def main():
    if len(sys.argv) < 3:
        return 2
    candidate = sys.argv[1]
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    try:
        with open(sys.argv[2], encoding="utf-8", errors="replace") as fh:
            names = fh.read().splitlines()
    except OSError:
        return 1
    hit = nearest(candidate, names, limit)
    if not hit:
        return 1
    print("%d\t%s" % hit)
    return 0


if __name__ == "__main__":
    sys.exit(main())
