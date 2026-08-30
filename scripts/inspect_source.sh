#!/usr/bin/env bash
# inspect_source.sh — Compile-time / source-level risk lane (Step 3b).
#
# Symbol diffing can only see capability that ends up in the crate's compiled
# .rlib. It is structurally blind to code that runs *at compile time*:
#   - build.rs        — an ordinary Rust program cargo compiles and RUNS on the
#                       build machine before your crate is built.
#   - proc-macro      — code that executes inside the compiler.
#   - links = "..."   — pulls a native (non-Rust) library into the build.
# These are the higher-value supply-chain vectors, so we inspect the crate's
# *source* (which cargo extracts during resolution, even when the later compile
# fails) and flag newly-added / newly-changed compile-time surface.
#
# Usage: inspect_source.sh <crate> <old_ver> <new_ver> <out_dir>
#   Writes <out_dir>/source_findings.tsv  (<tier>\t<kind>\t<detail>)
#          <out_dir>/source.json          ({"tier":..,"findings":[..]})
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

CRATE="${1:?crate name required}"
OLDV="${2:-}"
NEWV="${3:-}"
OUTDIR="${4:-${WORK:-/tmp/rsa}}"
mkdir -p "$OUTDIR"
TSV="$OUTDIR/source_findings.tsv"
JSON="$OUTDIR/source.json"
: > "$TSV"

OLD_SRC="$(crate_src_dir "$CRATE" "$OLDV" || true)"
NEW_SRC="$(crate_src_dir "$CRATE" "$NEWV" || true)"

add_finding() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TSV"; }

# The single-directory inspection (build script discovery incl. custom
# `build = "..."` paths, SRC_ALARM grep, proc-macro / links detection) lives in
# lib.sh as inspect_crate_dir; this script diffs those facts old vs new. The
# new-dependency lane (inspect_new_dep.sh) reads the same facts with no old side.

if [ -z "$NEW_SRC" ]; then
  log "inspect_source: no extracted source for $CRATE@$NEWV — skipping source lane"
  printf '{"tier":"none","findings":[]}\n' > "$JSON"
  exit 0
fi

NEW_FACTS="$OUTDIR/new_facts.tsv"; OLD_FACTS="$OUTDIR/old_facts.tsv"
inspect_crate_dir "$NEW_SRC" > "$NEW_FACTS"
inspect_crate_dir "$OLD_SRC" > "$OLD_FACTS"   # empty when there is no old side

# --- build.rs lane ---------------------------------------------------------
# Captures the ACTUAL build-script code/diff into $OUTDIR/build_rs.diff so the
# comment can show reviewers exactly what runs at compile time — not just that
# something changed.
NEW_BS="$(fact build_script "$NEW_FACTS")"
DIFFOUT="$OUTDIR/build_rs.diff"; : > "$DIFFOUT"
if [ -n "$NEW_BS" ]; then
  OLD_BS="$(fact build_script "$OLD_FACTS")"
  alarm="$(fact alarm "$NEW_FACTS")"
  if [ -z "$OLD_BS" ]; then
    if [ "$alarm" = "1" ]; then
      add_finding critical build-script "new version ADDED a build script that references process / network / fs APIs — this runs on your build machine at compile time"
    else
      add_finding high build-script "new version ADDED a build script (build.rs runs arbitrary code on your build machine at compile time)"
    fi
    { printf '# NEW build script (%s), first 60 lines:\n' "$(basename "$NEW_BS")"; sed -n '1,60p' "$NEW_BS"; } > "$DIFFOUT" 2>/dev/null || true
  elif ! cmp -s "$OLD_BS" "$NEW_BS"; then
    if [ "$alarm" = "1" ]; then
      add_finding critical build-script "build script CHANGED and references process / network / fs APIs (compile-time code — review the diff)"
    else
      add_finding high build-script "build script content CHANGED (compile-time code — review the diff)"
    fi
    { diff -u "$OLD_BS" "$NEW_BS" 2>/dev/null || true; } | sed -n '1,60p' > "$DIFFOUT" || true
  fi
fi

# --- proc-macro lane -------------------------------------------------------
if [ "$(fact proc_macro "$NEW_FACTS")" = "1" ] && [ "$(fact proc_macro "$OLD_FACTS")" != "1" ]; then
  add_finding high proc-macro "crate is now a proc-macro — it executes code inside the compiler when your project builds"
fi

# --- native links lane -----------------------------------------------------
NEW_LINKS="$(fact links "$NEW_FACTS")"
if [ -n "$NEW_LINKS" ] && [ -z "$(fact links "$OLD_FACTS")" ]; then
  add_finding medium native-link "new version links a native library ($NEW_LINKS) — pulls non-Rust code into the build"
fi

# --- overall tier + JSON ---------------------------------------------------
overall="$(max_tier "$TSV")"

OVERALL="$overall" python3 - "$TSV" > "$JSON" <<'PY'
import json, os, sys
tsv = sys.argv[1]
findings = []
try:
    with open(tsv, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            tier, _, rest = line.partition("\t")
            kind, _, detail = rest.partition("\t")
            findings.append({"tier": tier, "kind": kind, "detail": detail})
except FileNotFoundError:
    pass
print(json.dumps({"tier": os.environ.get("OVERALL", "none"), "findings": findings},
                 ensure_ascii=False))
PY

log "inspect_source: $CRATE ${OLDV:-<new>} -> $NEWV source tier=$overall findings=$(count_lines "$TSV")"
cat "$JSON"
