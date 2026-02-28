#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 <agent> <post_id> <content_file>

Example:
  $0 claude 123456 ./autonomy/state/moltbook/reply.md
USAGE
}

if [[ $# -eq 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 3 ]] || { usage; exit 1; }

require_cmd jq
require_cmd curl

agent="$1"
post_id="$2"
content_file="$3"

[[ -f "$content_file" ]] || die "Content file not found: $content_file"

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped

if [[ "${AUTO_POST_TO_MOLTBOOK:-false}" != "true" ]]; then
  die "AUTO_POST_TO_MOLTBOOK is false. Refusing to comment."
fi

if [[ -z "$post_id" ]]; then
  die "post_id is empty"
fi

content_abs="$(readlink -f "$content_file" 2>/dev/null || true)"
[[ -n "$content_abs" ]] || die "Failed to resolve content file path: $content_file"
if [[ "${MOLTBOOK_REQUIRE_STATE_ARTIFACTS_ONLY:-true}" == "true" ]]; then
  case "$content_abs" in
    "$STATE_DIR"/*) ;;
    *)
      die "Refusing to comment with non-state artifact file: $content_abs"
      ;;
  esac
fi

"$SELF_DIR/scan-secrets.sh" --file "$content_file"
"$SELF_DIR/quarantine-untrusted.sh" --file "$content_file" --context "moltbook_comment:$agent:$post_id" --check-patterns

api_key="$(moltbook_key_for_agent "$agent")"
[[ -n "$api_key" ]] || die "Missing Moltbook API key for agent: $agent"

content="$(cat "$content_file")"
max_chars="${MOLTBOOK_MAX_CONTENT_CHARS:-12000}"
if [[ "${#content}" -gt "$max_chars" ]]; then
  die "Moltbook comment content too large (${#content} chars > ${max_chars}). Create a summarized state artifact first."
fi

primary_ep="${MOLTBOOK_COMMENT_ENDPOINT:-https://www.moltbook.com/api/v1/comments}"
fallback_ep="${MOLTBOOK_COMMENT_ENDPOINT_FALLBACK:-https://www.moltbook.com/api/v1/posts/$post_id/comments}"

payload_primary="$(jq -n \
  --arg post_id "$post_id" \
  --arg content "$content" \
  '{post_id:$post_id, content:$content, type:"text"}')"

resp_primary="$(curl -sS -X POST "$primary_ep" \
  -H "Authorization: Bearer $api_key" \
  -H 'content-type: application/json' \
  --data "$payload_primary" || true)"

if jq -e '.success == true or .ok == true or .id or .comment.id or .data.id' <<<"$resp_primary" >/dev/null 2>&1; then
  printf '%s\n' "$resp_primary" | jq -c '.'
  exit 0
fi

payload_fallback="$(jq -n \
  --arg content "$content" \
  '{content:$content}')"

resp_fallback="$(curl -sS -X POST "$fallback_ep" \
  -H "Authorization: Bearer $api_key" \
  -H 'content-type: application/json' \
  --data "$payload_fallback" || true)"

if jq -e '.success == true or .ok == true or .id or .comment.id or .data.id' <<<"$resp_fallback" >/dev/null 2>&1; then
  printf '%s\n' "$resp_fallback" | jq -c '.'
  exit 0
fi

die "Moltbook comment API failed. primary=$(jq -c '{statusCode,message,error}' <<<"$resp_primary" 2>/dev/null || echo "$resp_primary") fallback=$(jq -c '{statusCode,message,error}' <<<"$resp_fallback" 2>/dev/null || echo "$resp_fallback")"
