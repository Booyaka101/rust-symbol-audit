# PROGRESS — rust-symbol-audit

Status: **v3.5.0 — SHIPPED 2026-08-30.** PR #26 squash-merged to main as
`bd5a13e`, all six checks green on that exact commit, tagged `v3.5.0` and
released; `v3` moved with it. A fresh clone of the published tag runs
**136/136 green**, including with `WORK` outside the MSYS root. Closes the gaps
3.4.0 left open: three were real and are fixed, and the fourth turned out never
to have existed, which is recorded rather than quietly dropped.

## What v3.5.0 adds

1. **A newly-added crate gets a dependency lane.** It was gated on the crate
   having an old version to diff, so a brand-new direct dependency that itself
   pulled a downloader produced nothing. It now falls back to the repo's pre-PR
   lockfile (`base_pkgs.tsv`, written by `parse_lockdiff.sh`) as the reference
   for what counts as new; a dependency the repo already had is not re-reported.
2. **`no-source-repo` for new dependencies**, with the same young/low-adoption
   gate. Measured: 1 of 120 random real crates lacks a repository
   (`serde_regex`, 46M downloads), so gated it alarms on none of them.
3. **The compile-time alarm reads code, not comments.** `SRC_ALARM` was a raw
   grep, so a URL in a comment escalated an added `build.rs` to `critical`.
   Measured over 224 real build scripts: 122 matched raw, 99 with comments
   stripped, **23 matched only through a comment** (the whole `icu_*_data`
   family, `portable-atomic`, `radium`). ⚠️ This lowers those to `high`, so a
   repo on `fail-on: critical` may newly pass. A genuine shell-out is still
   `critical`, asserted.
4. **The version-changed-dependency "gap" was not real.** `parse_lockdiff.sh`
   diffs the whole lockfile, so such a dependency already becomes its own
   audited row and `inspect_source.sh` already catches an added or changed build
   script there. Verified against the fixtures before writing any code. Nothing
   was built; the 3.4.0 write-up was the defect.

Also fixed on the way: `code_scan.py` forced to LF output. Windows python was
translating to CRLF, putting a stray carriage return into every fact value,
which survived only because Git Bash's awk tolerates it.

---

Previous release: **v3.4.0 — SHIPPED 2026-08-30.** PR #23 squash-merged to main as
`b53fdc1`, all six checks green on that exact commit, tagged `v3.4.0` and
released; `major-tag.yml` moved `v3` to the same commit, so consumers pinned at
`@v3` are on 3.4.0. The Marketplace listing already serves v3.4.0 (an
already-listed action picks up releases on its own, no TOTP step). Local suite:
126 passed, 0 failed (baseline was 95).

PR #24 followed as a test-only fix (`6ecb037`, green): TEST P embedded a path
inside a `python3 -c` string, where Git Bash cannot rewrite it for native
python, so the check failed whenever `WORK` sat outside the MSYS root. Found by
running the suite from a fresh clone of the published tag rather than from the
working copy. The tags deliberately stay at `b53fdc1`, since the shipped action
code is byte-identical and a patch release for a test-only change is noise; it
rides along in the next release.

## What v3.4.0 adds (the new-dependency source lane)

Built against the same 2026-08-20 arrayref incident as 3.3.0, but closing a
different blind spot. arrayref 0.3.10 kept its macro source byte-identical and
added one manifest line, `proc-macro1 = "1.0.107"`; the payload lived entirely
in that new dependency's build script (download + execute at compile time).
Before 3.4.0 the dependency lane classified each newly-pulled crate by a fixed
34-name grep (`run_audit.sh:115`, `:169-173`) and never read its source, so the
bump rendered `info proc-macro1` and every lane came back clean.

Now, for each crate a bump newly resolves into the tree:

1. **Versions are carried** through the lockfile diff (`new_deps.tsv`), not
   dropped by `awk '{print $1}'` — `inspect_new_dep.sh` needs the version to
   locate the extracted source.
2. **The build-script / proc-macro / links inspection was extracted** out of
   `inspect_source.sh` into one shared `inspect_crate_dir` in `lib.sh` (no
   clone), called from both the audited-crate path and the new-dependency path.
3. **crates.io `created_at` + total downloads** are fetched for each new dep
   through the provenance path, cached once per run (`RSA_DEPMETA_CACHE`), capped
   at `max-new-deps`, degrading to "unknown" offline.

