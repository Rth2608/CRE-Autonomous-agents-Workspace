#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 <agent> <submolt_name> <title> <content_file>

Example:
  $0 gpt cre-hackaton-rth2608 "Round 1 Proposal" ./autonomy/state/cycles/.../gpt.md
USAGE
}

[[ $# -eq 4 ]] || { usage; exit 1; }

require_cmd jq
require_cmd curl

agent="$1"
submolt="$2"
title="$3"
content_file="$4"

[[ -f "$content_file" ]] || die "Content file not found: $content_file"

load_autonomy_config

if [[ "${AUTO_POST_TO_MOLTBOOK:-false}" != "true" ]]; then
  die "AUTO_POST_TO_MOLTBOOK is false. Refusing to post."
fi

content_abs="$(readlink -f "$content_file" 2>/dev/null || true)"
[[ -n "$content_abs" ]] || die "Failed to resolve content file path: $content_file"
if [[ "${MOLTBOOK_REQUIRE_STATE_ARTIFACTS_ONLY:-true}" == "true" ]]; then
  case "$content_abs" in
    "$STATE_DIR"/*) ;;
    *)
      die "Refusing to post non-state artifact file: $content_abs"
      ;;
  esac
fi

# Prevent secret leaks.
"$SELF_DIR/scan-secrets.sh" --file "$content_file"
printf '%s\n' "$title" | "$SELF_DIR/scan-secrets.sh" --stdin
"$SELF_DIR/quarantine-untrusted.sh" --file "$content_file" --context "moltbook_post:$agent" --check-patterns
printf '%s\n' "$title" | "$SELF_DIR/quarantine-untrusted.sh" --stdin --context "moltbook_post_title:$agent" --check-patterns

api_key="$(moltbook_key_for_agent "$agent")"
[[ -n "$api_key" ]] || die "Missing Moltbook API key for agent: $agent"

content="$(cat "$content_file")"
max_chars="${MOLTBOOK_MAX_CONTENT_CHARS:-12000}"
if [[ "${#content}" -gt "$max_chars" ]]; then
  die "Moltbook post content too large (${#content} chars > ${max_chars}). Create a summarized state artifact first."
fi

payload="$(jq -n \
  --arg sub "$submolt" \
  --arg title "$title" \
  --arg content "$content" \
  '{submolt_name:$sub, title:$title, content:$content, type:"text"}')"

resp="$(curl -sS -X POST https://www.moltbook.com/api/v1/posts \
  -H "Authorization: Bearer $api_key" \
  -H 'content-type: application/json' \
  --data "$payload")"

printf '%s\n' "$resp" | jq -c '.'
