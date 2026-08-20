# rust-symbol-audit

[![tests](https://github.com/Booyaka101/rust-symbol-audit/actions/workflows/tests.yml/badge.svg)](https://github.com/Booyaka101/rust-symbol-audit/actions/workflows/tests.yml)
[![Release](https://img.shields.io/github/v/release/Booyaka101/rust-symbol-audit?sort=semver&color=orange)](https://github.com/Booyaka101/rust-symbol-audit/releases)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-rust--symbol--audit-2ea44f?logo=github)](https://github.com/marketplace/actions/rust-symbol-audit)
[![License: MIT](https://img.shields.io/github/license/Booyaka101/rust-symbol-audit?color=blue)](LICENSE)

A GitHub Action that turns a Rust dependency bump into a **capability-creep
review you can actually gate on**.

![The sticky PR comment rust-symbol-audit posts on a Cargo.lock bump. Headline verdict HIGH, three crates audited and two flagged, recommendation review. arrayref 0.3.9 to 0.3.10 is flagged because crates.io no longer lists the version; cap-std 3.4.5 to 3.4.6 is flagged because it was published four minutes earlier; once_cell is folded into a collapsed clean list showing its publish age.](images/pr-comment.png)

<sub>A real run against live crates.io, rendered as GitHub shows it.
`arrayref 0.3.10` is the version [deleted in the 2026-08-20 supply-chain
attack](https://blog.rust-lang.org/2026/08/20/supply-chain-attack-on-arrayref/).
`cap-std 3.4.6` was a perfectly legitimate release that happened to be four
minutes old when this ran, so the finding says *young*, not *malicious*. That
distinction is the point: it tells you what it actually knows.</sub>

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
   different account** than before, a crate with **no source repository**, a
   **yanked** version, a version **crates.io no longer lists** (deleted from the
   registry — how crates.io responds to a malicious publish), or a version
   **published within the last 24 hours** (`min-publish-age-hours`) — the
   arrayref/internment/append-only-vec malicious versions of 2026-08-20 were
   caught and removed within 86–107 minutes, so a version that young hasn't
   been through that window yet. This is what real supply-chain attacks look
   like first. The comment also shows each bump's publish age inline.
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

Already using [**cargo-vet**](https://mozilla.github.io/cargo-vet/)? Its
`supply-chain/audits.toml` certifications are imported automatically as sign-offs
(configurable via the `vet` input), so versions your team already vetted stay
green with no extra work.

> **What this is — and isn't.** A *triage gate*, not a sandbox or a proof. It
> reliably surfaces the realistic "this dependency's surface changed — look" case
> and is quiet enough to keep on. It does **not** catch capability reached only
> through generics never instantiated in the crate's own rlib, and a determined
> attacker can evade static symbol tells. A flag is a prompt to review.

### Publish age: prior art, and what this adds

Cooldown is not a new idea and this tool didn't invent it. Dependabot ships a
default 3-day cooldown (July 2026), Renovate has `minimumReleaseAge`,
[cargo-cooldown](https://crates.io/crates/cargo-cooldown) exists, and Cargo's own
[RFC 3923 min-publish-age](https://rust-lang.github.io/rfcs/3923-cargo-min-publish-age.html)
is **stabilizing**: the stabilization PR (rust-lang/cargo#17335, tracking issue
#17009) is in final comment period with disposition-merge, so it lands in a
coming release, and the Cargo team has said they're considering enabling it by
default. Treat that as the real fix for the resolution side.

What none of them cover is the same carve-out. They all act at *resolution*
time, and the RFC is explicit that the resolver ignores too-young versions
"unless they already exist in the `Cargo.lock` file". A version already pinned
in the diff you're reviewing is exactly that case: it arrived in a bot's PR or
a teammate's branch, and resolution is over by the time you're looking at it.

What this adds: rust-symbol-audit is a review gate that reads the lockfile diff
*after* resolution and emits a merge recommendation, and until 3.3.0 it did so
with no idea how old the version was. Now every audited bump carries its publish
age, a version inside the `min-publish-age-hours` window is a `high`-tier
`fresh-version` finding, and a version crates.io no longer lists at all (the
registry's response to a malicious publish, as with arrayref 0.3.10) is a
`high`-tier `version-not-on-registry` finding. Like advisories and the other
provenance findings, **neither can be suppressed by a review-ledger sign-off**;
the local suite asserts that property for both.

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
      - uses: actions/checkout@v7
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
| `vet` | `supply-chain/audits.toml` | A [cargo-vet](https://mozilla.github.io/cargo-vet/) audits file, if present — its certified versions are imported as sign-offs. |
| `check-provenance` | `true` | Query crates.io for publisher/repo/yank changes (needs network). |
| `check-advisories` | `true` | Query OSV.dev for RustSec advisories (needs network). |
| `min-publish-age-hours` | `24` | Tier a bumped version published less than this many hours ago as `high` (`fresh-version`). `0` keeps the publish-age note in the comment but never tiers it. |
| `comment` | `true` | Post the report as a PR comment. `false` = summary-only mode (still writes the job summary, sets outputs, and can `fail-on`). |
| `manifest-dir` | `.` | Directory holding the `Cargo.lock` to watch, for monorepos / non-root workspaces (e.g. `backend`). Also point the workflow's `paths:` filter at `<dir>/Cargo.lock`. |

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
bash test/run_local.sh      # -> RESULT: 95 passed, 0 failed / ALL GREEN
```

Exercises all five lanes, the ledger ratchet, config suppression, gating, the
Dependabot recommendation, and the evidence report — offline, using fixtures and
mock crates.io / OSV responses (plus one real crates.io bump). See
[`TESTING.md`](TESTING.md) for the live-PR checklist.

## What it can and can't catch

**Catches well:** a crate that starts directly calling `std::net`/`process`/`fs`;
a new or changed **build script** / **proc-macro** (even when the crate won't
build as a lib); a **native lib** newly linked; **new crates** in the tree; a
**publisher/repo/yank** change; a version **younger than the review window** or
**deleted from crates.io** (the arrayref-incident shapes); a **known advisory**
on the new version.

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
