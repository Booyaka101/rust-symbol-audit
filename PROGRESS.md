# PROGRESS — rust-symbol-audit

Status: **v3.3.0 — SHIPPED 2026-08-20.** PR #19 squash-merged to main as
`2223e09`, CI green on that exact commit, tagged `v3.3.0` and released;
`major-tag.yml` moved `v3` to the same commit, so consumers pinned at
`@v3` are on 3.3.0. Local suite: 95 passed, 0 failed (baseline was 71).

Verified after the release: the **Marketplace listing already serves v3.3.0**
(no TOTP step was needed; an action that is already listed picks up new
releases on its own), and the **demo PR was re-run against the published
`@v3`**, so the tag is proven working as a consumed action and not just from a
local checkout.

## What v3.3.0 adds (the arrayref-incident release)

Built against the 2026-08-20 Rust Security Response Team advisory ("Supply
chain attack on arrayref"): malicious versions of arrayref / internment /
append-only-vec were live 86–107 minutes, then **deleted** from crates.io (not
yanked). Two verified blind spots in the provenance lane, both closed using the
crates.io response it already fetches (no new network request):

1. **`fresh-version`** — reads the new version's `created_at` (UTC-only),
   compares against now. Inside `min-publish-age-hours` (new input, default 24,
   `0` = note only) → tier `high` with the real age + incident context.
   Outside → `none`-tier note carrying the age. Missing/malformed date → note,
   never a finding. Age also renders inline next to every audited bump in the
   comment (`` `0.3.9` → `0.3.10` (published 41 minutes ago) ``).
2. **`version-not-on-registry`** — audited version absent from the versions
   array (deleted from the registry) → tier `high`. Fires before/independently
   of the age check; newly-added crates get it too. Offline/disabled path still
   emits `provenance-unknown` byte-identically (asserted).

Both flow through the normal tier/recommendation computation (so
`fail-on: high` fails and auto-merge flips to review) and are **never
suppressed by a ledger sign-off** (tested, same property as advisories).

## Verified this session (2026-08-20)

- Baseline before edits: `bash test/run_local.sh` → **71 passed / ALL GREEN**.
- Live acceptance: `provenance.sh arrayref '' 0.3.10` → high
  `version-not-on-registry`; `provenance.sh arrayref 0.3.8 0.3.9` → none-tier
  age note ("published 705 days ago") and nothing else.
- Phase-0 re-verified live: crates.io API carries `created_at` on every version
  object and no longer lists arrayref 0.3.10; RFC 3923 skips versions already
  in Cargo.lock. **Corrected 2026-08-21:** min-publish-age is not nightly-only
  for much longer. Stabilization PR rust-lang/cargo#17335 is in FCP with
  disposition-merge, confirmed via the GitHub API after a Cargo maintainer said
  so in the r/rust arrayref thread. The lockfile carve-out is the durable part
  of our positioning, not the fact that it was unstable.
- New tests Z (fresh, incl. window 0), AA (years-old), AB (deleted version,
  incl. newly-added crate), AC (offline path byte-identical). Fresh fixture's
  `created_at` is computed at test time (now − 41 min); the old fixture is a
  static 2024 date, so the suite stays deterministic as it ages.

## Files touched in 3.3.0

- `scripts/provenance.sh` — the two findings, age formatting, `publish_age.txt`,
  `PYTHONUTF8=1` (Windows python died on em dashes in details).
- `scripts/run_audit.sh` — `RSA_MIN_PUBLISH_AGE_HOURS` threading, inline age in
  verstr + clean list, two new headline reasons.
- `action.yml` — `min-publish-age-hours` input.
- `test/fixtures/cratesio/` — netcap.json (+`created_at`),
  netcap-fresh.json.template, netcap-old.json, netcap-ghost.json.
- `test/run_local.sh` — tests Z/AA/AB/AC.
- `images/pr-comment.png` + `.gitattributes` (`*.png binary`) — README
  screenshot of a real live-crates.io run, rendered through GitHub's markdown
  API. Verified byte-identical after push and confirmed loading on the GitHub
  README page.
- README (lane #4, inputs table, prior-art section, catches list, screenshot),
  CHANGELOG.

## End-to-end proof of the published tag

`rust-symbol-audit-demo#1` re-run on 2026-08-20 against `@v3` (run
32387725119, success). The sticky comment it posted carries the 3.3.0 feature
in production:

```
### smallvec new -> 1.6.0 (published 5 years ago) - HIGH
- RUSTSEC-2021-0003 - Buffer overflow in SmallVec::insert_many
  once_cell 1.19.0 -> 1.20.2 (published 683 days ago)
```

Both the newly-added-crate path and the clean-list path show the age, and the
advisory lane is unaffected.

## Next steps (owner)

1. Nothing is blocking. Expect questions from anyone on `fail-on: high` whose
   next bump is under 24 h old; the answer is `min-publish-age-hours: "0"` or a
   smaller window.
2. Optional: announce it. The arrayref incident is the hook, and the honest
   framing is the one in the README's prior-art section rather than a claim to
   have invented cooldown.
