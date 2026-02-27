#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <service> <agent_name> [description]"
  echo "service: openclaw-gpt | openclaw-claude | openclaw-gemini | openclaw-grok"
  exit 1
fi

SERVICE="$1"
AGENT_NAME="$2"
DESCRIPTION="${3:-Autonomous agent participating in CRE hackathon workflows.}"

case "$SERVICE" in
  openclaw-gpt|openclaw-claude|openclaw-gemini|openclaw-grok)
    ;;
  *)
    echo "Unknown service: $SERVICE"
    exit 1
    ;;
esac

docker compose exec -T \
  -e MB_AGENT_NAME="$AGENT_NAME" \
  -e MB_AGENT_DESC="$DESCRIPTION" \
  "$SERVICE" \
  node -e '
    const fs = require("node:fs");

    (async () => {
      const name = process.env.MB_AGENT_NAME;
      const description = process.env.MB_AGENT_DESC;
      const res = await fetch("https://www.moltbook.com/api/v1/agents/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name, description })
      });

      const text = await res.text();
      let payload;
      try {
        payload = JSON.parse(text);
      } catch {
        payload = { raw: text };
      }

      if (!res.ok) {
        console.log(JSON.stringify({
          ok: false,
          status: res.status,
          error: payload
        }, null, 2));
        process.exit(2);
      }

      const agent = payload?.agent ?? {};
      const creds = {
        api_key: agent.api_key ?? null,
        agent_name: name,
        claim_url: agent.claim_url ?? null,
        verification_code: agent.verification_code ?? null,
        saved_at: new Date().toISOString()
      };

      const outPath = "/home/node/.openclaw/moltbook-credentials.json";
      fs.writeFileSync(outPath, JSON.stringify(creds, null, 2));
      console.log(JSON.stringify({
        ok: true,
        claim_url: creds.claim_url,
        verification_code: creds.verification_code,
        credentials_file: outPath
      }, null, 2));
    })().catch((err) => {
      console.log(JSON.stringify({
        ok: false,
        error: String(err)
      }, null, 2));
      process.exit(1);
    });
  '
