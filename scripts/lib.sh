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

log() { printf '[rust-symbol-audit] %s\n' "$*" >&2; }

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
  "$NM" "$rlib" 2>/dev/null \
    | awk '{ print $NF }' \
    | grep '^_R' \
    | "$RUSTFILT" \
    | sort -u
}
