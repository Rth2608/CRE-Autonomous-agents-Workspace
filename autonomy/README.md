# Autonomous Multi-Agent Control Plane

This folder contains guardrailed automation for 4 OpenClaw agents collaborating via:
- Git branches (`agent/gpt`, `agent/claude`, `agent/gemini`, `agent/grok`)
- Optional Moltbook discussion posts
- Optional AI review gate before PR creation

## Safety Guarantees

1. Virtual-mode enforcement:
- `EXECUTION_MODE` must be `virtual`
- non-virtual network mode is blocked
- RPC URLs are checked against denied mainnet patterns

2. Secret leak prevention:
- secret scanner blocks commits/pushes via git hooks
- Moltbook posting path scans title/content before send
- PR body/title is scanned before API call

## Setup

1. Copy config:

```bash
cp autonomy/config.env.example autonomy/config.env
```

2. Edit `autonomy/config.env`:
- keep `EXECUTION_MODE=virtual`
- set `AUTO_POST_TO_MOLTBOOK`, `AUTO_DEV_COMMITS`, `AUTO_CREATE_PR` as needed
- set `AUTO_MERGE_PR=true` for automatic merge after merge-consensus gate
- set `AGENT_LEADER=gemini` to make Gemini the coordination leader
- set `AUTO_MOLTBOOK_KICKOFF_DISCUSSION=true` to auto-publish kickoff discussion once topic is LOCKED
- keep `MOLTBOOK_REQUIRE_MAIN_LOCKED=true` to require locked kickoff on `origin/main` before publishing

3. Install git guard hooks in all 4 workdirs:

```bash
./scripts/autonomy/install-guard-hooks.sh
```

## Recommended References

- CRE HTTP Trigger (TypeScript): `https://docs.chain.link/cre/guides/workflow/using-triggers/http-trigger/overview-ts`
- Chainlink agent skills repo: `https://github.com/smartcontractkit/chainlink-agent-skills/`

Optional config overrides:
- `CRE_HTTP_TRIGGER_DOC_URL=...`
- `CHAINLINK_AGENT_SKILLS_URL=...`

## One Cycle (discussion + decision + task split)

```bash
./scripts/autonomy/run-cycle.sh
```

If `AUTO_POST_TO_MOLTBOOK=true` and kickoff is LOCKED, the cycle auto-runs:
- leader kickoff post
- 4 agent comments for plan concretization

## One Cycle with Autonomous Code Commit Attempts

```bash
./scripts/autonomy/run-cycle.sh --autocode
```

## Continuous Loop

```bash
./scripts/autonomy/run-loop.sh 1800
```

## AI Review Gate (manual check)

```bash
./scripts/autonomy/ai-review-gate.sh claude main
```

## Kickoff Gate (recommended before first autonomous cycle)

Initialize kickoff files in your dev repo (default: `workdirs/gpt`):

```bash
./scripts/autonomy/init-kickoff-gate-files.sh --repo workdirs/gpt
```

Check gate readiness:

```bash
./scripts/autonomy/check-kickoff-gate.sh --repo workdirs/gpt --require-health
```

## Test All 4 Agents At Once

```bash
./scripts/autonomy/test-all-agents.sh --prompt "한 문장으로 hello"
```

Skip Moltbook status checks:

```bash
./scripts/autonomy/test-all-agents.sh --skip-moltbook
```

## End-to-End GitHub Flow Test (Agent -> Review -> PR -> Main)

```bash
export GITHUB_TOKEN=...  # required
./scripts/autonomy/test-collab-main-flow.sh
```

Create PRs only (no merge):

```bash
./scripts/autonomy/test-collab-main-flow.sh --no-merge
```

Retry review gate for transient model/API failures:

```bash
./scripts/autonomy/test-collab-main-flow.sh --review-retries 5 --review-retry-sleep 8
```

Also retry commit phase for transient gateway errors:

```bash
./scripts/autonomy/test-collab-main-flow.sh --commit-retries 5 --commit-retry-sleep 8
```

## Create PR only if gate passes

```bash
export GITHUB_TOKEN=...  # keep in shell only
./scripts/autonomy/create-pr-if-approved.sh claude main "[agent/claude] feat: ..."
```

## Auto Merge (3-of-4 Consensus)

When `AUTO_MERGE_PR=true`, `create-pr-if-approved.sh` does:
1) PR creation
2) merge-consensus gate (includes all 4 agents, requires `MERGE_CONSENSUS_MIN`, default 3)
3) GitHub merge API call (`AUTO_MERGE_METHOD`, default `squash`)

Manual merge gate command:

```bash
./scripts/autonomy/merge-pr-if-approved.sh gemini 12 main
```

## Telegram Control (Optional)

1. Set in `.env`:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_ALLOWED_CHAT_IDS` (comma-separated)
- keep `TELEGRAM_ENABLE_E2E_MERGE=false` unless explicitly needed
- set `TELEGRAM_LEADER_ONLY_MODE=true` for leader-only human control
- set `TELEGRAM_MINIMAL_COMMAND_MODE=true` for approval + emergency-only control
- keep `TELEGRAM_AGENT_CONSENSUS_REQUIRED=true` and `TELEGRAM_AGENT_CONSENSUS_MIN=3`
- keep watchdog enabled for immediate escalation on agent failure/quota issues

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
- `/emergency_stop [reason]`
- `/resume [reason]`
- manual dev commands are disabled in minimal mode

Leader-only mode (`TELEGRAM_LEADER_ONLY_MODE=true`):
- `/ask <prompt>` targets only `AGENT_LEADER`
- `/commit <task_file>` targets only `AGENT_LEADER`
- `/pr [base_branch] [title...]` targets only `AGENT_LEADER`
- `/e2e`, `/e2e_merge` are forced to leader-only execution

Emergency stop behavior:
- `/emergency_stop` enables global stop flag (`autonomy/state/emergency-stop.json`)
- autonomous scripts refuse execution while stop is active
- `run-loop.sh` stays alive and skips cycle ticks until `/resume`

Approval policy:
- `TELEGRAM_REQUIRE_APPROVAL_COMMANDS` controls which commands require manual approval.
- Default: `pr,e2e_merge`
- `TELEGRAM_AUTO_REQUEST_ON_BLOCKER=true` auto-creates approval request only when
  command fails with blocker patterns (auth/permission/rate-limit/etc).
- `TELEGRAM_PAUSE_DEV_WHEN_PENDING=true` blocks dev commands while approvals are pending.
- `TELEGRAM_AUTO_PLAN_REVIEW_ON_PENDING=true` runs a planning-only review cycle during pause.
- `TELEGRAM_PLAN_REVIEW_REPO=workdirs/gpt` selects which repo snapshot is reviewed.
- `TELEGRAM_AGENT_CONSENSUS_REQUIRED=true` requires 3-of-4 vote before converting
  `[HUMAN_REQUEST]` to pending human approval.
- If consensus voting itself fails because one or more agents are unavailable,
  escalation is immediate.
- `PAUSE_ON_PENDING_APPROVALS=true` makes autonomous dev scripts/loops pause globally
  while any pending approval exists.

Watchdog policy:
- `TELEGRAM_WATCHDOG_ENABLED=true` periodically runs all-agent health checks.
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
