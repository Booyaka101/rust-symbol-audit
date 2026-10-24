# Security Policy

## Supported versions

The latest major tag (`@v3`) is the only one that gets fixes. Pinning to a commit SHA is fine, but you will not receive them.

## Reporting a vulnerability

Please **don't** open a public issue for a security problem.

Use GitHub's [private vulnerability reporting](https://github.com/Booyaka101/rust-symbol-audit/security/advisories/new) instead. Expect a first response within a week.

Please include what you found, how to reproduce it, and what an attacker gets out of it.

## What this touches

Runs inside your workflow against your dependency tree and writes a sticky pull-request comment. It publishes nothing.

- **It runs inside your workflow** against your dependency tree and writes a pull-request comment. It publishes nothing and needs no secrets beyond the built-in `GITHUB_TOKEN`.
- **Advisory data comes from upstream sources.** A wrong or missing advisory is upstream data rather than a flaw here, though it is still worth telling us.
- **Dependency builds execute code.** Build scripts and proc-macros run during
  symbol analysis, before findings can block a merge. Use disposable,
  unprivileged runners without secrets. Never use `pull_request_target` to build
  untrusted dependency changes. Removing the two GitHub token environment
  variables from build subprocesses is defense in depth, not a sandbox.

## Scope

In scope: anything that leaks a credential, reads data belonging to someone else, or lets untrusted input reach code execution.

Out of scope: findings that require an attacker to already control the machine it runs on.
