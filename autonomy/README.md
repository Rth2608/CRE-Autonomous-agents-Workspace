# Autonomous Multi-Agent Control Plane

This folder contains guardrailed automation for 4 OpenClaw agents collaborating via:
- Git branches (`agent/gpt`, `agent/claude`, `agent/gemini`, `agent/grok`)
- Optional Moltbook discussion posts

## Safety Guarantees

1. Virtual-mode enforcement:
- `EXECUTION_MODE` must be `virtual`
- non-virtual network mode is blocked
- RPC URLs are checked against denied mainnet patterns

2. Secret leak prevention:
- secret scanner checks key cycle artifacts before posting/processing
- Moltbook posting path scans title/content before send

## Setup

1. Copy config:

```bash
cp autonomy/config.env.example autonomy/config.env
```

2. Edit `autonomy/config.env`:
- keep `EXECUTION_MODE=virtual`
- keep `CYCLE_MODE=auto` (first cycle kickoff, later cycles execution)
- keep `AUTO_POST_TO_MOLTBOOK=true` if you want cycle discussions published
- set `AGENT_LEADER=gemini` to make Gemini the coordination leader
- set `AUTO_MOLTBOOK_KICKOFF_DISCUSSION=true` to auto-publish kickoff discussion once topic is LOCKED
- keep `MOLTBOOK_REQUIRE_MAIN_LOCKED=true` to require locked kickoff on `origin/main` before publishing
- keep `TELEGRAM_WATCHDOG_ENABLED=false` and `TELEGRAM_AUTO_PLAN_REVIEW_ON_PENDING=false` to avoid idle token spend

3. Check all agents before first cycle:

```bash
./scripts/autonomy/test-all-agents.sh --prompt "Say hello in one sentence."
```

## Recommended References

- Local skills repo: `autonomy/skills/chainlink-agent-skills`
- Default references folder used by `run-cycle.sh`:
  `autonomy/skills/chainlink-agent-skills/cre-skills/references`
- Optional kickoff source-of-truth file (if present):
  `workdirs/gemini/coordination/KICKOFF_PACK.md` (or `AUTONOMY_REPO_PATH/coordination/KICKOFF_PACK.md`)

Optional config overrides:
- `CHAINLINK_AGENT_SKILLS_DIR=...`
- `CHAINLINK_AGENT_SKILLS_REFERENCES_DIR=...`
- `CHAINLINK_AGENT_SKILLS_MAX_FILES=...`
- `CHAINLINK_AGENT_SKILLS_MAX_LINES_PER_FILE=...`
- `CHAINLINK_AGENT_SKILLS_MAX_CHARS=...`
- `KICKOFF_PACK_MAX_LINES=...`
- `TENDERLY_PLAN=pro`
- `LLM_BUDGET_OPENAI_USD=35`
- `LLM_BUDGET_ANTHROPIC_USD=35`
- `LLM_BUDGET_GOOGLE_USD=35`
- `LLM_BUDGET_XAI_USD=35`
- `OTHER_PAID_COST_BUDGET_USD=10`
- `ALT_TOPICS_SUMMARY_ENABLED=...`
- `ALT_TOPICS_PUSH_ENABLED=...`
- `ALT_TOPICS_PUSH_REQUIRED=...`
- `ALT_TOPICS_SUMMARY_DIR=...`

## One Cycle (discussion + decision + task split)

```bash
./scripts/autonomy/run-cycle.sh
```

`CYCLE_MODE=auto` behavior:
- if `autonomy/state/cycle-plan.json` is missing: kickoff cycle
- if `autonomy/state/cycle-plan.json` exists: execution cycle

Kickoff/execution outputs now include:
- `innovation_summary`
- `failure_modes_and_mitigations`
- `optional_enablers` (`tenderly_virtual_networks`, `world_id`)
- `cost_plan` (Tenderly plan + per-provider LLM budget caps + other paid-cost cap)
- kickoff-only: leader `alternative-topics` summary markdown + optional git push

Force kickoff once:

```bash
./scripts/autonomy/run-cycle.sh --kickoff
```

Force execution planning cycle:

```bash
./scripts/autonomy/run-cycle.sh --execution
```

