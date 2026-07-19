# rust-symbol-audit

[![Release](https://img.shields.io/github/v/release/Booyaka101/rust-symbol-audit?sort=semver&color=orange)](https://github.com/Booyaka101/rust-symbol-audit/releases)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-rust--symbol--audit-2ea44f?logo=github)](https://github.com/marketplace/actions/rust-symbol-audit)
[![License: MIT](https://img.shields.io/github/license/Booyaka101/rust-symbol-audit?color=blue)](LICENSE)

A GitHub Action that turns a Rust dependency bump into a **capability-creep
review you can actually gate on**.

> **See it in action →** a live demo PR where it catches a real advisory and folds
> away the clean bump: **[rust-symbol-audit-demo #1](https://github.com/Booyaka101/rust-symbol-audit-demo/pull/1)**. On PRs that change `Cargo.lock`, for every
crate whose version changed it runs five checks, merges them into one **sticky PR
comment**, and — once you've signed a version off — only ever alarms again on the
**unreviewed delta**.

It answers what a version number can't: *this bump — did the crate start opening
sockets, spawning processes, running code on my build machine, change who
publishes it, or ship a known vuln?*

## The five lanes

1. **Symbols** — builds old + new, diffs the **v0-demangled** `.rlib` symbols, and
   flags newly-referenced sensitive APIs (`std::process::Command`, `TcpStream`,
   `std::fs`, `env::var`, secret-ish names, `reqwest`/`rustls`…).
2. **Compile-time surface** — a newly-added or changed **`build.rs`**, a switch to
   **`proc-macro = true`**, or a new **`links =`** native lib. Code that runs *on
   your build machine at compile time* — and the comment shows the **actual
   build-script diff**, not just "it changed". Symbol-diffing is blind to this.
3. **Dependency tree** — crates the bump **newly pulls into your build**,
   highlighting ones with known network / process / crypto / FFI capability.
4. **Provenance** *(network)* — via the crates.io API: a version **published by a
   different account** than before, a crate with **no source repository**, or a
   **yanked** version. This is what real supply-chain attacks look like first.
5. **Advisories** *(network)* — via OSV.dev (RustSec): known vulnerabilities
   against the exact new version.

## The ratchet — why you can leave it on

A per-PR heuristic that re-alarms on every bump gets muted. rust-symbol-audit is
**stateful**: sign a version off once in `.rust-symbol-audit/reviews.toml` and
future audits stay green for it — so every red is genuinely **new and
unreviewed**. That's what makes `fail-on` trustworthy enough to block merges.

```toml
# .rust-symbol-audit/reviews.toml — capability sign-offs
[[review]]
crate = "reqwest"
version = "0.12.0"
reviewed_by = "alice"
notes = "http client; network capability expected"
```

The PR comment includes a copy-paste **sign-off snippet** for each unreviewed
crate (or run `scripts/review.sh <crate> <version>`), so approving a bump is one
paste. Crucially, a sign-off suppresses **only** the capability lanes — a later
**advisory or provenance change is never hidden by an old review**.

> **What this is — and isn't.** A *triage gate*, not a sandbox or a proof. It
> reliably surfaces the realistic "this dependency's surface changed — look" case
> and is quiet enough to keep on. It does **not** catch capability reached only
> through generics never instantiated in the crate's own rlib, and a determined
> attacker can evade static symbol tells. A flag is a prompt to review.

## Usage

Copy [`examples/pr-audit.yml`](examples/pr-audit.yml) to
`.github/workflows/pr-audit.yml`:

```yaml
on:
  pull_request:
    paths: ["Cargo.lock"]
permissions:
  contents: read
  pull-requests: write        # post/update the comment
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: booyaka101/rust-symbol-audit@v3
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          fail-on: "none"          # or critical/high/medium to block merges
```

To auto-merge boring Dependabot bumps and hold risky ones, see
[`examples/auto-merge.yml`](examples/auto-merge.yml) (gates GitHub auto-merge on
the `recommendation` output).

### Inputs

| Input | Default | Description |
|---|---|---|
| `github-token` | — | Usually `secrets.GITHUB_TOKEN`. Posts/updates the comment. |
| `max-crates` | `10` | Audit at most this many changed crates; the rest are listed as "not audited". |
| `fail-on` | `none` | Fail the check at `medium`/`high`/`critical`. `none` = advisory only. |
| `config` | `.rust-symbol-audit.toml` | Allow/ignore rules to suppress known-benign signals. |
| `reviews` | `.rust-symbol-audit/reviews.toml` | The review ledger (the ratchet). |
| `check-provenance` | `true` | Query crates.io for publisher/repo/yank changes (needs network). |
| `check-advisories` | `true` | Query OSV.dev for RustSec advisories (needs network). |

### Outputs

| Output | Description |
|---|---|
| `changed` | Did any crate version change in `Cargo.lock`. |
| `tier` | Highest risk tier: `critical`/`high`/`medium`/`none`. |
| `flagged` | Comma-separated crates with a flagged signal. |
| `build-script-changes` | Count of crates whose build script was added/changed. |
| `advisories` | Count of known RustSec/OSV advisories found. |
| `recommendation` | `auto-merge` (tier none) or `review` — gate Dependabot auto-merge on this. |
| `report` | Path to the machine-readable `audit-report.json` evidence file. |

### Suppressing false positives — `.rust-symbol-audit.toml`

See [`examples/rust-symbol-audit.toml`](examples/rust-symbol-audit.toml):

```toml
ignore_crates = ["libc", "windows-sys"]     # never flag these

[allow]
reqwest = ["TcpStream", "hyper", "rustls"]  # suppress these findings for this crate
```

`ignore`/`allow` silence a signal forever; the **ledger** signs off one version
at a time (and still surfaces future advisories). Use `allow` for "this crate is
allowed this capability always", the ledger for "I reviewed exactly this version".

### Compliance / SLSA evidence

Every run writes `audit-report.json` (overall verdict + every finding, per crate
and lane) and uploads it as a workflow artifact — the record that the dependency
change was reviewed.

## Run it locally

Requires `rustup`/`cargo`, `rustfilt` (`cargo install rustfilt`), and a symbol
lister (GNU `nm`, or `rustup component add llvm-tools` → `llvm-nm`, auto-detected
on Windows). In **Git Bash**:

```bash
bash test/run_local.sh      # -> RESULT: 46 passed, 0 failed / ALL GREEN
```

Exercises all five lanes, the ledger ratchet, config suppression, gating, the
Dependabot recommendation, and the evidence report — offline, using fixtures and
mock crates.io / OSV responses (plus one real crates.io bump). See
[`TESTING.md`](TESTING.md) for the live-PR checklist.

## What it can and can't catch

**Catches well:** a crate that starts directly calling `std::net`/`process`/`fs`;
a new or changed **build script** / **proc-macro** (even when the crate won't
build as a lib); a **native lib** newly linked; **new crates** in the tree; a
**publisher/repo/yank** change; a **known advisory** on the new version.

**Misses / limits (inherent to static analysis):** capability via generics never
instantiated in the crate's own rlib, or via an unchanged dependency; runtime
behavior (it reads surface, doesn't sandbox); crates that can't build standalone
(symbol lane only — other lanes still apply); network lanes need connectivity and
degrade gracefully offline. Tune noise with the config + ledger.

## Best first distribution step

Publish to the **GitHub Marketplace** (Security category), tagline *"A
capability-creep triage gate for Rust dependency PRs — with a review ratchet you
can block merges on."* The build-time-code lane and the sign-off ratchet are the
concrete hooks symbol-only and advisory-only tools lack.
