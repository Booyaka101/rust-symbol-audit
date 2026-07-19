#!/usr/bin/env bash
# run_audit.sh — orchestrator glue for Steps 2–5.
#
# For every changed crate (up to MAX_CRATES) it runs three independent risk
# lanes and merges them:
#   - symbols     : build old+new (Step 2) -> diff v0 symbols (Step 3) ->
#                   pattern-tier them (Step 4).
#   - source      : inspect build.rs / proc-macro / native links (Step 3b).
#   - dependencies: diff the resolved dependency tree old vs new (crates newly
#                   pulled into the build).
# Per-crate allow/ignore rules from .rust-symbol-audit.toml suppress known-benign
# signals. The highest surviving tier drives the PR comment and, if `fail-on` is
# set, the job's pass/fail.
#
# Env:
#   LOCKDIFF_TSV  path to the TSV from parse_lockdiff.sh
#   WORK          scratch dir (default /tmp/rsa)
#   MAX_CRATES    audit at most this many changed crates (default 10); the rest
#                 are listed as "not audited".
#   FAIL_ON       none|medium|high|critical — fail the job if the overall tier
#                 reaches this (default none = advisory comment only).
#   RSA_CONFIG    path to the config file (default .rust-symbol-audit.toml)
#   PR_NUMBER     pull-request number for the comment
#   GH_TOKEN / GITHUB_TOKEN   token for gh
#   RSA_DRY_RUN=1 build the comment but do not post (local testing)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

LOCKDIFF_TSV="${LOCKDIFF_TSV:-/tmp/rsa/lockdiff.tsv}"
WORK="${WORK:-/tmp/rsa}"
MAX_CRATES="${MAX_CRATES:-10}"
FAIL_ON="${FAIL_ON:-none}"
RSA_CONFIG="${RSA_CONFIG:-.rust-symbol-audit.toml}"
mkdir -p "$WORK"
SECTIONS="$WORK/sections.md"
: > "$SECTIONS"

if [ ! -s "$LOCKDIFF_TSV" ]; then
  log "run_audit: no changed crates in $LOCKDIFF_TSV — nothing to do"
  exit 0
fi

# --- config: normalize ignore/allow rules once -----------------------------
CONFIG_NORM="$WORK/config.norm"
: > "$CONFIG_NORM"
if [ -f "$RSA_CONFIG" ]; then
  if python3 "$HERE/read_config.py" "$RSA_CONFIG" > "$CONFIG_NORM" 2>/dev/null; then
    log "run_audit: loaded config $RSA_CONFIG ($(count_lines "$CONFIG_NORM") rule(s))"
  else
    log "run_audit: could not parse $RSA_CONFIG — ignoring it"
    : > "$CONFIG_NORM"
  fi
fi

is_ignored() { awk -F'\t' -v c="$1" '$1=="IGNORE"&&$2==c{f=1} END{exit !f}' "$CONFIG_NORM"; }

# apply_allow <crate> <file> -> file contents with allow-matching lines removed.
apply_allow() {
  local crate="$1" f="$2" rx
  rx="$(awk -F'\t' -v c="$crate" '$1=="ALLOW"&&$2==c{print $3}' "$CONFIG_NORM" 2>/dev/null | paste -sd'|' -)"
  if [ ! -f "$f" ]; then return 0; fi
  if [ -z "$rx" ]; then cat "$f"; else grep -viE "$rx" "$f" || true; fi
}

# max_tier <file-with-tier-in-col1> -> highest tier seen (none if empty).
max_tier() {
  local f="$1" o="none" t
  [ -f "$f" ] || { echo none; return; }
  while IFS=$'\t' read -r t _rest; do
    [ -n "$t" ] || continue
    if [ "$(tier_rank "$t")" -gt "$(tier_rank "$o")" ]; then o="$t"; fi
  done < "$f"
  echo "$o"
}

# markdown-escape a symbol/detail for a table cell.
md_cell() { printf '%s' "$1" | sed 's/|/\\|/g'; }

