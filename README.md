# 4-OpenClaw Docker Workspace

This workspace runs 4 independent OpenClaw agents in parallel:

- `openclaw-gpt` (OpenAI key)
- `openclaw-claude` (Anthropic key)
- `openclaw-gemini` (Gemini via Vertex AI service account)
- `openclaw-grok` (xAI key)

Each agent has isolated persistent state under `./state/<agent>`.
Each agent model is defined in `./config/<agent>/openclaw.json`.

## 1) Configure env

```bash
cp .env.example .env
```

Edit `.env` and fill:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `XAI_API_KEY`
- all `*_GATEWAY_TOKEN` values
- `GEMINI_VERTEX_PROJECT_ID`
- `GEMINI_VERTEX_LOCATION`
- `GEMINI_VERTEX_CREDENTIALS_FILE`

Optional (recommended for recovery after `down -v`):

- `GPT_MOLTBOOK_API_KEY`, `CLAUDE_MOLTBOOK_API_KEY`, `GEMINI_MOLTBOOK_API_KEY`, `GROK_MOLTBOOK_API_KEY`
- `*_MOLTBOOK_AGENT_NAME` (or keep defaults)

If a `state/*` folder is empty, the container entrypoint auto-creates:

- `state/<agent>/moltbook-credentials.json`

Create your Vertex service account file:

```bash
mkdir -p secrets
$EDITOR secrets/gemini-vertex-sa.json
```

Then set:

```bash
GEMINI_VERTEX_CREDENTIALS_FILE=./secrets/gemini-vertex-sa.json
```

Optional `.env`-only flow:

1. Put `GEMINI_VERTEX_SA_JSON=...` in `.env` (single-line JSON, escaped `\n`)
2. Run:

```bash
./scripts/write-gemini-vertex-sa.sh
```

## 2) Start all 4 agents

```bash
./scripts/start-agents.sh
```

Check status:

```bash
docker compose ps
```

See logs:

```bash
docker compose logs -f openclaw-gpt
docker compose logs -f openclaw-claude
docker compose logs -f openclaw-gemini
docker compose logs -f openclaw-grok
```

## 3) Stop all agents

```bash
docker compose down
```

## Notes

- The 4 agents run on separate ports (set in `.env`).
- `docker compose down -v` removes volumes/state. With `*_MOLTBOOK_API_KEY` set, run `./scripts/bootstrap-moltbook-credentials.sh` (or `./scripts/start-agents.sh`) to restore credentials files.
- If you change agent behavior/workflow later, you may need to update:
  - environment variables
  - mounted volumes
  - ports
  - startup command/image tag
  - model names in `config/*/openclaw.json`

## 4) Autonomous Orchestration (Guardrailed)

This workspace includes automation for multi-agent discussion, decision, and optional autonomous coding.

Quick start:

```bash
cp autonomy/config.env.example autonomy/config.env
./scripts/autonomy/install-guard-hooks.sh
./scripts/autonomy/run-cycle.sh
```

Docs:
- `autonomy/README.md`
- `autonomy/config.env.example`

Before autonomous build start, initialize and verify kickoff gate:

```bash
./scripts/autonomy/init-kickoff-gate-files.sh --repo workdirs/gpt
./scripts/autonomy/check-kickoff-gate.sh --repo workdirs/gpt --require-health
```

## 5) Telegram Controller (Optional)

Set in `.env`:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_ALLOWED_CHAT_IDS`
- optional: `TELEGRAM_REQUIRE_APPROVAL_COMMANDS=pr,e2e_merge`

Run:

```bash
./scripts/autonomy/run-telegram-controller.sh
```
