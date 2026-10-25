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
    delta = "1.0.0 -> 1.0.1"     # preserves safety only if the base is certified
    criteria = ["safe-to-run"]

Emits the same normalized lines as read_reviews.py (so run_audit treats them
identically):

    REVIEW<TAB><crate><TAB><version><TAB>ALL<TAB>vet:<who|criteria>

Only safety-certified versions reachable from a full safety audit are imported.
Custom criteria may imply safe-to-run/deploy. Crates with violation entries are
conservatively excluded; this is not a replacement for cargo-vet's resolver.
Wildcard audits and publisher trust are intentionally ignored. Python 3.11+.
"""
import sys


def _load_tomllib(path):
    import tomllib
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def _criteria(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(v, str) for v in value):
        return list(value)
    return []


def certified_versions(entries, definitions):
    """Follow safety-preserving directed deltas from fully audited versions."""
    if any('violation' in e for e in entries):
        return {}

    def safe(value):
        pending = _criteria(value)
        seen = set()
        while pending:
            criterion = pending.pop()
            if criterion in ('safe-to-run', 'safe-to-deploy'):
                return True
            if criterion not in seen:
                seen.add(criterion)
                pending.extend(_criteria(definitions.get(criterion, {}).get('implies')))
        return False

    certified, deltas = {}, []
    for entry in entries:
        if not safe(entry.get('criteria')) or entry.get('dependency-criteria'):
            continue
        version = entry.get('version')
        delta = entry.get('delta')
        if isinstance(version, str) and version and not delta:
            certified[version] = entry
        elif isinstance(delta, str) and delta.count('->') == 1 and not version:
            base, target = (v.strip() for v in delta.split('->'))
            if base and target:
                deltas.append((base, target, entry))
    changed = True
    while changed:
        changed = False
        for base, target, entry in deltas:
            if base in certified and target not in certified:
                certified[target] = entry
                changed = True
    return certified


def _label(entry):
    who = entry.get("who")
    if isinstance(who, list):
        who = who[0] if who else None
    crit = entry.get("criteria")
    if isinstance(crit, list):
        crit = crit[0] if crit else None
    return str(who or crit or "cargo-vet").replace('\t', ' ').replace('\r', ' ').replace('\n', ' ')[:40]


def main():
    if len(sys.argv) < 2:
        return 0
    path = sys.argv[1]
    try:
        data = _load_tomllib(path)
    except FileNotFoundError:
        return 0

    audits = data.get("audits") or {}
    for crate, entries in audits.items():
        if isinstance(entries, dict):
            entries = [entries]
        for ver, e in certified_versions(entries or [], data.get('criteria') or {}).items():
            print("REVIEW\t%s\t%s\tALL\tvet:%s" % (crate, ver, _label(e)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
