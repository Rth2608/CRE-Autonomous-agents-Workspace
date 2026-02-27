#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROMPT="${1:-너는 누구야? 한 문장으로 답해줘.}"

declare -A MODEL_BY_SERVICE=(
  ["openclaw-gpt"]="openai/gpt-5.2"
  ["openclaw-claude"]="anthropic/claude-opus-4-6"
  ["openclaw-gemini"]="google-vertex/gemini-2.5-pro"
  ["openclaw-grok"]="xai/grok-4"
)

SERVICES=(
  "openclaw-gpt"
  "openclaw-claude"
  "openclaw-gemini"
  "openclaw-grok"
)

for service in "${SERVICES[@]}"; do
  model="${MODEL_BY_SERVICE[$service]}"
  echo "=== $service ($model) ==="
  docker compose exec -T \
    -e TEST_PROMPT="$PROMPT" \
    -e TEST_MODEL="$model" \
    "$service" \
    node -e '
      (async () => {
        const body = {
          model: process.env.TEST_MODEL,
          messages: [{ role: "user", content: process.env.TEST_PROMPT }]
        };

        const res = await fetch("http://127.0.0.1:18789/v1/chat/completions", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: "Bearer " + process.env.OPENCLAW_GATEWAY_TOKEN
          },
          body: JSON.stringify(body)
        });

        const json = await res.json();
        const content = json?.choices?.[0]?.message?.content ?? JSON.stringify(json);
        console.log(content);
      })().catch((err) => {
        console.error(String(err));
        process.exit(1);
      });
    '
  echo
done
