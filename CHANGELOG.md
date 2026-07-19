# Changelog

All notable changes to **rust-symbol-audit** are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] — 2026-07-19

Turns the symbol-diff tool into a fuller **capability-creep triage gate**: three
detection lanes, per-repo false-positive suppression, a sticky comment, and
optional merge gating.

### Added
- **Compile-time surface lane** (`inspect_source.sh`) — flags a newly-added or
  changed **`build.rs`**, a switch to **`proc-macro = true`**, or a new
  **`links =`** native library. Catches code that runs at compile time, which the
  symbol lane is structurally blind to. Runs even when the crate fails to build
  as a library (source is inspected, not the rlib).
- **Dependency-tree lane** — diffs the resolved dependency set old-vs-new and
  lists crates the bump newly pulls in, highlighting known-capability crates.
- **Config file** `.rust-symbol-audit.toml` (`read_config.py`) — `ignore_crates`
  and per-crate `[allow]` regexes to suppress known-benign signals.
- **Sticky PR comment** — updates one comment in place (via a hidden marker)
  instead of posting a new one on every push. Report also mirrored to the Actions
  job summary.
- **`fail-on` input** (`none`|`medium`|`high`|`critical`) — optionally fail the
  check to block merges via branch protection. Advisory (`none`) by default.
- **New outputs** `flagged` and `build-script-changes`.
- **New fixtures & tests** — `netcap-0.3.0` (adds a build script), `procm-0.1.0`
  → `procm-0.2.0` (proc-macro transition); tests for every new lane, config
  suppression, dependency-tree diff, and gating. Suite is now 31 checks.

### Changed
- `max-crates` default raised `5` → `10`; over-limit crates are now **listed as
  "not audited"** instead of skipping the whole PR.
- Comment layout groups findings per crate into Compile-time / Dependencies /
  Symbols sections; legend and honest "what it can and can't catch" framing.

### Migration
- `uses: booyaka101/rust-symbol-audit@v1` → `@v2`. Existing workflows keep working
  unchanged (new inputs are optional and default to prior behavior, except the
  higher `max-crates` default and the sticky comment).

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

[2.0.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v2.0.0
[1.0.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v1.0.0
