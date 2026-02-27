#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 [--base main] [--agents "gpt claude gemini grok"] [--no-merge] [--review-retries N] [--review-retry-sleep N] [--commit-retries N] [--commit-retry-sleep N]

End-to-end collaboration test:
1) each agent creates one isolated commit on its branch
2) AI review gate validates the change
3) PR is created
4) PR is merged into base branch (unless --no-merge)

Requirements:
- GITHUB_TOKEN must be set
- selected agent containers must be running and healthy

Exit code:
- 0: all selected agents passed
- 2: one or more agents failed
USAGE
}

base_branch="main"
agents_input="gpt claude gemini grok"
do_merge=true
review_retries=3
review_retry_sleep=5
commit_retries=3
commit_retry_sleep=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      base_branch="$2"
      shift 2
      ;;
    --agents)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      agents_input="$2"
      shift 2
      ;;
    --no-merge)
      do_merge=false
      shift
      ;;
    --review-retries)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      review_retries="$2"
      shift 2
      ;;
    --review-retry-sleep)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      review_retry_sleep="$2"
      shift 2
      ;;
    --commit-retries)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      commit_retries="$2"
      shift 2
      ;;
    --commit-retry-sleep)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      commit_retry_sleep="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd jq
require_cmd git
require_cmd curl

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped
ensure_no_pending_human_approvals

[[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN is required"

read -r -a selected_agents <<<"$agents_input"
[[ "${#selected_agents[@]}" -gt 0 ]] || die "No agents selected"

for a in "${selected_agents[@]}"; do
  case "$a" in
    gpt|claude|gemini|grok) ;;
    *) die "Unknown agent in --agents: $a" ;;
  esac
done

run_id="e2e_collab_$(stamp)"
run_dir="$STATE_DIR/e2e/$run_id"
mkdir -p "$run_dir/tasks"

repo_dir="$(agent_workdir "${selected_agents[0]}")"
owner_repo="$(repo_owner_repo_from_origin "$repo_dir")"
owner="${owner_repo%%/*}"
repo="${owner_repo##*/}"
if [[ -n "${GITHUB_OWNER:-}" ]]; then owner="$GITHUB_OWNER"; fi
if [[ -n "${GITHUB_REPO:-}" ]]; then repo="$GITHUB_REPO"; fi

if [[ "$do_merge" == "true" ]]; then
  repo_info="$(curl -sS "https://api.github.com/repos/$owner/$repo" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28")"
  can_push="$(jq -r '.permissions.push // false' <<<"$repo_info" 2>/dev/null || echo false)"
  if [[ "$can_push" != "true" ]]; then
    msg="$(jq -r '.message // empty' <<<"$repo_info" 2>/dev/null || true)"
    die "Token cannot push/merge on $owner/$repo (permissions.push=false). ${msg:+API message: $msg}"
  fi
fi

log "Starting E2E flow: $run_id"
log "Base branch: $base_branch"
log "Agents: ${selected_agents[*]}"
log "Merge after PR: $do_merge"
log "Review retries: $review_retries (sleep ${review_retry_sleep}s)"
log "Commit retries: $commit_retries (sleep ${commit_retry_sleep}s)"
log "AUTO_MERGE_PR: ${AUTO_MERGE_PR:-false}"

fail_count=0
summary_file="$run_dir/summary.tsv"
printf 'agent\tcommit\tpr\tmerge\tinfo\n' > "$summary_file"

for agent in "${selected_agents[@]}"; do
  ensure_not_emergency_stopped
  ensure_no_pending_human_approvals
  service="$(agent_service "$agent")"
  repo="$(agent_workdir "$agent")"
  work_branch="e2e/${run_id}/${agent}"
  task_file="$run_dir/tasks/${agent}.md"
  marker="$(stamp)"
  test_file="coordination/e2e/${run_id}_${agent}.md"

  git -C "$repo" fetch origin "$base_branch" >/dev/null 2>&1 || true
  git -C "$repo" checkout -B "$work_branch" "origin/$base_branch" >/dev/null 2>&1 || \
    die "[$agent] failed to create work branch $work_branch from origin/$base_branch"

  cat > "$task_file" <<TASK
