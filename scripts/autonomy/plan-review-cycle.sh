#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 [--reason "<text>"] [--repo <path>]

Runs a planning-only review cycle (no code changes, no PR):
1) each agent critiques current project plan
2) each agent proposes creative improvements and risk mitigations
3) leader agent synthesizes one consolidated plan update
USAGE
}

reason="human_intervention_pending"
repo="$ROOT_DIR/workdirs/gpt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      reason="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      repo="$2"
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
require_cmd docker

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped
leader="$(leader_agent)"

[[ -d "$repo/.git" ]] || die "Not a git repo: $repo"

if ! wait_for_agent_services "${AGENT_SERVICES_READY_TIMEOUT_SECONDS:-60}" 3; then
  die "OpenClaw containers are not in running state"
fi

run_id="plan_review_$(stamp)"
run_dir="$STATE_DIR/plan-reviews/$run_id"
mkdir -p "$run_dir/reviews"

submolt="${MOLTBOOK_SUBMOLT:-cre-hackaton-rth2608}"

context_buf="$run_dir/context.txt"
: > "$context_buf"

append_context_file() {
  local rel="$1"
  local abs="$repo/$rel"
  if [[ -f "$abs" ]]; then
    {
      printf '## FILE: %s\n\n' "$rel"
      sed -n '1,240p' "$abs"
      printf '\n\n'
    } >> "$context_buf"
  fi
}

append_context_file "coordination/KICKOFF_PACK.md"
append_context_file "coordination/START.md"
append_context_file "coordination/DECISIONS.md"
append_context_file "coordination/TASKS.md"
append_context_file "docs/PROJECT_CHARTER.md"
append_context_file "docs/SUBMISSION_CHECKLIST.md"

if [[ ! -s "$context_buf" ]]; then
  echo "No context files found. Using minimal fallback context." > "$context_buf"
fi

log "Starting planning review cycle: $run_id"
log "Leader agent: $leader"

for agent in "${AGENTS[@]}"; do
  ensure_not_emergency_stopped
  out="$run_dir/reviews/$agent.md"
  prompt="You are '$agent' in planning-only mode.
Human intervention is pending due to: $reason

Rules:
- Do NOT propose code changes or PR actions.
- Focus on project plan quality while development is paused.
- Suggest concrete, creative improvements and risk mitigations.
- Keep all recommendations testnet-only and secret-safe.

Return markdown with sections:
1) Current plan weaknesses (max 5 bullets)
2) Creative alternatives (max 5 bullets)
3) Risk controls to add now (max 5 bullets)
4) Revised next 3 tasks (ordered)
5) What to ask the human in one sentence

Current project context:
$(cat "$context_buf")"

  if agent_prompt "$agent" "$prompt" > "$out"; then
    "$SELF_DIR/scan-secrets.sh" --file "$out"
    log "Plan review saved: $out"
  else
    printf '# %s\n\nPlan review failed.\n' "$agent" > "$out"
    log "Plan review failed for $agent"
  fi
done

all_reviews=""
for agent in "${AGENTS[@]}"; do
  all_reviews+=$'\n\n'
  all_reviews+="## $agent\n"
  all_reviews+="$(cat "$run_dir/reviews/$agent.md")"
done

summary_prompt="You are the planning coordinator and leader agent '$leader'.
Human intervention is pending due to: $reason

Based on the multi-agent planning reviews below, return ONLY JSON:
{
  \"run_id\": \"$run_id\",
  \"pause_reason\": \"...\",
  \"top_issues\": [\"...\"],
  \"creative_options\": [\"...\"],
  \"risk_controls\": [\"...\"],
  \"revised_next_tasks\": [\"...\", \"...\", \"...\"],
  \"human_question\": \"...\"
}

Reviews:
$all_reviews"

summary_raw="$run_dir/summary.raw.txt"
summary_json="$run_dir/summary.json"
if agent_prompt "$leader" "$summary_prompt" > "$summary_raw" && jq -e . "$summary_raw" > "$summary_json" 2>/dev/null; then
  "$SELF_DIR/scan-secrets.sh" --file "$summary_json"
  log "Planning summary saved: $summary_json"
else
  cp "$summary_raw" "$run_dir/summary.txt" || true
  die "Planning summary generation failed: $summary_raw"
fi

if [[ "${AUTO_POST_TO_MOLTBOOK:-false}" == "true" ]]; then
  "$SELF_DIR/safe-moltbook-post.sh" "$leader" "$submolt" "[$run_id] planning review while paused" "$summary_json" >/dev/null || true
fi

log "Planning review cycle completed: $run_id"
printf '%s\n' "$run_id"
