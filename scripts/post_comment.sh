#!/usr/bin/env bash
# post_comment.sh — Step 5
#
# Assemble the final Markdown report (header + per-crate sections + legend) and
# post it to the PR with `gh pr comment`. In dry-run mode (RSA_DRY_RUN=1, or no
# PR number / no gh) it writes the body to $WORK/comment_body.md and prints it
# instead of posting.
#
# Env:
#   OVERALL_TIER   critical|high|medium|none|skipped
#   CRATE_COUNT    number of crates audited
#   SECTIONS_FILE  file containing the per-crate markdown sections
#   BODY_FILE      (optional) a pre-assembled full body to post verbatim
#   PR_NUMBER      pull-request number
#   GH_TOKEN / GITHUB_TOKEN, GITHUB_REPOSITORY
#   RSA_DRY_RUN=1  do not actually post
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

WORK="${WORK:-/tmp/rsa}"
mkdir -p "$WORK"
BODY="${BODY_FILE:-$WORK/comment_body.md}"

if [ -z "${BODY_FILE:-}" ]; then
  OVERALL_TIER="${OVERALL_TIER:-none}"
  CRATE_COUNT="${CRATE_COUNT:-0}"
  emoji="$(tier_emoji "$OVERALL_TIER")"
  case "$OVERALL_TIER" in
    critical) verdict="🔴 **CRITICAL** — a dependency gained process-exec / raw-socket / syscall capability" ;;
    high)     verdict="🟠 **HIGH** — a dependency gained filesystem / env / secret-handling capability" ;;
    medium)   verdict="🟡 **MEDIUM** — a dependency gained network (http/tls/dns) capability" ;;
    none)     verdict="🟢 no sensitive new capabilities detected" ;;
    *)        verdict="$OVERALL_TIER" ;;
  esac
  {
    printf '## 🛡️ rust-symbol-audit — %s\n\n' "$verdict"
    printf 'Diffed **v0-demangled Rust symbols** between the old and new versions of **%s** dependency crate(s) changed by this PR.\n\n' "$CRATE_COUNT"
    if [ -n "${SECTIONS_FILE:-}" ] && [ -s "${SECTIONS_FILE:-/nonexistent}" ]; then
      cat "$SECTIONS_FILE"
    fi
    printf '\n---\n'
    printf '<sub>Tiers: 🔴 critical (exec/spawn/raw-socket/syscall/FFI) · 🟠 high (fs/env/secrets) · 🟡 medium (http/tls/dns/net). '
    printf 'Symbols shown are those present in the new crate version but not the old, after v0 demangling. '
    printf 'A flag is a prompt to review, not proof of malice.</sub>\n'
  } > "$BODY"
fi

log "post_comment: body assembled at $BODY ($(wc -l < "$BODY" | tr -d ' ') lines)"

PR_NUMBER="${PR_NUMBER:-}"
have_gh=0
command -v gh >/dev/null 2>&1 && have_gh=1

if [ "${RSA_DRY_RUN:-0}" = "1" ] || [ -z "$PR_NUMBER" ] || [ "$have_gh" -eq 0 ]; then
  log "post_comment: DRY RUN (RSA_DRY_RUN=${RSA_DRY_RUN:-0}, pr='${PR_NUMBER}', gh=$have_gh) — not posting."
  log "----- comment body -----"
  cat "$BODY"
  log "------------------------"
  exit 0
fi

REPO_ARG=()
[ -n "${GITHUB_REPOSITORY:-}" ] && REPO_ARG=(--repo "$GITHUB_REPOSITORY")
gh pr comment "$PR_NUMBER" "${REPO_ARG[@]}" --body-file "$BODY"
log "post_comment: posted to PR #$PR_NUMBER"
