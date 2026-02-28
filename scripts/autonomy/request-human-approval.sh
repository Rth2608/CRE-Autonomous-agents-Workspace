#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 --reason <reason_key> --detail <text> [--context <label>] [--command <text>]

Creates a pending human-approval request with optional 4-agent consensus and
sends Telegram notifications (if configured).
USAGE
}

reason=""
detail=""
context_label="autonomy"
command_text="(auto)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      reason="$2"
      shift 2
      ;;
    --detail)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      detail="$2"
      shift 2
      ;;
    --context)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      context_label="$2"
      shift 2
      ;;
    --command)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      command_text="$2"
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

[[ -n "$reason" ]] || die "--reason is required"
[[ -n "$detail" ]] || die "--detail is required"

require_cmd jq
require_cmd curl
require_cmd date

# Preserve one-shot env overrides passed at invocation time.
quarantine_consensus_required_override_set=false
quarantine_consensus_required_override=""
quarantine_consensus_min_override_set=false
quarantine_consensus_min_override=""
if [[ -n "${QUARANTINE_AGENT_CONSENSUS_REQUIRED+x}" ]]; then
  quarantine_consensus_required_override_set=true
  quarantine_consensus_required_override="$QUARANTINE_AGENT_CONSENSUS_REQUIRED"
fi
if [[ -n "${QUARANTINE_CONSENSUS_MIN+x}" ]]; then
  quarantine_consensus_min_override_set=true
  quarantine_consensus_min_override="$QUARANTINE_CONSENSUS_MIN"
fi

load_autonomy_config
if [[ "$quarantine_consensus_required_override_set" == "true" ]]; then
  QUARANTINE_AGENT_CONSENSUS_REQUIRED="$quarantine_consensus_required_override"
fi
if [[ "$quarantine_consensus_min_override_set" == "true" ]]; then
  QUARANTINE_CONSENSUS_MIN="$quarantine_consensus_min_override"
fi

consensus_required="${QUARANTINE_AGENT_CONSENSUS_REQUIRED:-true}"
consensus_min="${QUARANTINE_CONSENSUS_MIN:-${TELEGRAM_AGENT_CONSENSUS_MIN:-3}}"
if ! [[ "$consensus_min" =~ ^[0-9]+$ ]]; then
  consensus_min=3
fi
if (( consensus_min < 1 )); then consensus_min=1; fi
if (( consensus_min > 4 )); then consensus_min=4; fi

telegram_token="${TELEGRAM_BOT_TOKEN:-}"
allowed_chat_ids_raw="${TELEGRAM_ALLOWED_CHAT_IDS:-}"

approval_dir="$STATE_DIR/telegram-approvals"
consensus_dir="$STATE_DIR/consensus"
mkdir -p "$approval_dir" "$consensus_dir"

trim() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

first_chat_id() {
  local IFS=',' part
  for part in $allowed_chat_ids_raw; do
    part="$(trim <<<"$part")"
    [[ -n "$part" ]] || continue
    printf '%s\n' "$part"
    return 0
  done
  return 1
}

send_telegram() {
  local text="$1"
  [[ -n "$telegram_token" ]] || return 0
  [[ -n "$allowed_chat_ids_raw" ]] || return 0
  local IFS=',' cid payload
  for cid in $allowed_chat_ids_raw; do
    cid="$(trim <<<"$cid")"
    [[ -n "$cid" ]] || continue
    payload="$(jq -n --arg chat_id "$cid" --arg text "$text" '{chat_id:$chat_id, text:$text, disable_web_page_preview:true}')"
    curl -sS -X POST "https://api.telegram.org/bot${telegram_token}/sendMessage" \
      -H 'content-type: application/json' \
      --data "$payload" >/dev/null 2>&1 || true
  done
}

extract_json_obj() {
  local raw="$1"
  local tmp out
  tmp="$(mktemp)"
  printf '%s\n' "$raw" > "$tmp"
  out="$(awk '
    /^```json[[:space:]]*$/ {inblock=1; next}
    /^```[[:space:]]*$/ {if (inblock) exit}
    {if (inblock) print}
  ' "$tmp")"
  rm -f "$tmp"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$raw"
}

detail_short="$(printf '%s' "$detail" | tr '\n' ' ' | cut -c1-700)"
detail_hash="$(printf '%s|%s|%s' "$reason" "$context_label" "$detail_short" | sha256sum | awk '{print $1}')"

# Deduplicate pending requests for same quarantine issue.
for f in "$approval_dir"/req_*.json; do
  [[ -f "$f" ]] || continue
  st="$(jq -r '.status // empty' "$f" 2>/dev/null || true)"
  rs="$(jq -r '.reason // empty' "$f" 2>/dev/null || true)"
  hs="$(jq -r '.quarantine_hash // empty' "$f" 2>/dev/null || true)"
  if [[ "$st" == "pending" && "$rs" == "$reason" && "$hs" == "$detail_hash" ]]; then
    req_id="$(jq -r '.id // empty' "$f" 2>/dev/null || true)"
    if [[ -n "$req_id" ]]; then
      log "Pending request already exists for same quarantine issue: $req_id"
      printf '%s\n' "$req_id"
      exit 0
    fi
  fi
done

consensus_yes=0
consensus_run_id="consensus_$(stamp)_quarantine"
consensus_file="$consensus_dir/${consensus_run_id}.json"

