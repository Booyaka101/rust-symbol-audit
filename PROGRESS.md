# PROGRESS — rust-symbol-audit

Status: **v3.0.0 — COMPLETE & VERIFIED locally.** All acceptance checks pass via
`test/run_local.sh` (**46/46 green**). Remaining work is owner-only: push to
GitHub, run the live Action once (TESTING.md §2 — includes the network lanes,
which local testing can only mock), publish to Marketplace.

## What v3 is
A capability-creep triage **gate** for Rust dependency PRs. Five lanes merged per
crate into one sticky comment, made blockable by a stateful review ratchet.

Lanes:
1. **symbols** — v0-demangled rlib diff, pattern-tiered.
2. **compile-time** (`inspect_source.sh`) — build.rs / proc-macro / links; shows
   the actual build-script diff. Runs even if the crate won't build as a lib.
3. **dependencies** — crates newly pulled into the resolved tree.
4. **provenance** (`provenance.sh`, network) — crates.io publisher / source-repo /
   yank change. Mock: `RSA_CRATESIO_FIXTURE`.
5. **advisories** (`advisories.sh`, network) — RustSec via OSV.dev. Mock:
   `RSA_ADVISORY_FIXTURE`.

Ratchet + product:
- **Review ledger** `.rust-symbol-audit/reviews.toml` (`read_reviews.py`,
  `review.sh`): sign off a version once; future bumps alarm only on the
  unreviewed delta. Comment shows a sign-off snippet + "reviewed ✅". A sign-off
  suppresses ONLY the capability lanes — advisories/provenance always surface.
- **config** `.rust-symbol-audit.toml` (`read_config.py`): ignore/allow.
- **sticky comment** + job summary (`post_comment.sh`); **fail-on** gating.
- **Dependabot triage**: `recommendation` output + bot banner; `examples/auto-merge.yml`.
- **Evidence**: `audit-report.json` (`build_report.py`), uploaded as an artifact.

## Verified locally (Git Bash + MSVC toolchain, 46/46)
A–J as before (symbols, parse, full pipeline, real crates.io bump, build.rs lane,
proc-macro, config, dep-tree, gating, sticky marker). Plus:
- **K** ledger ratchet: signed-off version → tier none + "reviewed ✅".
- **L** advisory/provenance survive a stale sign-off (publisher swap still HIGH).
- **M** provenance publisher-change (mock crates.io).
- **N** advisory detection (mock OSV).
- **O** Dependabot recommendation (review vs auto-merge) + banner.
- **P** `audit-report.json` well-formed (critical verdict + per-crate symbols).
- **Q** comment shows the actual build.rs code.
- **R** `read_reviews.py` ALL vs ACCEPT normalization.

Run: `bash test/run_local.sh` → `RESULT: 46 passed, 0 failed`.

## Files
- `action.yml` — inputs: github-token, max-crates, fail-on, config, reviews,
  check-provenance, check-advisories. Outputs: changed, tier, flagged,
  build-script-changes, advisories, recommendation, report. Uploads the evidence
  artifact.
- `scripts/` — lib.sh, read_config.py, read_reviews.py, review.sh,
  parse_lockdiff.sh, build_crate.sh, diff_symbols.sh, inspect_source.sh,
  provenance.sh, advisories.sh, risk_check.sh, build_report.py, post_comment.sh,
  run_audit.sh (orchestrator).
- `test/` — run_local.sh + fixtures netcap-0.{1,2,3}.0, procm-0.{1,2}.0,
  cratesio/netcap.json, osv/vulncrate-1.0.0.json.
- `examples/` — pr-audit.yml, auto-merge.yml, rust-symbol-audit.toml.
- README.md, TESTING.md, CHANGELOG.md, LICENSE.

## Design notes
- **Ledger suppresses only capability lanes.** A later advisory or provenance
  change must never be hidden by an old sign-off (verified by test L).
- **Network lanes degrade gracefully** and are skipped for local fixtures unless a
  mock is provided, so the offline suite is deterministic.
- **Honest ceiling** unchanged: static analysis, not a sandbox; misses
  uninstantiated-generic capability and unchanged-dependency capability.

## Next steps (owner)
1. `git push` to `booyaka101/rust-symbol-audit`; push tags `v3.0.0` and `v3`.
2. TESTING.md §2 — live PR run; confirm sticky upsert, the ratchet, and the
   network lanes (advisory/provenance) firing on a real crate.
3. Publish to GitHub Marketplace (Security category).
