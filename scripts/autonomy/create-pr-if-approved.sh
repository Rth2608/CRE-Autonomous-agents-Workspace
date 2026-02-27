#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 <author_agent> [base_branch] [title]

Example:
  $0 claude main "[agent/claude] feat: add workflow skeleton"
USAGE
}

[[ $# -ge 1 ]] || { usage; exit 1; }

require_cmd jq
require_cmd git
require_cmd curl
require_cmd base64

author="$1"
base_branch="${2:-main}"
custom_title="${3:-}"
author_branch="${SOURCE_BRANCH:-agent/$author}"
repo_dir="$(agent_workdir "$author")"

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped
ensure_no_pending_human_approvals

if [[ "${AUTO_CREATE_PR:-false}" != "true" ]]; then
  die "AUTO_CREATE_PR is false. Refusing to open PR automatically."
fi

[[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN is required"

summary_tmp="$(mktemp)"
if ! "$SELF_DIR/ai-review-gate.sh" "$author" "$base_branch" >"$summary_tmp"; then
  cat "$summary_tmp" >&2 || true
  rm -f "$summary_tmp"
  die "AI review gate failed"
fi

summary_json="$(cat "$summary_tmp")"
rm -f "$summary_tmp"
summary_path="$(jq -r '.run_id' <<<"$summary_json")"

# Ensure no secrets in changed content before push.
"$SELF_DIR/scan-secrets.sh" --staged "$repo_dir"

# Push with token-auth header to avoid interactive credential issues.
origin_url="$(git -C "$repo_dir" remote get-url origin)"
if [[ "$origin_url" == https://github.com/* || "$origin_url" == git@github.com:* ]]; then
  if auth_b64="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0 2>/dev/null)"; then
    :
  else
    auth_b64="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
  fi
  git -C "$repo_dir" -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth_b64" push -u origin "$author_branch"
else
  git -C "$repo_dir" push -u origin "$author_branch"
fi

owner_repo="$(repo_owner_repo_from_origin "$repo_dir")"
owner="${owner_repo%%/*}"
repo="${owner_repo##*/}"

if [[ -n "${GITHUB_OWNER:-}" ]]; then owner="$GITHUB_OWNER"; fi
if [[ -n "${GITHUB_REPO:-}" ]]; then repo="$GITHUB_REPO"; fi

if [[ -n "$custom_title" ]]; then
  title="$custom_title"
else
  title="[agent/$author] automated update $(date -u +%Y-%m-%d)"
fi

body=$(
  cat <<BODY
Automated PR created after AI review gate passed.

- author: \`$author\`
- source branch: \`$author_branch\`
- base branch: \`$base_branch\`
- review run: \`$summary_path\`

Review summary:
\`\`\`json
$summary_json
\`\`\`
BODY
)

printf '%s\n' "$title" | "$SELF_DIR/scan-secrets.sh" --stdin
printf '%s\n' "$body" | "$SELF_DIR/scan-secrets.sh" --stdin

payload="$(jq -n \
  --arg title "$title" \
  --arg head "$author_branch" \
  --arg base "$base_branch" \
  --arg body "$body" \
  '{title:$title, head:$head, base:$base, body:$body, maintainer_can_modify:false, draft:false}')"

resp="$(curl -sS -X POST "https://api.github.com/repos/$owner/$repo/pulls" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -d "$payload")"

pr_out=""
if jq -e '.html_url and .number' <<<"$resp" >/dev/null 2>&1; then
  pr_out="$(printf '%s\n' "$resp" | jq -c '{url:.html_url, number, state, title, existing:false}')"
fi

# Reuse existing open PR when the same head/base pair already has one.
if [[ -z "$pr_out" ]] && jq -e '.errors[]? | select((.message // "") | test("A pull request already exists"; "i"))' <<<"$resp" >/dev/null 2>&1; then
  pr_list="$(curl -sS "https://api.github.com/repos/$owner/$repo/pulls?state=open&head=$owner:$author_branch&base=$base_branch" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H 'X-GitHub-Api-Version: 2022-11-28')"
  existing="$(jq -c '.[0] // empty' <<<"$pr_list")"
  if [[ -n "$existing" ]]; then
    pr_out="$(printf '%s\n' "$existing" | jq -c '{url:.html_url, number, state, title, existing:true}')"
  fi
fi

[[ -n "$pr_out" ]] || die "GitHub PR API failed: $(jq -c '{message,errors,documentation_url}' <<<"$resp")"

printf '%s\n' "$pr_out"

if [[ "${AUTO_MERGE_PR:-false}" == "true" ]]; then
  pr_number="$(jq -r '.number // empty' <<<"$pr_out")"
  [[ -n "$pr_number" ]] || die "AUTO_MERGE_PR=true but failed to parse PR number"
  "$SELF_DIR/merge-pr-if-approved.sh" "$author" "$pr_number" "$base_branch"
fi
