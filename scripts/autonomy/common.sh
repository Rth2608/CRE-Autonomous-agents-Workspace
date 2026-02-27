#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUTONOMY_DIR="$ROOT_DIR/autonomy"
STATE_DIR="$AUTONOMY_DIR/state"
LOG_DIR="$AUTONOMY_DIR/logs"
EMERGENCY_STOP_FILE="$STATE_DIR/emergency-stop.json"
TELEGRAM_APPROVAL_DIR="$STATE_DIR/telegram-approvals"

mkdir -p "$STATE_DIR" "$LOG_DIR"

AGENTS=(gpt claude gemini grok)

declare -A SERVICE_BY_AGENT=(
  [gpt]=openclaw-gpt
  [claude]=openclaw-claude
  [gemini]=openclaw-gemini
  [grok]=openclaw-grok
)

declare -A WORKDIR_BY_AGENT=(
  [gpt]="$ROOT_DIR/workdirs/gpt"
  [claude]="$ROOT_DIR/workdirs/claude"
  [gemini]="$ROOT_DIR/workdirs/gemini"
  [grok]="$ROOT_DIR/workdirs/grok"
)

declare -A MOLTBOOK_ENV_KEY_BY_AGENT=(
  [gpt]=GPT_MOLTBOOK_API_KEY
  [claude]=CLAUDE_MOLTBOOK_API_KEY
  [gemini]=GEMINI_MOLTBOOK_API_KEY
  [grok]=GROK_MOLTBOOK_API_KEY
)

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

stamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

