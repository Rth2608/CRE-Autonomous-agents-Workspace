#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <service> [prompt]"
  echo "service: openclaw-gpt | openclaw-claude | openclaw-gemini | openclaw-grok"
  exit 1
fi

SERVICE="$1"
PROMPT="${2:-Who are you? Answer in one sentence.}"

case "$SERVICE" in
  openclaw-gpt)
    MODEL="openai/gpt-5.2-pro"
    ;;
  openclaw-claude)
    MODEL="anthropic/claude-opus-4-6"
    ;;
  openclaw-gemini)
    MODEL="google/gemini-3.1-pro-preview"
    ;;
  openclaw-grok)
    MODEL="xai/grok-4"
    ;;
  *)
    echo "Unknown service: $SERVICE"
    exit 1
    ;;
esac

docker compose exec -T \
  -e TEST_PROMPT="$PROMPT" \
  -e TEST_MODEL="$MODEL" \
  -e GATEWAY_READY_RETRIES="${GATEWAY_READY_RETRIES:-45}" \
  -e GATEWAY_READY_SLEEP_MS="${GATEWAY_READY_SLEEP_MS:-1000}" \
  "$SERVICE" \
  node -e '
    (async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const readyRetries = Number(process.env.GATEWAY_READY_RETRIES || 45);
      const readySleepMs = Number(process.env.GATEWAY_READY_SLEEP_MS || 1000);

      // Wait briefly for local gateway bootstrap on fresh container starts.
      let portReady = false;
      for (let i = 0; i < readyRetries; i++) {
        try {
          await fetch("http://127.0.0.1:18789/v1/models", {
            method: "GET",
            headers: {
              authorization: "Bearer " + process.env.OPENCLAW_GATEWAY_TOKEN
            }
          });
          portReady = true;
          break;
        } catch {
          await sleep(readySleepMs);
        }
      }

      if (!portReady) {
        throw new Error("gateway_not_ready: 127.0.0.1:18789 did not become reachable");
      }

      const body = {
        model: process.env.TEST_MODEL,
        messages: [{ role: "user", content: process.env.TEST_PROMPT }]
      };

      let res;
      let lastErr;
      for (let i = 0; i < 5; i++) {
        try {
          res = await fetch("http://127.0.0.1:18789/v1/chat/completions", {
            method: "POST",
            headers: {
              "content-type": "application/json",
              authorization: "Bearer " + process.env.OPENCLAW_GATEWAY_TOKEN
            },
            body: JSON.stringify(body)
          });
          break;
        } catch (err) {
          lastErr = err;
          await sleep(1500);
        }
      }

      if (!res) {
        throw lastErr ?? new Error("chat_completions_request_failed");
      }

      const json = await res.json();
      const content = json?.choices?.[0]?.message?.content ?? JSON.stringify(json);
      console.log(content);
    })().catch((err) => {
      console.error(String(err));
      process.exit(1);
    });
  '
