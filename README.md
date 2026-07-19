# rust-symbol-audit

A GitHub Action that turns a Rust dependency bump into a **capability-creep
review**. On PRs that change `Cargo.lock`, for every crate whose version changed
it answers the question a version number can't:

> *This patch bump — did the crate quietly start opening sockets, spawning
> processes, or running code on my build machine?*

It looks three ways, because no single view is enough:

1. **Symbols** — builds the old and new version, diffs the **v0-demangled**
   symbols in each compiled `.rlib`, and flags newly-referenced sensitive APIs
   (`std::process::Command`, `TcpStream`, `std::fs`, `env::var`, secret-ish
   names, `reqwest`/`rustls`…).
2. **Compile-time surface** — inspects each version's source for a newly-added or
   changed **`build.rs`**, a switch to **`proc-macro = true`**, or a new
   **`links =`** native library. This is code that runs *on your build machine at
   compile time* — the higher-value supply-chain vector that symbol-diffing is
   structurally blind to.
3. **Dependency tree** — diffs the resolved dependency set old-vs-new and lists
   crates the bump **newly pulls into your build**, highlighting ones with known
   network / process / crypto / FFI capability.

The highest surviving signal across all three lanes becomes a single **sticky PR
comment** (updated in place on each push), and can optionally **fail the check**
to block a merge.

> **What this is — and isn't.** It's a *triage gate*, not a sandbox or a proof.
> It reliably surfaces the realistic "a dependency's capability surface changed —
> go look" case and is quiet enough to leave on. It does **not** catch capability
> reached purely through generics never instantiated in the crate's own rlib, or
> through a dependency that didn't itself change, and a determined attacker can
> evade static symbol tells. A flag is a prompt to review, not proof of malice.

## Why the symbol trick works

Since **Rust 1.97 (2026-07-09)** the `v0` symbol mangling scheme is the stable
default. v0 symbols demangle back to real, stable, human-readable paths like
`<std::net::tcp::TcpStream as std::io::Write>::write`, so a plain `nm | rustfilt`
over a compiled `.rlib` reveals which library capabilities a crate's code reaches
for — no debug info needed. This action forces `-C symbol-mangling-version=v0`
explicitly, so it also works on toolchains older than 1.97.

## What it does (pipeline)

| Step | Script | Role |
|---|---|---|
| 1 | `parse_lockdiff.sh` | `git diff` `Cargo.lock` base→HEAD → TSV of `crate old new`. No change → `changed=false`, exit 0. |
| 2 | `build_crate.sh` | Build each version in isolation as a dependency of a throwaway probe lib; print its `.rlib`. |
| 3 | `diff_symbols.sh` | `nm` → keep `_R…` (v0) → `rustfilt` → `comm` → symbols only in the new version. |
| 3b | `inspect_source.sh` | Flag newly-added/changed `build.rs`, proc-macro transition, new `links =`. |
| 4 | `risk_check.sh` | Pattern-match added symbols into risk tiers. |
| 5 | `run_audit.sh` → `post_comment.sh` | Merge the three lanes, apply config allow/ignore, render + post the sticky comment, optionally fail the check. |

### Risk tiers

| Tier | 🔴 critical | 🟠 high | 🟡 medium |
|---|---|---|---|
| Symbols | process exec/spawn, raw sockets (`TcpStream`/`UdpSocket`), syscalls/FFI, mem-injection | filesystem, env access, secret-ish identifiers (`token`/`password`/`api_key`) | higher-level networking (`http`/`tls`/`dns`, `reqwest`/`hyper`/`rustls`) |
| Compile-time | build script (added/changed) that references process/net/fs APIs | new build script, or crate became a proc-macro | new `links =` native library |
| Dependencies | — | — | newly-pulled crate with known capability |

The comment's overall tier is the highest seen across all changed crates and all
three lanes.

## Usage

Copy [`examples/pr-audit.yml`](examples/pr-audit.yml) into your repo at
`.github/workflows/pr-audit.yml`:

