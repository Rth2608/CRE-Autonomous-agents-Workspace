#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 [--prompt "text"] [--skip-moltbook] [--timeout-seconds N]

Checks all 4 agents in one run:
- container running readiness
- LLM prompt response via prompt-one-agent.sh
- Moltbook claimed/status check (optional)

Exit code:
- 0: all required checks passed
- 2: one or more checks failed
USAGE
}

prompt="한 문장으로 hello"
skip_moltbook=false
timeout_seconds=90

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      prompt="$2"
      shift 2
      ;;
    --skip-moltbook)
      skip_moltbook=true
      shift
      ;;
    --timeout-seconds)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      timeout_seconds="$2"
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

require_cmd docker
require_cmd jq
require_cmd curl

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped

compose_probe="$(docker compose ps --services 2>&1 || true)"
if grep -qi "permission denied while trying to connect to the Docker daemon socket" <<<"$compose_probe"; then
  echo "Docker daemon socket permission denied." >&2
  echo "Run this script with a user that can access Docker (or add your user to docker group)." >&2
  exit 2
fi

log "Waiting for all agent containers to be running (timeout: ${timeout_seconds}s)"
if ! wait_for_agent_services "$timeout_seconds" 3; then
  echo
  echo "Container readiness check: FAIL"
  docker compose ps || true
  exit 2
fi

fail_count=0
printf '\n=== Agent Health Summary ===\n'

for agent in "${AGENTS[@]}"; do
  service="$(agent_service "$agent")"
  llm_state="FAIL"
  llm_note=""
  molt_state="SKIP"
  molt_note=""

  llm_raw="$(mktemp)"
  if "$ROOT_DIR/scripts/prompt-one-agent.sh" "$service" "$prompt" >"$llm_raw" 2>&1; then
    llm_state="PASS"
    llm_note="$(head -n 1 "$llm_raw")"
  else
    llm_state="FAIL"
    llm_note="$(tr '\n' ' ' < "$llm_raw" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
    fail_count=$((fail_count + 1))
  fi
  rm -f "$llm_raw"

  if [[ "$skip_moltbook" == "false" ]]; then
    key="$(moltbook_key_for_agent "$agent")"
    if [[ -z "$key" ]]; then
      molt_state="WARN"
      molt_note="No Moltbook API key configured"
    else
      status_raw="$(mktemp)"
      if curl -sS "https://www.moltbook.com/api/v1/agents/status" \
        -H "Authorization: Bearer $key" >"$status_raw" 2>/dev/null; then
        if jq -e '.status == "claimed"' "$status_raw" >/dev/null 2>&1; then
          molt_state="PASS"
          molt_note="$(jq -r '.agent.name // "unknown-agent"' "$status_raw")"
        else
          molt_state="FAIL"
          molt_note="$(jq -c '{status, message, error}' "$status_raw" 2>/dev/null || head -c 180 "$status_raw")"
          fail_count=$((fail_count + 1))
        fi
      else
        molt_state="FAIL"
        molt_note="status API request failed"
        fail_count=$((fail_count + 1))
      fi
      rm -f "$status_raw"
    fi
  fi

  printf '\n[%s]\n' "$agent"
  printf '  LLM: %s - %s\n' "$llm_state" "${llm_note:-n/a}"
  if [[ "$skip_moltbook" == "false" ]]; then
    printf '  Moltbook: %s - %s\n' "$molt_state" "${molt_note:-n/a}"
  else
    printf '  Moltbook: SKIP\n'
  fi
done

echo
if [[ "$fail_count" -eq 0 ]]; then
  echo "Overall: PASS"
  exit 0
fi

echo "Overall: FAIL (${fail_count} check(s) failed)"
exit 2
