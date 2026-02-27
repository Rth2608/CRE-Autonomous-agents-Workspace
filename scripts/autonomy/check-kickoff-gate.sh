#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 [--repo <path>] [--require-health]

Gate PASS conditions:
1) coordination/KICKOFF_PACK.md exists and is LOCKED with TOPIC_ID set
2) coordination/ACK/{gpt,claude,gemini,grok}.md all exist with:
   - ACK_STATUS: READY
   - FIRST_TASK: non-empty
3) coordination/START.md exists with:
   - START_APPROVED: true
   - STARTED_AT_UTC: non-empty
   - LOCKED_TOPIC_ID matches KICKOFF TOPIC_ID
4) (optional) all agents healthy when --require-health is passed

Exit code:
- 0: PASS
- 2: FAIL
USAGE
}

target_repo="$ROOT_DIR/workdirs/gpt"
require_health=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      target_repo="$2"
      shift 2
      ;;
    --require-health)
      require_health=true
      shift
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

[[ -d "$target_repo/.git" ]] || die "Not a git repo: $target_repo"
load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped

get_field() {
  local file="$1"
  local key="$2"
  grep -E "^${key}:" "$file" | tail -n1 | cut -d: -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

fail_count=0
report() {
  local level="$1"
  local msg="$2"
  printf '[%s] %s\n' "$level" "$msg"
}

kickoff="$target_repo/coordination/KICKOFF_PACK.md"
start_file="$target_repo/coordination/START.md"
ack_dir="$target_repo/coordination/ACK"

if [[ ! -f "$kickoff" ]]; then
  report FAIL "Missing $kickoff"
  fail_count=$((fail_count + 1))
fi
if [[ ! -f "$start_file" ]]; then
  report FAIL "Missing $start_file"
  fail_count=$((fail_count + 1))
fi
if [[ ! -d "$ack_dir" ]]; then
  report FAIL "Missing $ack_dir"
  fail_count=$((fail_count + 1))
fi

topic_id=""
if [[ -f "$kickoff" ]]; then
  kickoff_status="$(get_field "$kickoff" "KICKOFF_STATUS" || true)"
  topic_id="$(get_field "$kickoff" "TOPIC_ID" || true)"
  if [[ "$kickoff_status" != "LOCKED" ]]; then
    report FAIL "KICKOFF_STATUS must be LOCKED (current: ${kickoff_status:-empty})"
    fail_count=$((fail_count + 1))
  else
    report PASS "KICKOFF_STATUS=LOCKED"
  fi
  if [[ -z "$topic_id" ]]; then
    report FAIL "TOPIC_ID is empty in KICKOFF_PACK"
    fail_count=$((fail_count + 1))
  else
    report PASS "TOPIC_ID=$topic_id"
  fi
fi

for agent in "${AGENTS[@]}"; do
  ack_file="$ack_dir/${agent}.md"
  if [[ ! -f "$ack_file" ]]; then
    report FAIL "Missing ACK file: $ack_file"
    fail_count=$((fail_count + 1))
    continue
  fi

  ack_status="$(get_field "$ack_file" "ACK_STATUS" || true)"
  first_task="$(get_field "$ack_file" "FIRST_TASK" || true)"

  if [[ "$ack_status" != "READY" ]]; then
    report FAIL "ACK_STATUS must be READY for $agent (current: ${ack_status:-empty})"
    fail_count=$((fail_count + 1))
  else
    report PASS "$agent ACK_STATUS=READY"
  fi

  if [[ -z "$first_task" ]]; then
    report FAIL "FIRST_TASK is empty for $agent"
    fail_count=$((fail_count + 1))
  else
    report PASS "$agent FIRST_TASK set"
  fi
done

if [[ -f "$start_file" ]]; then
  start_approved="$(get_field "$start_file" "START_APPROVED" || true)"
  started_at="$(get_field "$start_file" "STARTED_AT_UTC" || true)"
  locked_topic_id="$(get_field "$start_file" "LOCKED_TOPIC_ID" || true)"
  start_approved_lower="$(printf '%s' "$start_approved" | tr '[:upper:]' '[:lower:]')"

  if [[ "$start_approved_lower" != "true" ]]; then
    report FAIL "START_APPROVED must be true (current: ${start_approved:-empty})"
    fail_count=$((fail_count + 1))
  else
    report PASS "START_APPROVED=true"
  fi

  if [[ -z "$started_at" ]]; then
    report FAIL "STARTED_AT_UTC is empty"
    fail_count=$((fail_count + 1))
  else
    report PASS "STARTED_AT_UTC set"
  fi

  if [[ -z "$locked_topic_id" ]]; then
    report FAIL "LOCKED_TOPIC_ID is empty"
    fail_count=$((fail_count + 1))
  else
    report PASS "LOCKED_TOPIC_ID=$locked_topic_id"
  fi

  if [[ -n "$topic_id" && -n "$locked_topic_id" && "$topic_id" != "$locked_topic_id" ]]; then
    report FAIL "LOCKED_TOPIC_ID ($locked_topic_id) != TOPIC_ID ($topic_id)"
    fail_count=$((fail_count + 1))
  elif [[ -n "$topic_id" && -n "$locked_topic_id" ]]; then
    report PASS "LOCKED_TOPIC_ID matches TOPIC_ID"
  fi
fi

if [[ "$require_health" == "true" ]]; then
  report INFO "Running health gate: scripts/autonomy/test-all-agents.sh --skip-moltbook"
  if "$ROOT_DIR/scripts/autonomy/test-all-agents.sh" --skip-moltbook >/tmp/kickoff_health.out 2>&1; then
    report PASS "Agent health check passed"
  else
    report FAIL "Agent health check failed"
    sed -n '1,120p' /tmp/kickoff_health.out | sed 's/^/  /'
    fail_count=$((fail_count + 1))
  fi
fi

echo
if [[ "$fail_count" -eq 0 ]]; then
  report PASS "Kickoff gate PASSED"
  exit 0
fi

report FAIL "Kickoff gate FAILED (${fail_count} issue(s))"
exit 2
