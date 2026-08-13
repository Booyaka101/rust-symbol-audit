# Changelog

All notable changes to **rust-symbol-audit** are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Probe builds share one cargo target dir** (#6). Every crate version was built
  in its own throwaway probe with its own `target/`, so a multi-crate PR
  recompiled the common dependency layer once per probe, and twice over for the
  two sides of every bump. They now share a target dir for the run, set by
  `run_audit.sh` and overridable with `RSA_TARGET_DIR` if you want to keep the
  compiled dependencies between runs.

  Measured on a 5-crate bump PR (`serde_json`, `regex`, `thiserror`, `bytes`,
  `tracing`), 10 probe builds with a warm registry: 70s down to 47s at the
  median of 5 alternating runs, with 32 of 77 compilation units served from the
  shared dir instead of rebuilt. Symbol output is byte-identical.

  Sharing a dir means `lib<crate>-<hash>.rlib` no longer identifies a version,
  since both sides of a bump now sit in the same `deps/`, so `build_crate.sh`
  reads the rlib path out of cargo's own JSON build log (`pick_rlib.py`) instead
  of globbing for it. Picking wrong would have audited one version against
  itself and reported no change, quietly, so the local suite now asserts the two
  versions resolve apart.

## [3.1.1] — 2026-08-10

### Changed

- **Bundled actions moved to their current majors** — `actions/cache` v4 → v6 and
  `actions/upload-artifact` v4 → v7. These run inside `action.yml`, so they execute
  in the consumer's workflow, not ours: anyone pinning `@v3` was still invoking
  `upload-artifact@v4`. No input, output or behaviour change.
- README and the `examples/` workflows use the same current majors, since those are
  what people paste.

## [3.1.0] — 2026-07-19

Feature round bundling five merged issues. Backward-compatible; new inputs default
to prior behavior.

### Added
- **`comment` input** (#2) — `comment: "false"` gives summary-only mode: the job
  summary and outputs (and `fail-on`) still apply, only the PR comment is skipped.
- **`manifest-dir` input** (#4) — watch a `Cargo.lock` outside the repo root
  (monorepos / non-root workspaces, e.g. `backend/Cargo.lock`).
- **cargo-vet interop** (#5) — a `vet` input; certified versions in a
  `supply-chain/audits.toml` are imported as review-ledger sign-offs
  (`read_vet.py`), so cargo-vet users get the ratchet for free.
- **New capability patterns** (#1) — the high tier now flags clipboard
  (`arboard`/`copypasta`), input capture / keylogging (`rdev`/`enigo`/
  `device_query`/`GetAsyncKeyState`/`SetWindowsHookEx`), and screen/camera/mic
  capture (`scrap`/`xcap`/`nokhwa`/`screenshots`/`cpal`).

### Changed
- **Crate names link to crates.io** (#3) in the PR comment (flagged headers and
  the collapsed clean list).
- Local suite grown to **65 checks** (was 46), covering all of the above.

## [3.0.2] — 2026-07-19

### Changed (comment presentation)
- **Accurate verdict headline.** The top line now names the crate and the *actual*
  dominant reason (e.g. "`smallvec` has a known security advisory (RUSTSEC-…)")
  instead of a fixed per-tier sentence that could misdescribe why the tier is what
  it is.
- **Summary line** with counts: crates audited · flagged · advisories · recommendation.
- **Flagged crates first**, sorted by severity; clean/unchanged crates fold into a
  collapsed "N with no flagged findings" `<details>` so the important one stands out.
- **Newly-added crates** render as `new → x.y.z` (not `— → x.y.z`).
- **Advisories deduped and linked** — a RUSTSEC id and its GHSA alias collapse into
  one linked entry (`[RUSTSEC-…](…) (aka GHSA-…) — summary`).

## [3.0.1] — 2026-07-19

### Fixed
- **Newly-added crates were mis-parsed.** `run_audit.sh` read the lockdiff TSV with
  `IFS=$'\t' read`, which collapses the consecutive tabs in a newly-added row
  (`name<TAB><TAB>version`, empty old version) — shifting the version into the old
  field and leaving the new version empty. The crate was then audited with no new
  version, so its build/advisory lanes were skipped. Now split tabs manually to
  preserve empty fields. Found by the live smoke test (a newly-added `smallvec`
  with a known advisory showed no finding); covered by a regression test. Suite is
  now 48 checks.

## [3.0.0] — 2026-07-19

Makes the tool a **gate you can block merges on**: a stateful review ledger
(ratchet) plus two supply-chain lanes, Dependabot auto-merge triage, and a
compliance evidence report.

### Added
- **Review ledger / ratchet** (`.rust-symbol-audit/reviews.toml`,
  `read_reviews.py`, `review.sh`). Sign off a `(crate, version)` once; future
  bumps only alarm on the **unreviewed capability delta**. The PR comment emits a
  copy-paste sign-off snippet, and shows a "reviewed ✅" badge. A sign-off
  suppresses **only** the capability lanes — advisories and provenance changes are
  never hidden by a stale review.
- **Provenance lane** (`provenance.sh`, network) — crates.io publisher change,
  missing source repository, or yanked version. Mockable via `RSA_CRATESIO_FIXTURE`.
- **Advisory lane** (`advisories.sh`, network) — known RustSec vulns for the new
  version via OSV.dev. Mockable via `RSA_ADVISORY_FIXTURE`.
- **Concrete build.rs diff** — the comment now shows the actual build-script
  code/diff in a `<details>` block, not just that it changed.
- **Dependabot / Renovate triage** — `recommendation` output (`auto-merge` when
  tier is none, else `review`) + a bot banner in the comment; example
  `examples/auto-merge.yml` gates GitHub auto-merge on it.
- **Compliance evidence** — every run writes `audit-report.json` (`build_report.py`)
  with the overall verdict and every finding per crate/lane, uploaded as a
  workflow artifact.
- **New inputs**: `reviews`, `check-provenance`, `check-advisories`.
  **New outputs**: `advisories`, `recommendation`, `report`.
- **New fixtures & tests** — mock crates.io / OSV responses; tests for the ratchet,
  the "advisory survives sign-off" safety property, both network lanes, the
  Dependabot recommendation, the build.rs diff, and the evidence report. Suite is
  now **46 checks**.

### Migration
- `uses: booyaka101/rust-symbol-audit@v2` → `@v3`. Existing workflows keep working;
  new lanes/inputs are additive. The network lanes default on and degrade
  gracefully offline (set `check-provenance`/`check-advisories: "false"` to skip).

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

[3.1.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.1.0
[3.0.2]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.0.2
[3.0.1]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.0.1
[3.0.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.0.0
[2.0.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v2.0.0
[1.0.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v1.0.0
