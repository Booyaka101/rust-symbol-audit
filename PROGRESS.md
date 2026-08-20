# PROGRESS — rust-symbol-audit

Status: **v3.3.0 — SHIPPED 2026-08-20.** PR #19 squash-merged to main as
`2223e09`, CI green on that exact commit, tagged `v3.3.0` and released;
`major-tag.yml` moved `v3` to the same commit, so consumers pinned at
`@v3` are on 3.3.0. Local suite: 95 passed, 0 failed (baseline was 71).

Not done, and owner-only: the **Marketplace listing** still advertises the
previous release. Updating it means ticking "Publish this Action to the GitHub
Marketplace" on the release edit page, which triggers GitHub's sudo-mode TOTP
prompt. No CLI or REST path exists for it.

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
  object and no longer lists arrayref 0.3.10; RFC 3923 is nightly-only
  (`-Zmin-publish-age`) and skips versions already in Cargo.lock.
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

## Next steps (owner)

1. **Marketplace**: republish the listing from the v3.3.0 release page (TOTP
   step, see above).
2. Re-run the live demo PR (`rust-symbol-audit-demo#1`) against `@v3` so the
   README's demo link shows the new inline publish ages. This is also the only
   remaining end-to-end proof of the published tag running as a consumed
   action rather than from a local checkout.
3. Expect questions from anyone on `fail-on: high` whose next bump is under 24 h
   old. The answer is `min-publish-age-hours: "0"`, or a smaller window.