Create file \`$test_file\` with:
E2E collaboration flow check
agent: $agent
service: $service
utc: $marker
note: virtual-mode only, no secrets

Do not modify any other files.
TASK

  commit_state="FAIL"
  pr_state="SKIP"
  merge_state="SKIP"
  info=""

  dev_log="$run_dir/${agent}.dev.log"
  pr_log="$run_dir/${agent}.pr.log"
  merge_log="$run_dir/${agent}.merge.json"

  log "[$agent] commit phase"
  : >"$dev_log"
  commit_ok=0
  for attempt in $(seq 1 "$commit_retries"); do
    if SOURCE_BRANCH="$work_branch" "$SELF_DIR/agent-dev-commit.sh" "$agent" "$task_file" >>"$dev_log" 2>&1; then
      commit_ok=1
      commit_state="PASS"
      break
    fi
    if grep -q "Agent gateway/service is not ready" "$dev_log"; then
      log "[$agent] commit retry $attempt/$commit_retries"
      sleep "$commit_retry_sleep"
      continue
    fi
    break
  done
  if [[ "$commit_ok" -ne 1 ]]; then
    info="commit_failed"
    printf '%s\t%s\t%s\t%s\t%s\n' "$agent" "$commit_state" "$pr_state" "$merge_state" "$info" >> "$summary_file"
    fail_count=$((fail_count + 1))
    continue
  fi

  log "[$agent] PR phase"
  : >"$pr_log"
  pr_ok=0
  for attempt in $(seq 1 "$review_retries"); do
    if SOURCE_BRANCH="$work_branch" AUTO_CREATE_PR=true "$SELF_DIR/create-pr-if-approved.sh" "$agent" "$base_branch" \
      "[agent/$agent] test: e2e collab $run_id" >>"$pr_log" 2>&1; then
      pr_ok=1
      pr_state="PASS"
      break
    fi
    if grep -q "AI review gate failed" "$pr_log"; then
      log "[$agent] PR review gate retry $attempt/$review_retries"
      sleep "$review_retry_sleep"
      continue
    fi
    break
  done
  if [[ "$pr_ok" -ne 1 ]]; then
    info="pr_failed"
    printf '%s\t%s\t%s\t%s\t%s\n' "$agent" "$commit_state" "$pr_state" "$merge_state" "$info" >> "$summary_file"
    fail_count=$((fail_count + 1))
    continue
  fi

  pr_json="$(grep -E '^\{.*"url":.*"number":.*\}$' "$pr_log" | tail -n1 || true)"
  pr_number="$(jq -r '.number // empty' <<<"$pr_json" 2>/dev/null || true)"
  if [[ -z "$pr_number" ]]; then
    info="pr_number_parse_failed"
    printf '%s\t%s\t%s\t%s\t%s\n' "$agent" "$commit_state" "$pr_state" "$merge_state" "$info" >> "$summary_file"
    fail_count=$((fail_count + 1))
    continue
  fi

  if [[ "$do_merge" == "true" ]]; then
    if [[ "${AUTO_MERGE_PR:-false}" == "true" ]]; then
      log "[$agent] merge verification phase (AUTO_MERGE_PR=true, PR #$pr_number)"
      pr_state_resp="$(curl -sS "https://api.github.com/repos/$owner/$repo/pulls/$pr_number" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28")"
      printf '%s\n' "$pr_state_resp" > "$merge_log"
      if jq -e '.merged == true' <<<"$pr_state_resp" >/dev/null 2>&1; then
        merge_state="PASS"
        info="pr#$pr_number:auto_merged"
      else
        merge_state="FAIL"
        msg="$(jq -r '.message // "not_merged"' <<<"$pr_state_resp" 2>/dev/null || echo "not_merged")"
        info="pr#$pr_number:$msg"
        fail_count=$((fail_count + 1))
      fi
    else
      log "[$agent] merge phase (PR #$pr_number)"
      merge_payload="$(jq -n \
        --arg method "squash" \
        --arg title "[agent/$agent] merge e2e $run_id" \
        --arg msg "Automated merge from test-collab-main-flow.sh" \
        '{merge_method:$method, commit_title:$title, commit_message:$msg}')"

      merge_resp="$(curl -sS -X PUT "https://api.github.com/repos/$owner/$repo/pulls/$pr_number/merge" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "$merge_payload")"
      printf '%s\n' "$merge_resp" > "$merge_log"

      if jq -e '.merged == true' <<<"$merge_resp" >/dev/null 2>&1; then
        merge_state="PASS"
        info="pr#$pr_number"
      else
        merge_state="FAIL"
        msg="$(jq -r '.message // "merge_failed"' <<<"$merge_resp" 2>/dev/null || echo "merge_failed")"
        status_code="$(jq -r '.status // empty' <<<"$merge_resp" 2>/dev/null || true)"
        if [[ "$status_code" == "404" ]]; then
          msg="Not Found (likely token lacks merge permission: contents/write)"
        fi
        info="pr#$pr_number:$msg"
        fail_count=$((fail_count + 1))
      fi
    fi
  else
    merge_state="SKIP"
    info="pr#$pr_number"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$agent" "$commit_state" "$pr_state" "$merge_state" "$info" >> "$summary_file"
done

echo
echo "=== E2E Collaboration Summary ($run_id) ==="
column -s $'\t' -t "$summary_file" || cat "$summary_file"
echo "Artifacts: $run_dir"

if [[ "$fail_count" -gt 0 ]]; then
  exit 2
fi

exit 0