# crates known to carry network / process / crypto / FFI capability — a bump
# newly pulling one of these into the tree is worth flagging (medium).
CAP_CRATES='^(reqwest|hyper|h2|ureq|isahc|surf|attohttpc|curl|native-tls|openssl|openssl-sys|rustls|tokio|mio|async-std|smol|socket2|libc|nix|windows-sys|winapi|windows|ring|jsonwebtoken|ssh2|git2|rusqlite|mysql|mysqlclient-sys|postgres|redis|lettre|trust-dns-resolver|hickory-resolver|zmq|rdkafka)$'

NCHANGED="$(count_lines "$LOCKDIFF_TSV")"
OVERALL="none"
CRATES_DONE=0
INDEX=0
BUILD_SCRIPT_CHANGES=0
FLAGGED=""
NOTAUDITED=""

while IFS=$'\t' read -r name oldv newv; do
  [ -n "${name:-}" ] || continue
  INDEX=$((INDEX + 1))

  # smarter max-crates: audit the first MAX_CRATES, list the remainder.
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
  CDIR="$WORK/crates/$name"
  mkdir -p "$CDIR"
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

  # --- source lane (build.rs / proc-macro / links) — runs even if the compile
  #     failed, because cargo extracts source during resolution. ---
  "$HERE/inspect_source.sh" "$name" "${oldv:-}" "$newv" "$CDIR" >/dev/null 2>>"$CDIR/build.log" || true
  SRC_TSV="$CDIR/source_findings.tsv"
  apply_allow "$name" "$SRC_TSV" > "$CDIR/source_findings.filtered" 2>/dev/null || true
  SRC_TSV_F="$CDIR/source_findings.filtered"
  SRC_TIER="$(max_tier "$SRC_TSV_F")"
  if [ -f "$SRC_TSV_F" ] && awk -F'\t' '$2=="build-script"{f=1} END{exit !f}' "$SRC_TSV_F"; then
    BUILD_SCRIPT_CHANGES=$((BUILD_SCRIPT_CHANGES + 1))
  fi

  # --- dependency-tree lane ---
  DEP_TSV="$CDIR/dep_findings.tsv"; : > "$DEP_TSV"
  OLD_LOCK="$CDIR/old/Cargo.lock"; NEW_LOCK="$CDIR/new/Cargo.lock"
  if [ -n "${oldv:-}" ] && [ -f "$OLD_LOCK" ] && [ -f "$NEW_LOCK" ]; then
    pkg_set "$OLD_LOCK" | awk '{print $1}' | sort -u > "$CDIR/old_pkgs.txt"
    pkg_set "$NEW_LOCK" | awk '{print $1}' | sort -u > "$CDIR/new_pkgs.txt"
    # newly-introduced crate names (drop the probe crate and the audited crate).
    # `|| true` so an all-filtered / empty diff (the common case) is not fatal.
    comm -13 "$CDIR/old_pkgs.txt" "$CDIR/new_pkgs.txt" \
      | grep -vxE "probe_lib|$name" > "$CDIR/new_dep_names.txt" 2>/dev/null || true
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      if printf '%s' "$dep" | grep -qiE "$CAP_CRATES"; then
        printf 'medium\t%s\n' "$dep"
      else
        printf 'info\t%s\n' "$dep"
      fi
    done < "$CDIR/new_dep_names.txt" > "$DEP_TSV"
  fi
  apply_allow "$name" "$DEP_TSV" > "$CDIR/dep_findings.filtered" 2>/dev/null || true
  DEP_TSV_F="$CDIR/dep_findings.filtered"
  DEP_TIER="$(max_tier "$DEP_TSV_F")"

  # --- symbol lane ---
  SYM_TIER="none"; ADDED_COUNT=0; MATCH_COUNT=0
  RISK_TSV_F="$CDIR/risk.filtered"; : > "$RISK_TSV_F"
  if [ -n "$NEW_RLIB" ]; then
    "$HERE/diff_symbols.sh" "$OLD_RLIB" "$NEW_RLIB" "$CDIR" >/dev/null 2>>"$CDIR/build.log" || true
    ADDED_FILE="$CDIR/added_syms.txt"
    ADDED_COUNT="$(count_lines "$ADDED_FILE")"
    "$HERE/risk_check.sh" "$ADDED_FILE" "$CDIR" >/dev/null 2>>"$CDIR/build.log" || true
    apply_allow "$name" "$CDIR/risk.tsv" > "$RISK_TSV_F" 2>/dev/null || true
    MATCH_COUNT="$(count_lines "$RISK_TSV_F")"
    SYM_TIER="$(max_tier "$RISK_TSV_F")"
  fi

  # --- crate tier = highest surviving across all three lanes ---
  CTIER="none"
  for t in "$SYM_TIER" "$SRC_TIER" "$DEP_TIER"; do
    [ "$(tier_rank "$t")" -gt "$(tier_rank "$CTIER")" ] && CTIER="$t"
  done
  [ "$(tier_rank "$CTIER")" -gt "$(tier_rank "$OVERALL")" ] && OVERALL="$CTIER"
  [ "$(tier_rank "$CTIER")" -gt 0 ] && FLAGGED="${FLAGGED:+$FLAGGED, }$name"

  emoji="$(tier_emoji "$CTIER")"
  tierlabel="$(printf '%s' "$CTIER" | tr '[:lower:]' '[:upper:]')"
  [ "$CTIER" = "none" ] && tierlabel="no flagged capabilities"

  # --- render the crate section ---
  {
    printf '### %s `%s` %s → %s — **%s**\n\n' "$emoji" "$name" "${oldv:-—}" "$newv" "$tierlabel"

    if [ -n "$NEW_ERR" ]; then
      printf '> ⚠️ The new version failed to build in isolation (missing features, system libs, or a proc-macro / bin-only crate), so the **symbol** lane could not run. Source & dependency findings below still apply.\n\n'
    elif [ -n "$OLD_ERR" ]; then
      printf '> ⚠️ The old version failed to build; its symbol set is treated as empty (the added-symbol list may be inflated).\n\n'
    fi

    # compile-time / manifest findings
    if [ -s "$SRC_TSV_F" ]; then
      printf '**Compile-time surface:**\n\n'
      while IFS=$'\t' read -r t kind detail; do
        [ -n "$t" ] || continue
        # leading '- ' passed as an argument, not in the format (printf would
        # otherwise parse a format starting with '-' as an option flag).
        printf '%s%s **%s** — %s\n' '- ' "$(tier_emoji "$t")" "$kind" "$detail"
      done < "$SRC_TSV_F"
      printf '\n'
    fi

    # newly-introduced dependencies
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
    elif [ -n "$NEW_RLIB" ]; then
      if [ "$ADDED_COUNT" -gt 0 ]; then
        printf '_No sensitive capabilities flagged among %s newly-added symbols. Sample:_\n\n| added symbol |\n|:--|\n' "$ADDED_COUNT"
        head -15 "$CDIR/added_syms.txt" | while IFS= read -r sym; do
          printf '| `%s` |\n' "$(md_cell "$sym")"
        done
        printf '\n'
      else
        printf '_No newly-added symbols in the compiled rlib._\n\n'
      fi
    fi
  } >> "$SECTIONS"

