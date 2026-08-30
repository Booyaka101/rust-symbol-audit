#!/usr/bin/env bash
# lib.sh — shared helpers for rust-symbol-audit scripts.
# Sourced by the other scripts; not meant to be executed directly.

# Portable tool overrides:
#   NM       — symbol lister. On the GitHub ubuntu-latest runner this is GNU `nm`.
#              For local testing on a machine without binutils, export NM to a
#              full path, e.g. rustup's llvm-nm.
#   RUSTFILT — the v0/legacy Rust demangler (installed via `cargo install rustfilt`).
NM="${NM:-nm}"
RUSTFILT="${RUSTFILT:-rustfilt}"

# Directory this library lives in, so helpers can find sibling scripts
# (code_scan.py, typosquat.py) regardless of which script sourced lib.sh.
RSA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[rust-symbol-audit] %s\n' "$*" >&2; }

# Hidden marker embedded in the PR comment so we can find & update our own
# previous comment instead of posting a new one every push (sticky comment).
RSA_MARKER='<!-- rust-symbol-audit -->'

# count_lines <file> -> number of lines (records), 0 for missing/empty.
# Robust where `grep -c . f || echo 0` is not: on an empty file `grep -c`
# prints 0 AND exits 1, so the `|| echo 0` fires and you get "0\n0", which then
# breaks integer comparisons. awk counts records (even a final unterminated one).
count_lines() {
  [ -f "$1" ] || { echo 0; return; }
  awk 'END { print NR + 0 }' "$1"
}

# Emit a key=value line to the GitHub Actions step-output file, if present.
set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
}

# tier_rank <tier> -> integer for comparing severities.
tier_rank() {
  case "$1" in
    critical) echo 3 ;;
    high)     echo 2 ;;
    medium)   echo 1 ;;
    *)        echo 0 ;;
  esac
}

# max_tier <findings_tsv> -> the highest tier in column 1, "none" for a missing
# or empty file. Every lane script folds its findings down to one tier this way.
max_tier() {
  local f="${1:-}" o="none" t
  [ -n "$f" ] && [ -f "$f" ] || { echo none; return; }
  while IFS=$'\t' read -r t _rest; do
    [ -n "$t" ] || continue
    if [ "$(tier_rank "$t")" -gt "$(tier_rank "$o")" ]; then o="$t"; fi
  done < "$f"
  echo "$o"
}

# tier_emoji <tier> -> a leading emoji for markdown.
tier_emoji() {
  case "$1" in
    critical) echo "🔴" ;;
    high)     echo "🟠" ;;
    medium)   echo "🟡" ;;
    *)        echo "🟢" ;;
  esac
}

# Extract the set of demangled Rust symbol names from an .rlib (or object file).
#
# Why not `nm --defined-only` (as an early draft did)? The security-relevant
# signal — that a crate newly reaches into std::net::TcpStream / process::Command
# etc. — lives in the *undefined* (external) symbols the crate references, which
# `--defined-only` throws away. We therefore keep every symbol, restrict to the
# v0-mangled ones (prefix `_R`, which also drops MSVC/ELF unwind-table noise and
# non-Rust C symbols), demangle (this also strips the per-crate disambiguator
# hash, making names comparable across versions), and sort-unique.
extract_symbols() {
  local rlib="$1"
  if [ -z "$rlib" ] || [ ! -f "$rlib" ]; then
    return 0
  fi
  # An rlib with no v0 symbols is an ordinary crate, not an error: facade crates
  # that are all consts, type aliases and macros (thiserror 1.0.61 is one) carry
  # none. Callers run under `set -euo pipefail`, so grep's empty-match exit 1
  # would take them down mid-diff and leave the whole symbol lane silently unrun.
  "$NM" "$rlib" 2>/dev/null \
    | awk '{ print $NF }' \
    | { grep '^_R' || true; } \
    | "$RUSTFILT" \
    | sort -u
}

# crate_src_dir <crate> <version> -> path to the extracted crate source, or empty.
#
# The compile-time / manifest lane needs the crate's *source* (build.rs,
# Cargo.toml), not just its compiled rlib. Two cases:
#   - Local testing: RSA_FIXTURES/<crate>-<version> is a path-dep fixture.
#   - crates.io: cargo extracts the .crate tarball into
#     $CARGO_HOME/registry/src/<index>/<crate>-<version>/ during resolution
#     (this happens even if the later *compile* fails, so this lane still works
#     for proc-macro / bin-only crates that don't produce a diffable rlib).
crate_src_dir() {
  local crate="$1" version="${2:-}"
  [ -n "$version" ] || return 0
  if [ -n "${RSA_FIXTURES:-}" ] && [ -d "${RSA_FIXTURES}/${crate}-${version}" ]; then
    printf '%s\n' "${RSA_FIXTURES}/${crate}-${version}"
    return 0
  fi
  local cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  local d
  d="$(find "$cargo_home/registry/src" -maxdepth 2 -type d -name "${crate}-${version}" 2>/dev/null | head -1)"
  [ -n "$d" ] && printf '%s\n' "$d"
}

# --- compile-time source inspection (shared by inspect_source.sh for the
# --- audited crate and inspect_new_dep.sh for newly-pulled dependencies) ----

# Tokens that turn a build script / proc-macro from "worth a glance" into
# "alarming": process spawning, networking, filesystem writes, base64 blobs,
# shelling out. Case-insensitive.
SRC_ALARM='process::command|command::new|::exec|tcpstream|udpsocket|std::net|reqwest|ureq|hyper|http[s]?://|curl |wget |[^a-z]download|include_bytes!|/bin/sh|/bin/bash|powershell|cmd\.exe|base64|std::fs::write|openoptions|::set_var'

