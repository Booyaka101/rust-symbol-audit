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

# JSON's escaped strings are also TOML basic strings. Validate the existing
# document before appending, and only a whole-version review is a no-op.
python3 - "$LEDGER" "$CRATE" "$VERSION" "$BY" "$NOTES" <<'PY'
from datetime import date
import json
from pathlib import Path
import sys
import tomllib

ledger = Path(sys.argv[1])
crate, version, who, notes = sys.argv[2:]
text = ledger.read_text(encoding='utf-8') if ledger.exists() else ''
data = tomllib.loads(text)
if any(r.get('crate') == crate and r.get('version') == version and not r.get('accept')
       for r in data.get('review', [])):
    print('review: already signed off %s %s' % (crate, version), file=sys.stderr)
    sys.exit(0)
entry = dict(crate=crate, version=version, reviewed_by=who, date=date.today().isoformat(), notes=notes)
block = '\n[[review]]\n' + ''.join('%s = %s\n' % (k, json.dumps(v, ensure_ascii=False))
                                      for k, v in entry.items()) + '\n'
tomllib.loads(text + block)
ledger.parent.mkdir(parents=True, exist_ok=True)
with ledger.open('a', encoding='utf-8', newline='\n') as fh:
    fh.write(block)
print('review: signed off %s %s in %s' % (crate, version, ledger), file=sys.stderr)
PY
