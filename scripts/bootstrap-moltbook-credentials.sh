#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

declare -A KEY_VAR_BY_AGENT=(
  [gpt]=GPT_MOLTBOOK_API_KEY
  [claude]=CLAUDE_MOLTBOOK_API_KEY
  [gemini]=GEMINI_MOLTBOOK_API_KEY
  [grok]=GROK_MOLTBOOK_API_KEY
)

declare -A NAME_VAR_BY_AGENT=(
  [gpt]=GPT_MOLTBOOK_AGENT_NAME
  [claude]=CLAUDE_MOLTBOOK_AGENT_NAME
  [gemini]=GEMINI_MOLTBOOK_AGENT_NAME
  [grok]=GROK_MOLTBOOK_AGENT_NAME
)

for agent in gpt claude gemini grok; do
  key_var="${KEY_VAR_BY_AGENT[$agent]}"
  name_var="${NAME_VAR_BY_AGENT[$agent]}"

  key="${!key_var:-}"
  name="${!name_var:-openclaw-$agent}"

  out="state/$agent/moltbook-credentials.json"
  mkdir -p "$(dirname "$out")"

  # Keep existing credentials unless explicitly missing.
  if [[ -f "$out" ]]; then
    continue
  fi

  if [[ -z "$key" ]]; then
    continue
  fi

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat > "$out" <<JSON
{
  "api_key": "$key",
  "agent_name": "$name",
  "claim_url": null,
  "verification_code": null,
  "saved_at": "$ts",
  "source": "host_bootstrap"
}
JSON

  chmod 600 "$out" || true
  echo "wrote: $out"
done
