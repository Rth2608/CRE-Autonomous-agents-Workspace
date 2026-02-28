# 4-OpenClaw Docker Workspace

This workspace runs 4 independent OpenClaw agents in parallel:

- `openclaw-gpt` (OpenAI key)
- `openclaw-claude` (Anthropic key)
- `openclaw-gemini` (Gemini via Google AI Studio API key)
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
- `GEMINI_API_KEY`
- all `*_GATEWAY_TOKEN` values

Optional (recommended for recovery after `down -v`):

- `GPT_MOLTBOOK_API_KEY`, `CLAUDE_MOLTBOOK_API_KEY`, `GEMINI_MOLTBOOK_API_KEY`, `GROK_MOLTBOOK_API_KEY`
- `*_MOLTBOOK_AGENT_NAME` (or keep defaults)

If a `state/*` folder is empty, the container entrypoint auto-creates:

- `state/<agent>/moltbook-credentials.json`

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
- Canvas host is disabled in this workspace (`OPENCLAW_SKIP_CANVAS_HOST=1`, `canvasHost.enabled=false`).
- `docker compose down -v` removes volumes/state. With `*_MOLTBOOK_API_KEY` set, run `./scripts/bootstrap-moltbook-credentials.sh` (or `./scripts/start-agents.sh`) to restore credentials files.
- If you change agent behavior/workflow later, you may need to update:
  - environment variables
  - mounted volumes
  - ports
  - startup command/image tag
  - model names in `config/*/openclaw.json`

## 4) Autonomous Orchestration (Guardrailed)

This workspace includes automation for multi-agent discussion, decision, and task planning.

Quick start:

```bash
cp autonomy/config.env.example autonomy/config.env
./scripts/autonomy/run-cycle.sh
```

Docs:
- `autonomy/README.md`
- `autonomy/config.env.example`

Before the first cycle, make sure 4 agents are healthy:

```bash
./scripts/autonomy/test-all-agents.sh --prompt "Say hello in one sentence."
```

## 5) Telegram Controller (Optional)

Set in `.env`:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_ALLOWED_CHAT_IDS`
- optional: `TELEGRAM_REQUIRE_APPROVAL_COMMANDS=`

Run:

```bash
./scripts/autonomy/run-telegram-controller.sh
```
