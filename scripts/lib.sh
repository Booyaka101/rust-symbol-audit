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
