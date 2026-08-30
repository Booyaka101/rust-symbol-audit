# Changelog

All notable changes to **rust-symbol-audit** are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.5.0] — 2026-08-30

Closes the gaps 3.4.0 left open in its own PROGRESS notes. One of the four
turned out not to exist, which is recorded below rather than quietly dropped.

⚠️ **This changes verdicts in both directions.** A build script whose only
alarming token sits in a comment now tiers `high` instead of `critical`, so a
repo on `fail-on: critical` may newly pass where it used to fail. It is still
reported as an added build script, and `fail-on: high` catches it either way.
In the other direction, a newly-added crate now gets a dependency lane it never
had, and a new dependency with no source repository is a finding, so some bumps
will newly fail.

### Added

- **A newly-added crate gets a dependency lane.** The lane was gated on the
  crate having an old version to diff against, so adding a brand-new direct
  dependency that itself pulled in a downloader produced nothing at all. It now
  falls back to the repo's pre-PR lockfile, written alongside the diff by
  `parse_lockdiff.sh`, as the reference for what actually counts as new. A
  dependency the repo already had is not re-reported.
- **`no-source-repo` for new dependencies.** The provenance lane has always
  flagged a missing source repository for the audited crate and never saw a new
  dependency. Sampling 120 random real crate names, exactly one lacks a
  repository (`serde_regex`, 46M downloads), so it is a rare tell that still
  happens to legitimate crates. Same gate as the rest of the lane: missing *and*
  young or barely downloaded is `high`, missing but established is a note.

### Changed

- **The compile-time alarm reads code, not comments.** `SRC_ALARM` decides
  whether an added or changed `build.rs` is `high` or `critical`, and it was a
  raw grep, so a URL in a comment counted as networking. Measured over the same
  224 real build scripts: it matched 122 raw, 99 with comments stripped, and
  **23 matched only through a comment**. Those 23 are the entire `icu_*_data`
  family plus `portable-atomic` and `radium`, escalated to `critical` for
  linking to a rust-lang issue. A build script that genuinely shells out is
  still `critical`, asserted in the suite.
- The build-script scanning that `lib.sh` did with a grep plus a helper is now
  one pass in `code_scan.py`, which emits every fact the callers need. It forces
  LF on stdout: Windows python was translating to CRLF, putting a stray carriage
  return into every fact value, which survived only because Git Bash's awk
  happens to tolerate it.

### Not a defect after all

3.4.0's notes claimed a dependency whose **version** changed was never
inspected. That was wrong, and checking it before writing code is what caught
it. `parse_lockdiff.sh` diffs the whole lockfile, so a transitive dependency
moving 1.0.106 to 1.0.107 already becomes its own audited row and
`inspect_source.sh` already catches an added or changed build script there. The
only residual is the `max-crates` cutoff, which is already reported as "not
audited". Nothing was built for it.

Local suite: 136 checks, up from 126.

## [3.4.0] — 2026-08-30

