# Testing rust-symbol-audit

Two levels of verification: the **local suite** (already passing on this machine)
and the **live GitHub Action** (for the owner to run in a real repo).

---

## 1. Local suite — no GitHub, no network required (except one crates.io fetch)

### Prerequisites (all present on this dev box)
- `rustup` / `cargo` (any toolchain ≥ 1.59; v0 mangling is forced explicitly).
- `rustfilt`:  `cargo install rustfilt`
- A symbol lister:
  - Linux/macOS: GNU `nm` (usually already installed).
  - Windows: `rustup component add llvm-tools` provides `llvm-nm.exe`, which
    `test/run_local.sh` auto-detects from the toolchain sysroot.
- `python3` (JSON serialization in `risk_check.sh`).

### Run
In **Git Bash** (not PowerShell — these are bash scripts):

```bash
cd /d/Repos/ideas/rust-symbol-audit
bash test/run_local.sh
```

Expected result: **`RESULT: 95 passed, 0 failed` / `ALL GREEN`**.

### What each test proves
| Test | Proves | Acceptance |
|---|---|---|
| A | Build old+new fixture, diff symbols, a bump gaining `std::net::TcpStream` + `Command` tiers **critical**; the two versions stay apart in the shared target dir | #3, #6 |
| B | `parse_lockdiff.sh` emits the bump row on a real git repo; a no-change diff → `changed=false`, empty TSV | #1, #4 |
| C | Full pipeline `parse → run_audit → post_comment` (dry-run) produces a Markdown comment with a symbol table naming the crate | #1, #2 |
| D | `build_crate.sh` fetches & builds **real crates.io versions** (`once_cell` 1.19.0 → 1.20.2) and the whole single-crate bump runs in **~2 s** | #5 |
| E | Compile-time lane flags a newly-added **`build.rs`** that shells out (`netcap` 0.2.0 → 0.3.0) as **critical** — even though the bump adds **zero** new rlib symbols | new |
| F | Compile-time lane flags a crate switching to **`proc-macro = true`** (`procm` 0.1.0 → 0.2.0) as **high** | new |
| G | `.rust-symbol-audit.toml` `ignore_crates` drops a crate to `tier=none`; `[allow]` regexes suppress the critical symbols | new |
| H | Dependency-tree diff detects a crate (`reqwest`) newly pulled into the resolved tree | new |
| I | `fail-on: critical` makes the run exit non-zero (comment still posted) on a critical bump; `fail-on: none` stays advisory | new |
| J | The PR comment carries the hidden sticky-comment marker used to update it in place | new |
| K | **Review-ledger ratchet**: signing off `netcap` 0.2.0 drops the overall tier to `none` with a "reviewed ✅" badge | new |
| L | A stale sign-off does **not** hide a provenance change — publisher swap still tiers **high** | new |
| M | `provenance.sh` detects a publisher change against a mock crates.io response | new |
| N | `advisories.sh` detects a RustSec/OSV advisory against a mock OSV response | new |
| O | Dependabot triage: risky bump → `recommendation=review` + bot banner; clean bump → `auto-merge` | new |
| P | `audit-report.json` evidence file is well-formed with the verdict + per-crate findings | new |
| Q | The comment shows the **actual build.rs code** (not just "it changed") in a `<details>` block | new |
| R | `read_reviews.py` normalizes whole-version (`ALL`) vs per-capability (`ACCEPT`) sign-offs | new |
| Y | A crate whose old version carries **zero v0 symbols** (`facade` 0.1.0, the `thiserror` shape) still gets diffed, so a bump that gains `TcpStream` + `Command` tiers **critical** instead of coming back clean | #14 |

`test/fixtures/netcap-0.1.0` (pure compute) vs `netcap-0.2.0` (adds
`TcpStream::connect` + `Command::spawn`) is the "real version bump that gains
std::net usage" test case, built through the real toolchain.

### Verify a specific claim by hand
```bash
# Build the "malicious" fixture and see the raw v0 symbols demangle:
NM="$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | sed -n 's/host: //p')/bin/llvm-nm"   # or just: nm
WORK=/d/tmp/probe; rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
cargo init --lib --name probe -q
echo 'netcap = { path = "D:/Repos/ideas/rust-symbol-audit/test/fixtures/netcap-0.2.0" }' >> Cargo.toml
RUSTFLAGS="-C symbol-mangling-version=v0" cargo build --release -q
RLIB=$(find target/release/deps -name 'libnetcap-*.rlib' | head -1)
"$NM" "$RLIB" | awk '{print $NF}' | grep '^_R' | rustfilt | grep -iE 'TcpStream|Command'
# -> <std::process::Command>::spawn ,  <...TcpStream>::connect::inner , ...
```

