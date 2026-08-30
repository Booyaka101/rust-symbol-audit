#!/usr/bin/env bash
# provenance.sh — supply-chain provenance lane.
#
# The highest-signal supply-chain tells are not "new capability" but "who/where
# did this come from": a version published by a DIFFERENT account than before, a
# crate with NO declared source repository, a version that has been YANKED, a
# version crates.io no longer LISTS at all (how the registry responds to a
# malicious publish — arrayref 0.3.10 was deleted, not yanked, 2026-08-20), or a
# version published so RECENTLY it predates the window in which compromised
# releases get caught (the arrayref/internment/append-only-vec malicious
# versions were live 86-107 minutes).
# (event-stream / ua-parser-js / xz all looked like a provenance change first.)
#
# Queries the crates.io API for the crate's version metadata. NEEDS NETWORK at
# runtime; degrades gracefully (emits an "unknown" note) if offline. For
# deterministic offline tests, set RSA_CRATESIO_FIXTURE to a dir containing
# "<crate>.json" (a saved crates.io /api/v1/crates/<crate> response).
#
# Usage: provenance.sh <crate> <old_ver> <new_ver> <out_dir>
#   Writes <out_dir>/provenance_findings.tsv (<tier>\t<kind>\t<detail>)
#          <out_dir>/provenance.json
#          <out_dir>/publish_age.txt (human age of the new version, when known)
# Env: RSA_MIN_PUBLISH_AGE_HOURS — fresh-version window, default 24; 0 keeps the
#      publish-age note but never tiers it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

# Finding details are UTF-8; Windows python otherwise decodes/encodes cp1252
# and dies on them (Linux runners are unaffected).
export PYTHONUTF8=1

CRATE="${1:?crate required}"
OLDV="${2:-}"
NEWV="${3:-}"
OUTDIR="${4:-${WORK:-/tmp/rsa}}"
mkdir -p "$OUTDIR"
TSV="$OUTDIR/provenance_findings.tsv"
JSON="$OUTDIR/provenance.json"
RAW="$OUTDIR/cratesio.json"
: > "$TSV"
rm -f "$OUTDIR/publish_age.txt"

# --- obtain crates.io metadata (mock, else network) ---
got=0
if [ -n "${RSA_CRATESIO_FIXTURE:-}" ] && [ -f "${RSA_CRATESIO_FIXTURE}/${CRATE}.json" ]; then
  cp "${RSA_CRATESIO_FIXTURE}/${CRATE}.json" "$RAW" && got=1
elif [ "${RSA_CHECK_PROVENANCE:-1}" = "1" ] && command -v curl >/dev/null 2>&1; then
  if curl -sS -m 20 -A "rust-symbol-audit (github action)" \
        "https://crates.io/api/v1/crates/${CRATE}" -o "$RAW" 2>/dev/null \
     && [ -s "$RAW" ]; then
    got=1
  fi
fi

if [ "$got" -ne 1 ]; then
  log "provenance: no metadata for $CRATE (offline or disabled) — skipping lane"
  printf 'none\tprovenance-unknown\tcrates.io metadata unavailable (offline or disabled) — provenance not checked\n' >> "$TSV"
  printf '{"tier":"none","findings":[{"tier":"none","kind":"provenance-unknown","detail":"crates.io metadata unavailable"}]}\n' > "$JSON"
  cat "$JSON"; exit 0
fi

OLDV="$OLDV" NEWV="$NEWV" OUTDIR="$OUTDIR" PYTHONPATH="$HERE" python3 - "$RAW" >> "$TSV" <<'PY'
import json, os, sys
from datetime import datetime, timezone
from agefmt import rel_age
oldv = os.environ.get("OLDV", "")
newv = os.environ.get("NEWV", "")
outdir = os.environ.get("OUTDIR", ".")
try:
    min_age_h = float(os.environ.get("RSA_MIN_PUBLISH_AGE_HOURS", "24"))
except ValueError:
    min_age_h = 24.0
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)