4. **Typosquat**, added after the first review pass. RustSec filed the incident
   as "via typosquatted `proc-macro1`" and `proc-macro2` was already in every
   victim's tree, so the check compares each new dependency's name against the
   names the OLD lockfile resolved. Fires on the name alone, so it survives a
   payload hidden from the build-script grep. New `typosquat-distance` input,
   `0` disables.

**Tiering:** a `build.rs` that both fetches (network client/tool) and executes,
in a young or barely-downloaded crate = `critical` with the excerpt inline; in
an established, widely-downloaded crate = `medium`; with neither tell = a note.
proc-macro = `high`, links = `medium` (unchanged from the audited-crate lane).
A typosquat name is `high` when the newcomer is also young or barely
downloaded, `critical` when it additionally carries the downloader build
script, and a `none`-tier note when the near-miss is established (`sha1` next
to `sha2`) or metadata is unavailable. A dependency's own ledger sign-off
suppresses all of these; the audited crate's does not (arrayref's sign-off
never vouched for proc-macro1).

## Verified this session (2026-08-30)

- **Phase 0** re-verified live: Rust Security Response Team blog (build script
  "downloading a malicious payload"; arrayref 0.3.10 / append-only-vec 0.1.9 /
  internment 0.8.7, 86/107/90 min online), advisory-db#3161 closed as not
  planned, SafeDep line-level teardown (0.3.10 keeps macro source + one manifest
  line), crates.io API (arrayref tops out at 0.3.9, 251M downloads; cargo-audit
  0.22.2, 11.1M downloads). No cost barrier. LESSONS.md read; no contradiction.
- **Local suite: 136 passed / 0 failed** (was 95). New tests AD (arrayref shape
  → critical end to end, excerpt + dep sign-off snippet), AE (benign
  rustc-probing build.rs → none; dependency sign-off suppresses; audited-crate
  sign-off does NOT), AF (offline → medium, no-source dep → logged skip), AG
  (typosquat: high with NO build script, established near-miss stays a note).
- **A real pre-existing bug found and fixed**: `advisories.sh` lacked
  `PYTHONUTF8=1`, so on Windows its second python block died on cp1252 and
  `advisories.json` was never written. It survived three releases because the
  test asserted only on the TSV, which the *first* block writes. Found by the
  before/after refactor baseline, not by the suite. Linux CI was unaffected.
- **max_tier extracted** to `lib.sh` (five copies → one), proved
  behaviour-neutral over 15 recorded branches, 13 byte-identical, the two that
  moved being the advisories fix and a fixture timestamp.
- **Fixture safety fix**: `dlmacro`'s `build.rs` was genuinely executing during
  every test run (cargo compiles AND runs build scripts), shelling out to curl
  against the real address from the incident. The payload now sits behind a
  guard that is never true; the detector reads the file as text, so detection is
  unchanged (asserted).
- **Worked example reproduced live**: carrier 0.1.0 → 0.2.0 (adds dlmacro, a
  downloader build script) renders `new dependency dlmacro 1.0.0 (crate first
  published 2 days ago, 0 total downloads) ships a build script that downloads
  and executes a remote payload`, tier critical, recommendation review.
- **Corpus measured** (test/CORPUS.md, reproducible via test/corpus_scan.py):
  1810 unique crate versions across 19 popular trees, 224 with a build script,
  **0** fetch+execute hits. A first-cut `http(s)://` rule fired on 61 (serde,
  proc-macro2, quote, thiserror, libc, anyhow, zerocopy…), all comment/error-
  string URLs — re-gated to require a real client + comment-stripping → 0.
- **Typosquat measured on the same corpus**: 1155 names yield 21 distance-1
  pairs and *every one is legitimate* (sha1/sha2, libc/libm, mime/time,
  hyper/hypher…), so name proximity alone is 100% false positives. Gated on the
  newcomer being young or barely downloaded → **0 of 21**; checked against
  crates.io the youngest of those 39 crates is 509 days and the least downloaded
  has 369,664, against gates of 30 days and 10,000.
- **Byte-identical proof**: a no-new-deps bump (netcap 0.1.0 → 0.2.0) renders a
  comment body byte-identical to 3.3.0 (diffed across `git stash`).

## Files touched in 3.4.0

