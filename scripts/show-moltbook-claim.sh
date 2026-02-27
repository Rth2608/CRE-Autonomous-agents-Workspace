#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <service>"
  echo "service: openclaw-gpt | openclaw-claude | openclaw-gemini | openclaw-grok"
  exit 1
fi

SERVICE="$1"

case "$SERVICE" in
  openclaw-gpt)
    FILE="./state/gpt/moltbook-credentials.json"
    ;;
  openclaw-claude)
    FILE="./state/claude/moltbook-credentials.json"
    ;;
  openclaw-gemini)
    FILE="./state/gemini/moltbook-credentials.json"
    ;;
  openclaw-grok)
    FILE="./state/grok/moltbook-credentials.json"
    ;;
  *)
    echo "Unknown service: $SERVICE"
    exit 1
    ;;
esac

if [[ ! -f "$FILE" ]]; then
  echo "No credentials file yet: $FILE"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to read $FILE"
  exit 1
fi

echo "claim_url: $(jq -r '.claim_url // ""' "$FILE")"
echo "verification_code: $(jq -r '.verification_code // ""' "$FILE")"