# The two halves of the proc-macro1 shape (2026-08-20): a build script that
# FETCHES something remote AND EXECUTES something. Either half alone is normal
# (proc-macro2/libc/serde all invoke rustc via Command::new in build.rs), so
# both together is the download-and-run pattern. Kept separate from SRC_ALARM so
# the audited-crate lane's tiering is unchanged.
#
# FETCH is deliberately about invoking a network CLIENT or download tool, NOT
# about a URL appearing anywhere: measured over 1810 real crate versions, a bare
# `http[s]?://` rule fired on 61 of the most-downloaded crates in the ecosystem
# (serde, proc-macro2, quote, thiserror, libc, anyhow, zerocopy...) because they
# carry blog/issue/license URLs in comments and error strings. Requiring a real
# client (reqwest/ureq/curl/wget/raw sockets) and stripping comments first (see
# code_scan.py) takes that to 0 while still catching the curl-based payload.
SRC_FETCH='reqwest|ureq|isahc|attohttpc|minreq|\bhyper\b|\bcurl\b|\bwget\b|tcpstream|udpsocket|std::net'
SRC_EXEC='process::command|command::new|::exec|::spawn|/bin/sh|/bin/bash|powershell|cmd\.exe'

# manifest_has <src_dir> <regex> -> 0 if that dir's Cargo.toml matches.
manifest_has() {
  [ -n "$1" ] && [ -f "$1/Cargo.toml" ] && grep -qiE "$2" "$1/Cargo.toml"
}

# build_rs_path <src_dir> -> path to the build script if the crate has one,
# including a custom `build = "path"` in [package]. Always exits 0.
build_rs_path() {
  local d="$1" p
  [ -n "$d" ] || return 0
  if [ -f "$d/build.rs" ]; then printf '%s\n' "$d/build.rs"; return 0; fi
  p="$(grep -E '^[[:space:]]*build[[:space:]]*=' "$d/Cargo.toml" 2>/dev/null \
        | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' | head -1 || true)"
  if [ -n "$p" ] && [ -f "$d/$p" ]; then printf '%s\n' "$d/$p"; fi
  return 0
}

# inspect_crate_dir <src_dir> -> compile-time facts for ONE source directory
# (no old side), as key<TAB>value lines on stdout:
#   build_script <path>      the build script, if any (incl. custom `build =`)
#   readable     0|1         could the build script actually be read
#   alarm        0|1         build script CODE matches SRC_ALARM (comments stripped)
#   fetch_exec   0|1         build script CODE matches SRC_FETCH AND SRC_EXEC
#   proc_macro   0|1         Cargo.toml declares proc-macro = true
#   links        <lib>       Cargo.toml declares links = "<lib>"
# Emits nothing for a missing dir. Both the audited-crate diff and the
# new-dependency classifier read these same facts.
inspect_crate_dir() {
  local d="$1" bs lib
  [ -n "$d" ] && [ -d "$d" ] || return 0
  bs="$(build_rs_path "$d" || true)"
  if [ -n "$bs" ]; then
    printf 'build_script\t%s\n' "$bs"
    if [ -r "$bs" ] && grep -q '' "$bs" 2>/dev/null; then
      printf 'readable\t1\n'
      # Both facts come from one pass over the script's real code, comments
      # stripped. Measured: 23 of 224 real build scripts matched SRC_ALARM only
      # through a URL in a comment (every icu_*_data crate, portable-atomic,
      # radium), which used to escalate an added build script to critical for no
      # reason. See code_scan.py.
      SRC_ALARM="$SRC_ALARM" SRC_FETCH="$SRC_FETCH" SRC_EXEC="$SRC_EXEC" \
        python3 "$RSA_LIB_DIR/code_scan.py" "$bs" 2>/dev/null \
        || printf 'alarm\t0\nfetch_exec\t0\n'
    else
      printf 'readable\t0\nalarm\t0\nfetch_exec\t0\n'
    fi
  fi
  if manifest_has "$d" '^[[:space:]]*proc-macro[[:space:]]*=[[:space:]]*true'; then
    printf 'proc_macro\t1\n'
  else
    printf 'proc_macro\t0\n'
  fi
  if manifest_has "$d" '^[[:space:]]*links[[:space:]]*='; then
    lib="$(grep -E '^[[:space:]]*links[[:space:]]*=' "$d/Cargo.toml" \
            | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' | head -1 || true)"
    printf 'links\t%s\n' "${lib:-unknown}"
  fi
}

# fact <key> <facts_file> -> value of the first matching key, empty if absent.
fact() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$2" 2>/dev/null; }

# pkg_set <cargo_lock> -> sorted-unique "name version" for every [[package]].
# Used to diff the resolved dependency *tree* of the old vs new build (each
# build_crate probe writes a full Cargo.lock), surfacing crates a bump newly
# pulls in — capability that can enter transitively, which the audited crate's
# own symbols won't show.
pkg_set() {
  [ -f "$1" ] || return 0
  awk '
    /^\[\[package\]\]/                 { name=""; ver=""; inpkg=1; next }
    /^\[/ && $0 !~ /^\[\[package\]\]/  { inpkg=0 }
    inpkg && /^name = / {
      l=$0; sub(/^name = "/,"",l); sub(/".*$/,"",l); name=l
    }
    inpkg && /^version = / {
      l=$0; sub(/^version = "/,"",l); sub(/".*$/,"",l); ver=l
      if (name != "") print name " " ver
    }
  ' "$1" | sort -u
}
