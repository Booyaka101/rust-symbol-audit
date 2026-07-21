#!/usr/bin/env bash
# parse_lockdiff.sh — Step 1
#
# Compare Cargo.lock between the PR base commit and HEAD and emit a TSV of
# packages whose version changed (or that were newly added):
#
#     <crate_name>\t<old_version>\t<new_version>
#
# A newly-added crate has an empty old_version field.
#
# Sets GitHub Action outputs `changed` (true/false) and `count`.
# Exits 0 with `changed=false` when Cargo.lock did not change.
#
# Usage: parse_lockdiff.sh <base_sha> <head_ref> [out_tsv]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

BASE_SHA="${1:-${BASE_SHA:-}}"
HEAD_REF="${2:-${HEAD_REF:-HEAD}}"
OUT="${3:-${LOCKDIFF_TSV:-/tmp/rsa/lockdiff.tsv}}"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"

# The lockfile to watch. Defaults to the repo-root Cargo.lock; set MANIFEST_DIR
# (action input `manifest-dir`) to a subdirectory for monorepos / non-root
# workspaces, e.g. MANIFEST_DIR=backend -> backend/Cargo.lock.
MANIFEST_DIR="${MANIFEST_DIR:-.}"
case "$MANIFEST_DIR" in
  "" | ".") LOCKPATH="Cargo.lock" ;;
  *)        LOCKPATH="${MANIFEST_DIR%/}/Cargo.lock" ;;
esac

if [ -z "$BASE_SHA" ]; then
  log "no base SHA provided — nothing to diff"
  set_output "changed=false"; set_output "count=0"
  exit 0
fi

# The base commit may be missing from a shallow checkout; best-effort fetch.
if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  git fetch --no-tags --depth=1 origin "$BASE_SHA" >/dev/null 2>&1 || true
fi

# No Cargo.lock change at all -> silent success.
if git diff --quiet "$BASE_SHA" "$HEAD_REF" -- "$LOCKPATH" 2>/dev/null; then
  log "$LOCKPATH unchanged between $BASE_SHA and $HEAD_REF"
  set_output "changed=false"; set_output "count=0"
  exit 0
fi

# Print "name<TAB>version" for every [[package]] block in a given ref's lockfile.
pkgmap() {
  local ref="$1"
  git show "${ref}:${LOCKPATH}" 2>/dev/null | awk '
    /^\[\[package\]\]/            { name=""; ver=""; inpkg=1; next }
    /^\[/ && $0 !~ /^\[\[package\]\]/ { inpkg=0 }
    inpkg && /^name = / {
      line=$0; sub(/^name = "/,"",line); sub(/".*$/,"",line); name=line
    }
    inpkg && /^version = / {
      line=$0; sub(/^version = "/,"",line); sub(/".*$/,"",line); ver=line
      if (name != "") print name "\t" ver
    }
  '
}

OLD_MAP="$(mktemp)"; NEW_MAP="$(mktemp)"
trap 'rm -f "$OLD_MAP" "$NEW_MAP"' EXIT
pkgmap "$BASE_SHA" | sort -u > "$OLD_MAP"
pkgmap "$HEAD_REF" | sort -u > "$NEW_MAP"

declare -A OLDV
while IFS=$'\t' read -r n v; do
  [ -n "$n" ] && OLDV["$n"]="$v"
done < "$OLD_MAP"

count=0
while IFS=$'\t' read -r n v; do
  [ -n "$n" ] || continue
  old="${OLDV[$n]:-}"
  if [ -z "$old" ]; then
    printf '%s\t\t%s\n' "$n" "$v" >> "$OUT"          # newly added crate
    count=$((count + 1))
  elif [ "$old" != "$v" ]; then
    printf '%s\t%s\t%s\n' "$n" "$old" "$v" >> "$OUT" # version bump
    count=$((count + 1))
  fi
done < "$NEW_MAP"

if [ "$count" -eq 0 ]; then
  log "Cargo.lock changed but no package versions differ (metadata only)"
  set_output "changed=false"; set_output "count=0"
  exit 0
fi

set_output "changed=true"; set_output "count=$count"
log "$count changed package(s)"
cat "$OUT"