---

## 2. Live GitHub Action — run this in a real repo (owner's step)

The local suite proves everything except the final `gh pr comment` POST, which
needs a real PR. Do this once to confirm the Marketplace-facing behavior.

### Option A — test inside this action's own repo (fastest)
1. Create a GitHub repo and push this project to it (root contains `action.yml`).
2. Add a tiny Rust crate that depends on something, so it has a `Cargo.lock`.
   The simplest self-contained demo:
   ```bash
   mkdir demo && cd demo
   cargo init --lib --name demo -q
   echo 'netcap = { path = "../test/fixtures/netcap-0.1.0" }' >> Cargo.toml
   cargo generate-lockfile
   git add -A && git commit -m "demo base with netcap 0.1.0"
   ```
   > Path-deps don't hit crates.io; for a truer test use a published crate, e.g.
   > pin `once_cell = "=1.19.0"`, commit the lockfile, then bump to `=1.20.2`.
3. Add `.github/workflows/pr-audit.yml` from
   [`examples/pr-audit.yml`](examples/pr-audit.yml), but point `uses:` at `./`.
4. Open a PR that **bumps the dependency** in `demo/Cargo.toml` and regenerates
   `demo/Cargo.lock` (change `netcap-0.1.0` → `netcap-0.2.0`, or `once_cell`
   `=1.19.0` → `=1.20.2`). Note: the action diffs the repo-root `Cargo.lock`; if
   your lockfile lives in `demo/`, run the action from that dir or move the demo
   crate to the repo root.
5. Confirm the Action run is green and a **capability-diff comment** appears on the
   PR. A `netcap` 0.1.0→0.2.0 bump must show a 🔴 CRITICAL table.

### Option B — drop it into a real existing Rust repo
1. Push this action to a repo, tag it (e.g. `v3`).
2. In the target repo add `.github/workflows/pr-audit.yml` with
   `uses: booyaka101/rust-symbol-audit@v3` and `permissions: pull-requests: write`.
3. Open a PR that bumps a dependency (`cargo update -p <crate> --precise <ver>`
   then commit `Cargo.lock`). The comment should appear within a few minutes.

### Checklist for the live run
- [ ] Action completes green on a one-dependency bump PR. *(acc #1)*
- [ ] A PR comment is posted containing a table of added symbols. *(acc #2)*
- [ ] A dep that gains `std::net::TcpStream` is tiered **critical**. *(acc #3)*
- [ ] A PR that does **not** change `Cargo.lock` → job is skipped / exits 0 with
      no comment. *(acc #4)*  (The `paths: ["Cargo.lock"]` filter also gates this.)
- [ ] A single-crate bump finishes well under 4 minutes. *(acc #5)*
- [ ] **Sticky comment**: push a second commit to the PR → the *same* comment is
      updated, not a new one posted. *(v2)*
- [ ] **Ratchet**: sign the version off (paste the comment's snippet into
      `.rust-symbol-audit/reviews.toml`, or run `scripts/review.sh`), push → the
      next run shows "reviewed ✅" and drops the tier. *(v3, ledger)*
- [ ] **Network lanes** *(v3, live-only — mocked in the local suite)*: on a real
      crates.io bump the comment includes any OSV/RustSec **advisory** and, if the
      publisher/repo/yank changed, a **provenance** finding. Try a crate+version
      with a known RustSec advisory to confirm the advisory lane fires.
- [ ] **Evidence artifact**: the run uploads `rust-symbol-audit-report` containing
      `audit-report.json`. *(v3)*

### Gotchas
- **`fetch-depth: 0`** in `actions/checkout` (or at least a fetch of `base.sha`) —
  the action best-effort-fetches the base commit, but full history removes doubt.
- **`permissions: pull-requests: write`** — without it `gh pr comment` gets 403.
- The action installs `rustfilt` via `cargo install` on first run (~30–60 s),
  cached thereafter by the `actions/cache` step.
- **Network lanes**: provenance (crates.io) and advisories (OSV.dev) need outbound
  HTTPS. They degrade gracefully (a "unavailable" note, tier none) if the runner
  is offline; disable with `check-provenance`/`check-advisories: "false"`.
