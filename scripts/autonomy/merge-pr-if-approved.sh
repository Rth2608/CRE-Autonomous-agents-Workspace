#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 <author_agent> <pr_number> [base_branch]

Example:
  $0 gemini 12 main
USAGE
}

if [[ $# -eq 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -ge 2 ]] || { usage; exit 1; }

require_cmd jq
require_cmd curl
require_cmd git

author="$1"
pr_number="$2"
base_branch="${3:-main}"
repo_dir="$(agent_workdir "$author")"

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped
ensure_no_pending_human_approvals

if [[ "${AUTO_MERGE_PR:-false}" != "true" ]]; then
  die "AUTO_MERGE_PR is false. Refusing to merge automatically."
fi

[[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN is required"
[[ "$pr_number" =~ ^[0-9]+$ ]] || die "Invalid pr_number: $pr_number"

# 3-of-4 merge consensus gate (includes author as one voter).
summary_tmp="$(mktemp)"
merge_min="${MERGE_CONSENSUS_MIN:-3}"
merge_block_on_high="${MERGE_BLOCK_ON_HIGH:-true}"
if ! REVIEW_INCLUDE_AUTHOR=true REVIEW_MIN_APPROVALS="$merge_min" REVIEW_BLOCK_ON_HIGH="$merge_block_on_high" \
  "$SELF_DIR/ai-review-gate.sh" "$author" "$base_branch" >"$summary_tmp"; then
  cat "$summary_tmp" >&2 || true
  rm -f "$summary_tmp"
  die "Merge consensus gate failed (need $merge_min of 4 approvals)"
fi
summary_json="$(cat "$summary_tmp")"
rm -f "$summary_tmp"
consensus_run_id="$(jq -r '.run_id // empty' <<<"$summary_json")"

owner_repo="$(repo_owner_repo_from_origin "$repo_dir")"
owner="${owner_repo%%/*}"
repo="${owner_repo##*/}"
if [[ -n "${GITHUB_OWNER:-}" ]]; then owner="$GITHUB_OWNER"; fi
if [[ -n "${GITHUB_REPO:-}" ]]; then repo="$GITHUB_REPO"; fi

# If already merged, treat as success.
pr_state="$(curl -sS "https://api.github.com/repos/$owner/$repo/pulls/$pr_number" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H 'X-GitHub-Api-Version: 2022-11-28')"
if jq -e '.merged == true' <<<"$pr_state" >/dev/null 2>&1; then
  jq -n \
    --arg author "$author" \
    --argjson pr_number "$pr_number" \
    --arg base "$base_branch" \
    --arg consensus_run_id "$consensus_run_id" \
    '{
      author:$author,
      pr_number:$pr_number,
      base:$base,
      merged:true,
      already_merged:true,
      consensus_run_id:$consensus_run_id
    }'
  exit 0
fi

merge_method="${AUTO_MERGE_METHOD:-squash}"
case "$merge_method" in
  merge|squash|rebase) ;;
  *) die "AUTO_MERGE_METHOD must be one of: merge|squash|rebase (current: $merge_method)" ;;
esac

merge_payload="$(jq -n \
  --arg method "$merge_method" \
  --arg title "[agent/$author] auto-merge PR #$pr_number" \
  --arg msg "Auto-merged after 3-of-4 AI consensus gate. run=$consensus_run_id" \
  '{merge_method:$method, commit_title:$title, commit_message:$msg}')"

merge_resp="$(curl -sS -X PUT "https://api.github.com/repos/$owner/$repo/pulls/$pr_number/merge" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -d "$merge_payload")"

if jq -e '.merged == true' <<<"$merge_resp" >/dev/null 2>&1; then
  jq -n \
    --arg author "$author" \
    --argjson pr_number "$pr_number" \
    --arg base "$base_branch" \
    --arg merge_method "$merge_method" \
    --arg consensus_run_id "$consensus_run_id" \
    --arg sha "$(jq -r '.sha // empty' <<<"$merge_resp")" \
    --arg message "$(jq -r '.message // empty' <<<"$merge_resp")" \
    '{
      author:$author,
      pr_number:$pr_number,
      base:$base,
      merge_method:$merge_method,
      merged:true,
      sha:$sha,
      message:$message,
      consensus_run_id:$consensus_run_id
    }'
  exit 0
fi

die "GitHub merge API failed: $(jq -c '{message,documentation_url,errors}' <<<"$merge_resp")"
