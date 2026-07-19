#!/usr/bin/env bash
# run_audit.sh — orchestrator. For every changed crate (up to MAX_CRATES) it runs
# five risk lanes and merges them into one verdict + sticky comment:
#   - symbols      : diff v0 rlib symbols old->new, pattern-tier them.
#   - source       : build.rs / proc-macro / native-links (compile-time code).
#   - dependencies : crates newly pulled into the resolved tree.
#   - provenance   : crates.io publisher / source-repo / yank changes (network).
#   - advisories   : known RustSec vulns for the new version via OSV.dev (network).
#
# Two suppression layers keep it quiet enough to gate on:
#   - config  (.rust-symbol-audit.toml)      : ignore_crates + per-crate allow.
#   - ledger  (.rust-symbol-audit/reviews.toml): sign off a version once; future
#     bumps only alarm on the UNREVIEWED capability delta (the ratchet).
# The ledger suppresses ONLY the capability lanes (symbols/source/deps). Newly
# disclosed advisories and provenance changes are never hidden by an old sign-off.
#
# Env: LOCKDIFF_TSV WORK MAX_CRATES FAIL_ON RSA_CONFIG REVIEWS PR_NUMBER PR_AUTHOR
#      RSA_CHECK_PROVENANCE RSA_CHECK_ADVISORIES GH_TOKEN RSA_DRY_RUN
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

LOCKDIFF_TSV="${LOCKDIFF_TSV:-/tmp/rsa/lockdiff.tsv}"
WORK="${WORK:-/tmp/rsa}"
MAX_CRATES="${MAX_CRATES:-10}"
FAIL_ON="${FAIL_ON:-none}"
RSA_CONFIG="${RSA_CONFIG:-.rust-symbol-audit.toml}"
REVIEWS="${REVIEWS:-.rust-symbol-audit/reviews.toml}"
mkdir -p "$WORK"
SECTIONS="$WORK/sections.md"; : > "$SECTIONS"
: > "$WORK/evidence.jsonl" 2>/dev/null || true

if [ ! -s "$LOCKDIFF_TSV" ]; then
  log "run_audit: no changed crates in $LOCKDIFF_TSV — nothing to do"
  exit 0
fi

# --- config (ignore/allow) -------------------------------------------------
CONFIG_NORM="$WORK/config.norm"; : > "$CONFIG_NORM"
if [ -f "$RSA_CONFIG" ]; then
  python3 "$HERE/read_config.py" "$RSA_CONFIG" > "$CONFIG_NORM" 2>/dev/null \
    || : > "$CONFIG_NORM"
  log "run_audit: config $RSA_CONFIG -> $(count_lines "$CONFIG_NORM") rule(s)"
fi
# --- review ledger ---------------------------------------------------------
REVIEWS_NORM="$WORK/reviews.norm"; : > "$REVIEWS_NORM"
if [ -f "$REVIEWS" ]; then
  python3 "$HERE/read_reviews.py" "$REVIEWS" > "$REVIEWS_NORM" 2>/dev/null \
    || : > "$REVIEWS_NORM"
  log "run_audit: ledger $REVIEWS -> $(count_lines "$REVIEWS_NORM") sign-off(s)"
fi

is_ignored() { awk -F'\t' -v c="$1" '$1=="IGNORE"&&$2==c{f=1} END{exit !f}' "$CONFIG_NORM"; }

# apply_allow <crate> <file> -> file contents minus config-allow matches.
apply_allow() {
  local crate="$1" f="$2" rx
  rx="$(awk -F'\t' -v c="$crate" '$1=="ALLOW"&&$2==c{print $3}' "$CONFIG_NORM" 2>/dev/null | paste -sd'|' -)"
  [ -f "$f" ] || return 0
  if [ -z "$rx" ]; then cat "$f"; else grep -viE "$rx" "$f" || true; fi
}

max_tier() {
  local f="$1" o="none" t
  [ -f "$f" ] || { echo none; return; }
  while IFS=$'\t' read -r t _rest; do
    [ -n "$t" ] || continue
    if [ "$(tier_rank "$t")" -gt "$(tier_rank "$o")" ]; then o="$t"; fi
  done < "$f"
  echo "$o"
}

md_cell() { printf '%s' "$1" | sed 's/|/\\|/g'; }

CAP_CRATES='^(reqwest|hyper|h2|ureq|isahc|surf|attohttpc|curl|native-tls|openssl|openssl-sys|rustls|tokio|mio|async-std|smol|socket2|libc|nix|windows-sys|winapi|windows|ring|jsonwebtoken|ssh2|git2|rusqlite|mysql|mysqlclient-sys|postgres|redis|lettre|trust-dns-resolver|hickory-resolver|zmq|rdkafka)$'

