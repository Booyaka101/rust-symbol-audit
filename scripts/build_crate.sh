#!/usr/bin/env bash
# build_crate.sh — Step 2
#
# Build a single crate version in isolation (as a dependency of a throwaway
# probe library) and print the path to that dependency's compiled .rlib.
#
# We force `-C symbol-mangling-version=v0` (stable since Rust 1.59, the default
# since 1.97) so the pipeline works identically on any toolchain and always
# produces demangleable v0 symbols.
#
# Usage: build_crate.sh <version> <crate_name> <out_dir>
#   Prints the .rlib path on stdout. Exits non-zero (and prints nothing on
#   stdout) if the crate could not be built.
#
# Env: RSA_TARGET_DIR — the cargo target dir every probe shares. run_audit.sh
#      points it inside WORK; point it somewhere persistent to keep the
#      compiled dependencies between runs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

VERSION="$1"
CRATE="$2"
OUTDIR="$3"

if [ -z "${VERSION:-}" ]; then
  log "build_crate: no version for '$CRATE' (newly added crate?) — skipping this side"
  exit 0
fi

export RUSTFLAGS="${RUSTFLAGS:-} -C symbol-mangling-version=v0"
export CARGO_TERM_COLOR=never
# Keep each probe hermetic and off the caller's target dir.
export CARGO_NET_RETRY="${CARGO_NET_RETRY:-3}"
# ...but not off each other's. Probes share a dependency graph heavily -- the two
# sides of one bump almost entirely, and separate crates through the common
# libc/syn/serde layer -- so one target dir compiles that layer once per audit
# instead of once per probe. RUSTFLAGS is identical across probes, which is what
# makes the artifacts reusable rather than silently rebuilt.
export CARGO_TARGET_DIR="${RSA_TARGET_DIR:-${TMPDIR:-/tmp}/rsa-cargo-target}"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
cd "$OUTDIR"

cargo init --lib --name probe_lib -q >/dev/null 2>&1
# Pin the *exact* version so cargo resolves the same one Cargo.lock names.
#
# Local-testing hook: if RSA_FIXTURES is set and a directory
# "<RSA_FIXTURES>/<crate>-<version>" exists, build that local crate instead of
# fetching from crates.io. This lets the full pipeline be exercised offline with
# deterministic fixtures. On CI RSA_FIXTURES is unset, so crates.io is used.
FIXDIR="${RSA_FIXTURES:-}/${CRATE}-${VERSION}"
if [ -n "${RSA_FIXTURES:-}" ] && [ -d "$FIXDIR" ]; then
  # Normalize to a native path. On Windows/MSYS the bash-visible fixture path is
  # like "/d/Repos/..."; a native (MSVC) cargo would misread that as "D:\d\...".
  # `cygpath -m` yields "D:/Repos/..." which cargo accepts. On Linux CI cygpath
  # is absent (and RSA_FIXTURES is normally unset anyway) so we just fix slashes.
  if command -v cygpath >/dev/null 2>&1; then
    FIXDIR_FWD="$(cygpath -m "$FIXDIR")"
  else
    FIXDIR_FWD="$(printf '%s' "$FIXDIR" | sed 's#\\#/#g')"
  fi
  printf '%s = { path = "%s" }\n' "$CRATE" "$FIXDIR_FWD" >> Cargo.toml
else
  printf '%s = "=%s"\n' "$CRATE" "$VERSION" >> Cargo.toml
fi

if ! cargo build --release --quiet --message-format=json-render-diagnostics \
       > build.json 2> build.err; then
  log "build_crate: '$CRATE@$VERSION' failed to build:"
  sed 's/^/    /' build.err >&2 || true
  exit 3
fi

# Which of the rlibs in the shared deps dir is this version's is cargo's to say,
# not something a filename or an mtime can settle. See pick_rlib.py.
RLIB="$(python3 "$HERE/pick_rlib.py" build.json "$CRATE" "$VERSION" 2>/dev/null || true)"

if [ -z "$RLIB" ]; then
  log "build_crate: no .rlib produced for '$CRATE@$VERSION' (proc-macro / bin-only crate?)"
  exit 4
fi

# Cargo prints native paths; on Windows those are "D:/...", which the rest of
# the pipeline cannot stat.
if command -v cygpath >/dev/null 2>&1; then
  RLIB="$(cygpath -u "$RLIB")"
fi

printf '%s\n' "$RLIB"
