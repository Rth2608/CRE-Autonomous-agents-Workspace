#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 --check-url <url> [--context <label>]
  $0 --file <path> [--context <label>] [--check-patterns]
  $0 --stdin [--context <label>] [--check-patterns]

Notes:
- Enforced only when EXTERNAL_CONTENT_QUARANTINE=true
- URL host allowlist comes from QUARANTINE_ALLOWED_HOSTS (comma-separated)
USAGE
}

check_url=""
input_file=""
use_stdin=false
check_patterns=false
context_label="external_content"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-url)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      check_url="$2"
      shift 2
      ;;
    --file)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      input_file="$2"
      shift 2
      ;;
    --stdin)
      use_stdin=true
      shift
      ;;
    --check-patterns)
      check_patterns=true
      shift
      ;;
    --context)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      context_label="$2"
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

if [[ -z "$check_url" && -z "$input_file" && "$use_stdin" != "true" ]]; then
  usage
  exit 1
fi

if [[ -n "$check_url" ]]; then
  if [[ -n "$input_file" || "$use_stdin" == "true" ]]; then
    die "Use either --check-url or (--file/--stdin), not both"
  fi
fi

# Preserve one-shot env overrides passed at invocation time.
declare -A _ov_set=()
declare -A _ov_val=()
for k in \
  EXTERNAL_CONTENT_QUARANTINE \
  QUARANTINE_ALLOWED_HOSTS \
  QUARANTINE_MAX_URLS \
  QUARANTINE_AUTO_REQUEST_ON_BLOCK \
  QUARANTINE_AGENT_CONSENSUS_REQUIRED \
  QUARANTINE_CONSENSUS_MIN; do
  if [[ -n "${!k+x}" ]]; then
    _ov_set["$k"]=1
    _ov_val["$k"]="${!k}"
  fi
done

load_autonomy_config

for k in "${!_ov_set[@]}"; do
  export "$k=${_ov_val[$k]}"
done

if [[ "${EXTERNAL_CONTENT_QUARANTINE:-true}" != "true" ]]; then
  exit 0
fi

allowed_hosts_csv="${QUARANTINE_ALLOWED_HOSTS:-chain.link,docs.chain.link,github.com,raw.githubusercontent.com,api.github.com,docs.tenderly.co,tenderly.co,docs.world.org,world.org,moltbook.com,www.moltbook.com}"
max_urls="${QUARANTINE_MAX_URLS:-40}"

trim_spaces() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

host_allowed() {
  local host="$1"
  local host_lc allow
  host_lc="$(tr '[:upper:]' '[:lower:]' <<<"$host")"
  IFS=',' read -r -a _allowed <<<"$allowed_hosts_csv"
  for allow in "${_allowed[@]}"; do
    allow="$(trim_spaces <<<"$allow")"
    [[ -z "$allow" ]] && continue
    allow="$(tr '[:upper:]' '[:lower:]' <<<"$allow")"
    if [[ "$host_lc" == "$allow" || "$host_lc" == *".${allow}" ]]; then
      return 0
    fi
  done
  return 1
}

validate_url() {
  local url="$1"
  local sanitized scheme rest host

  sanitized="$(sed 's/[),.;:!?]*$//' <<<"$url")"
  if [[ ! "$sanitized" =~ ^https?:// ]]; then
    echo "invalid_url_scheme:$sanitized"
    return 1
  fi

  scheme="${sanitized%%://*}"
  rest="${sanitized#*://}"
  rest="${rest#*@}"
  host="${rest%%/*}"
  host="${host%%\?*}"
  host="${host%%#*}"
  host="${host%%:*}"
  host="$(tr '[:upper:]' '[:lower:]' <<<"$host")"

  if [[ -z "$host" ]]; then
    echo "missing_host:$sanitized"
    return 1
  fi

  if [[ "$scheme" == "http" && "$host" != "127.0.0.1" && "$host" != "localhost" ]]; then
    echo "insecure_http_url:$sanitized"
    return 1
  fi

  if ! host_allowed "$host"; then
    echo "host_not_allowlisted:$host:$sanitized"
    return 1
  fi

  return 0
}

check_text_patterns() {
  local file="$1"
  local -a findings=()
  local -a patterns=(
    'ignore[[:space:]]+(all|previous)[[:space:]]+instructions'
    'do[[:space:]]+not[[:space:]]+follow[[:space:]]+system'
    'curl[[:space:]].*\|[[:space:]]*(sh|bash)'
    'wget[[:space:]].*\|[[:space:]]*(sh|bash)'
    'reveal[[:space:]].*(api[_-]?key|private[_-]?key|seed|mnemonic|token|password|secret)'
  )

  for pat in "${patterns[@]}"; do
    if grep -Eiq "$pat" "$file"; then
      findings+=("$pat")
    fi
  done

  if [[ "${#findings[@]}" -gt 0 ]]; then
    echo "pattern_blocked:${findings[*]}"
    return 1
  fi
  return 0
}

violations=()

if [[ -n "$check_url" ]]; then
  if ! reason="$(validate_url "$check_url")"; then
    violations+=("$reason")
  fi
else
  src_file="$input_file"
  if [[ "$use_stdin" == "true" ]]; then
    src_file="$(mktemp)"
    cat >"$src_file"
  fi
  [[ -f "$src_file" ]] || die "Input file not found: $src_file"

  mapfile -t urls < <(grep -Eo 'https?://[^[:space:]<>"'"'"']+' "$src_file" | sed 's/[),.;:!?]*$//' | sort -u || true)
  if [[ "${#urls[@]}" -gt "$max_urls" ]]; then
    violations+=("too_many_urls:${#urls[@]} > ${max_urls}")
  fi
  for u in "${urls[@]}"; do
    [[ -z "$u" ]] && continue
    if ! reason="$(validate_url "$u")"; then
      violations+=("$reason")
    fi
  done

  if [[ "$check_patterns" == "true" ]]; then
    if ! reason="$(check_text_patterns "$src_file")"; then
      violations+=("$reason")
    fi
  fi

  if [[ "$use_stdin" == "true" ]]; then
    rm -f "$src_file"
  fi
fi

if [[ "${#violations[@]}" -gt 0 ]]; then
  reason_key="quarantine_violation"
  if printf '%s\n' "${violations[@]}" | grep -q "host_not_allowlisted:"; then
    reason_key="quarantine_host_not_allowlisted"
  fi
  detail="context=${context_label}; violations=$(IFS='; '; echo "${violations[*]}")"

  if [[ "${QUARANTINE_AUTO_REQUEST_ON_BLOCK:-true}" == "true" ]]; then
    if req_out="$("$SELF_DIR/request-human-approval.sh" \
      --reason "$reason_key" \
      --context "$context_label" \
      --command "quarantine_guard" \
      --detail "$detail" 2>&1)"; then
      printf '[%s] INFO: Human request created from quarantine block: %s\n' "$(now_utc)" "$(tail -n1 <<<"$req_out")" >&2
    else
      printf '[%s] WARN: Failed to create human request from quarantine block: %s\n' "$(now_utc)" "$(tr '\n' ' ' <<<"$req_out" | cut -c1-300)" >&2
    fi
  fi

  {
    printf '[%s] ERROR: Quarantine blocked content (%s)\n' "$(now_utc)" "$context_label"
    printf '[HUMAN_REQUEST]: quarantine blocked external content; reason=%s; context=%s\n' "$reason_key" "$context_label"
    for v in "${violations[@]}"; do
      printf -- '- %s\n' "$v"
    done
    printf 'Allowed hosts: %s\n' "$allowed_hosts_csv"
  } >&2
  exit 2
fi

exit 0