OVERALL="none"; CRATES_DONE=0; INDEX=0
BUILD_SCRIPT_CHANGES=0; ADVISORY_COUNT=0
FLAGGED=""; NOTAUDITED=""

# NB: read the whole line and split on tab MANUALLY. `IFS=$'\t' read a b c`
# collapses consecutive tabs (tab is IFS-whitespace), so a newly-added crate
# row `name<TAB><TAB>version` (empty old version) would shift version into `oldv`
# and leave `newv` empty — skipping the build/advisory lanes for new crates.
while IFS= read -r _line || [ -n "$_line" ]; do
  [ -n "$_line" ] || continue
  name="${_line%%$'\t'*}"
  _rest="${_line#*$'\t'}"
  oldv="${_rest%%$'\t'*}"
  newv="${_rest#*$'\t'}"
  [ -n "${name:-}" ] || continue
  INDEX=$((INDEX + 1))
  if [ "$INDEX" -gt "$MAX_CRATES" ]; then
    NOTAUDITED="${NOTAUDITED:+$NOTAUDITED, }\`$name\`"
    continue
  fi
  if is_ignored "$name"; then
    log "run_audit: '$name' ignored via config"
    printf '### 🔇 `%s` %s → %s — ignored\n\nSkipped via `.rust-symbol-audit.toml` (`ignore_crates`).\n\n' \
      "$name" "${oldv:-—}" "$newv" >> "$SECTIONS"
    continue
  fi

  CRATES_DONE=$((CRATES_DONE + 1))
  CDIR="$WORK/crates/$name"; mkdir -p "$CDIR"
  log "=== auditing $name : ${oldv:-<new>} -> $newv ==="

  OLD_RLIB=""; OLD_ERR=""
  if [ -n "${oldv:-}" ]; then
    if OLD_RLIB="$("$HERE/build_crate.sh" "$oldv" "$name" "$CDIR/old" 2>>"$CDIR/build.log")"; then :; else
      OLD_RLIB=""; OLD_ERR="1"
    fi
  fi
  NEW_RLIB=""; NEW_ERR=""
  if NEW_RLIB="$("$HERE/build_crate.sh" "$newv" "$name" "$CDIR/new" 2>>"$CDIR/build.log")"; then :; else
    NEW_RLIB=""; NEW_ERR="1"
  fi

  # capability lanes (allow-filtered) -----------------------------------------
  "$HERE/inspect_source.sh" "$name" "${oldv:-}" "$newv" "$CDIR" >/dev/null 2>>"$CDIR/build.log" || true
  apply_allow "$name" "$CDIR/source_findings.tsv" > "$CDIR/source_findings.filtered" 2>/dev/null || true
  SRC_TSV_F="$CDIR/source_findings.filtered"

  DEP_TSV="$CDIR/dep_findings.tsv"; : > "$DEP_TSV"
  OLD_LOCK="$CDIR/old/Cargo.lock"; NEW_LOCK="$CDIR/new/Cargo.lock"
  if [ -n "${oldv:-}" ] && [ -f "$OLD_LOCK" ] && [ -f "$NEW_LOCK" ]; then
    pkg_set "$OLD_LOCK" | awk '{print $1}' | sort -u > "$CDIR/old_pkgs.txt"
    pkg_set "$NEW_LOCK" | awk '{print $1}' | sort -u > "$CDIR/new_pkgs.txt"
    comm -13 "$CDIR/old_pkgs.txt" "$CDIR/new_pkgs.txt" \
      | grep -vxE "probe_lib|$name" > "$CDIR/new_dep_names.txt" 2>/dev/null || true
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      if printf '%s' "$dep" | grep -qiE "$CAP_CRATES"; then printf 'medium\t%s\n' "$dep"
      else printf 'info\t%s\n' "$dep"; fi
    done < "$CDIR/new_dep_names.txt" > "$DEP_TSV"
  fi
  apply_allow "$name" "$DEP_TSV" > "$CDIR/dep_findings.filtered" 2>/dev/null || true
  DEP_TSV_F="$CDIR/dep_findings.filtered"

  ADDED_COUNT=0
  RISK_TSV_F="$CDIR/risk.filtered"; : > "$RISK_TSV_F"
  if [ -n "$NEW_RLIB" ]; then
    "$HERE/diff_symbols.sh" "$OLD_RLIB" "$NEW_RLIB" "$CDIR" >/dev/null 2>>"$CDIR/build.log" || true
    ADDED_COUNT="$(count_lines "$CDIR/added_syms.txt")"
    "$HERE/risk_check.sh" "$CDIR/added_syms.txt" "$CDIR" >/dev/null 2>>"$CDIR/build.log" || true
    apply_allow "$name" "$CDIR/risk.tsv" > "$RISK_TSV_F" 2>/dev/null || true
  fi

  # ledger ratchet: suppress capability findings for signed-off versions -------
  FULLY_REVIEWED=0; REVIEWED_BY=""; LEDGER_RX=""
  if awk -F'\t' -v c="$name" -v v="$newv" '$1=="REVIEW"&&$2==c&&$3==v&&$4=="ALL"{f=1} END{exit !f}' "$REVIEWS_NORM"; then
    FULLY_REVIEWED=1
    REVIEWED_BY="$(awk -F'\t' -v c="$name" -v v="$newv" '$1=="REVIEW"&&$2==c&&$3==v&&$4=="ALL"{print $5; exit}' "$REVIEWS_NORM")"
  fi
  LEDGER_RX="$(awk -F'\t' -v c="$name" -v v="$newv" '$1=="REVIEW"&&$2==c&&$3==v&&$4=="ACCEPT"{print $5}' "$REVIEWS_NORM" | paste -sd'|' -)"
  ledger_filter() {
    local f="$1"
    [ -f "$f" ] || return 0
    if [ "$FULLY_REVIEWED" -eq 1 ]; then : > "$f"
    elif [ -n "$LEDGER_RX" ]; then
      grep -viE "$LEDGER_RX" "$f" > "$f.tmp" 2>/dev/null || true; mv "$f.tmp" "$f"
    fi
  }
  # note whether there were capability findings BEFORE the ledger wiped them
  HAD_CAP=0
  { [ -s "$SRC_TSV_F" ] || [ -s "$RISK_TSV_F" ] || awk -F'\t' '$1=="medium"{f=1} END{exit !f}' "$DEP_TSV_F" 2>/dev/null; } && HAD_CAP=1
  ledger_filter "$SRC_TSV_F"; ledger_filter "$DEP_TSV_F"; ledger_filter "$RISK_TSV_F"

  SRC_TIER="$(max_tier "$SRC_TSV_F")"
  DEP_TIER="$(max_tier "$DEP_TSV_F")"
  MATCH_COUNT="$(count_lines "$RISK_TSV_F")"
  SYM_TIER="$(max_tier "$RISK_TSV_F")"
  if [ -f "$SRC_TSV_F" ] && awk -F'\t' '$2=="build-script"{f=1} END{exit !f}' "$SRC_TSV_F"; then
    BUILD_SCRIPT_CHANGES=$((BUILD_SCRIPT_CHANGES + 1))
  fi

  # registry lanes (provenance + advisories) — never ledger-suppressed ---------
  # Skip for pure local fixtures with no mock (they aren't crates.io crates).
  is_fixture=0
  [ -n "${RSA_FIXTURES:-}" ] && [ -d "${RSA_FIXTURES}/${name}-${newv}" ] && is_fixture=1

  PROV_TSV_F="$CDIR/provenance_findings.tsv"; : > "$PROV_TSV_F"; PROV_TIER="none"
  if [ "${RSA_CHECK_PROVENANCE:-1}" != "0" ] && { [ "$is_fixture" -eq 0 ] || [ -n "${RSA_CRATESIO_FIXTURE:-}" ]; }; then
    "$HERE/provenance.sh" "$name" "${oldv:-}" "$newv" "$CDIR" >/dev/null 2>>"$CDIR/build.log" || true
    apply_allow "$name" "$CDIR/provenance_findings.tsv" > "$CDIR/provenance.filtered" 2>/dev/null || true
    PROV_TSV_F="$CDIR/provenance.filtered"
    PROV_TIER="$(max_tier "$PROV_TSV_F")"
  fi

  ADV_TSV_F="$CDIR/advisory_findings.tsv"; : > "$ADV_TSV_F"; ADV_TIER="none"
  if [ "${RSA_CHECK_ADVISORIES:-1}" != "0" ] && { [ "$is_fixture" -eq 0 ] || [ -n "${RSA_ADVISORY_FIXTURE:-}" ]; }; then
    "$HERE/advisories.sh" "$name" "$newv" "$CDIR" >/dev/null 2>>"$CDIR/build.log" || true
    apply_allow "$name" "$CDIR/advisory_findings.tsv" > "$CDIR/advisory.filtered" 2>/dev/null || true
    ADV_TSV_F="$CDIR/advisory.filtered"
    ADV_TIER="$(max_tier "$ADV_TSV_F")"
    ADVISORY_COUNT=$((ADVISORY_COUNT + $(count_lines "$ADV_TSV_F")))
  fi

  # crate tier = highest surviving across all five lanes -----------------------
  CTIER="none"
  for t in "$SYM_TIER" "$SRC_TIER" "$DEP_TIER" "$PROV_TIER" "$ADV_TIER"; do
    [ "$(tier_rank "$t")" -gt "$(tier_rank "$CTIER")" ] && CTIER="$t"
  done
  [ "$(tier_rank "$CTIER")" -gt "$(tier_rank "$OVERALL")" ] && OVERALL="$CTIER"
  [ "$(tier_rank "$CTIER")" -gt 0 ] && FLAGGED="${FLAGGED:+$FLAGGED, }$name"

  emoji="$(tier_emoji "$CTIER")"
  tierlabel="$(printf '%s' "$CTIER" | tr '[:lower:]' '[:upper:]')"
  [ "$CTIER" = "none" ] && tierlabel="no flagged capabilities"
  [ "$FULLY_REVIEWED" -eq 1 ] && [ "$CTIER" = "none" ] && tierlabel="reviewed ✅"

  # evidence record (machine-readable, for compliance/SLSA) --------------------
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${oldv:-}" "$newv" "$CTIER" "$FULLY_REVIEWED" > "$CDIR/meta.tsv"

  # render the crate section --------------------------------------------------
  {
    printf '### %s `%s` %s → %s — **%s**\n\n' "$emoji" "$name" "${oldv:-—}" "$newv" "$tierlabel"

    if [ "$FULLY_REVIEWED" -eq 1 ]; then
      printf '> ✅ Signed off in the review ledger%s. Capability findings suppressed; advisories & provenance still checked.\n\n' \
        "${REVIEWED_BY:+ by \`$REVIEWED_BY\`}"
    fi
    if [ -n "$NEW_ERR" ]; then
      printf '> ⚠️ New version failed to build in isolation (features/system-libs/proc-macro/bin-only); the **symbol** lane could not run. Other lanes still apply.\n\n'
    elif [ -n "$OLD_ERR" ]; then
      printf '> ⚠️ Old version failed to build; its symbol set is treated as empty (added list may be inflated).\n\n'
    fi

    # advisories first — highest-signal
    if [ -s "$ADV_TSV_F" ]; then
      printf '**⚠️ Known advisories (RustSec/OSV):**\n\n'
      while IFS=$'\t' read -r t _kind detail; do
        [ -n "$t" ] || continue
        printf '%s%s %s\n' '- ' "$(tier_emoji "$t")" "$detail"
      done < "$ADV_TSV_F"
      printf '\n'
    fi
    # provenance
    if [ -s "$PROV_TSV_F" ] && awk -F'\t' '$1!="none"{f=1} END{exit !f}' "$PROV_TSV_F"; then
      printf '**Provenance:**\n\n'
      while IFS=$'\t' read -r t _kind detail; do
        [ "$t" = "none" ] && continue
        [ -n "$t" ] || continue
        printf '%s%s %s\n' '- ' "$(tier_emoji "$t")" "$detail"
      done < "$PROV_TSV_F"
      printf '\n'
    fi
    # compile-time surface
    if [ -s "$SRC_TSV_F" ]; then
      printf '**Compile-time surface:**\n\n'
      while IFS=$'\t' read -r t kind detail; do
        [ -n "$t" ] || continue
        printf '%s%s **%s** — %s\n' '- ' "$(tier_emoji "$t")" "$kind" "$detail"
      done < "$SRC_TSV_F"
      printf '\n'
      if [ -s "$CDIR/build_rs.diff" ]; then
        printf '<details><summary>📄 show build script</summary>\n\n```diff\n'
        sed 's/```/`​``/g' "$CDIR/build_rs.diff"
        printf '\n```\n</details>\n\n'
      fi
    fi
    # new dependencies
    if [ -s "$DEP_TSV_F" ]; then
      capdeps="$(awk -F'\t' '$1=="medium"{print $2}' "$DEP_TSV_F" | paste -sd', ' -)"
      othdeps="$(awk -F'\t' '$1!="medium"{print $2}' "$DEP_TSV_F" | paste -sd', ' -)"
      printf '**New dependencies pulled into the build:**'
      [ -n "$capdeps" ] && printf ' 🟡 %s' "$capdeps"
      [ -n "$othdeps" ] && printf ' %s' "$othdeps"
      printf '\n\n'
    fi
    # symbols
    if [ "$MATCH_COUNT" -gt 0 ]; then
      printf '**Added symbols (capability):**\n\n| risk | added symbol |\n|:--|:--|\n'
      for t in critical high medium; do
        awk -F'\t' -v t="$t" '$1==t{print $2}' "$RISK_TSV_F" | while IFS= read -r sym; do
          printf '| %s %s | `%s` |\n' "$(tier_emoji "$t")" "$t" "$(md_cell "$sym")"
        done
      done | head -40
      printf '\n_%s flagged of %s newly-added symbols._\n\n' "$MATCH_COUNT" "$ADDED_COUNT"
    elif [ -n "$NEW_RLIB" ] && [ "$FULLY_REVIEWED" -eq 0 ]; then
      if [ "$ADDED_COUNT" -gt 0 ]; then
        printf '_No sensitive capabilities flagged among %s newly-added symbols._\n\n' "$ADDED_COUNT"
      else
        printf '_No newly-added symbols in the compiled rlib._\n\n'
      fi
    fi

    # sign-off snippet (the ratchet UX) — only when there is unreviewed capability
    if [ "$HAD_CAP" -eq 1 ] && [ "$FULLY_REVIEWED" -eq 0 ]; then
      printf '<details><summary>✍️ Sign off `%s` %s once reviewed</summary>\n\n' "$name" "$newv"
      printf 'Append to `%s` (or run `scripts/review.sh %s %s`):\n\n' "$REVIEWS" "$name" "$newv"
      printf '```toml\n[[review]]\ncrate = "%s"\nversion = "%s"\nreviewed_by = "YOUR_NAME"\nnotes = ""\n```\n' "$name" "$newv"
      printf '</details>\n\n'
    fi
  } >> "$SECTIONS"

