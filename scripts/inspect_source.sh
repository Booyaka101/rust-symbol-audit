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

# Tokens that turn a build script / proc-macro from "worth a glance" into
# "alarming": process spawning, networking, filesystem writes, base64 blobs,
# shelling out. Case-insensitive.
SRC_ALARM='process::command|command::new|::exec|tcpstream|udpsocket|std::net|reqwest|ureq|hyper|http[s]?://|curl |wget |[^a-z]download|include_bytes!|/bin/sh|/bin/bash|powershell|cmd\.exe|base64|std::fs::write|openoptions|::set_var'

manifest="" # set per-call
manifest_has() { # <src_dir> <regex> -> 0 if that dir's Cargo.toml matches
  [ -n "$1" ] && [ -f "$1/Cargo.toml" ] && grep -qiE "$2" "$1/Cargo.toml"
}

build_rs_path() { # <src_dir> -> path to build script if the crate has one (always exits 0)
  local d="$1" p
  [ -n "$d" ] || return 0
  if [ -f "$d/build.rs" ]; then printf '%s\n' "$d/build.rs"; return 0; fi
  # explicit custom path: build = "path/to/build.rs" in [package]
  p="$(grep -E '^[[:space:]]*build[[:space:]]*=' "$d/Cargo.toml" 2>/dev/null \
        | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' | head -1 || true)"
  if [ -n "$p" ] && [ -f "$d/$p" ]; then printf '%s\n' "$d/$p"; fi
  return 0
}

if [ -z "$NEW_SRC" ]; then
  log "inspect_source: no extracted source for $CRATE@$NEWV — skipping source lane"
  printf '{"tier":"none","findings":[]}\n' > "$JSON"
  exit 0
fi

# --- build.rs lane ---------------------------------------------------------
# Captures the ACTUAL build-script code/diff into $OUTDIR/build_rs.diff so the
# comment can show reviewers exactly what runs at compile time — not just that
# something changed.
NEW_BS="$(build_rs_path "$NEW_SRC" || true)"
DIFFOUT="$OUTDIR/build_rs.diff"; : > "$DIFFOUT"
if [ -n "$NEW_BS" ]; then
  OLD_BS="$(build_rs_path "$OLD_SRC" || true)"
  alarm=0
  grep -qiE "$SRC_ALARM" "$NEW_BS" 2>/dev/null && alarm=1
  if [ -z "$OLD_BS" ]; then
    if [ "$alarm" -eq 1 ]; then
      add_finding critical build-script "new version ADDED a build script that references process / network / fs APIs — this runs on your build machine at compile time"
    else
      add_finding high build-script "new version ADDED a build script (build.rs runs arbitrary code on your build machine at compile time)"
    fi
    { printf '# NEW build script (%s), first 60 lines:\n' "$(basename "$NEW_BS")"; sed -n '1,60p' "$NEW_BS"; } > "$DIFFOUT" 2>/dev/null || true
  elif ! cmp -s "$OLD_BS" "$NEW_BS"; then
    if [ "$alarm" -eq 1 ]; then
      add_finding critical build-script "build script CHANGED and references process / network / fs APIs (compile-time code — review the diff)"
    else
      add_finding high build-script "build script content CHANGED (compile-time code — review the diff)"
    fi
    { diff -u "$OLD_BS" "$NEW_BS" 2>/dev/null || true; } | sed -n '1,60p' > "$DIFFOUT" || true
  fi
fi

# --- proc-macro lane -------------------------------------------------------
if manifest_has "$NEW_SRC" '^[[:space:]]*proc-macro[[:space:]]*=[[:space:]]*true'; then
  if ! manifest_has "$OLD_SRC" '^[[:space:]]*proc-macro[[:space:]]*=[[:space:]]*true'; then
    add_finding high proc-macro "crate is now a proc-macro — it executes code inside the compiler when your project builds"
  fi
fi

# --- native links lane -----------------------------------------------------
if manifest_has "$NEW_SRC" '^[[:space:]]*links[[:space:]]*='; then
  if ! manifest_has "$OLD_SRC" '^[[:space:]]*links[[:space:]]*='; then
    lib="$(grep -E '^[[:space:]]*links[[:space:]]*=' "$NEW_SRC/Cargo.toml" \
            | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' | head -1 || true)"
    add_finding medium native-link "new version links a native library (${lib:-unknown}) — pulls non-Rust code into the build"
  fi
fi

# --- overall tier + JSON ---------------------------------------------------
overall="none"
while IFS=$'\t' read -r t _rest; do
  [ -n "$t" ] || continue
  if [ "$(tier_rank "$t")" -gt "$(tier_rank "$overall")" ]; then overall="$t"; fi
done < "$TSV"

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