done < "$LOCKDIFF_TSV"

# remainder note when the PR changed more crates than MAX_CRATES.
if [ -n "$NOTAUDITED" ]; then
  {
    printf '### ⏭️ Not audited (over `max-crates`=%s)\n\n' "$MAX_CRATES"
    printf 'These changed crates were not symbol-diffed to keep the run fast: %s. Raise `max-crates` to include them.\n\n' "$NOTAUDITED"
  } >> "$SECTIONS"
fi

log "run_audit: overall tier=$OVERALL across $CRATES_DONE crate(s); flagged=[${FLAGGED:-}]"
set_output "tier=$OVERALL"
set_output "audited=$CRATES_DONE"
set_output "flagged=$FLAGGED"
set_output "build-script-changes=$BUILD_SCRIPT_CHANGES"

OVERALL_TIER="$OVERALL" CRATE_COUNT="$CRATES_DONE" SECTIONS_FILE="$SECTIONS" \
  "$HERE/post_comment.sh"

# --- gating: fail the job if the overall tier reaches the fail-on threshold ---
if [ "$FAIL_ON" != "none" ] && [ -n "$FAIL_ON" ]; then
  if [ "$(tier_rank "$OVERALL")" -ge "$(tier_rank "$FAIL_ON")" ] && [ "$(tier_rank "$OVERALL")" -gt 0 ]; then
    log "run_audit: overall tier '$OVERALL' >= fail-on '$FAIL_ON' — failing the check."
    exit 1
  fi
fi