log() {
  printf '[%s] %s\n' "$(now_utc)" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$(now_utc)" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

load_autonomy_config() {
  load_env_file() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue

      key="${line%%=*}"
      val="${line#*=}"

      # Strip matching outer quotes for common .env forms.
      if [[ "$val" =~ ^\".*\"$ ]]; then
        val="${val:1:${#val}-2}"
      elif [[ "$val" =~ ^\'.*\'$ ]]; then
        val="${val:1:${#val}-2}"
      fi

      export "$key=$val"
    done < "$env_file"
  }

  load_env_file "$ROOT_DIR/.env"

  local cfg="$AUTONOMY_DIR/config.env"
  if [[ -f "$cfg" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$cfg"
    set +a
  fi
}

leader_agent() {
  local leader="${AGENT_LEADER:-gemini}"
  case "$leader" in
    gpt|claude|gemini|grok)
      printf '%s\n' "$leader"
      ;;
    *)
      die "AGENT_LEADER must be one of: gpt, claude, gemini, grok (current: $leader)"
      ;;
  esac
}

is_emergency_stopped() {
  [[ -f "$EMERGENCY_STOP_FILE" ]] || return 1
  grep -qi '"emergency_stop"[[:space:]]*:[[:space:]]*true' "$EMERGENCY_STOP_FILE"
}

emergency_stop_reason() {
  [[ -f "$EMERGENCY_STOP_FILE" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '.reason // empty' "$EMERGENCY_STOP_FILE" 2>/dev/null || true
  else
    sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$EMERGENCY_STOP_FILE" | head -n1
  fi
}

ensure_not_emergency_stopped() {
  if is_emergency_stopped; then
    local reason
    reason="$(emergency_stop_reason)"
    if [[ -n "$reason" ]]; then
      die "Emergency stop is active. Reason: $reason (resume via /resume)"
    fi
    die "Emergency stop is active (resume via /resume)"
  fi
}

has_pending_human_approvals() {
  [[ "${PAUSE_ON_PENDING_APPROVALS:-true}" == "true" ]] || return 1
  [[ -d "$TELEGRAM_APPROVAL_DIR" ]] || return 1
  local f
  for f in "$TELEGRAM_APPROVAL_DIR"/req_*.json; do
    [[ -f "$f" ]] || continue
    if grep -qi '"status"[[:space:]]*:[[:space:]]*"pending"' "$f"; then
      return 0
    fi
  done
  return 1
}

ensure_no_pending_human_approvals() {
  if has_pending_human_approvals; then
    die "Pending human approval exists. Development is paused until /approve or /reject resolves pending requests."
  fi
}

ensure_virtual_mode() {
  local mode="${EXECUTION_MODE:-virtual}"
  local allow_non_virtual="${ALLOW_NON_VIRTUAL_NETWORKS:-false}"
  if [[ "$mode" != "virtual" ]]; then
    die "EXECUTION_MODE must be 'virtual'. Current: $mode"
  fi
  if [[ "$allow_non_virtual" == "true" ]]; then
    die "ALLOW_NON_VIRTUAL_NETWORKS must be false for safety"
  fi

  local deny_raw="${NETWORK_DENY_PATTERNS:-mainnet,eth-mainnet,arb1,base-mainnet,polygon-mainnet,bsc-mainnet,api.mainnet-beta.solana.com}"
  IFS=',' read -r -a deny_patterns <<<"$deny_raw"

  for url_var in PRIMARY_RPC_URL SECONDARY_RPC_URL; do
    local val="${!url_var:-}"
    [[ -z "$val" ]] && continue
    for pat in "${deny_patterns[@]}"; do
      if [[ "$val" == *"$pat"* ]]; then
        die "$url_var points to denied network pattern '$pat': $val"
      fi
    done
  done
}

agent_service() {
  local agent="$1"
  local service="${SERVICE_BY_AGENT[$agent]:-}"
  [[ -n "$service" ]] || die "Unknown agent: $agent"
  printf '%s\n' "$service"
}

agent_workdir() {
  local agent="$1"
  local wd="${WORKDIR_BY_AGENT[$agent]:-}"
  [[ -n "$wd" ]] || die "Unknown agent: $agent"
  printf '%s\n' "$wd"
}

agent_prompt() {
  local agent="$1"
  local prompt="$2"
  local service
  service="$(agent_service "$agent")"
  local retries="${AGENT_PROMPT_RETRIES:-3}"
  local retry_sleep="${AGENT_PROMPT_RETRY_SLEEP_SECONDS:-3}"
  local attempt output

  for ((attempt = 1; attempt <= retries; attempt++)); do
    if output="$("$ROOT_DIR/scripts/prompt-one-agent.sh" "$service" "$prompt" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi

    if [[ "$output" == *"is restarting"* ]] || \
       [[ "$output" == *"is not running"* ]] || \
       [[ "$output" == *"gateway_not_ready"* ]] || \
       [[ "$output" == *"No response from OpenClaw"* ]] || \
       [[ "$output" == *"fetch failed"* ]] || \
       [[ "$output" == *"connection refused"* ]]; then
      log "Agent service not ready ($service), retry $attempt/$retries"
      sleep "$retry_sleep"
      continue
    fi

    printf '%s\n' "$output" >&2
    return 1
  done

  printf '%s\n' "$output" >&2
  return 1
}

wait_for_agent_services() {
  local timeout_seconds="${1:-60}"
  local sleep_seconds="${2:-3}"
  local deadline=$((SECONDS + timeout_seconds))

  while ((SECONDS <= deadline)); do
    local all_ready=1
    local running
    running="$(docker compose ps --status running --services 2>/dev/null || true)"

    for agent in "${AGENTS[@]}"; do
      local service
      service="$(agent_service "$agent")"
      if ! grep -qx "$service" <<<"$running"; then
        all_ready=0
        break
      fi
    done

    if ((all_ready == 1)); then
      return 0
    fi

    sleep "$sleep_seconds"
  done

  return 1
}

moltbook_key_for_agent() {
  local agent="$1"
  local env_name="${MOLTBOOK_ENV_KEY_BY_AGENT[$agent]:-}"
  [[ -n "$env_name" ]] || die "Unknown agent: $agent"
  local key="${!env_name:-}"

  if [[ -n "$key" ]]; then
    printf '%s\n' "$key"
    return 0
  fi

  local cred_file="$ROOT_DIR/state/$agent/moltbook-credentials.json"
  if [[ -f "$cred_file" ]]; then
    jq -r '.api_key // empty' "$cred_file"
    return 0
  fi

  printf '\n'
}

repo_owner_repo_from_origin() {
  local repo_dir="$1"
  local origin
  origin="$(git -C "$repo_dir" remote get-url origin)"

  if [[ "$origin" =~ ^https://github.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
    printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  if [[ "$origin" =~ ^git@github.com:([^/]+)/([^/.]+)(\.git)?$ ]]; then
    printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  die "Unsupported origin URL format: $origin"
}