crate = data.get("crate", {}) or {}
versions = data.get("versions", []) or []
by_num = {}
for v in versions:
    by_num[str(v.get("num"))] = v

def pub(v):
    pb = (v or {}).get("published_by") or {}
    return pb.get("login") or pb.get("name")

nv = by_num.get(str(newv))
ov = by_num.get(str(oldv)) if oldv else None

out = []
# 1) no declared source repository
repo = crate.get("repository")
if not repo:
    out.append(("high", "no-source-repo",
                "crate declares NO source repository on crates.io — the published code cannot be traced to a git source"))

# 2) the audited version is not in the registry's versions array at all. This is
# how crates.io responds to a malicious publish (deleted, not yanked — so the
# yanked check below never sees it), and it must run before the age check since
# a removed version has no created_at to read. The metadata-fetch-failed case
# never reaches here (the offline path above exits early).
if nv is None:
    out.append(("high", "version-not-on-registry",
                "crates.io does not list version %s — it was removed from the registry, which is how crates.io responds to a malicious publish (Rust Security Response Team, 2026-08-20)" % newv))

# 3) new version yanked
if nv and nv.get("yanked"):
    out.append(("high", "yanked", "the new version is YANKED on crates.io (pulled by the author/registry)"))

# 4) publish age. Inside the window -> high; outside -> a none-tier note so the
# comment always carries the age. Window 0 disables the tiering, note only.
# UTC only: crates.io returns Z-suffixed ISO-8601; never the runner's zone.
if nv is not None:
    created = nv.get("created_at")
    secs = None
    try:
        ts = datetime.fromisoformat(str(created).replace("Z", "+00:00"))
        secs = (datetime.now(timezone.utc) - ts.astimezone(timezone.utc)).total_seconds()
    except (TypeError, ValueError):
        pass
    if secs is None:
        # absent/malformed date is a note, never a finding — no verdict from missing data
        out.append(("none", "publish-age-unknown",
                    "crates.io metadata carries no usable publish date for %s — publish age not assessed" % newv))
    else:
        age = rel_age(max(secs, 0))
        with open(os.path.join(outdir, "publish_age.txt"), "w", encoding="utf-8") as fh:
            fh.write(age)
        if min_age_h > 0 and secs < min_age_h * 3600:
            out.append(("high", "fresh-version",
                        "published %s; the arrayref/internment/append-only-vec malicious versions of 2026-08-20 were removed within 86-107 minutes, so a version this young has not yet been through the window in which compromised releases get caught" % age))
        elif min_age_h > 0:
            out.append(("none", "fresh-version",
                        "published %s (older than the %g h fresh-version window)" % (age, min_age_h)))
        else:
            out.append(("none", "fresh-version",
                        "published %s (fresh-version window disabled)" % age))

# 5) publisher changed between old and new
np, opb = pub(nv), pub(ov)
if np and opb and np != opb:
    out.append(("high", "publisher-change",
                "published by a DIFFERENT account than the previous version: %s -> %s" % (opb, np)))
elif np and not opb and oldv:
    # can't compare (old lacked publisher metadata) — informational
    out.append(("none", "publisher-unknown",
                "previous version has no publisher metadata; new version published by %s" % np))

for tier, kind, detail in out:
    print("%s\t%s\t%s" % (tier, kind, detail))
PY

# --- overall tier + json ---
overall="$(max_tier "$TSV")"

OVERALL="$overall" python3 - "$TSV" > "$JSON" <<'PY'
import json, os, sys
findings = []
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            tier, _, rest = line.partition("\t")
            kind, _, detail = rest.partition("\t")
            findings.append({"tier": tier, "kind": kind, "detail": detail})
except FileNotFoundError:
    pass
print(json.dumps({"tier": os.environ.get("OVERALL", "none"), "findings": findings}, ensure_ascii=False))
PY

log "provenance: $CRATE ${OLDV:-<new>} -> $NEWV tier=$overall findings=$(count_lines "$TSV")"
cat "$JSON"
