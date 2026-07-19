#!/usr/bin/env bash
# post_comment.sh — Step 5
#
# Assemble the final Markdown report (header + per-crate sections + legend) and
# post it to the PR as a STICKY comment: on the first run it creates a comment,
# on later pushes it edits that same comment (found via a hidden marker) instead
# of spamming a new one each time. Also mirrors the report to the Actions job
# summary. In dry-run mode (RSA_DRY_RUN=1, or no PR number / no gh) it writes the
# body to $WORK/comment_body.md and prints it instead of posting.
#
# Env:
#   OVERALL_TIER   critical|high|medium|none|skipped
#   CRATE_COUNT    number of crates audited
#   SECTIONS_FILE  file containing the per-crate markdown sections
#   BODY_FILE      (optional) a pre-assembled full body to post verbatim
#   PR_NUMBER      pull-request number
#   GH_TOKEN / GITHUB_TOKEN, GITHUB_REPOSITORY
#   GITHUB_STEP_SUMMARY  (optional) file to also receive the report
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
  FLAGGED_COUNT="${FLAGGED_COUNT:-0}"
  ADVISORY_COUNT="${ADVISORY_COUNT:-0}"
  RECOMMENDATION="${RECOMMENDATION:-review}"
  crate="${OVERALL_CRATE:-a dependency}"
  reason="${OVERALL_REASON:-changed its capability surface}"
  case "$OVERALL_TIER" in
    critical) verdict="🔴 **CRITICAL** — \`$crate\` $reason" ;;
    high)     verdict="🟠 **HIGH** — \`$crate\` $reason" ;;
    medium)   verdict="🟡 **MEDIUM** — \`$crate\` $reason" ;;
    none)     verdict="🟢 **CLEAR** — no sensitive dependency changes detected" ;;
    *)        verdict="$OVERALL_TIER" ;;
  esac
  # pluralize the advisory count
  if [ "$ADVISORY_COUNT" = "1" ]; then adv_word="advisory"; else adv_word="advisories"; fi
  {
    printf '%s\n' "$RSA_MARKER"
    printf '## 🛡️ rust-symbol-audit\n\n'
    printf '%s\n\n' "$verdict"
    printf '`%s` audited · `%s` flagged · `%s` %s · recommendation **%s**\n\n' \
      "$CRATE_COUNT" "$FLAGGED_COUNT" "$ADVISORY_COUNT" "$adv_word" "$RECOMMENDATION"
    if [ -n "${SECTIONS_FILE:-}" ] && [ -s "${SECTIONS_FILE:-/nonexistent}" ]; then
      printf -- '---\n\n'
      cat "$SECTIONS_FILE"
    fi
    printf -- '---\n'
    printf '<sub>Five lanes: symbols (v0-demangled rlib diff) · compile-time (build.rs/proc-macro) · dependencies · provenance (crates.io) · advisories (RustSec/OSV). '
    printf 'Tiers: 🔴 critical · 🟠 high · 🟡 medium. A flag is a prompt to review, not proof of malice. '
    printf 'Suppress known-benign signals via `.rust-symbol-audit.toml`; sign off a reviewed version in `.rust-symbol-audit/reviews.toml`.</sub>\n'
  } > "$BODY"
else
  # Ensure a pre-assembled body still carries the marker so it stays sticky.
  if ! head -1 "$BODY" | grep -qF "$RSA_MARKER"; then
    printf '%s\n%s' "$RSA_MARKER" "$(cat "$BODY")" > "$BODY.tmp" && mv "$BODY.tmp" "$BODY"
  fi
fi

log "post_comment: body assembled at $BODY ($(count_lines "$BODY") lines)"

# Mirror to the Actions job summary (visible even when there is no PR / comment
# permission). Strip the invisible marker line from the summary.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  grep -vF "$RSA_MARKER" "$BODY" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

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

# --- sticky post: update our previous comment if present, else create --------
REPO="${GITHUB_REPOSITORY:-}"
existing_id=""
if [ -n "$REPO" ]; then
  # Find the newest comment authored earlier by this action (carries the marker).
  existing_id="$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
      --jq "map(select(.body | contains(\"$RSA_MARKER\"))) | last | .id" 2>/dev/null || true)"
  [ "$existing_id" = "null" ] && existing_id=""
fi

if [ -n "$existing_id" ] && [ -n "$REPO" ]; then
  if gh api --method PATCH "repos/$REPO/issues/comments/$existing_id" \
        -F body=@"$BODY" >/dev/null 2>&1; then
    log "post_comment: updated existing sticky comment #$existing_id on PR #$PR_NUMBER"
    exit 0
  fi
  log "post_comment: could not update comment #$existing_id — creating a new one"
fi

REPO_ARG=()
[ -n "$REPO" ] && REPO_ARG=(--repo "$REPO")
gh pr comment "$PR_NUMBER" "${REPO_ARG[@]}" --body-file "$BODY"
log "post_comment: posted new comment to PR #$PR_NUMBER"
