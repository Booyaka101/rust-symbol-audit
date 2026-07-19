# Changelog

All notable changes to **rust-symbol-audit** are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-07-19

First public release. A composite GitHub Action that, on dependency-change PRs,
diffs the v0-demangled Rust symbols between the old and new versions of every
crate whose version changed in `Cargo.lock`, and flags newly-gained sensitive
capabilities as a PR comment.

### Added
- **Pipeline** (`scripts/`): `parse_lockdiff.sh` → `build_crate.sh` →
  `diff_symbols.sh` → `risk_check.sh` → `post_comment.sh`, orchestrated by
  `run_audit.sh`.
- **Composite action** (`action.yml`) with inputs `github-token` and
  `max-crates`, and outputs `changed` and `tier`.
- **Risk tiers**: 🔴 critical (exec/spawn/raw-socket/syscall/FFI),
  🟠 high (fs/env/secrets), 🟡 medium (http/tls/dns/net).
- **Forced v0 mangling** (`-C symbol-mangling-version=v0`) so the audit works on
  any toolchain ≥ 1.59, not only Rust ≥ 1.97 where v0 is the default.
- **Offline local test suite** (`test/run_local.sh`) exercising the whole
  pipeline against `netcap` fixtures plus one real crates.io bump; 17 checks
  covering all five acceptance criteria.
- **Consumer example** (`examples/pr-audit.yml`) and docs (`README.md`,
  `TESTING.md`).

[1.0.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v1.0.0