The dependency lane now reads the source of every crate a bump newly pulls in,
instead of classifying it by name alone. Built against the same
[2026-08-20 supply chain attack on arrayref](https://blog.rust-lang.org/2026/08/20/supply-chain-attack-on-arrayref/):
the malicious `arrayref` 0.3.10 kept its original macro source byte for byte and
added a single manifest line, `proc-macro1 = "1.0.107"`. The whole payload lived
in that new dependency's build script, which downloaded and executed a remote
binary at compile time. arrayref 0.3.10, internment 0.8.7 and append-only-vec
0.1.9 were live for 86, 90 and 107 minutes and then deleted from crates.io.
RustSec closed the report (advisory-db#3161) as not planned, so cargo-audit has
nothing to fire on.

On that bump the symbol lane sees no added symbols (arrayref's own code did not
change), the compile-time lane sees no build script on arrayref, and until this
release the dependency lane printed `info proc-macro1` from a fixed 34-name grep
that never read the new crate's source. Three crates deep in almost every GUI
tree, and every lane was blind to it.

⚠️ **This changes verdicts.** A PR whose bump pulls in a new dependency with a
download-and-execute build script now tiers `critical` (young or barely
downloaded crate) or `medium` (established, widely used), so it will newly fail
`fail-on: medium`/`high`/`critical` and flip `recommendation` from `auto-merge`
to `review`. A PR that passed clean under 3.3.0 can fail under 3.4.0 for a
transitive dependency the bump introduced. A new proc-macro dependency stays
`high` and a new `links =` dependency stays `medium`, the tiers the compile-time
lane already assigns.

### Added

- **New-dependency source inspection.** For each crate a bump newly resolves
  into the tree (versions are now carried through the lockfile diff, not thrown
  away), the crate's extracted source is inspected: a `build.rs` (including a
  custom `build = "..."` path), a switch to `proc-macro = true`, a `links =`
  native lib, plus the crate's `created_at` and total downloads from crates.io
  (through the provenance lane's existing path, cached once per run, capped, and
  degrading to "unknown" offline exactly as provenance already does).
- **Tiering on the combination, not the build script alone.** A build script
  that references both remote fetch and execution is `critical` when the crate
  is young or barely downloaded (the proc-macro1 shape), `medium` when the crate
  is established and widely downloaded (more likely vendored build tooling), and
  a plain note when it has neither tell. The `critical`/`medium` cases render the
  build-script excerpt inline, the way the audited crate's build-script diff
  already does. Offline, a download-and-execute script with unknown age degrades
  to `medium` rather than being silently cleared.
- **A dependency's own sign-off suppresses these; the audited crate's does not.**
  Signing off `proc-macro1 1.0.107` in the ledger clears the finding for that
  exact version, the same ratchet the capability lanes use. Signing off the crate
  that pulled it in (arrayref) does not hide its dependency's build script, since
  nobody reviewed proc-macro1. The suite asserts both directions.
- **`max-new-deps` input** (default `10`), which source-inspects at most this many new
  dependencies per audited crate. Any beyond the cap are named in the comment as
  not inspected, never silently skipped (house no-silent-caps rule).
- **Typosquat detection.** RustSec filed this incident as "Malware: `arrayref`
  0.3.10 executes a remote payload at build time via typosquatted
  `proc-macro1`", and `proc-macro2` was already sitting in every victim's tree.
  A newly-pulled crate whose name is within one edit of a crate the *old*
  lockfile already resolved, and which is itself young or barely downloaded,
  now tiers `high`, or `critical` when it also carries a download-and-execute
  build script. This fires on the name alone, so it catches a squat whose
  payload is hidden well enough to evade the build-script check. Needs no
  network beyond the metadata already fetched and no bundled list of popular
  crates: the crate being shadowed is one you already depend on. Tunable with
  the new `typosquat-distance` input (`0` disables it).
- New fixtures reconstructing the 2026-08-20 shape (an audited crate whose lib
  source is byte-identical across the bump, one added dependency with a
  downloader build script), a negative fixture modelled on a real established
  build-script crate (rustc feature-probing, no remote fetch), and a typosquat
  fixture that ships **no** build script so the name signal is tested on its
  own. Local suite grown to **126 checks** (was 95).

### Measured before shipping

The gate was run across the resolved trees of 19 popular crates (tokio, serde,
reqwest, hyper, clap, syn, ring, rustls, git2, rusqlite, image, prost and their
transitive dependencies): **1810 unique crate versions, 224 with a build
script**. A first cut that treated any `http(s)://` as a fetch fired on **61**
of the most-downloaded crates in the ecosystem (serde, proc-macro2, quote,
thiserror, libc, anyhow, zerocopy, rustversion, paste), every one a URL sitting
in a comment or an error string, never a real download. The rule was wrong, so
it was re-gated: fetch now means a network client or download tool is actually
invoked (reqwest/ureq/curl/wget/raw sockets), and comments are stripped before
matching. Re-measured, the download-and-execute rule fires on **0 of 1810**
crates while still catching the curl-based payload fixture. Measured
false-positive rate on this corpus: **0%**.

The typosquat rule got the same treatment and it changed the design. Those 1810
versions carry 1155 distinct names, which yield **21 pairs within one edit, and
every single pair is two legitimate crates**: `sha1`/`sha2`, `libc`/`libm`,
`mime`/`time`, `hyper`/`hypher`, `bit-vec`/`bitvec`, `wasi`/`wasmi` and so on. A
rule that alarmed on name proximity would fire in nearly every Rust project on
earth, so name distance is not the signal. The signal is the asymmetry the real
attack had: `proc-macro1` was new with no downloads, `proc-macro2` had years and
billions. Requiring the newcomer to be young or barely downloaded takes those 21
pairs to **0**, with room to spare: checked against crates.io the youngest of
the 39 crates involved is 509 days old and the least downloaded has 369,664
downloads, against gates of 30 days and 10,000. Both measurements are
reproducible with `test/corpus_scan.py` and written up in `test/CORPUS.md`.

### Fixed

- **`advisories.sh` died halfway through on Windows and never wrote
  `advisories.json`.** The lane emits advisory prose containing an em dash, and
  the second of its two python blocks decodes and re-encodes that text; without
  `PYTHONUTF8=1` a Windows interpreter falls back to cp1252 and raises
  `UnicodeEncodeError`, so the script exited 1 with the JSON missing and the
  detail string mangled to a replacement character. 3.3.0 fixed exactly this in
  `provenance.sh` and `advisories.sh` was missed. It survived three releases
  because the test asserted only on `advisory_findings.tsv`, which the *first*
  block writes, so the half-run was invisible. The suite now asserts the exit
  code, the JSON, and the absence of replacement characters. Linux runners were
  never affected, so no released audit result was wrong; the local lane output
  was.

### Changed

- The build-script / proc-macro / links inspection that `inspect_source.sh` ran
  only for the audited crate is now one shared function (`inspect_crate_dir` in
  `lib.sh`), called from both the audited-crate path and the new-dependency
  path, rather than a second copy. A bump that pulls in no new dependencies
  produces byte-identical output to 3.3.0 (verified by diffing the rendered
  comment over a real no-new-deps bump across both versions).
- The tier-folding loop that every lane script carried its own copy of is now
  `max_tier` in `lib.sh`, with the five copies (four lane scripts plus
  `run_audit.sh`'s private duplicate) reduced to one. Proved behaviour-neutral
  by recording each lane's real output across fifteen branches (every tier,
  empty findings, missing source, offline, registry-removed) before and after,
  and diffing byte for byte: thirteen identical, and the two that moved are the
  advisories fix above and a fixture timestamp.

## [3.3.0] — 2026-08-20

The provenance lane now reads publish age and notices a version the registry has
deleted. Built against the
[2026-08-20 supply chain attack on arrayref](https://blog.rust-lang.org/2026/08/20/supply-chain-attack-on-arrayref/):
malicious versions of `arrayref`, `internment` and `append-only-vec` (carrying
the `proc-macro1` typosquat, whose build script downloads and runs a payload)
were live for 86, 90 and 107 minutes and were then **deleted** from crates.io,
not yanked. Before this release the lane had two blind spots against exactly
that: it never read `created_at`, so a version published twelve minutes ago
audited the same as one from 2024, and a version deleted from the registry
produced **zero** findings, because every check was guarded on finding the
version in the crates.io response.

⚠️ **This changes verdicts.** A PR bumping to a version younger than the window
(default 24 h), or to one crates.io no longer lists, now tiers `high`: it will
newly fail `fail-on: high`, and `recommendation` becomes `review` instead of
`auto-merge`. Set `min-publish-age-hours: "0"` to keep the old tiering (the
age still shows in the comment).

### Added

- **`fresh-version` finding** — the new version's `created_at` is read from the
  crates.io response the lane already fetches (no new network request) and
  compared against UTC now. Inside the window: tier `high`, with the real age
  and the incident context in the detail. Outside: a `none`-tier note carrying
  the age, so the comment always shows it. The window is the new
  `min-publish-age-hours` input (default `24`; `0` disables the tiering and
  keeps the note). A missing or malformed `created_at` is a note, never a
  finding.
- **`version-not-on-registry` finding** (tier `high`) — the audited version is
  absent from the crates.io versions array, i.e. removed from the registry,
  which is how crates.io responds to a malicious publish. This is the
  `arrayref 0.3.10` shape and it fires for newly-added crates too. The
  offline/disabled path still emits `provenance-unknown` and nothing else
  (asserted byte-identical in the suite).
- **Publish age inline in the comment** — every audited bump renders as e.g.
  `` `0.3.9` → `0.3.10` (published 41 minutes ago) ``, in flagged sections and
  the collapsed clean list both.
- Like every provenance finding, **neither new finding is suppressed by a
  review-ledger sign-off** — the suite asserts the property for both, alongside
  the existing advisory/provenance-survive-sign-off tests.
- Prior art named in the README rather than implied away: Dependabot's default
  cooldown, Renovate `minimumReleaseAge`, cargo-cooldown, and Cargo RFC 3923
  (`min-publish-age`, whose stabilization PR rust-lang/cargo#17335 is in final
  comment period, so it is landing soon and is the real fix for the resolution
  side). What none of them cover is the carve-out they share: by design the
  resolver leaves a too-young version alone once it is already in the lockfile,
  which is exactly what a review gate is looking at.
- Local suite grown to **95 checks** (was 71): fresh/old/deleted-version
  fixtures, window `0`, sign-off survival, and the offline path.

### Fixed

- **Bot-bump comments lost the rule above the legend.** Prepending the
  Dependabot/Renovate banner went through `"$(cat "$SECTIONS")"`, and command
  substitution strips trailing newlines, so the closing `---` landed glued to
  the last block (`</details>---`) and stopped rendering as a horizontal rule.
  The banner is now prepended by streaming the file. Only affected bot-authored
  PRs, which is most of the ones this tool sees. Found by rendering a real
  comment through GitHub's markdown API rather than reading the raw text.

## [3.2.0] — 2026-08-13

Faster, and it no longer clears a bump it never actually looked at. ⚠️ The fix
changes verdicts: a crate whose old version carries no v0 symbols used to come
back `none` and can now come back `critical`, so a repo running `fail-on` may
newly fail. That is the point of it.

### Fixed

- **A crate whose old version has no v0 symbols is no longer reported as clean**
  (#14). `extract_symbols` ended in a `grep '^_R'` that exits 1 when an rlib
  carries no v0 symbols, and `diff_symbols.sh` runs under `set -euo pipefail`,
  so the whole symbol lane died right after writing `old_syms.txt`.
  `added_syms.txt` was never written, `run_audit.sh` swallowed the failure, and
  the crate came back with no added symbols and tier `none`.

  Rlibs with no v0 symbols are ordinary: facade crates that are all consts, type
  aliases and macros have none, `thiserror` 1.0.61 among them. The bad case is
  such a version bumping to one that adds real code, where the audit skipped the
  diff entirely and cleared it. On the new `facade` fixture, a bump that gains
  `TcpStream::connect` and `Command::spawn` went from `tier=none` to
  `tier=critical`.

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

[3.3.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.3.0
[3.2.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.2.0
[3.1.1]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.1.1
[3.1.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.1.0
[3.0.2]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.0.2
[3.0.1]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.0.1
[3.0.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v3.0.0
[2.0.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v2.0.0
[1.0.0]: https://github.com/booyaka101/rust-symbol-audit/releases/tag/v1.0.0