done < "$LOCKDIFF_TSV"

if [ -n "$NOTAUDITED" ]; then
  {
    printf '### ⏭️ Not audited (over `max-crates`=%s)\n\n' "$MAX_CRATES"
    printf 'Not diffed, to keep the run fast: %s. Raise `max-crates` to include them.\n\n' "$NOTAUDITED"
  } >> "$SECTIONS"
fi

# --- Dependabot / Renovate recommendation ----------------------------------
PR_AUTHOR="${PR_AUTHOR:-}"; is_bot=0
case "$PR_AUTHOR" in
  dependabot*|renovate*|*\[bot\]) is_bot=1;;
esac
RECOMMENDATION="review"
[ "$(tier_rank "$OVERALL")" -eq 0 ] && RECOMMENDATION="auto-merge"
if [ "$is_bot" -eq 1 ]; then
  if [ "$RECOMMENDATION" = "auto-merge" ]; then
    banner="> 🤖 **Bot dependency bump — ✅ no new capability, advisory, or provenance change detected. Safe to auto-merge.**"
  else
    banner="> 🤖 **Bot dependency bump — ⚠️ this one changed the capability/risk surface (see below). Review before merging.**"
  fi
  printf '%s\n\n%s' "$banner" "$(cat "$SECTIONS")" > "$SECTIONS.tmp" && mv "$SECTIONS.tmp" "$SECTIONS"
