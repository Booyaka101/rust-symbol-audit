#!/usr/bin/env bash
# advisories.sh — known-vulnerability lane (RustSec via OSV.dev).
#
# A capability audit should also say "…and this exact version has a published
# advisory." Queries OSV.dev (which mirrors the RustSec advisory DB) for the
# crate@version. NEEDS NETWORK at runtime; degrades gracefully if offline. For
# deterministic offline tests, set RSA_ADVISORY_FIXTURE to a dir containing
# "<crate>-<version>.json" (a saved OSV /v1/query response).
#
# Usage: advisories.sh <crate> <version> <out_dir>
#   Writes <out_dir>/advisory_findings.tsv (<tier>\t<kind>\t<detail>)
#          <out_dir>/advisories.json
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

CRATE="${1:?crate required}"
VERSION="${2:-}"
OUTDIR="${3:-${WORK:-/tmp/rsa}}"
mkdir -p "$OUTDIR"
TSV="$OUTDIR/advisory_findings.tsv"
JSON="$OUTDIR/advisories.json"
RAW="$OUTDIR/osv.json"
: > "$TSV"

got=0
if [ -n "${RSA_ADVISORY_FIXTURE:-}" ] && [ -f "${RSA_ADVISORY_FIXTURE}/${CRATE}-${VERSION}.json" ]; then
  cp "${RSA_ADVISORY_FIXTURE}/${CRATE}-${VERSION}.json" "$RAW" && got=1
elif [ "${RSA_CHECK_ADVISORIES:-1}" = "1" ] && [ -n "$VERSION" ] && command -v curl >/dev/null 2>&1; then
  body="$(printf '{"version":"%s","package":{"ecosystem":"crates.io","name":"%s"}}' "$VERSION" "$CRATE")"
  if curl -sS -m 20 -A "rust-symbol-audit (github action)" -H "Content-Type: application/json" \
        -X POST -d "$body" "https://api.osv.dev/v1/query" -o "$RAW" 2>/dev/null \
     && [ -s "$RAW" ]; then
    got=1
  fi
fi

if [ "$got" -ne 1 ]; then
  log "advisories: no data for $CRATE@$VERSION (offline or disabled) — skipping lane"
  printf '{"tier":"none","findings":[]}\n' > "$JSON"
  cat "$JSON"; exit 0
fi

python3 - "$RAW" >> "$TSV" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)

def cvss_score(v):
    best = 0.0
    for s in (v.get("severity") or []):
        try:
            best = max(best, float(s.get("score", "")))
        except (TypeError, ValueError):
            pass  # CVSS vector string, not a number — leave best as-is
    return best

def ids_of(v):
    return [i for i in ([v.get("id")] + (v.get("aliases") or [])) if i]

# Group a vuln and its aliases (e.g. a RUSTSEC id + its GHSA id) into one finding
# so the same advisory isn't listed twice.
groups, seen = [], {}
for v in (data.get("vulns") or []):
    idset = set(ids_of(v))
    gi = next((seen[i] for i in idset if i in seen), None)
    if gi is None:
        gi = len(groups); groups.append({"ids": set(), "summary": "", "worst": 0.0})
    g = groups[gi]
    g["ids"] |= idset
    for i in idset:
        seen[i] = gi
    summ = (v.get("summary") or v.get("details") or "").strip().replace("\n", " ")
    if summ and not g["summary"]:
        g["summary"] = summ
    g["worst"] = max(g["worst"], cvss_score(v))

def url_for(i):
    if i.startswith("RUSTSEC-"): return "https://rustsec.org/advisories/%s.html" % i
    if i.startswith("GHSA-"):    return "https://github.com/advisories/%s" % i
    if i.startswith("CVE-"):     return "https://nvd.nist.gov/vuln/detail/%s" % i
    return "https://osv.dev/vulnerability/%s" % i

def rank_id(i):
    return (0 if i.startswith("RUSTSEC-") else 1 if i.startswith("CVE-")
            else 2 if i.startswith("GHSA-") else 3, i)

for g in groups:
    ids = sorted(g["ids"], key=rank_id)
    if not ids:
        continue
    primary, aliases = ids[0], ids[1:]
    summ = g["summary"] or "(no summary)"
    if len(summ) > 120:
        summ = summ[:117] + "..."
    tier = "critical" if g["worst"] >= 9.0 else "high"
    alias_str = " (aka %s)" % ", ".join(aliases) if aliases else ""
    print("%s\tadvisory\t[%s](%s)%s — %s" % (tier, primary, url_for(primary), alias_str, summ))
PY

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

log "advisories: $CRATE@$VERSION tier=$overall count=$(count_lines "$TSV")"
cat "$JSON"
