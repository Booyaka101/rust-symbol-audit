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

![The PR comment for a bump that pulls in a new dependency. Headline verdict CRITICAL, recommendation review. The finding reads: new dependency dlmacro 1.0.0, crate first published 54 minutes ago, 0 total downloads, ships a build script that downloads and executes a remote payload. The build script is shown inline, decoding a base64 host, curling a payload and executing it. Below it is a copy-paste sign-off snippet for the dependency itself.](images/new-dependency-finding.png)

<sub>The lane added in 3.4.0, on the shape of the 2026-08-20 attack: the audited
crate's own source is byte-identical across the bump and it adds one dependency
whose build script downloads and runs a payload. This is a **reconstruction**
run through the real pipeline, not a live fetch: `arrayref 0.3.10` and
`proc-macro1 1.0.107` were deleted from crates.io within 107 minutes, so nobody
can resolve them any more. The tiering is what the tool actually computes from
the crate's age, its download count, and its build script.</sub>

![The PR comment for a typosquatted dependency. Headline verdict HIGH, recommendation review. The finding reads: new dependency pm2lke 1.0.0, crate first published 6 hours ago, 3 total downloads, is 1 character from pm2like, which your tree already depends on.](images/typosquat-finding.png)

<sub>The typosquat check, on a dependency that ships **no build script at all**.
The name is one character from a crate the tree already depended on and the
newcomer is hours old with three downloads, which is the asymmetry
`proc-macro1` had beside `proc-macro2`. Measured over 1155 real crate names,
every one of the 21 distance-1 pairs was a legitimate pair like `sha1`/`sha2`,
so the age and adoption gate is what makes this rule usable rather than the
name distance.</sub>

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
   Whether that build script is `high` or `critical` is decided by reading its
   **code**, with comments stripped: 23 of 224 real build scripts were being
   escalated purely for linking to a rust-lang issue in a comment.
3. **Dependency tree** — crates the bump **newly pulls into your build**, and for
   each one it reads the crate's **actual source**: a **`build.rs`** that both
   fetches something remote *and* executes it, a switch to **`proc-macro = true`**,
   a **`links =`** native lib, plus the crate's **age and download count** from
   crates.io. A downloader build script in a **young or barely-downloaded** crate
   is `critical` with the excerpt shown inline; the same script in an
   established, widely-used crate is `medium`; a build script with neither tell
   (the shape `proc-macro2`, `libc` and `serde` all have) is a plain note. This
   is the lane that catches the **2026-08-20 arrayref attack**, where the bumped
   crate was byte-identical and the payload lived entirely in a newly-added
   dependency's build script. It also flags a **typosquat**: a brand-new,
   barely-downloaded crate whose name is one character from one your tree
   *already* depends on, which is how `proc-macro1` rode in beside
   `proc-macro2`. That fires on the name alone, so it still catches a squat
   whose payload is hidden too well for the build-script check. A new dependency
   that declares **no source repository** on crates.io, and is itself young or
   barely downloaded, is flagged too. This lane runs for a **newly-added** crate
   as well, using the lockfile from before the PR to decide what is genuinely
   new.
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
| `max-new-deps` | `10` | Source-inspect at most this many crates newly pulled into the tree per audited crate (build.rs / proc-macro / links + crates.io age and downloads). Any beyond the cap are listed as not inspected, never silently skipped. |
| `typosquat-distance` | `1` | Flag a newly-pulled crate whose name is within this many edits of one already in your tree, *and* which is itself young or barely downloaded. `0` disables it. Raising it above `1` is not recommended: distance-2 covers many legitimate pairs. |
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
bash test/run_local.sh      # -> RESULT: 136 passed, 0 failed / ALL GREEN
```

Exercises all five lanes, the ledger ratchet, config suppression, gating, the
Dependabot recommendation, and the evidence report — offline, using fixtures and
mock crates.io / OSV responses (plus one real crates.io bump). See
[`TESTING.md`](TESTING.md) for the live-PR checklist.

## What it can and can't catch

**Catches well:** a crate that starts directly calling `std::net`/`process`/`fs`;
a new or changed **build script** / **proc-macro** (even when the crate won't
build as a lib); a **native lib** newly linked; **new crates** in the tree, each
with its **build script read** (a download-and-execute `build.rs` in a young or
barely-downloaded crate is the arrayref/proc-macro1 shape); a
**publisher/repo/yank** change; a version **younger than the review window** or
**deleted from crates.io** (the arrayref-incident shapes); a **known advisory**
on the new version.

**Measured false-positive rate (typosquat).** Across the same corpus, **1155
crate names produced 21 distance-1 pairs, and every one is a pair of legitimate
crates** (`sha1`/`sha2`, `libc`/`libm`, `mime`/`time`, `hyper`/`hypher`…). Name
proximity alone would therefore fire in nearly every Rust project, so it is not
the signal. The rule additionally requires the newcomer to be young or barely
downloaded, which is the asymmetry the real attack had: checked against
crates.io, the youngest of those 39 crates is 509 days old and the least
downloaded has 369,664 downloads, so **none of them trips the gate**. An
established near-miss still renders as a note naming what it resembles.

**Measured false-positive rate.** The new-dependency build-script rule was run
over the resolved trees of 19 popular crates — **1810 unique crate versions, 224
with a build script** — and fired on **0** of them, while catching the
curl-based payload fixture. The gate requires a build script to *both* invoke a
network client (reqwest/ureq/curl/wget/raw sockets) *and* execute something, with
comments stripped first; a naive "any `http(s)://`" rule fired on 61 of those
crates (serde, proc-macro2, quote, thiserror, libc, anyhow…), every one a URL in
a comment or error string, which is why it was re-gated. `proc-macro2`, `libc`
and `serde` all shell out to rustc from `build.rs`; that is execution without a
fetch, and it is correctly a note, not an alarm.

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
