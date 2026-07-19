#!/usr/bin/env bash
# diff_symbols.sh — Step 3
#
# Extract demangled v0 symbols from the old and new .rlib and print the symbols
# present ONLY in the new one (i.e. the capabilities/API surface the version bump
# added). Writes old_syms.txt / new_syms.txt / added_syms.txt into <out_dir>.
#
# Usage: diff_symbols.sh <old_rlib> <new_rlib> [out_dir]
#   Either rlib path may be empty (e.g. a newly-added crate has no "old"); an
#   empty/missing rlib is treated as the empty symbol set.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

OLD_RLIB="${1:-}"
NEW_RLIB="${2:-}"
OUTDIR="${3:-${WORK:-/tmp/rsa}}"
mkdir -p "$OUTDIR"

extract_symbols "$OLD_RLIB" > "$OUTDIR/old_syms.txt"
extract_symbols "$NEW_RLIB" > "$OUTDIR/new_syms.txt"

# comm needs sorted input (extract_symbols already sort -u's); -13 => lines only
# in the second file (new).
comm -13 "$OUTDIR/old_syms.txt" "$OUTDIR/new_syms.txt" > "$OUTDIR/added_syms.txt"

log "symbols: old=$(wc -l < "$OUTDIR/old_syms.txt" | tr -d ' ') new=$(wc -l < "$OUTDIR/new_syms.txt" | tr -d ' ') added=$(wc -l < "$OUTDIR/added_syms.txt" | tr -d ' ')"
cat "$OUTDIR/added_syms.txt"
