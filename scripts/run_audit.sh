#!/usr/bin/env bash
# run_audit.sh — orchestrator. For every changed crate (up to MAX_CRATES) it runs
# five risk lanes and merges them into one verdict + sticky comment:
#   - symbols      : diff v0 rlib symbols old->new, pattern-tier them.
#   - source       : build.rs / proc-macro / native-links (compile-time code).
#   - dependencies : crates newly pulled into the resolved tree.
#   - provenance   : crates.io publisher / source-repo / yank changes (network).
#   - advisories   : known RustSec vulns for the new version via OSV.dev (network).
#
# Suppression layers: config (.rust-symbol-audit.toml ignore/allow) and the review
# ledger (.rust-symbol-audit/reviews.toml). The ledger suppresses ONLY capability
# lanes; advisories/provenance are never hidden by a stale sign-off.
#
# Env: LOCKDIFF_TSV WORK MAX_CRATES FAIL_ON RSA_CONFIG REVIEWS PR_NUMBER PR_AUTHOR
#      RSA_CHECK_PROVENANCE RSA_CHECK_ADVISORIES RSA_MIN_PUBLISH_AGE_HOURS
#      GH_TOKEN RSA_DRY_RUN RSA_TARGET_DIR
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
export RSA_MIN_PUBLISH_AGE_HOURS="${RSA_MIN_PUBLISH_AGE_HOURS:-24}"
mkdir -p "$WORK"
# Every probe build in this audit shares one target dir (see build_crate.sh);
# keeping it under WORK means it is scoped to the run and cleaned up with it.
export RSA_TARGET_DIR="${RSA_TARGET_DIR:-$WORK/cargo-target}"
SECTIONS="$WORK/sections.md"; : > "$SECTIONS"
: > "$WORK/flagged.list"; : > "$WORK/clean.list"
: > "$WORK/evidence.jsonl" 2>/dev/null || true

if [ ! -s "$LOCKDIFF_TSV" ]; then
  log "run_audit: no changed crates in $LOCKDIFF_TSV — nothing to do"
  exit 0
fi

# --- config (ignore/allow) -------------------------------------------------
CONFIG_NORM="$WORK/config.norm"; : > "$CONFIG_NORM"
if [ -f "$RSA_CONFIG" ]; then
  python3 "$HERE/read_config.py" "$RSA_CONFIG" > "$CONFIG_NORM" 2>/dev/null || : > "$CONFIG_NORM"
  log "run_audit: config $RSA_CONFIG -> $(count_lines "$CONFIG_NORM") rule(s)"
fi
# --- review ledger + cargo-vet import --------------------------------------
REVIEWS_NORM="$WORK/reviews.norm"; : > "$REVIEWS_NORM"
if [ -f "$REVIEWS" ]; then
  python3 "$HERE/read_reviews.py" "$REVIEWS" > "$REVIEWS_NORM" 2>/dev/null || : > "$REVIEWS_NORM"
  log "run_audit: ledger $REVIEWS -> $(count_lines "$REVIEWS_NORM") sign-off(s)"
fi
# cargo-vet interop: treat existing supply-chain/audits.toml certifications as
# sign-offs too (appended to the same normalized ledger).
VET_AUDITS="${VET_AUDITS:-supply-chain/audits.toml}"
if [ -f "$VET_AUDITS" ]; then
  python3 "$HERE/read_vet.py" "$VET_AUDITS" >> "$REVIEWS_NORM" 2>/dev/null || true
  log "run_audit: + cargo-vet $VET_AUDITS -> $(count_lines "$REVIEWS_NORM") total sign-off(s)"
fi

is_ignored() { awk -F'\t' -v c="$1" '$1=="IGNORE"&&$2==c{f=1} END{exit !f}' "$CONFIG_NORM"; }

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