```yaml
on:
  pull_request:
    paths: ["Cargo.lock"]
permissions:
  contents: read
  pull-requests: write        # needed to post/update the comment
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }   # so base.sha is reachable
      - uses: booyaka101/rust-symbol-audit@v2
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          max-crates: "10"         # audit up to N crates; list the rest
          fail-on: "none"          # or critical/high/medium to block merges
```

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `github-token` | yes | — | Usually `secrets.GITHUB_TOKEN`. Used to post/update the comment. |
| `max-crates` | no | `10` | Audit at most this many changed crates; the remainder are listed as "not audited" (symbol-diffing every crate is slow). |
| `fail-on` | no | `none` | Fail the check when the overall tier reaches this level: `none`\|`medium`\|`high`\|`critical`. `none` = advisory comment only. Combine with branch protection to block merges. |
| `config` | no | `.rust-symbol-audit.toml` | Path to the repo's config file for allow/ignore rules. |

### Outputs

| Output | Description |
|---|---|
| `changed` | `true`/`false` — did any crate version change in `Cargo.lock`. |
| `tier` | Highest risk tier: `critical`/`high`/`medium`/`none`. |
| `flagged` | Comma-separated crates that had at least one flagged capability. |
| `build-script-changes` | Count of audited crates whose build script was newly added or changed. |

### Tuning out false positives — `.rust-symbol-audit.toml`

A capability flag on a crate you trust is noise. Silence it per-crate instead of
muting the whole bot. Drop a config file at your repo root (see
[`examples/rust-symbol-audit.toml`](examples/rust-symbol-audit.toml)):

```toml
# Never flag these crates at all (e.g. ones whose whole job is I/O).
ignore_crates = ["libc", "windows-sys"]

[allow]
# Per crate: suppress any finding whose text matches one of these regexes.
reqwest = ["TcpStream", "hyper", "rustls", "http"]
ring    = ["mmap", "libc::"]
```

Action inputs (`fail-on`, `max-crates`) take precedence; the config file governs
allow/ignore suppression.

## Run it locally

No GitHub needed. Requires `rustup`/`cargo`, `rustfilt` (`cargo install
rustfilt`), and a symbol lister (GNU `nm`, or `rustup component add llvm-tools`
which provides `llvm-nm` — auto-detected on Windows). Then, in **Git Bash**:

```bash
bash test/run_local.sh
```

This exercises all three lanes offline against real fixtures plus one real
crates.io bump, and asserts every acceptance check. Expected tail:

```
RESULT: 31 passed, 0 failed
ALL GREEN
```

See [`TESTING.md`](TESTING.md) for how to try it against a real repo/PR.

## Sample output

A bump that gains `TcpStream` + `Command` at runtime:

> ## 🛡️ rust-symbol-audit — 🔴 **CRITICAL** — a dependency gained process-exec / raw-socket / syscall / build-time-code capability
>
> ### 🔴 `netcap` 0.1.0 → 0.2.0 — **CRITICAL**
>
> **Added symbols (capability):**
>
> | risk | added symbol |
> |:--|:--|
> | 🔴 critical | `<std::process::Command>::spawn` |
> | 🔴 critical | `<std::sys::net::connection::socket::TcpStream>::connect::inner` |

A bump that adds **zero new symbols** but ships a malicious build script — caught
only by the compile-time lane:

> ### 🔴 `netcap` 0.2.0 → 0.3.0 — **CRITICAL**
>
> **Compile-time surface:**
>
> - 🔴 **build-script** — new version ADDED a build script that references process / network / fs APIs — this runs on your build machine at compile time
>
> _No newly-added symbols in the compiled rlib._

## What it can and can't catch

**Catches well**
- A crate that starts *directly* calling `std::net` / `std::process` / `std::fs`.
- A newly-added or changed **build script**, or a switch to **proc-macro** — code
  that runs at compile time (works even when the crate fails to build as a lib).
- A **native library** newly linked in, and **new crates** pulled into the tree.

**Misses / limits (inherent to static analysis)**
- Capability reached only through generics never instantiated in the crate's own
  rlib, or through a dependency whose own version didn't change.
- Runtime behavior — it reads the *capability surface*, it does not sandbox.
- Many crates don't build **standalone as a library** (feature/system-lib-gated,
  proc-macro-only, bin-only). Those are reported as `build failed` for the symbol
  lane, but the compile-time and dependency lanes still apply.
- Pattern-based tiering can miss and can over-flag; use `.rust-symbol-audit.toml`
  to quiet known-benign signals.
- `added=0` is common and correct for internal-only patch releases.

## Best first distribution step

Publish the repo and submit it to the **GitHub Marketplace** under the *Security*
category with the tagline *"A capability-creep triage gate for Rust dependency
PRs."* The built-in audience is maintainers already nervous about supply-chain
risk, and the build-time-code lane is the concrete hook symbol-only tools lack.
