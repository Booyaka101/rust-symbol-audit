# PROGRESS — rust-symbol-audit

Status: **v2.0.0 — COMPLETE & VERIFIED locally.** All acceptance checks pass via
`test/run_local.sh` (**31/31 green**). Remaining work is owner-only: push to
GitHub, run the live Action once (TESTING.md §2), publish to Marketplace.

## What v2 is
A capability-creep triage gate for Rust dependency PRs. Three detection lanes,
merged per crate into one sticky PR comment, with optional merge-gating:

1. **Symbols** — build old+new, diff v0-demangled `.rlib` symbols, tier by
   pattern (`build_crate.sh` → `diff_symbols.sh` → `risk_check.sh`).
2. **Compile-time surface** (`inspect_source.sh`) — newly-added/changed
   `build.rs`, switch to `proc-macro = true`, new `links =`. Catches build-time
   code the symbol lane is structurally blind to; runs even when the crate fails
   to build as a lib (inspects extracted source, not the rlib).
3. **Dependency tree** — diff resolved dep set old-vs-new (each build's
   `Cargo.lock`); list newly-pulled crates, flag known-capability ones.

Plus: `.rust-symbol-audit.toml` allow/ignore (`read_config.py`), sticky comment
+ job summary (`post_comment.sh`), `fail-on` gating and new outputs
(`run_audit.sh`).

## Verified working (this machine, Git Bash + MSVC toolchain, 31/31)
- **A** netcap 0.1→0.2 symbol bump (TcpStream+Command) → **critical**.
- **B** `parse_lockdiff` bump row + no-change → `changed=false`.
- **C** full pipeline → sticky markdown comment with a risk table.
- **D** real crates.io bump (`once_cell` 1.19→1.20) in ~2 s.
- **E** netcap 0.2→0.3 adds a shelling-out `build.rs` → **critical** with **zero**
  new rlib symbols (proves the compile-time lane catches what symbols can't).
- **F** procm 0.1→0.2 proc-macro transition → **high**.
- **G** config `ignore_crates` → `tier=none`; `[allow]` regexes suppress crits.
- **H** dep-tree diff detects a newly-pulled `reqwest`.
- **I** `fail-on: critical` exits non-zero (comment still posted); `none` = exit 0.
- **J** comment carries the sticky-comment marker.

Run to reproduce: `bash test/run_local.sh` → `RESULT: 31 passed, 0 failed`.

## Files
- `action.yml` — composite action. Inputs: `github-token`, `max-crates` (10),
  `fail-on` (none), `config`. Outputs: `changed`, `tier`, `flagged`,
  `build-script-changes`.
- `scripts/` — `lib.sh`, `read_config.py`, `parse_lockdiff.sh`, `build_crate.sh`,
  `diff_symbols.sh`, `inspect_source.sh`, `risk_check.sh`, `post_comment.sh`,
  `run_audit.sh` (orchestrator).
- `test/` — `run_local.sh` + fixtures `netcap-0.{1,2,3}.0`, `procm-0.{1,2}.0`.
- `examples/` — `pr-audit.yml`, `rust-symbol-audit.toml`.
- `README.md`, `TESTING.md`, `CHANGELOG.md`, `LICENSE`.

## Design notes
- **No `nm --defined-only`.** The security signal (a crate newly *referencing*
  `TcpStream::connect` / `Command::spawn`) lives in the *undefined external*
  symbols, which `--defined-only` discards. We keep all symbols, restrict to
  `^_R` (v0), demangle, `sort -u`.
- **Honest ceiling.** Static symbol analysis can't see capability via
  uninstantiated generics or an unchanged dependency, and doesn't sandbox. The
  README says so plainly. The compile-time lane is the main coverage win over
  symbol-only tools.

## Next steps (owner)
1. `git push` to `booyaka101/rust-symbol-audit`; push tags `v2.0.0` and `v2`.
2. TESTING.md §2 — run the live Action on a bump PR; confirm the sticky
   `gh pr comment` upsert works (the one thing local testing can't cover).
3. Publish to GitHub Marketplace (Security category).
