#!/usr/bin/env bash
# run_audit.sh — orchestrator glue for Steps 2–5.
#
# Reads the lockdiff TSV, enforces max-crates, and for every changed crate:
#   build old + new (Step 2) -> diff symbols (Step 3) -> risk tier (Step 4),
# accumulating one markdown section per crate. Finally hands the sections to
# post_comment.sh (Step 5).
#
# Env:
#   LOCKDIFF_TSV  path to the TSV from parse_lockdiff.sh
#   WORK          scratch dir (default /tmp/rsa)
#   MAX_CRATES    skip entirely if more than this many crates changed (default 5)
#   PR_NUMBER     pull-request number for the comment
#   GH_TOKEN / GITHUB_TOKEN   token for gh
#   RSA_DRY_RUN=1 build the comment but do not post (local testing)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

LOCKDIFF_TSV="${LOCKDIFF_TSV:-/tmp/rsa/lockdiff.tsv}"
WORK="${WORK:-/tmp/rsa}"
MAX_CRATES="${MAX_CRATES:-5}"
mkdir -p "$WORK"
SECTIONS="$WORK/sections.md"
: > "$SECTIONS"

if [ ! -s "$LOCKDIFF_TSV" ]; then
  log "run_audit: no changed crates in $LOCKDIFF_TSV — nothing to do"
  exit 0
fi

NCHANGED="$(count_lines "$LOCKDIFF_TSV")"
if [ "$NCHANGED" -gt "$MAX_CRATES" ]; then
  log "run_audit: $NCHANGED crates changed (> max-crates=$MAX_CRATES) — skipping audit"
  {
    printf '## 🛡️ rust-symbol-audit\n\n'
    printf '⏭️ Skipped: **%s** crates changed in this PR, above the configured `max-crates` limit of **%s** (symbol diffing every crate would be too slow). Bump `max-crates` to audit anyway.\n' "$NCHANGED" "$MAX_CRATES"
  } > "$WORK/comment_body.md"
  OVERALL_TIER="skipped" CRATE_COUNT="$NCHANGED" SECTIONS_FILE="" \
    BODY_FILE="$WORK/comment_body.md" "$HERE/post_comment.sh"
  exit 0
fi

# markdown-escape a symbol for a table cell wrapped in a code span.
md_cell() { printf '%s' "$1" | sed 's/|/\\|/g'; }

OVERALL="none"
CRATES_DONE=0

while IFS=$'\t' read -r name oldv newv; do
  [ -n "${name:-}" ] || continue
  CRATES_DONE=$((CRATES_DONE + 1))
  CDIR="$WORK/crates/$name"
  mkdir -p "$CDIR"
  log "=== auditing $name : ${oldv:-<new>} -> $newv ==="

  OLD_RLIB=""
  OLD_ERR=""
  if [ -n "${oldv:-}" ]; then
    if OLD_RLIB="$("$HERE/build_crate.sh" "$oldv" "$name" "$CDIR/old" 2>>"$CDIR/build.log")"; then :; else
      OLD_RLIB=""; OLD_ERR="1"
    fi
  fi
  NEW_RLIB=""
  NEW_ERR=""
  if NEW_RLIB="$("$HERE/build_crate.sh" "$newv" "$name" "$CDIR/new" 2>>"$CDIR/build.log")"; then :; else
    NEW_RLIB=""; NEW_ERR="1"
  fi

  # If we couldn't build the new version, we can't say anything useful.
  if [ -z "$NEW_RLIB" ]; then
    emoji="⚠️"
    {
      printf '### %s `%s` %s → %s — build failed\n\n' "$emoji" "$name" "${oldv:-—}" "$newv"
      printf 'Could not build the new version in isolation (missing features, system libs, or a proc-macro/bin-only crate). Nothing to diff.\n\n'
    } >> "$SECTIONS"
    continue
  fi

  "$HERE/diff_symbols.sh" "$OLD_RLIB" "$NEW_RLIB" "$CDIR" >/dev/null
  ADDED_FILE="$CDIR/added_syms.txt"
  ADDED_COUNT="$(count_lines "$ADDED_FILE")"

  "$HERE/risk_check.sh" "$ADDED_FILE" "$CDIR" >/dev/null
  TIER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["tier"])' "$CDIR/risk.json" 2>/dev/null || echo none)"
  RISK_TSV="$CDIR/risk.tsv"
  MATCH_COUNT="$(count_lines "$RISK_TSV")"

  if [ "$(tier_rank "$TIER")" -gt "$(tier_rank "$OVERALL")" ]; then OVERALL="$TIER"; fi
  emoji="$(tier_emoji "$TIER")"
  tierlabel="$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')"
  [ "$TIER" = "none" ] && tierlabel="no flagged capabilities"

  {
    printf '### %s `%s` %s → %s — **%s**\n\n' "$emoji" "$name" "${oldv:-—}" "$newv" "$tierlabel"
    [ -n "$OLD_ERR" ] && printf '> ⚠️ old version failed to build; treating its symbol set as empty (added list may be inflated).\n\n'
    if [ "$MATCH_COUNT" -gt 0 ]; then
      printf '| risk | added symbol |\n|:--|:--|\n'
      # highest tier first, cap rows
      for t in critical high medium; do
        awk -F'\t' -v t="$t" '$1==t{print $2}' "$RISK_TSV" | while IFS= read -r sym; do
          printf '| %s %s | `%s` |\n' "$(tier_emoji "$t")" "$t" "$(md_cell "$sym")"
        done
      done | head -40
      printf '\n_%s flagged of %s newly-added symbols._\n\n' "$MATCH_COUNT" "$ADDED_COUNT"
    else
      if [ "$ADDED_COUNT" -gt 0 ]; then
        printf '_No sensitive capabilities flagged among %s newly-added symbols. Sample:_\n\n' "$ADDED_COUNT"
        printf '| added symbol |\n|:--|\n'
        head -15 "$ADDED_FILE" | while IFS= read -r sym; do
          printf '| `%s` |\n' "$(md_cell "$sym")"
        done
        printf '\n'
      else
        printf '_No newly-added symbols._\n\n'
      fi
    fi
  } >> "$SECTIONS"

done < "$LOCKDIFF_TSV"

log "run_audit: overall tier=$OVERALL across $CRATES_DONE crate(s)"
set_output "tier=$OVERALL"
set_output "audited=$CRATES_DONE"

OVERALL_TIER="$OVERALL" CRATE_COUNT="$CRATES_DONE" SECTIONS_FILE="$SECTIONS" \
  "$HERE/post_comment.sh"
