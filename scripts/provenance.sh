#!/usr/bin/env bash
# provenance.sh — supply-chain provenance lane.
#
# The highest-signal supply-chain tells are not "new capability" but "who/where
# did this come from": a version published by a DIFFERENT account than before, a
# crate with NO declared source repository, or a version that has been YANKED.
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
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

CRATE="${1:?crate required}"
OLDV="${2:-}"
NEWV="${3:-}"
OUTDIR="${4:-${WORK:-/tmp/rsa}}"
mkdir -p "$OUTDIR"
TSV="$OUTDIR/provenance_findings.tsv"
JSON="$OUTDIR/provenance.json"
RAW="$OUTDIR/cratesio.json"
: > "$TSV"

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

OLDV="$OLDV" NEWV="$NEWV" python3 - "$RAW" >> "$TSV" <<'PY'
import json, os, sys
oldv = os.environ.get("OLDV", "")
newv = os.environ.get("NEWV", "")
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

# 2) new version yanked
if nv and nv.get("yanked"):
    out.append(("high", "yanked", "the new version is YANKED on crates.io (pulled by the author/registry)"))

# 3) publisher changed between old and new
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
overall="none"
while IFS=$'\t' read -r t _rest; do
  [ -n "$t" ] || continue
  if [ "$(tier_rank "$t")" -gt "$(tier_rank "$overall")" ]; then overall="$t"; fi
done < "$TSV"

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
