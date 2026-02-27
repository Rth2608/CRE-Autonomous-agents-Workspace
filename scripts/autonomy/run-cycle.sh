#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 [--autocode]

Runs one full autonomous cycle:
1) Multi-agent topic discussion
2) Topic decision synthesis
3) Per-agent task assignment
4) (optional) autonomous code commit attempts
USAGE
}

autocode="false"
if [[ $# -gt 0 ]]; then
  [[ "$1" == "--autocode" ]] || { usage; exit 1; }
  autocode="true"
fi

require_cmd jq
require_cmd docker
require_cmd git

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped
ensure_no_pending_human_approvals
leader="$(leader_agent)"

cycle_id="cycle_$(stamp)"
cycle_dir="$STATE_DIR/cycles/$cycle_id"
mkdir -p "$cycle_dir/proposals" "$cycle_dir/tasks"

source_url="${HACKATHON_SOURCE_URL:-https://chain.link/hackathon/prizes}"
cre_http_trigger_url="${CRE_HTTP_TRIGGER_DOC_URL:-https://docs.chain.link/cre/guides/workflow/using-triggers/http-trigger/overview-ts}"
agent_skills_url="${CHAINLINK_AGENT_SKILLS_URL:-https://github.com/smartcontractkit/chainlink-agent-skills/}"
submolt="${MOLTBOOK_SUBMOLT:-cre-hackaton-rth2608}"

log "Starting cycle: $cycle_id"
log "Leader agent: $leader"

if ! wait_for_agent_services "${AGENT_SERVICES_READY_TIMEOUT_SECONDS:-60}" 3; then
  die "OpenClaw containers are not in running state. Check: docker compose ps && docker compose logs --tail=80 openclaw-gpt openclaw-claude openclaw-gemini openclaw-grok"
fi

if [[ "${AUTO_MOLTBOOK_KICKOFF_DISCUSSION:-true}" == "true" ]] && [[ "${AUTO_POST_TO_MOLTBOOK:-false}" == "true" ]]; then
  repo_for_kickoff="${AUTONOMY_REPO_PATH:-$ROOT_DIR/workdirs/gpt}"
  if ! "$SELF_DIR/publish-kickoff-discussion.sh" --repo "$repo_for_kickoff" >/tmp/kickoff_discussion.out 2>/tmp/kickoff_discussion.err; then
    log "Kickoff Moltbook discussion skipped/failed: $(tr '\n' ' ' </tmp/kickoff_discussion.err | cut -c1-300)"
  else
    log "Kickoff Moltbook discussion published: $(cat /tmp/kickoff_discussion.out)"
  fi
  rm -f /tmp/kickoff_discussion.out /tmp/kickoff_discussion.err || true
fi

# 1) Proposals
for agent in "${AGENTS[@]}"; do
  ensure_not_emergency_stopped
  ensure_no_pending_human_approvals
  prompt="You are agent '$agent' planning a Chainlink CRE hackathon project.
Use these sources as context:
- $source_url
- $cre_http_trigger_url
- $agent_skills_url
Constraints:
- virtual testnet development only
- no mainnet or real funds
- never reveal secrets
Return concise markdown with:
1. Title
2. Problem
3. Why CRE orchestration is required
4. On-chain write plan (testnet)
5. Simulation plan (cre simulate)
6. MVP scope for 1 week"

  out="$cycle_dir/proposals/$agent.md"
  if agent_prompt "$agent" "$prompt" > "$out"; then
    "$SELF_DIR/scan-secrets.sh" --file "$out"
    log "Proposal saved: $out"

    if [[ "${AUTO_POST_TO_MOLTBOOK:-false}" == "true" ]]; then
      "$SELF_DIR/safe-moltbook-post.sh" "$agent" "$submolt" "[$cycle_id] proposal from $agent" "$out" >/dev/null || true
    fi
  else
    printf '# %s\n\nFailed to generate proposal.\n' "$agent" > "$out"
    log "Proposal failed for $agent"
  fi
done

# 2) Decision synthesis by leader agent
all_proposals=""
for agent in "${AGENTS[@]}"; do
  all_proposals+=$'\n\n'
  all_proposals+="## $agent\n"
  all_proposals+="$(cat "$cycle_dir/proposals/$agent.md")"
done

decision_prompt="You are the coordinator and leader agent '$leader'.
Given the proposals below, select ONE final project.
Return ONLY JSON:
{
  \"selected_title\": \"...\",
  \"selected_track\": \"DeFi & Tokenization|AI|Prediction Markets|Privacy\",
  \"reason\": \"...\",
  \"onchain_write\": \"...\",
  \"simulation\": \"...\",
  \"task_split\": {
    \"gpt\": \"...\",
    \"claude\": \"...\",
    \"gemini\": \"...\",
    \"grok\": \"...\"
  }
}

Proposals:
$all_proposals"

decision_raw="$cycle_dir/decision.raw.txt"
decision_json="$cycle_dir/decision.json"

if agent_prompt "$leader" "$decision_prompt" > "$decision_raw" && jq -e . "$decision_raw" > "$decision_json" 2>/dev/null; then
  "$SELF_DIR/scan-secrets.sh" --file "$decision_json"
  log "Decision JSON saved: $decision_json"
else
  cp "$decision_raw" "$cycle_dir/decision.txt" || true
  die "Decision generation failed or non-JSON output: $decision_raw"
fi

if [[ "${AUTO_POST_TO_MOLTBOOK:-false}" == "true" ]]; then
  "$SELF_DIR/safe-moltbook-post.sh" "$leader" "$submolt" "[$cycle_id] final topic decision" "$decision_json" >/dev/null || true
fi

# 3) Task files
for agent in "${AGENTS[@]}"; do
  ensure_not_emergency_stopped
  ensure_no_pending_human_approvals
  task="$(jq -r --arg a "$agent" '.task_split[$a] // "Define your own implementation task from the selected title."' "$decision_json")"
  cat > "$cycle_dir/tasks/$agent.md" <<TASK
# Task for $agent

Cycle: $cycle_id
Leader: $leader
Title: $(jq -r '.selected_title' "$decision_json")
Track: $(jq -r '.selected_track' "$decision_json")

Assigned task:
$task
TASK

  "$SELF_DIR/scan-secrets.sh" --file "$cycle_dir/tasks/$agent.md"
done

# 4) Optional autonomous coding
if [[ "$autocode" == "true" ]] || [[ "${AUTO_DEV_COMMITS:-false}" == "true" ]]; then
  log "Autocode enabled. Running one commit attempt per agent."
  for agent in "${AGENTS[@]}"; do
    ensure_not_emergency_stopped
    ensure_no_pending_human_approvals
    if "$SELF_DIR/agent-dev-commit.sh" "$agent" "$cycle_dir/tasks/$agent.md"; then
      if [[ "${AUTO_CREATE_PR:-false}" == "true" ]]; then
        "$SELF_DIR/create-pr-if-approved.sh" "$agent" main || true
      fi
    else
      log "Autocode failed for $agent"
    fi
  done
fi

log "Cycle completed: $cycle_id"
printf '%s\n' "$cycle_id"