if [[ "$consensus_required" == "true" ]]; then
  votes_json='[]'
  error_agents='[]'
  for agent in "${AGENTS[@]}"; do
    prompt="You are agent '$agent' in a safety consensus vote.
Context: quarantine blocked an unallowlisted external domain.

Return ONLY JSON:
{
  \"agent\":\"$agent\",
  \"decision\":\"approve|reject\",
  \"requires_human\": true|false,
  \"reason\":\"one short sentence\"
}

Reason key: $reason
Context label: $context_label
Detail: $detail_short"
    if response="$(agent_prompt "$agent" "$prompt" 2>/dev/null || true)"; then
      parsed="$(extract_json_obj "$response")"
      if jq -e '.agent and (.decision or .requires_human != null)' <<<"$parsed" >/dev/null 2>&1; then
        decision="$(jq -r '.decision // empty' <<<"$parsed")"
        needs_human="$(jq -r '.requires_human // false' <<<"$parsed")"
        yes=false
        if [[ "$decision" == "approve" || "$needs_human" == "true" ]]; then
          yes=true
          consensus_yes=$((consensus_yes + 1))
        fi
        vote="$(jq -n \
          --arg agent "$agent" \
          --arg decision "${decision:-unknown}" \
          --arg reason "$(jq -r '.reason // ""' <<<"$parsed" | cut -c1-240)" \
          --argjson yes "$yes" \
          '{agent:$agent, decision:$decision, yes:$yes, reason:$reason}')"
        votes_json="$(jq --argjson v "$vote" '. + [$v]' <<<"$votes_json")"
      else
        vote="$(jq -n --arg agent "$agent" '{agent:$agent, decision:"error", yes:false, reason:"invalid_json"}')"
        votes_json="$(jq --argjson v "$vote" '. + [$v]' <<<"$votes_json")"
        error_agents="$(jq --arg a "$agent" '. + [$a]' <<<"$error_agents")"
      fi
    else
      vote="$(jq -n --arg agent "$agent" '{agent:$agent, decision:"error", yes:false, reason:"prompt_failed"}')"
      votes_json="$(jq --argjson v "$vote" '. + [$v]' <<<"$votes_json")"
      error_agents="$(jq --arg a "$agent" '. + [$a]' <<<"$error_agents")"
    fi
  done

  consensus_pass=false
  if (( consensus_yes >= consensus_min )); then
    consensus_pass=true
  fi

  jq -n \
    --arg run_id "$consensus_run_id" \
    --arg created_at "$(now_utc)" \
    --arg reason "$reason" \
    --arg context "$context_label" \
    --arg detail "$detail_short" \
    --argjson min "$consensus_min" \
    --argjson yes "$consensus_yes" \
    --argjson pass "$consensus_pass" \
    --argjson votes "$votes_json" \
    --argjson error_agents "$error_agents" \
    '{run_id:$run_id, created_at:$created_at, reason:$reason, context:$context, detail:$detail, consensus_min:$min, yes_count:$yes, passed:$pass, votes:$votes, error_agents:$error_agents}' \
    > "$consensus_file"

  if [[ "$consensus_pass" != "true" ]]; then
    log "Quarantine consensus rejected human request: $consensus_yes/$consensus_min"
    send_telegram "[quarantine] consensus rejected human intervention ($consensus_yes/$consensus_min). context=$context_label"
    printf '%s\n' "$consensus_file"
    exit 2
  fi
fi

chat_id="$(first_chat_id || true)"
[[ -n "$chat_id" ]] || chat_id="system"

suffix="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
req_id="req_$(date -u +%s)_${suffix}"
req_file="$approval_dir/${req_id}.json"

jq -n \
  --arg id "$req_id" \
  --arg created_at "$(now_utc)" \
  --arg chat_id "$chat_id" \
  --arg command_text "$command_text" \
  --arg reason "$reason" \
  --arg note "Auto-created from quarantine block on non-allowlisted domain." \
  --arg detail "$detail_short" \
  --arg context "$context_label" \
  --arg qhash "$detail_hash" \
  --arg consensus_run_id "$consensus_run_id" \
  --arg consensus_file "$consensus_file" \
  --argjson consensus_required "$([[ "$consensus_required" == "true" ]] && echo true || echo false)" \
  --argjson consensus_min "$consensus_min" \
  --argjson consensus_yes "$consensus_yes" \
  '{
    id:$id,
    status:"pending",
    created_at:$created_at,
    chat_id:$chat_id,
    command_text:$command_text,
    plan_review_triggered:false,
    reason:$reason,
    note:$note,
    agent_request_reason:$detail,
    quarantine_context:$context,
    quarantine_hash:$qhash,
    consensus_required:$consensus_required,
    consensus_min:$consensus_min,
    consensus_yes:$consensus_yes,
    consensus_run_id:$consensus_run_id,
    consensus_artifact:$consensus_file
  }' > "$req_file"

send_telegram "[quarantine] Human intervention required.
request_id: $req_id
reason: $reason
context: $context_label
detail: $detail_short
consensus: ${consensus_yes}/${consensus_min}

Approve: /approve $req_id
Reject: /reject $req_id"

log "Created pending human request: $req_id"
printf '%s\n' "$req_id"