# crate_headline — the single human reason a crate's tier is what it is, used for
# the top-line verdict. Reads the current crate's filtered lane files in scope.
crate_headline() {
  if [ -s "$ADV_TSV_F" ]; then
    local id
    id="$(grep -oE 'RUSTSEC-[0-9]+-[0-9]+|GHSA-[a-z0-9-]+|CVE-[0-9]+-[0-9]+' "$ADV_TSV_F" | head -1)"
    printf 'has a known security advisory%s' "${id:+ ($id)}"; return
  fi
  if awk -F'\t' '$2=="version-not-on-registry"{f=1} END{exit !f}' "$PROV_TSV_F" 2>/dev/null; then
    printf 'bumps to a version crates.io no longer lists (removed from the registry)'; return; fi
  if awk -F'\t' '$2=="publisher-change"{f=1} END{exit !f}' "$PROV_TSV_F" 2>/dev/null; then
    printf 'is now published by a different account'; return; fi
  if awk -F'\t' '$2=="yanked"{f=1} END{exit !f}' "$PROV_TSV_F" 2>/dev/null; then
    printf 'has a yanked new version'; return; fi
  if awk -F'\t' '$2=="no-source-repo"{f=1} END{exit !f}' "$PROV_TSV_F" 2>/dev/null; then
    printf 'has no source repository on crates.io'; return; fi
  if awk -F'\t' '$1=="high"&&$2=="fresh-version"{f=1} END{exit !f}' "$PROV_TSV_F" 2>/dev/null; then
    printf 'was published %s, inside the fresh-version review window' \
      "$(cat "$CDIR/publish_age.txt" 2>/dev/null || printf 'very recently')"; return; fi
  if awk -F'\t' '$2=="build-script"{f=1} END{exit !f}' "$SRC_TSV_F" 2>/dev/null; then
    printf 'added or changed a build script that runs at compile time'; return; fi
  if awk -F'\t' '$2=="proc-macro"{f=1} END{exit !f}' "$SRC_TSV_F" 2>/dev/null; then
    printf 'became a proc-macro (runs code at compile time)'; return; fi
  case "$SYM_TIER" in
    critical) printf 'gained process-exec / raw-socket / syscall capability'; return;;
    high)     printf 'gained filesystem / env / secret-handling capability'; return;;
    medium)   printf 'gained higher-level network (http/tls/dns) capability'; return;;
  esac
  [ "$DEP_TIER" = "medium" ] && { printf 'pulled in new capability-bearing dependencies'; return; }
  printf 'changed its capability surface'
}

CAP_CRATES='^(reqwest|hyper|h2|ureq|isahc|surf|attohttpc|curl|native-tls|openssl|openssl-sys|rustls|tokio|mio|async-std|smol|socket2|libc|nix|windows-sys|winapi|windows|ring|jsonwebtoken|ssh2|git2|rusqlite|mysql|mysqlclient-sys|postgres|redis|lettre|trust-dns-resolver|hickory-resolver|zmq|rdkafka)$'

OVERALL="none"; OVERALL_CRATE=""; OVERALL_REASON=""
CRATES_DONE=0; INDEX=0
BUILD_SCRIPT_CHANGES=0; ADVISORY_COUNT=0; FLAGGED_COUNT=0
FLAGGED=""; NOTAUDITED=""; IGNORED=""

