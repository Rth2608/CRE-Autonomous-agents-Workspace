#!/bin/sh
set -eu

CRED_FILE="${MOLTBOOK_CREDENTIALS_FILE:-/home/node/.openclaw/moltbook-credentials.json}"

if [ ! -f "$CRED_FILE" ] && [ -n "${MOLTBOOK_API_KEY:-}" ]; then
  mkdir -p "$(dirname "$CRED_FILE")"

  AGENT_NAME="${MOLTBOOK_AGENT_NAME:-}"
  if [ -z "$AGENT_NAME" ]; then
    AGENT_NAME="$(hostname)"
  fi

  SAVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat >"$CRED_FILE" <<EOF
{
  "api_key": "${MOLTBOOK_API_KEY}",
  "agent_name": "${AGENT_NAME}",
  "claim_url": null,
  "verification_code": null,
  "saved_at": "${SAVED_AT}",
  "source": "env_bootstrap"
}
EOF
fi

exec "$@"
