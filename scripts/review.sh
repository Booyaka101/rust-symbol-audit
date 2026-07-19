#!/usr/bin/env bash
# review.sh — append a sign-off entry to the review ledger.
#
# Signing off a (crate, version) tells rust-symbol-audit you have vetted that
# version's capability surface, so future audits stay green for it and only
# alarm on the UNREVIEWED delta (the ratchet).
#
# Usage: review.sh <crate> <version> [reviewed_by] [notes]
#   REVIEWS   env override for the ledger path (default .rust-symbol-audit/reviews.toml)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

CRATE="${1:?usage: review.sh <crate> <version> [reviewed_by] [notes]}"
VERSION="${2:?version required}"
BY="${3:-${USER:-unknown}}"
NOTES="${4:-}"
LEDGER="${REVIEWS:-.rust-symbol-audit/reviews.toml}"

mkdir -p "$(dirname "$LEDGER")"
[ -f "$LEDGER" ] || {
  printf '# rust-symbol-audit review ledger — capability sign-offs.\n' > "$LEDGER"
  printf '# Future bumps only alarm on the unreviewed delta. See README.\n\n' >> "$LEDGER"
}

# Already signed off? (exact crate+version ALL entry)
if python3 "$HERE/read_reviews.py" "$LEDGER" 2>/dev/null \
    | awk -F'\t' -v c="$CRATE" -v v="$VERSION" '$2==c && $3==v {f=1} END{exit !f}'; then
  log "review: $CRATE $VERSION is already in the ledger — nothing to do"
  exit 0
fi

DATE="$(date +%F 2>/dev/null || echo '')"
{
  printf '[[review]]\n'
  printf 'crate = "%s"\n' "$CRATE"
  printf 'version = "%s"\n' "$VERSION"
  printf 'reviewed_by = "%s"\n' "$BY"
  [ -n "$DATE" ] && printf 'date = "%s"\n' "$DATE"
  printf 'notes = "%s"\n' "$NOTES"
  printf '\n'
} >> "$LEDGER"

log "review: signed off $CRATE $VERSION (by $BY) in $LEDGER"