- `scripts/lib.sh` — `inspect_crate_dir` (shared), `fact`, `SRC_FETCH`/
  `SRC_EXEC` (client-based, re-gated), `RSA_LIB_DIR`, `pkg_set` unchanged.
- `scripts/inspect_source.sh` — now diffs `inspect_crate_dir` facts instead of
  its own build_rs_path/manifest_has/SRC_ALARM copies.
- `scripts/inspect_new_dep.sh` — NEW: the new-dependency classifier.
- `scripts/fetch_exec.py` — NEW: comment-stripping fetch+execute test.
- `scripts/agefmt.py` — NEW: shared age formatter (lifted from provenance.sh).
- `scripts/run_audit.sh` — carries dep versions, per-dep inspection with
  `MAX_NEW_DEPS` cap, dep-self ledger filter, comment rendering + excerpt +
  sign-off snippet, headline reasons, `NEWDEP_TIER` in the crate tier.
- `scripts/build_report.py` — `new_dependencies[]` in the evidence JSON.
- `scripts/provenance.sh` — `rel_age` now imported from `agefmt`.
- `action.yml` — `max-new-deps` input + `MAX_NEW_DEPS` env.
- `test/fixtures/` — carrier-{0.1.0,0.2.0,0.3.0}, dlmacro-1.0.0 (downloader),
  pm2like-1.0.0 (benign rustc-probe), cratesio/{dlmacro.json.template,
  pm2like.json}.
- `test/run_local.sh` — tests AD/AE/AF/AG, plus three new assertions on the
  advisories lane (exit code, JSON, no cp1252 mangling).
- `scripts/typosquat.py` — NEW: edit-distance near-miss check.
- `scripts/advisories.sh` — `PYTHONUTF8=1` (the half-run fix).
- `test/corpus_scan.py` + `test/CORPUS.md` — the measurement, reproducible.
- README (lane 3 rewritten, inputs table, catches list + measured FP rate),
  CHANGELOG (3.4.0), PROGRESS.

## Next steps (owner)

1. Nothing blocking. The release is out and verified end to end: a fresh clone
   of the published `v3.4.0` tag carries every new script with the right exec
   bit, and its suite runs green.
2. ⚠️ **Announce the verdict change loudly.** A PR that passed under 3.3.0 can
   now fail for a *transitive dependency* the bump introduced: a
   download-and-execute build script, or a brand-new name one edit from a crate
   already in the tree. `fail-on` users will see new failures. The escape
   hatches are `max-new-deps`, `typosquat-distance: "0"`, and a ledger sign-off
   of the dependency itself.
3. Optional distribution: the arrayref incident is the hook, and the honest
   framing (we read the added dependency's build script and notice it is one
   character from something you already trust; cargo-audit had no advisory to
   fire on) is the one to lead with.

## The four gaps: three closed in 3.5.0, one was never real

1. ~~A dependency whose **version** changed is never inspected.~~ **This claim
   was wrong.** `parse_lockdiff.sh` diffs the *whole* lockfile, so a transitive
   dep moving 1.0.106 → 1.0.107 already becomes its own audited row and
   `inspect_source.sh` catches an added or changed build script at `critical`.
   Verified against the fixtures before writing any code. The only residual is
   the `max-crates` cutoff, which is already reported as "not audited". Nothing
   was built for this; the write-up was the defect.
2. **Newly-added crates get no dependency lane** — CLOSED. The lane was gated on
   the crate having an old version. It now falls back to the repo's pre-PR
   lockfile (`base_pkgs.tsv`, written by `parse_lockdiff.sh`) as the reference
   for what counts as new, so adding a brand-new direct dependency that itself
   pulls a downloader is caught. A dependency the repo already had is correctly
   not re-reported.
3. **New deps skip the no-source-repo check** — CLOSED, with the same
   young/low-adoption gate as everything else in this lane.
4. **`SRC_ALARM` was a raw grep** — CLOSED, and it changes verdicts. See the
   3.5.0 CHANGELOG entry.

## Still open

- The `max-crates` / `max-new-deps` cutoffs are reported, not audited. That is
  by design, but a very wide bump still gets a partial read.
- `CAP_CRATES` (the 34-name capability list in `run_audit.sh`) is untouched and
  still crude. It only sets `medium` on the plain dependency list and no longer
  carries much weight now that the source lane exists, but it is dead weight
  worth revisiting.