If `AUTO_POST_TO_MOLTBOOK=true` and kickoff is LOCKED, the cycle auto-runs:
- leader kickoff post
- multi-round agent discussion comments on one feature thread (single-thread mode)
- leader checkpoint comment per round (optional)
- final leader consensus comment

Discussion tuning options:
- `AUTO_MOLTBOOK_DISCUSSION_ROUNDS` (default: 3)
- `AUTO_MOLTBOOK_LEADER_ROUND_SUMMARIES` (default: true)

## Test All 4 Agents At Once

```bash
./scripts/autonomy/test-all-agents.sh --prompt "Say hello in one sentence."
```

Skip Moltbook status checks:

```bash
./scripts/autonomy/test-all-agents.sh --skip-moltbook
```

## Telegram Control (Optional)

1. Set in `.env`:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_ALLOWED_CHAT_IDS` (comma-separated)
- set `TELEGRAM_LEADER_ONLY_MODE=true` for leader-only human control
- set `TELEGRAM_MINIMAL_COMMAND_MODE=true` for approval + emergency-only control
- keep `TELEGRAM_AGENT_CONSENSUS_REQUIRED=true` and `TELEGRAM_AGENT_CONSENSUS_MIN=3`
- keep `TELEGRAM_WATCHDOG_ENABLED=false` for zero idle LLM checks
- keep `TELEGRAM_AUTO_PLAN_REVIEW_ON_PENDING=false` unless you want automatic plan-review runs

2. Start controller:

```bash
./scripts/autonomy/run-telegram-controller.sh
```

3. Telegram commands (minimal mode):
- `/help`
- `/pending`
- `/approve <request_id>`
- `/reject <request_id>`
- `/status`
- `/cycle [execution|kickoff|auto]`
- `/emergency_stop [reason]`
- `/resume [reason]`
- manual dev commands are disabled in minimal mode

Leader-only mode (`TELEGRAM_LEADER_ONLY_MODE=true`):
- `/ask <prompt>` targets only `AGENT_LEADER`

Emergency stop behavior:
- `/emergency_stop` enables global stop flag (`autonomy/state/emergency-stop.json`)
- autonomous scripts refuse execution while stop is active
- `/resume` clears stop state and allows cycle commands again

Approval policy:
- `TELEGRAM_REQUIRE_APPROVAL_COMMANDS` controls which commands require manual approval.
- Default: empty (no pre-execution approval commands)
- `TELEGRAM_AUTO_REQUEST_ON_BLOCKER=true` auto-creates approval request only when
  command fails with blocker patterns (auth/permission/rate-limit/etc).
- `TELEGRAM_PAUSE_DEV_WHEN_PENDING=true` blocks `/cycle` while approvals are pending.
- `TELEGRAM_AUTO_PLAN_REVIEW_ON_PENDING=false` avoids background planning costs while paused.
- `TELEGRAM_AGENT_CONSENSUS_REQUIRED=true` requires 3-of-4 vote before converting
  `[HUMAN_REQUEST]` to pending human approval.
- If consensus voting itself fails because one or more agents are unavailable,
  escalation is immediate.
- `PAUSE_ON_PENDING_APPROVALS=true` makes autonomous dev scripts/loops pause globally
  while any pending approval exists.

Watchdog policy:
- `TELEGRAM_WATCHDOG_ENABLED=false` by default (manual-only, no idle checks).
- Set `TELEGRAM_WATCHDOG_ENABLED=true` only when you need automatic health escalation.
- If any agent fails (including provider quota/token/billing failures), it creates
  a pending human request immediately.
- Recovery message is sent automatically once health checks pass again.

For max autonomy with human only on blocker:

```bash
TELEGRAM_REQUIRE_APPROVAL_COMMANDS=
TELEGRAM_AUTO_REQUEST_ON_BLOCKER=true
```

Agent-consensus escalation (dynamic, not pre-defined):
- If any agent/leader output includes:
  - `[HUMAN_REQUEST]: <reason>` or
  - `[HUMAN_APPROVAL]: <reason>`
- Telegram controller auto-creates a pending approval request and notifies the human.

## Important

- Do not put secrets in `autonomy/config.env` if this repo may be shared.
- Keep API keys in local shell env or private secret manager.
- The human operator still owns legal/compliance and final submission responsibility.