# NB: manual tab-split — `IFS=$'\t' read` collapses the empty old-version field
# of a newly-added crate row (name<TAB><TAB>version), corrupting old/new.
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
    IGNORED="${IGNORED:+$IGNORED, }\`$name\`"
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

  # ledger ratchet ------------------------------------------------------------
  FULLY_REVIEWED=0; REVIEWED_BY=""; LEDGER_RX=""
  if awk -F'\t' -v c="$name" -v v="$newv" '$1=="REVIEW"&&$2==c&&$3==v&&$4=="ALL"{f=1} END{exit !f}' "$REVIEWS_NORM"; then
    FULLY_REVIEWED=1
    REVIEWED_BY="$(awk -F'\t' -v c="$name" -v v="$newv" '$1=="REVIEW"&&$2==c&&$3==v&&$4=="ALL"{print $5; exit}' "$REVIEWS_NORM")"
  fi
  LEDGER_RX="$(awk -F'\t' -v c="$name" -v v="$newv" '$1=="REVIEW"&&$2==c&&$3==v&&$4=="ACCEPT"{print $5}' "$REVIEWS_NORM" | paste -sd'|' -)"
  ledger_filter() {
    local f="$1"; [ -f "$f" ] || return 0
    if [ "$FULLY_REVIEWED" -eq 1 ]; then : > "$f"
    elif [ -n "$LEDGER_RX" ]; then
      grep -viE "$LEDGER_RX" "$f" > "$f.tmp" 2>/dev/null || true; mv "$f.tmp" "$f"
    fi
  }
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

  # registry lanes (never ledger-suppressed) ----------------------------------
  is_fixture=0
  [ -n "${RSA_FIXTURES:-}" ] && [ -d "${RSA_FIXTURES}/${name}-${newv}" ] && is_fixture=1
  PROV_TSV_F="$CDIR/provenance_findings.tsv"; : > "$PROV_TSV_F"; PROV_TIER="none"
  if [ "${RSA_CHECK_PROVENANCE:-1}" != "0" ] && { [ "$is_fixture" -eq 0 ] || [ -n "${RSA_CRATESIO_FIXTURE:-}" ]; }; then
    "$HERE/provenance.sh" "$name" "${oldv:-}" "$newv" "$CDIR" >/dev/null 2>>"$CDIR/build.log" || true
    apply_allow "$name" "$CDIR/provenance_findings.tsv" > "$CDIR/provenance.filtered" 2>/dev/null || true
    PROV_TSV_F="$CDIR/provenance.filtered"; PROV_TIER="$(max_tier "$PROV_TSV_F")"
  fi
  PUB_AGE=""
  [ -s "$CDIR/publish_age.txt" ] && PUB_AGE="$(cat "$CDIR/publish_age.txt")"
  ADV_TSV_F="$CDIR/advisory_findings.tsv"; : > "$ADV_TSV_F"; ADV_TIER="none"
  if [ "${RSA_CHECK_ADVISORIES:-1}" != "0" ] && { [ "$is_fixture" -eq 0 ] || [ -n "${RSA_ADVISORY_FIXTURE:-}" ]; }; then
    "$HERE/advisories.sh" "$name" "$newv" "$CDIR" >/dev/null 2>>"$CDIR/build.log" || true
    apply_allow "$name" "$CDIR/advisory_findings.tsv" > "$CDIR/advisory.filtered" 2>/dev/null || true
    ADV_TSV_F="$CDIR/advisory.filtered"; ADV_TIER="$(max_tier "$ADV_TSV_F")"
    ADVISORY_COUNT=$((ADVISORY_COUNT + $(count_lines "$ADV_TSV_F")))
  fi

  # crate tier ----------------------------------------------------------------
  CTIER="none"
  for t in "$SYM_TIER" "$SRC_TIER" "$DEP_TIER" "$PROV_TIER" "$ADV_TIER"; do
    [ "$(tier_rank "$t")" -gt "$(tier_rank "$CTIER")" ] && CTIER="$t"
  done
  if [ "$(tier_rank "$CTIER")" -gt "$(tier_rank "$OVERALL")" ]; then
    OVERALL="$CTIER"; OVERALL_CRATE="$name"; OVERALL_REASON="$(crate_headline)"
  fi
  if [ "$(tier_rank "$CTIER")" -gt 0 ]; then
    FLAGGED="${FLAGGED:+$FLAGGED, }$name"; FLAGGED_COUNT=$((FLAGGED_COUNT + 1))
  fi

  emoji="$(tier_emoji "$CTIER")"
  tierlabel="$(printf '%s' "$CTIER" | tr '[:lower:]' '[:upper:]')"
  [ "$CTIER" = "none" ] && tierlabel="no flagged changes"
  if [ -z "${oldv:-}" ]; then verstr="new → \`$newv\`"; else verstr="\`$oldv\` → \`$newv\`"; fi
  [ -n "$PUB_AGE" ] && verstr="$verstr (published $PUB_AGE)"

  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${oldv:-}" "$newv" "$CTIER" "$FULLY_REVIEWED" > "$CDIR/meta.tsv"

  # decide: show a full section, or fold into the clean summary ---------------
  show_full=0
  [ "$(tier_rank "$CTIER")" -gt 0 ] && show_full=1
  [ -n "$NEW_ERR" ] && show_full=1

  if [ "$show_full" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${oldv:-—}" "$newv" "$FULLY_REVIEWED" "$PUB_AGE" >> "$WORK/clean.list"
    continue
  fi
  printf '%s\t%s\t%s\n' "$(tier_rank "$CTIER")" "$name" "$CDIR" >> "$WORK/flagged.list"

  # render the crate's full section to its own file --------------------------
  {
    printf '### %s [`%s`](https://crates.io/crates/%s) %s — **%s**\n\n' "$emoji" "$name" "$name" "$verstr" "$tierlabel"

    if [ "$FULLY_REVIEWED" -eq 1 ]; then
      printf '> ✅ Signed off in the review ledger%s — capability findings suppressed; advisories & provenance still checked.\n\n' \
        "${REVIEWED_BY:+ by \`$REVIEWED_BY\`}"
    fi
    if [ -n "$NEW_ERR" ]; then
      printf '> ⚠️ New version failed to build in isolation (features/system-libs/proc-macro/bin-only); the symbol lane could not run. Other lanes still apply.\n\n'
    elif [ -n "$OLD_ERR" ]; then
      printf '> ⚠️ Old version failed to build; its symbol set is treated as empty (added list may be inflated).\n\n'
    fi

    if [ -s "$ADV_TSV_F" ]; then
      printf '**⚠️ Known advisories (RustSec / OSV):**\n\n'
      while IFS=$'\t' read -r t _kind detail; do
        [ -n "$t" ] || continue
        printf '%s%s %s\n' '- ' "$(tier_emoji "$t")" "$detail"
      done < "$ADV_TSV_F"
      printf '\n'
    fi
    if [ -s "$PROV_TSV_F" ] && awk -F'\t' '$1!="none"{f=1} END{exit !f}' "$PROV_TSV_F"; then
      printf '**Provenance:**\n\n'
      while IFS=$'\t' read -r t _kind detail; do
        [ "$t" = "none" ] && continue
        [ -n "$t" ] || continue
        printf '%s%s %s\n' '- ' "$(tier_emoji "$t")" "$detail"
      done < "$PROV_TSV_F"
      printf '\n'
    fi
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
    if [ -s "$DEP_TSV_F" ]; then
      capdeps="$(awk -F'\t' '$1=="medium"{print $2}' "$DEP_TSV_F" | paste -sd', ' -)"
      othdeps="$(awk -F'\t' '$1!="medium"{print $2}' "$DEP_TSV_F" | paste -sd', ' -)"
      printf '**New dependencies pulled into the build:**'
      [ -n "$capdeps" ] && printf ' 🟡 %s' "$capdeps"
      [ -n "$othdeps" ] && printf ' %s' "$othdeps"
      printf '\n\n'
    fi
    if [ "$MATCH_COUNT" -gt 0 ]; then
      printf '**Added symbols (capability):**\n\n| risk | added symbol |\n|:--|:--|\n'
      for t in critical high medium; do
        awk -F'\t' -v t="$t" '$1==t{print $2}' "$RISK_TSV_F" | while IFS= read -r sym; do
          printf '| %s %s | `%s` |\n' "$(tier_emoji "$t")" "$t" "$(md_cell "$sym")"
        done
      done | head -40
      printf '\n_%s flagged of %s newly-added symbols._\n\n' "$MATCH_COUNT" "$ADDED_COUNT"
    elif [ -n "$NEW_RLIB" ] && [ "$FULLY_REVIEWED" -eq 0 ]; then
      printf '_No sensitive symbols flagged among %s newly-added._\n\n' "$ADDED_COUNT"
    fi

    if [ "$HAD_CAP" -eq 1 ] && [ "$FULLY_REVIEWED" -eq 0 ]; then
      printf '<details><summary>✍️ Sign off `%s` %s once reviewed</summary>\n\n' "$name" "$newv"
      printf 'Append to `%s` (or run `scripts/review.sh %s %s`):\n\n' "$REVIEWS" "$name" "$newv"
      printf '```toml\n[[review]]\ncrate = "%s"\nversion = "%s"\nreviewed_by = "YOUR_NAME"\nnotes = ""\n```\n' "$name" "$newv"
      printf '</details>\n\n'
    fi
  } > "$CDIR/section.md"

done < "$LOCKDIFF_TSV"

# --- assemble: flagged crates first (highest tier), then a collapsed clean list
if [ -s "$WORK/flagged.list" ]; then
  sort -t$'\t' -k1,1nr "$WORK/flagged.list" | while IFS=$'\t' read -r _rank _name _cdir; do
    cat "$_cdir/section.md"; printf '\n'
  done >> "$SECTIONS"
fi
if [ -s "$WORK/clean.list" ]; then
  n="$(count_lines "$WORK/clean.list")"
  {
    printf '<details><summary>🟢 %s dependency change(s) with no flagged findings</summary>\n\n' "$n"
    while IFS=$'\t' read -r nm ov nv rv age; do
      if [ "$ov" = "—" ]; then vs="new → \`$nv\`"; else vs="\`$ov\` → \`$nv\`"; fi
      [ -n "$age" ] && vs="$vs (published $age)"
      [ "$rv" = "1" ] && note=" — reviewed ✅" || note=""
      printf -- '- [`%s`](https://crates.io/crates/%s) %s%s\n' "$nm" "$nm" "$vs" "$note"
    done < "$WORK/clean.list"
    printf '\n</details>\n\n'
  } >> "$SECTIONS"
fi
if [ -n "$IGNORED" ]; then
  printf '🔇 Ignored via config: %s\n\n' "$IGNORED" >> "$SECTIONS"
fi
if [ -n "$NOTAUDITED" ]; then
  printf '⏭️ Not audited (over `max-crates`=%s): %s\n\n' "$MAX_CRATES" "$NOTAUDITED" >> "$SECTIONS"
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
    banner="> 🤖 **Bot dependency bump — ✅ no new capability, advisory, or provenance change. Safe to auto-merge.**"
  else
    banner="> 🤖 **Bot dependency bump — ⚠️ changed the risk surface (see below). Review before merging.**"
  fi
  # Prepend by streaming, not "$(cat)": command substitution strips the trailing
  # newlines and the next block's `---` then glues onto the last `</details>`.
  { printf '%s\n\n' "$banner"; cat "$SECTIONS"; } > "$SECTIONS.tmp" && mv "$SECTIONS.tmp" "$SECTIONS"
fi

# --- machine-readable evidence report --------------------------------------
REPORT="$WORK/audit-report.json"
OVERALL="$OVERALL" FAIL_ON="$FAIL_ON" RECOMMENDATION="$RECOMMENDATION" \
AUDITED="$CRATES_DONE" FLAGGED="$FLAGGED" \
python3 "$HERE/build_report.py" "$WORK/crates" > "$REPORT" 2>>"$WORK/report.log" || true

log "run_audit: overall=$OVERALL crates=$CRATES_DONE flagged=$FLAGGED_COUNT reco=$RECOMMENDATION advisories=$ADVISORY_COUNT"
set_output "tier=$OVERALL"
set_output "audited=$CRATES_DONE"
set_output "flagged=$FLAGGED"
set_output "build-script-changes=$BUILD_SCRIPT_CHANGES"
set_output "advisories=$ADVISORY_COUNT"
set_output "recommendation=$RECOMMENDATION"
set_output "report=$REPORT"

OVERALL_TIER="$OVERALL" OVERALL_CRATE="$OVERALL_CRATE" OVERALL_REASON="$OVERALL_REASON" \
CRATE_COUNT="$CRATES_DONE" FLAGGED_COUNT="$FLAGGED_COUNT" ADVISORY_COUNT="$ADVISORY_COUNT" \
RECOMMENDATION="$RECOMMENDATION" SECTIONS_FILE="$SECTIONS" \
  "$HERE/post_comment.sh"

# --- gating ----------------------------------------------------------------
if [ "$FAIL_ON" != "none" ] && [ -n "$FAIL_ON" ]; then
  if [ "$(tier_rank "$OVERALL")" -ge "$(tier_rank "$FAIL_ON")" ] && [ "$(tier_rank "$OVERALL")" -gt 0 ]; then
    log "run_audit: overall tier '$OVERALL' >= fail-on '$FAIL_ON' — failing the check."
    exit 1
  fi
fi