fi

# --- machine-readable evidence report (compliance / SLSA) ------------------
REPORT="$WORK/audit-report.json"
OVERALL="$OVERALL" FAIL_ON="$FAIL_ON" RECOMMENDATION="$RECOMMENDATION" \
AUDITED="$CRATES_DONE" FLAGGED="$FLAGGED" \
python3 "$HERE/build_report.py" "$WORK/crates" > "$REPORT" 2>>"$WORK/report.log" || true

log "run_audit: overall=$OVERALL crates=$CRATES_DONE flagged=[${FLAGGED:-}] reco=$RECOMMENDATION advisories=$ADVISORY_COUNT"
set_output "tier=$OVERALL"
set_output "audited=$CRATES_DONE"
set_output "flagged=$FLAGGED"
set_output "build-script-changes=$BUILD_SCRIPT_CHANGES"
set_output "advisories=$ADVISORY_COUNT"
set_output "recommendation=$RECOMMENDATION"
set_output "report=$REPORT"

OVERALL_TIER="$OVERALL" CRATE_COUNT="$CRATES_DONE" SECTIONS_FILE="$SECTIONS" \
  "$HERE/post_comment.sh"

# --- gating ----------------------------------------------------------------
if [ "$FAIL_ON" != "none" ] && [ -n "$FAIL_ON" ]; then
  if [ "$(tier_rank "$OVERALL")" -ge "$(tier_rank "$FAIL_ON")" ] && [ "$(tier_rank "$OVERALL")" -gt 0 ]; then
    log "run_audit: overall tier '$OVERALL' >= fail-on '$FAIL_ON' — failing the check."
    exit 1
  fi
fi
