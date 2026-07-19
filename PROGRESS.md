# PROGRESS — rust-symbol-audit

Status: **COMPLETE & VERIFIED locally.** All 5 acceptance checks pass via
`test/run_local.sh` (17/17 green). Remaining work is owner-only: the live GitHub
Actions run (documented in TESTING.md).

## Phase 0 — resource verification (done)
- Rust 1.97.0 blog (https://blog.rust-lang.org/2026/07/09/Rust-1.97.0/) re-fetched:
  **confirmed** v0 mangling is the stable default as of 1.97 (2026-07-09). (The
  brief's paraphrase about "supply-chain scanners" is not literally in the post,
  but it is not a build dependency — the load-bearing fact, v0-default, holds.)
- `rustfilt` installs free from crates.io (`rust_demangle 0.2.1` present). No paid
  API / account / hosting anywhere in the design. **Not blocked.**
- Local toolchain present: rustc/cargo 1.95.0 (MSVC), git, gh, python3, rustfilt,
  and `llvm-nm.exe` via the `llvm-tools` component. v0 is forced with
  `-C symbol-mangling-version=v0`, so 1.95 works despite not being 1.97.

## What is VERIFIED working (this machine, Git Bash + MSVC toolchain)
- **acc #3** Fixture bump `netcap` 0.1.0→0.2.0 (gains `TcpStream` + `Command`)
  tiers **critical**. Raw `_R…` v0 symbols demangle correctly and `llvm-nm` reads
  MSVC COFF `.rlib`s.
- **acc #1** `parse_lockdiff.sh` emits the `crate old new` bump row from a real git
  repo diff; sets `changed=true`.
- **acc #4** No-change lockfile diff → `changed=false`, empty TSV, exit 0.
- **acc #2** Full `parse → run_audit → post_comment` (dry-run) renders a Markdown
  comment with a risk/symbol table naming the crate.
- **acc #5** Real crates.io path: `build_crate.sh` fetched & built `once_cell`
  1.19.0 → 1.20.2; whole single-crate bump ran in ~2 s (< 240 s).

Run to reproduce: `bash test/run_local.sh` → `RESULT: 17 passed, 0 failed`.

## Fixes applied this session (all local-Windows-portability or robustness; the
Linux CI path was already correct)
1. `scripts/build_crate.sh` — normalize the `RSA_FIXTURES` fixture path with
   `cygpath -m` when available. Native (MSVC) cargo was misreading the MSYS path
   `/d/Repos/...` as `D:\d\Repos\...` (os error 3). No effect on Linux CI (cygpath
   absent, RSA_FIXTURES unset there).
2. `scripts/lib.sh` — added `count_lines()` (awk-based). Replaces the
   `grep -c . f || echo 0` idiom that prints `"0\n0"` on empty files and then
   breaks integer comparisons.
3. `scripts/run_audit.sh` — use `count_lines` for NCHANGED / ADDED_COUNT /
   MATCH_COUNT.
4. `test/run_local.sh` — TEST B used `grep -qP` (PCRE `\t`), which errors on this
   Git Bash locale → switched to `grep -qF` with a literal tab. TEST D count used
   the same `0\n0` idiom → awk count.

## Files
- `action.yml` — composite action, inputs `github-token` / `max-crates`, outputs
  `changed` / `tier`.
- `scripts/` — `lib.sh`, `parse_lockdiff.sh`, `build_crate.sh`, `diff_symbols.sh`,
  `risk_check.sh`, `post_comment.sh`, `run_audit.sh` (orchestrator).
- `test/` — `run_local.sh` + `fixtures/netcap-0.{1,2}.0`.
- `examples/pr-audit.yml` — copy-paste consumer workflow.
- `README.md`, `TESTING.md`.

## Design note (deliberate deviation from the brief's Step 3)
The brief showed `nm --defined-only`. The implementation intentionally does NOT
use `--defined-only`: the security signal (a crate newly *referencing*
`TcpStream::connect` / `Command::spawn`) lives in the **undefined external**
symbols an rlib carries, which `--defined-only` discards. We keep all symbols,
restrict to `^_R` (v0), demangle, `sort -u`. Verified: this is exactly what makes
the `netcap` 0.2.0 network/exec references show up and get flagged.

## Next steps (owner)
1. Push to a GitHub repo (root has `action.yml`), tag `v1`.
2. Follow TESTING.md §2 to run the live Action on a bump PR and confirm the
   `gh pr comment` POST works (the one thing local testing can't cover).
3. Publish to GitHub Marketplace (Security category) — see README "Best first
   distribution step".
