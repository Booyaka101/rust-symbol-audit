# rust-symbol-audit

A GitHub Action that, on dependency-change PRs, **diffs the v0-demangled Rust
symbols** between the old and new versions of every crate whose version changed
in `Cargo.lock`, and flags newly-gained sensitive capabilities (process exec,
raw sockets, filesystem, env/secrets, networking) as a PR comment.

It answers the question a version-number diff can't: *"this patch bump — did the
crate quietly start opening sockets or spawning processes?"*

## Why this works now

Since **Rust 1.97 (2026-07-09)** the `v0` symbol mangling scheme is the stable
default. v0 symbols demangle back to real, stable, human-readable paths like
`<std::net::tcp::TcpStream as std::io::Write>::write` — so a plain `nm | rustfilt`
over a compiled `.rlib` reveals which std/library capabilities a crate's code
actually reaches for, with no debug info required. This action forces
`-C symbol-mangling-version=v0` explicitly, so it also works on older toolchains.

> A flag is a *prompt to review*, not proof of malice. New symbols can appear for
> perfectly benign reasons. The point is to surface capability creep for a human.

## What it does (pipeline)

1. **`parse_lockdiff.sh`** — `git diff base..HEAD -- Cargo.lock`, emit a TSV of
   `crate  old_version  new_version` for every changed/added package. No change →
   exit 0, `changed=false`.
2. **`build_crate.sh`** — build each version in isolation as a dependency of a
   throwaway probe lib; print the dependency's `.rlib`.
3. **`diff_symbols.sh`** — `nm` → keep `_R…` (v0) symbols → `rustfilt` → `sort -u`
   for old and new; `comm -13` yields symbols present only in the new version.
4. **`risk_check.sh`** — pattern-match added symbols into risk tiers, emit JSON.
5. **`post_comment.sh`** — assemble Markdown and post with `gh pr comment`.

### Risk tiers

| Tier | 🔴 critical | 🟠 high | 🟡 medium |
|---|---|---|---|
| Signals | process exec / spawn, raw sockets (`TcpStream`/`UdpSocket`), syscalls / FFI, mem-injection | filesystem, env access, secret-ish identifiers (`token`/`password`/`api_key`) | higher-level networking (`http`/`tls`/`dns`, `reqwest`/`hyper`/`rustls`) |

The comment's overall tier is the highest tier seen across all changed crates.

## Usage

Copy [`examples/pr-audit.yml`](examples/pr-audit.yml) into your repo at
`.github/workflows/pr-audit.yml`:

```yaml
on:
  pull_request:
    paths: ["Cargo.lock"]
permissions:
  contents: read
  pull-requests: write        # needed to post the comment
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }   # so base.sha is reachable
      - uses: booyaka101/rust-symbol-audit@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          max-crates: "5"          # skip if more crates changed (too slow)
```

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `github-token` | yes | — | Usually `secrets.GITHUB_TOKEN`. Used to post the comment. |
| `max-crates` | no | `5` | Skip the audit (and post a "skipped" note) if more than this many crates changed — symbol-diffing every crate is slow. |

### Outputs

| Output | Description |
|---|---|
| `changed` | `true`/`false` — did any crate version change in `Cargo.lock`. |
| `tier` | Highest risk tier detected: `critical` / `high` / `medium` / `none`. |

## Run it locally

No GitHub needed. Requires `rustup`/`cargo`, `rustfilt` (`cargo install rustfilt`),
and a symbol lister (GNU `nm`, or `rustup component add llvm-tools` which provides
`llvm-nm` — auto-detected on Windows). Then, in **Git Bash**:

```bash
bash test/run_local.sh
```

This exercises the whole pipeline offline against real fixtures plus one real
crates.io bump, and asserts every acceptance check. Expected tail:

```
RESULT: 17 passed, 0 failed
ALL GREEN
```

See [`TESTING.md`](TESTING.md) for how to try it against a real repo/PR.

## Sample output

For a bump where a crate gains `TcpStream` + `Command`:

> ## 🛡️ rust-symbol-audit — 🔴 **CRITICAL** — a dependency gained process-exec / raw-socket / syscall capability
>
> ### 🔴 `netcap` 0.1.0 → 0.2.0 — **CRITICAL**
>
> | risk | added symbol |
> |:--|:--|
> | 🔴 critical | `<std::process::Command>::spawn` |
> | 🔴 critical | `<std::sys::net::connection::socket::TcpStream>::connect::inner` |
> | 🟡 medium | `<str as std::net::socket_addr::ToSocketAddrs>::to_socket_addrs` |

## Limitations

- Only crates that build **standalone as a library** are diffed. Proc-macro-only,
  bin-only, or feature/system-lib-gated crates that fail to build are reported as
  `build failed` (nothing to diff), not silently skipped.
- Capability detection is by symbol pattern, so it can miss capabilities reached
  purely through generics never instantiated in the crate's own rlib, and it will
  flag benign uses. It is a triage signal, not a sandbox.
- `added=0` is common and correct for internal-only patch releases (the compiled
  symbol surface didn't change).

## Best first distribution step

Publish the repo and submit it to the **GitHub Marketplace** under the *Security*
category with the tagline *"Catch dependency capability-creep on Rust PRs."* The
built-in audience is maintainers already nervous about supply-chain risk, and the
v0-default-in-1.97 angle is a timely, concrete hook.
