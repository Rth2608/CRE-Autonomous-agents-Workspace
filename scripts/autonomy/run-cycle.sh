#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 [--kickoff|--execution]

Runs one full autonomous cycle:
1) kickoff cycle: initial topic selection + first plan
2) execution cycle: requirements analysis from previous progress + next plan
3) per-agent task assignment
USAGE
}

cycle_mode_cli=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kickoff)
      cycle_mode_cli="kickoff"
      ;;
    --execution)
      cycle_mode_cli="execution"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift
done

require_cmd jq
require_cmd docker
require_cmd git

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped
ensure_no_pending_human_approvals
leader="$(leader_agent)"

cycle_id="cycle_$(stamp)"
cycle_dir="$STATE_DIR/cycles/$cycle_id"
mkdir -p "$cycle_dir/proposals" "$cycle_dir/tasks"
cycle_plan_file="$STATE_DIR/cycle-plan.json"

skills_dir="${CHAINLINK_AGENT_SKILLS_DIR:-$ROOT_DIR/autonomy/skills/chainlink-agent-skills}"
skills_refs_dir="${CHAINLINK_AGENT_SKILLS_REFERENCES_DIR:-$skills_dir/cre-skills/references}"
skills_max_files="${CHAINLINK_AGENT_SKILLS_MAX_FILES:-10}"
skills_max_lines="${CHAINLINK_AGENT_SKILLS_MAX_LINES_PER_FILE:-80}"
skills_max_chars="${CHAINLINK_AGENT_SKILLS_MAX_CHARS:-25000}"
kickoff_pack_max_lines="${KICKOFF_PACK_MAX_LINES:-220}"
submolt="${MOLTBOOK_SUBMOLT:-cre-hackaton-rth2608}"
single_thread_mode="${AUTO_MOLTBOOK_SINGLE_THREAD_MODE:-true}"
cycle_mode_requested="${cycle_mode_cli:-${CYCLE_MODE:-auto}}"
history_cycles="${CYCLE_HISTORY_CYCLES:-3}"
planning_repo="${AUTONOMY_REPO_PATH:-$ROOT_DIR/workdirs/gemini}"
tenderly_plan="${TENDERLY_PLAN:-pro}"
llm_budget_openai_usd="${LLM_BUDGET_OPENAI_USD:-35}"
llm_budget_anthropic_usd="${LLM_BUDGET_ANTHROPIC_USD:-35}"
llm_budget_google_usd="${LLM_BUDGET_GOOGLE_USD:-35}"
llm_budget_xai_usd="${LLM_BUDGET_XAI_USD:-35}"
other_paid_cost_budget_usd="${OTHER_PAID_COST_BUDGET_USD:-10}"
feedback_only_mode="${FEEDBACK_ONLY_MODE:-true}"
sync_agent_branches_from_main="${SYNC_AGENT_BRANCHES_FROM_MAIN:-true}"
sync_agent_branches_required="${SYNC_AGENT_BRANCHES_REQUIRED:-true}"
leader_cycle_summary_enabled="${LEADER_CYCLE_SUMMARY_ENABLED:-true}"
leader_cycle_summary_required="${LEADER_CYCLE_SUMMARY_REQUIRED:-true}"
leader_cycle_summary_dir="${LEADER_CYCLE_SUMMARY_DIR:-coordination/cycle-summaries}"
leader_cycle_summary_auto_merge_main="${LEADER_CYCLE_SUMMARY_AUTO_MERGE_MAIN:-true}"
leader_cycle_summary_notify_telegram="${LEADER_CYCLE_SUMMARY_NOTIFY_TELEGRAM:-true}"
leader_cycle_summary_push_branch_prefix="${LEADER_CYCLE_SUMMARY_PUSH_BRANCH_PREFIX:-autonomy/cycle-summary}"

if ! [[ "$history_cycles" =~ ^[0-9]+$ ]]; then
  history_cycles=3
fi
if (( history_cycles < 1 )); then history_cycles=1; fi
if (( history_cycles > 20 )); then history_cycles=20; fi

if [[ "$skills_dir" != /* ]]; then
  skills_dir="$ROOT_DIR/$skills_dir"
fi
if [[ "$skills_refs_dir" != /* ]]; then
  skills_refs_dir="$ROOT_DIR/$skills_refs_dir"
fi
if [[ "$planning_repo" != /* ]]; then
  planning_repo="$ROOT_DIR/$planning_repo"
fi

[[ -d "$skills_dir" ]] || die "Skills directory not found: $skills_dir"

if ! [[ "$skills_max_files" =~ ^[0-9]+$ ]]; then
  skills_max_files=10
fi
if ! [[ "$skills_max_lines" =~ ^[0-9]+$ ]]; then
  skills_max_lines=80
fi
if ! [[ "$skills_max_chars" =~ ^[0-9]+$ ]]; then
  skills_max_chars=25000
fi
if ! [[ "$kickoff_pack_max_lines" =~ ^[0-9]+$ ]]; then
  kickoff_pack_max_lines=220
fi
if ! [[ "$llm_budget_openai_usd" =~ ^[0-9]+$ ]]; then
  llm_budget_openai_usd=35
fi
if ! [[ "$llm_budget_anthropic_usd" =~ ^[0-9]+$ ]]; then
  llm_budget_anthropic_usd=35
fi
if ! [[ "$llm_budget_google_usd" =~ ^[0-9]+$ ]]; then
  llm_budget_google_usd=35
fi
if ! [[ "$llm_budget_xai_usd" =~ ^[0-9]+$ ]]; then
  llm_budget_xai_usd=35
fi
if ! [[ "$other_paid_cost_budget_usd" =~ ^[0-9]+$ ]]; then
  other_paid_cost_budget_usd=10
fi
if (( skills_max_files < 1 )); then skills_max_files=1; fi
if (( skills_max_lines < 1 )); then skills_max_lines=1; fi
if (( skills_max_chars < 2000 )); then skills_max_chars=2000; fi
if (( kickoff_pack_max_lines < 40 )); then kickoff_pack_max_lines=40; fi

default_task_text="Define your own implementation task from the selected title."
default_evidence_text="commit hash + changed files + simulation/test command output path"
default_next_action_text="implement on branch \`agent/<agent>\`, then request reviewed PR."
if [[ "$feedback_only_mode" == "true" ]]; then
  default_task_text="Provide structured feedback on current project progress, gaps, and next-priority improvements."
  default_evidence_text="feedback note path + reviewed repo paths/commits + rationale summary"
  default_next_action_text="review latest main-aligned state and post one concrete feedback update."
fi

summary_rel_file=""
summary_commit_hash=""
summary_merge_status="disabled"

summary_fail_or_warn() {
  local msg="$1"
  if [[ "$leader_cycle_summary_required" == "true" ]]; then
    die "$msg"
  fi
  log "WARN: $msg"
  return 1
}

notify_telegram_text() {
  local text="$1"
  local token="${TELEGRAM_BOT_TOKEN:-}"
  local allowed_chat_ids="${TELEGRAM_ALLOWED_CHAT_IDS:-}"
  local cid payload
  local IFS=','

  [[ -n "$token" ]] || return 0
  [[ -n "$allowed_chat_ids" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  for cid in $allowed_chat_ids; do
    cid="$(printf '%s' "$cid" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$cid" ]] || continue
    payload="$(jq -n --arg chat_id "$cid" --arg text "$text" '{chat_id:$chat_id, text:$text, disable_web_page_preview:true}')"
    curl -sS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
      -H 'content-type: application/json' \
      --data "$payload" >/dev/null 2>&1 || true
  done
}

sync_agent_branches() {
  [[ "$sync_agent_branches_from_main" == "true" ]] || {
    log "Agent branch sync disabled (SYNC_AGENT_BRANCHES_FROM_MAIN=false)"
    return 0
  }

  local sync_errors=0
  local agent repo branch
  for agent in "${AGENTS[@]}"; do
    ensure_not_emergency_stopped
    ensure_no_pending_human_approvals

    repo="$(agent_workdir "$agent")"
    branch="agent/$agent"
    if [[ ! -d "$repo/.git" ]]; then
      log "WARN: Missing git repo for $agent: $repo"
      sync_errors=$((sync_errors + 1))
      continue
    fi
    if ! git -C "$repo" diff --quiet --ignore-submodules -- || \
       ! git -C "$repo" diff --cached --quiet --ignore-submodules --; then
      log "WARN: Repo has tracked uncommitted changes, skip auto-sync for $agent: $repo"
      sync_errors=$((sync_errors + 1))
      continue
    fi
    if ! git -C "$repo" fetch origin --prune >/dev/null 2>&1; then
      log "WARN: Failed to fetch origin in $repo"
      sync_errors=$((sync_errors + 1))
      continue
    fi

    if git -C "$repo" rev-parse --verify "$branch" >/dev/null 2>&1; then
      git -C "$repo" checkout "$branch" >/dev/null 2>&1 || {
        log "WARN: Failed to checkout branch '$branch' in $repo"
        sync_errors=$((sync_errors + 1))
        continue
      }
    elif git -C "$repo" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
      git -C "$repo" checkout -B "$branch" "origin/$branch" >/dev/null 2>&1 || {
        log "WARN: Failed to create local '$branch' from origin/$branch in $repo"
        sync_errors=$((sync_errors + 1))
        continue
      }
    elif git -C "$repo" rev-parse --verify "origin/main" >/dev/null 2>&1; then
      git -C "$repo" checkout -B "$branch" "origin/main" >/dev/null 2>&1 || {
        log "WARN: Failed to create '$branch' from origin/main in $repo"
        sync_errors=$((sync_errors + 1))
        continue
      }
    else
      log "WARN: origin/main not found for $repo"
      sync_errors=$((sync_errors + 1))
      continue
    fi

    if ! git -C "$repo" merge --ff-only origin/main >/dev/null 2>&1; then
      log "WARN: Cannot fast-forward '$branch' to origin/main in $repo"
      sync_errors=$((sync_errors + 1))
      continue
    fi
    log "Synced $agent branch '$branch' with latest origin/main"
  done

  if (( sync_errors > 0 )); then
    if [[ "$sync_agent_branches_required" == "true" ]]; then
      die "Agent branch sync completed with ${sync_errors} issue(s). Resolve and rerun cycle."
    fi
    log "WARN: Agent branch sync completed with ${sync_errors} issue(s)"
  fi
}

build_cycle_comments_bundle() {
  local bundle=""
  local f rel
  if [[ ! -d "$cycle_dir/comments" ]]; then
    printf '%s\n' "(no comment artifacts found)"
    return 0
  fi
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    rel="$f"
    if [[ "$f" == "$cycle_dir/"* ]]; then
      rel="${f#$cycle_dir/}"
    fi
    bundle+=$'\n\n'
    bundle+="## ${rel}\n"
    bundle+="$(cat "$f")"
  done < <(find "$cycle_dir/comments" -type f -name '*.md' | sort)

  if [[ -z "$bundle" ]]; then
    bundle="(no comment artifacts found)"
  fi
  printf '%s\n' "$bundle"
}

publish_leader_cycle_summary() {
  summary_rel_file=""
  summary_commit_hash=""
  summary_merge_status="disabled"
  [[ "$leader_cycle_summary_enabled" == "true" ]] || return 0

  local leader_repo summary_branch summary_abs_file comments_bundle
  leader_repo="$(agent_workdir "$leader")"
  if [[ ! -d "$leader_repo/.git" ]]; then
    leader_repo="$planning_repo"
  fi
  [[ -d "$leader_repo/.git" ]] || summary_fail_or_warn "Leader summary repo is not a git repo: $leader_repo" || return 1

  if ! git -C "$leader_repo" diff --quiet --ignore-submodules -- || \
     ! git -C "$leader_repo" diff --cached --quiet --ignore-submodules --; then
    summary_fail_or_warn "Leader repo has tracked uncommitted changes, cannot auto-merge summary: $leader_repo" || return 1
  fi
  if ! git -C "$leader_repo" fetch origin --prune >/dev/null 2>&1; then
    summary_fail_or_warn "Failed to fetch origin in leader repo: $leader_repo" || return 1
  fi
  if ! git -C "$leader_repo" rev-parse --verify origin/main >/dev/null 2>&1; then
    summary_fail_or_warn "origin/main not found in leader repo: $leader_repo" || return 1
  fi

  summary_branch="${leader_cycle_summary_push_branch_prefix}-${cycle_id}"
  if ! git -C "$leader_repo" checkout -B "$summary_branch" origin/main >/dev/null 2>&1; then
    summary_fail_or_warn "Failed to prepare summary branch '$summary_branch' from origin/main" || return 1
  fi

  mkdir -p "$leader_repo/$leader_cycle_summary_dir"
  summary_rel_file="$leader_cycle_summary_dir/${cycle_id}.md"
  summary_abs_file="$leader_repo/$summary_rel_file"
  comments_bundle="$(build_cycle_comments_bundle)"

  summary_prompt="You are leader '$leader' writing the final cycle summary markdown.
Cycle: $cycle_id
Mode: $cycle_mode
Selected title: $(jq -r '.selected_title // "n/a"' "$decision_json")
Selected track: $(jq -r '.selected_track // "n/a"' "$decision_json")
Feedback-only mode: $feedback_only_mode

Decision JSON:
$(cat "$decision_json")

Team discussion comments:
$comments_bundle

Return concise markdown with sections:
1) Cycle objective
2) Final decisions
3) Agent feedback highlights (gpt/claude/gemini/grok)
4) Open risks and blockers
5) Next cycle trigger conditions (what human command should request next cycle)"

  if ! agent_prompt "$leader" "$summary_prompt" > "$summary_abs_file"; then
    cat > "$summary_abs_file" <<FALLBACK
# Cycle Summary ($cycle_id)

- mode: $cycle_mode
- selected_title: $(jq -r '.selected_title // "n/a"' "$decision_json")
- selected_track: $(jq -r '.selected_track // "n/a"' "$decision_json")
- feedback_only_mode: $feedback_only_mode

## Final Decision

$(jq -r '.reason // "n/a"' "$decision_json")

## Agent Task Split

$(jq -r '.task_split | to_entries[] | "- \(.key): \(.value)"' "$decision_json")

## Next Cycle Focus

$(jq -r '.next_cycle_focus // "n/a"' "$decision_json")
FALLBACK
  fi
  "$SELF_DIR/scan-secrets.sh" --file "$summary_abs_file"

  git -C "$leader_repo" add -- "$summary_rel_file"
  if git -C "$leader_repo" diff --cached --quiet -- "$summary_rel_file"; then
    summary_merge_status="no_changes"
    summary_commit_hash="$(git -C "$leader_repo" rev-parse --short HEAD 2>/dev/null || true)"
    return 0
  fi

  if ! git -C "$leader_repo" commit -m "[autonomy][$cycle_id] docs: cycle summary" >/dev/null 2>&1; then
    summary_fail_or_warn "Failed to commit leader cycle summary in $leader_repo" || return 1
  fi
  summary_commit_hash="$(git -C "$leader_repo" rev-parse --short HEAD)"

  if ! git -C "$leader_repo" push origin "$summary_branch" >/dev/null 2>&1; then
    summary_fail_or_warn "Failed to push summary branch '$summary_branch'" || return 1
  fi

  if [[ "$leader_cycle_summary_auto_merge_main" == "true" ]]; then
    if ! git -C "$leader_repo" checkout main >/dev/null 2>&1; then
      if ! git -C "$leader_repo" checkout -B main origin/main >/dev/null 2>&1; then
        summary_fail_or_warn "Failed to checkout main in $leader_repo" || return 1
      fi
    fi
    if ! git -C "$leader_repo" pull --ff-only origin main >/dev/null 2>&1; then
      summary_fail_or_warn "Failed to fast-forward local main from origin/main in $leader_repo" || return 1
    fi
    if ! git -C "$leader_repo" merge --ff-only "$summary_branch" >/dev/null 2>&1; then
      summary_fail_or_warn "Failed to fast-forward merge '$summary_branch' into main" || return 1
    fi
    if ! git -C "$leader_repo" push origin main >/dev/null 2>&1; then
      summary_fail_or_warn "Failed to push merged main after summary commit" || return 1
    fi
    summary_merge_status="merged_main"
    summary_commit_hash="$(git -C "$leader_repo" rev-parse --short HEAD)"
  else
    summary_merge_status="pushed_branch_only"
  fi

  if [[ "$leader_cycle_summary_notify_telegram" == "true" ]]; then
    notify_telegram_text "[cycle-summary] cycle=${cycle_id}\nfile=${summary_rel_file}\nstatus=${summary_merge_status}\ncommit=${summary_commit_hash}"
  fi
}

extract_kickoff_field() {
  local file="$1"
  local key="$2"
  grep -E "^${key}:" "$file" | tail -n1 | cut -d: -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

kickoff_pack_file="$planning_repo/coordination/KICKOFF_PACK.md"
kickoff_pack_context_file="$cycle_dir/kickoff-pack-context.md"
kickoff_pack_available=false
kickoff_status=""
kickoff_topic_id=""
kickoff_topic_title=""
kickoff_track=""
if [[ -f "$kickoff_pack_file" ]]; then
  kickoff_pack_available=true
  sed -n "1,${kickoff_pack_max_lines}p" "$kickoff_pack_file" > "$kickoff_pack_context_file"
  kickoff_status="$(extract_kickoff_field "$kickoff_pack_file" "KICKOFF_STATUS" || true)"
  kickoff_topic_id="$(extract_kickoff_field "$kickoff_pack_file" "TOPIC_ID" || true)"
  kickoff_topic_title="$(extract_kickoff_field "$kickoff_pack_file" "TOPIC_TITLE" || true)"
  kickoff_track="$(extract_kickoff_field "$kickoff_pack_file" "TRACK" || true)"
else
  printf '(KICKOFF_PACK.md not found at %s)\n' "$kickoff_pack_file" > "$kickoff_pack_context_file"
fi

ai_stack_docs_context_file="$cycle_dir/ai-stack-docs-context.md"
cat > "$ai_stack_docs_context_file" <<'DOCS'
# Extended AI Stack References (official docs)

- ElizaOS: https://eliza.how/docs/intro
- Rig (Rust LLM framework): https://docs.rig.rs/
- EZKL (zkML): https://docs.ezkl.xyz/
- Giza Orion: https://docs.gizatech.xyz/
- FinRL: https://finrl.readthedocs.io/en/latest/
- Chronos (time-series foundation model): https://github.com/amazon-science/chronos-forecasting
- LangGraph: https://langchain-ai.github.io/langgraph/
- vLLM: https://docs.vllm.ai/
DOCS

infra_cost_constraints_file="$cycle_dir/infra-cost-constraints.md"
cat > "$infra_cost_constraints_file" <<COST
# Infra / Cost Constraints

- One single server can be used without hard cap (CPU/GPU/RAM scale-up allowed).
- Tenderly plan: ${tenderly_plan} (fixed paid infra allowed).
- LLM API budget cap per provider (USD):
  - OpenAI / GPT: <= ${llm_budget_openai_usd}
  - Anthropic / Claude: <= ${llm_budget_anthropic_usd}
  - Google / Gemini: <= ${llm_budget_google_usd}
  - xAI / Grok: <= ${llm_budget_xai_usd}
- Other paid costs must be free or kept around 10 USD or less (max ${other_paid_cost_budget_usd} USD).
- Prefer local-first architecture: self-hosted models/runtime/tooling (for example vLLM + open-source frameworks).
- Every proposal must explicitly state how it fits these budget caps.
COST

plan_ready=false
if [[ -f "$cycle_plan_file" ]] && \
   jq -e '
     ((.project.selected_title // "") | type == "string" and (length > 0)) and
     ((.project.selected_track // "") | type == "string" and (length > 0))
   ' "$cycle_plan_file" >/dev/null 2>&1; then
  plan_ready=true
fi

latest_decision_file=""
if [[ -d "$STATE_DIR/cycles" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    latest_decision_file="$f"
  done < <(find "$STATE_DIR/cycles" -mindepth 2 -maxdepth 2 -type f -name 'decision.json' | sort)
fi

cycle_mode="$cycle_mode_requested"
if [[ "$cycle_mode" == "auto" ]]; then
  if [[ "$plan_ready" == "true" ]]; then
    cycle_mode="execution"
  else
    cycle_mode="kickoff"
  fi
fi
case "$cycle_mode" in
  kickoff|execution) ;;
  *)
    die "Invalid cycle mode: $cycle_mode (allowed: auto|kickoff|execution)"
    ;;
esac

sync_agent_branches

project_title=""
project_track=""
project_reason=""
project_onchain_write=""
project_simulation=""
if [[ "$plan_ready" == "true" ]]; then
  project_title="$(jq -r '.project.selected_title // ""' "$cycle_plan_file")"
  project_track="$(jq -r '.project.selected_track // ""' "$cycle_plan_file")"
  project_reason="$(jq -r '.project.reason // ""' "$cycle_plan_file")"
  project_onchain_write="$(jq -r '.project.onchain_write // ""' "$cycle_plan_file")"
  project_simulation="$(jq -r '.project.simulation // ""' "$cycle_plan_file")"
elif [[ -n "$latest_decision_file" ]]; then
  project_title="$(jq -r '.selected_title // ""' "$latest_decision_file")"
  project_track="$(jq -r '.selected_track // ""' "$latest_decision_file")"
  project_reason="$(jq -r '.reason // ""' "$latest_decision_file")"
  project_onchain_write="$(jq -r '.onchain_write // ""' "$latest_decision_file")"
  project_simulation="$(jq -r '.simulation // ""' "$latest_decision_file")"
fi

if [[ "$cycle_mode" == "execution" ]] && [[ -z "$project_title" || -z "$project_track" ]]; then
  die "Execution cycle requested but no prior kickoff plan/decision found. Run one kickoff cycle first."
fi

previous_cycle_context_file="$cycle_dir/previous-cycle-context.md"
: > "$previous_cycle_context_file"
printf '# Previous Cycle Context\n\n' >> "$previous_cycle_context_file"
if [[ "$cycle_mode" == "execution" ]]; then
  printf -- '- project_title: %s\n' "$project_title" >> "$previous_cycle_context_file"
  printf -- '- project_track: %s\n' "$project_track" >> "$previous_cycle_context_file"
  [[ -n "$project_reason" ]] && printf -- '- project_reason: %s\n' "$project_reason" >> "$previous_cycle_context_file"
  [[ -n "$project_onchain_write" ]] && printf -- '- project_onchain_write: %s\n' "$project_onchain_write" >> "$previous_cycle_context_file"
  [[ -n "$project_simulation" ]] && printf -- '- project_simulation: %s\n' "$project_simulation" >> "$previous_cycle_context_file"
  printf '\n## Recent cycles (latest %s)\n' "$history_cycles" >> "$previous_cycle_context_file"

  mapfile -t recent_cycle_dirs < <(find "$STATE_DIR/cycles" -mindepth 1 -maxdepth 1 -type d -name 'cycle_*' | sort | tail -n "$history_cycles")
  for cyc in "${recent_cycle_dirs[@]}"; do
    dfile="$cyc/decision.json"
    [[ -f "$dfile" ]] || continue
    cid="$(basename "$cyc")"
    title="$(jq -r '.selected_title // ""' "$dfile")"
    track="$(jq -r '.selected_track // ""' "$dfile")"
    reason="$(jq -r '.reason // ""' "$dfile" | tr '\n' ' ' | cut -c1-240)"
    next_focus="$(jq -r '.next_cycle_focus // ""' "$dfile" | tr '\n' ' ' | cut -c1-220)"
    printf '\n### %s\n' "$cid" >> "$previous_cycle_context_file"
    printf -- '- title: %s\n' "$title" >> "$previous_cycle_context_file"
    printf -- '- track: %s\n' "$track" >> "$previous_cycle_context_file"
    [[ -n "$reason" ]] && printf -- '- reason: %s\n' "$reason" >> "$previous_cycle_context_file"
    [[ -n "$next_focus" ]] && printf -- '- next_cycle_focus: %s\n' "$next_focus" >> "$previous_cycle_context_file"
  done

  printf '\n## Branch progress snapshot\n' >> "$previous_cycle_context_file"
  for agent in "${AGENTS[@]}"; do
    repo="$(agent_workdir "$agent")"
    branch="agent/$agent"
    printf '\n### %s\n' "$agent" >> "$previous_cycle_context_file"
    if git -C "$repo" rev-parse --verify "$branch" >/dev/null 2>&1; then
      commits="$(git -C "$repo" log --oneline -n 4 "$branch" 2>/dev/null || true)"
      diffstat="$(git -C "$repo" diff --shortstat "origin/main...$branch" 2>/dev/null || true)"
      if [[ -n "$commits" ]]; then
        printf 'recent_commits:\n%s\n' "$commits" >> "$previous_cycle_context_file"
      else
        printf 'recent_commits: (none)\n' >> "$previous_cycle_context_file"
      fi
      [[ -n "$diffstat" ]] && printf 'diffstat_vs_origin_main: %s\n' "$diffstat" >> "$previous_cycle_context_file"
    else
      printf 'branch_not_found: %s\n' "$branch" >> "$previous_cycle_context_file"
    fi
  done
else
  printf 'kickoff cycle: no previous project context required.\n' >> "$previous_cycle_context_file"
fi

skills_file_candidates="$cycle_dir/skills-file-candidates.txt"
{
  [[ -f "$skills_dir/README.md" ]] && printf '%s\n' "$skills_dir/README.md"
  [[ -f "$skills_dir/cre-skills/SKILL.md" ]] && printf '%s\n' "$skills_dir/cre-skills/SKILL.md"
  [[ -f "$skills_dir/cre-skills/assets/cre-docs-index.md" ]] && printf '%s\n' "$skills_dir/cre-skills/assets/cre-docs-index.md"
  if [[ -d "$skills_refs_dir" ]]; then
    find "$skills_refs_dir" -maxdepth 1 -type f -name '*.md' | sort
  fi
} | sort -u > "$skills_file_candidates"

mapfile -t skill_files < <(sed -n "1,${skills_max_files}p" "$skills_file_candidates")
[[ ${#skill_files[@]} -gt 0 ]] || die "No skill markdown files found under: $skills_dir"

skills_index_file="$cycle_dir/skills-index.md"
skills_context_file="$cycle_dir/skills-context.md"
: > "$skills_index_file"
: > "$skills_context_file"
printf '# Local skills context files\n\n' >> "$skills_index_file"

for file in "${skill_files[@]}"; do
  [[ -f "$file" ]] || continue
  rel="$file"
  if [[ "$file" == "$ROOT_DIR/"* ]]; then
    rel="${file#$ROOT_DIR/}"
  fi
  printf -- '- %s\n' "$rel" >> "$skills_index_file"

  file_lines="$(wc -l < "$file" | tr -d '[:space:]')"
  if ! [[ "$file_lines" =~ ^[0-9]+$ ]]; then
    file_lines=0
  fi

  {
    printf '### %s\n' "$rel"
    sed -n "1,${skills_max_lines}p" "$file"
    if (( file_lines > skills_max_lines )); then
      printf '\n[truncated: showing first %s of %s lines]\n' "$skills_max_lines" "$file_lines"
    fi
    printf '\n'
  } >> "$skills_context_file"
done

skills_context_bytes="$(wc -c < "$skills_context_file" | tr -d '[:space:]')"
if [[ "$skills_context_bytes" =~ ^[0-9]+$ ]] && (( skills_context_bytes > skills_max_chars )); then
  tmp_skills_context="$cycle_dir/skills-context.trimmed.md"
  head -c "$skills_max_chars" "$skills_context_file" > "$tmp_skills_context"
  printf '\n\n[truncated: context capped at %s chars]\n' "$skills_max_chars" >> "$tmp_skills_context"
  mv "$tmp_skills_context" "$skills_context_file"
fi

log "Starting cycle: $cycle_id"
log "Cycle mode: $cycle_mode (requested=$cycle_mode_requested)"
log "Leader agent: $leader"
log "Feedback-only mode: $feedback_only_mode"
log "Skills context root: $skills_dir"
log "Skills context files used: ${#skill_files[@]}"
if [[ "$kickoff_pack_available" == "true" ]]; then
  log "Kickoff pack context: $kickoff_pack_file"
else
  log "Kickoff pack context missing (optional): $kickoff_pack_file"
fi
if [[ "$cycle_mode" == "execution" ]]; then
  log "Execution project identity: title='$project_title' track='$project_track'"
fi

if ! wait_for_agent_services "${AGENT_SERVICES_READY_TIMEOUT_SECONDS:-60}" 3; then
  die "OpenClaw containers are not in running state. Check: docker compose ps && docker compose logs --tail=80 openclaw-gpt openclaw-claude openclaw-gemini openclaw-grok"
fi

if [[ "${AUTO_MOLTBOOK_KICKOFF_DISCUSSION:-true}" == "true" ]] && [[ "${AUTO_POST_TO_MOLTBOOK:-false}" == "true" ]]; then
  repo_for_kickoff="$planning_repo"
  if ! "$SELF_DIR/publish-kickoff-discussion.sh" --repo "$repo_for_kickoff" >/tmp/kickoff_discussion.out 2>/tmp/kickoff_discussion.err; then
    log "Kickoff Moltbook discussion skipped/failed: $(tr '\n' ' ' </tmp/kickoff_discussion.err | cut -c1-300)"
  else
    log "Kickoff Moltbook discussion published: $(cat /tmp/kickoff_discussion.out)"
  fi
  rm -f /tmp/kickoff_discussion.out /tmp/kickoff_discussion.err || true
fi

# 1) Proposals
for agent in "${AGENTS[@]}"; do
  ensure_not_emergency_stopped
  ensure_no_pending_human_approvals
  if [[ "$cycle_mode" == "kickoff" ]]; then
    prompt="You are agent '$agent' planning a Chainlink CRE hackathon project kickoff.
Use local skill files from this workspace as context.
Reference root:
- $skills_dir
Selected files:
$(cat "$skills_index_file")

Reference excerpts:
$(cat "$skills_context_file")

Constraints:
- virtual testnet development only
- no mainnet or real funds
- never reveal secrets
- prioritize creative, non-obvious system design (not a trivial variant)
- explicitly surface known track failure modes and concrete mitigations
- consider Tenderly Virtual Networks and World ID as optional enablers; if skipped, explain why
- enforce infra/cost rule: single-server scale is allowed, Tenderly plan is '${tenderly_plan}', and each LLM API provider stays within its USD cap
- feedback_only_mode=${feedback_only_mode}; when true, propose review/feedback tasks only (no direct code edits)
Kickoff pack metadata:
- status: ${kickoff_status:-unknown}
- topic_id: ${kickoff_topic_id:-n/a}
- topic_title: ${kickoff_topic_title:-n/a}
- track_hint: ${kickoff_track:-n/a}

Kickoff pack excerpt (source of truth when available):
$(cat "$kickoff_pack_context_file")

Extended AI stack docs to consider:
$(cat "$ai_stack_docs_context_file")

Infra/cost constraints (mandatory):
$(cat "$infra_cost_constraints_file")

Return concise markdown with:
1. Candidate Title (aligned with locked topic when provided)
2. Problem + baseline limitation in existing approaches
3. Novel system mechanism (what is truly different)
4. Track failure modes + mitigations
5. Why CRE orchestration is required
6. Optional enablers fit: Tenderly Virtual Networks / World ID (use or skip + reason)
7. On-chain write plan (testnet)
8. Simulation plan (cre simulate / tenderly simulation if relevant)
9. MVP scope for 1 week + evidence checklist"
  else
    prompt="You are agent '$agent' continuing a multi-cycle project execution.
Project identity is fixed for this cycle:
- title: $project_title
- track: $project_track

Use local skill files from this workspace as context.
Reference root:
- $skills_dir
Selected files:
$(cat "$skills_index_file")

Reference excerpts:
$(cat "$skills_context_file")

Previous cycle context:
$(cat "$previous_cycle_context_file")

Constraints:
- virtual testnet development only
- no mainnet or real funds
- never reveal secrets
- do not propose a new project title/track
- keep improving novelty, robustness, and evaluation quality from previous cycles
- reassess whether Tenderly Virtual Networks and World ID should be adopted this cycle
- enforce infra/cost rule: single-server scale is allowed, Tenderly plan is '${tenderly_plan}', and each LLM API provider stays within its USD cap
- feedback_only_mode=${feedback_only_mode}; when true, focus on review/advice scope and avoid code-edit tasks

Kickoff pack excerpt:
$(cat "$kickoff_pack_context_file")

Extended AI stack docs to consider:
$(cat "$ai_stack_docs_context_file")

Infra/cost constraints (mandatory):
$(cat "$infra_cost_constraints_file")

Return concise markdown with:
1. Progress since last cycle
2. Requirements analysis for next iteration
3. What to focus in this cycle (specific scope; review/advice if feedback_only_mode=true)
4. Novel design improvement for this cycle
5. Risks/blockers and mitigations
6. Optional enabler update (Tenderly VN / World ID)
7. Suggested task refinement for your role
8. Evidence artifact to produce this cycle"
  fi

  out="$cycle_dir/proposals/$agent.md"
  if agent_prompt "$agent" "$prompt" > "$out"; then
    "$SELF_DIR/scan-secrets.sh" --file "$out"
    log "Proposal saved: $out"

    if [[ "${AUTO_POST_TO_MOLTBOOK:-false}" == "true" ]] && [[ "$single_thread_mode" != "true" ]]; then
      "$SELF_DIR/safe-moltbook-post.sh" "$agent" "$submolt" "[$cycle_id] proposal from $agent" "$out" >/dev/null || true
    fi
  else
    printf '# %s\n\nFailed to generate proposal.\n' "$agent" > "$out"
    log "Proposal failed for $agent"
  fi
done

# 2) Decision synthesis by leader agent
all_proposals=""
for agent in "${AGENTS[@]}"; do
  all_proposals+=$'\n\n'
  all_proposals+="## $agent\n"
  all_proposals+="$(cat "$cycle_dir/proposals/$agent.md")"
done

if [[ "$cycle_mode" == "kickoff" ]]; then
  decision_prompt="You are the coordinator and leader agent '$leader'.
Given the kickoff proposals below, select ONE final project.
Prioritize originality, concrete risk mitigation, and demonstrable evidence plan.
Tenderly Virtual Networks and World ID are optional; include them if they materially improve safety or evaluation quality.
Return ONLY JSON:
{
  \"selected_title\": \"...\",
  \"selected_track\": \"track label string\",
  \"reason\": \"...\",
  \"innovation_summary\": \"what is genuinely new vs baseline\",
  \"onchain_write\": \"...\",
  \"simulation\": \"...\",
  \"failure_modes_and_mitigations\": [
    {
      \"risk\": \"...\",
      \"mitigation\": \"...\",
      \"owner\": \"gpt|claude|gemini|grok\"
    }
  ],
  \"optional_enablers\": {
    \"tenderly_virtual_networks\": {
      \"use\": true,
      \"reason\": \"...\",
      \"implementation_note\": \"...\"
    },
    \"world_id\": {
      \"use\": false,
      \"reason\": \"...\",
      \"implementation_note\": \"...\"
    }
  },
  \"cost_plan\": {
    \"tenderly_plan\": \"${tenderly_plan}\",
    \"llm_api_budget_usd\": {
      \"openai_gpt\": ${llm_budget_openai_usd},
      \"anthropic_claude\": ${llm_budget_anthropic_usd},
      \"google_gemini\": ${llm_budget_google_usd},
      \"xai_grok\": ${llm_budget_xai_usd}
    },
    \"other_paid_cost_budget_usd_max\": ${other_paid_cost_budget_usd},
    \"single_server_strategy\": \"how to use one server effectively\",
    \"paid_api_budget_policy\": \"explain how api usage stays under the per-provider caps\",
    \"local_first_components\": [\"vLLM\", \"LangGraph\", \"...\"]
  },
  \"task_split\": {
    \"gpt\": \"...\",
    \"claude\": \"...\",
    \"gemini\": \"...\",
    \"grok\": \"...\"
  },
  \"review_assignments\": {
    \"gpt\": \"claude|gemini|grok\",
    \"claude\": \"gpt|gemini|grok\",
    \"gemini\": \"gpt|claude|grok\",
    \"grok\": \"gpt|claude|gemini\"
  },
  \"evidence_plan\": {
    \"gpt\": \"concrete artifact path/command/output\",
    \"claude\": \"concrete artifact path/command/output\",
    \"gemini\": \"concrete artifact path/command/output\",
    \"grok\": \"concrete artifact path/command/output\"
  },
  \"requirements_analysis\": \"...\",
  \"next_cycle_focus\": \"...\"
}

Rule:
- If feedback_only_mode=${feedback_only_mode}, task_split must contain review/analysis/advice responsibilities only (no code implementation tasks).

Kickoff pack metadata:
- status: ${kickoff_status:-unknown}
- topic_id: ${kickoff_topic_id:-n/a}
- topic_title: ${kickoff_topic_title:-n/a}
- track_hint: ${kickoff_track:-n/a}
Kickoff pack excerpt:
$(cat "$kickoff_pack_context_file")

Extended AI stack docs:
$(cat "$ai_stack_docs_context_file")

Infra/cost constraints:
$(cat "$infra_cost_constraints_file")

Proposals:
$all_proposals"
else
  decision_prompt="You are the coordinator and leader agent '$leader'.
This is an execution cycle. Continue the SAME project identity.
Fixed project identity:
- selected_title: $project_title
- selected_track: $project_track

Use previous-cycle context and current agent proposals to produce the next execution plan.
Return ONLY JSON:
{
  \"selected_title\": \"$project_title\",
  \"selected_track\": \"$project_track\",
  \"reason\": \"updated rationale for this iteration\",
  \"innovation_summary\": \"what new capability/robustness is added this cycle\",
  \"onchain_write\": \"what on-chain/testnet write is planned this cycle\",
  \"simulation\": \"what simulation/test validation will be run this cycle\",
  \"failure_modes_and_mitigations\": [
    {
      \"risk\": \"...\",
      \"mitigation\": \"...\",
      \"owner\": \"gpt|claude|gemini|grok\"
    }
  ],
  \"optional_enablers\": {
    \"tenderly_virtual_networks\": {
      \"use\": true,
      \"reason\": \"...\",
      \"implementation_note\": \"...\"
    },
    \"world_id\": {
      \"use\": false,
      \"reason\": \"...\",
      \"implementation_note\": \"...\"
    }
  },
  \"cost_plan\": {
    \"tenderly_plan\": \"${tenderly_plan}\",
    \"llm_api_budget_usd\": {
      \"openai_gpt\": ${llm_budget_openai_usd},
      \"anthropic_claude\": ${llm_budget_anthropic_usd},
      \"google_gemini\": ${llm_budget_google_usd},
      \"xai_grok\": ${llm_budget_xai_usd}
    },
    \"other_paid_cost_budget_usd_max\": ${other_paid_cost_budget_usd},
    \"single_server_strategy\": \"how to use one server effectively\",
    \"paid_api_budget_policy\": \"explain how api usage stays under the per-provider caps\",
    \"local_first_components\": [\"vLLM\", \"LangGraph\", \"...\"]
  },
  \"requirements_analysis\": \"requirements derived from prior progress and gaps\",
  \"next_cycle_focus\": \"what should be prioritized in the following cycle\",
  \"task_split\": {
    \"gpt\": \"...\",
    \"claude\": \"...\",
    \"gemini\": \"...\",
    \"grok\": \"...\"
  },
  \"review_assignments\": {
    \"gpt\": \"claude|gemini|grok\",
    \"claude\": \"gpt|gemini|grok\",
    \"gemini\": \"gpt|claude|grok\",
    \"grok\": \"gpt|claude|gemini\"
  },
  \"evidence_plan\": {
    \"gpt\": \"concrete artifact path/command/output\",
    \"claude\": \"concrete artifact path/command/output\",
    \"gemini\": \"concrete artifact path/command/output\",
    \"grok\": \"concrete artifact path/command/output\"
  }
}

Rules:
- Do not change selected_title or selected_track.
- Task split must reflect next executable requirements, not a fresh ideation.
- If feedback_only_mode=${feedback_only_mode}, task_split must be review/analysis/advice responsibilities only (no code implementation tasks).
- Re-evaluate Tenderly Virtual Networks and World ID decisions based on current blockers/evidence needs.
- Keep Tenderly on '${tenderly_plan}', keep each LLM provider under its USD cap, and keep other paid costs under the USD cap.

Previous cycle context:
$(cat "$previous_cycle_context_file")

Kickoff pack excerpt:
$(cat "$kickoff_pack_context_file")

Extended AI stack docs:
$(cat "$ai_stack_docs_context_file")

Infra/cost constraints:
$(cat "$infra_cost_constraints_file")

Agent proposals:
$all_proposals"
fi

decision_raw="$cycle_dir/decision.raw.txt"
decision_json="$cycle_dir/decision.json"
decision_candidate="$cycle_dir/decision.candidate.json"

is_transient_decision_error() {
  local text="$1"
  if [[ "$text" =~ [Rr]ate[[:space:]-]limit ]] || \
     [[ "$text" =~ [Tt]oo[[:space:]]many[[:space:]]requests ]] || \
     [[ "$text" =~ [Tt]ry[[:space:]]again[[:space:]]later ]] || \
     [[ "$text" =~ [Qq]uota[[:space:]]exceeded|insufficient_quota ]] || \
     [[ "$text" =~ [Oo]verloaded|[Ss]ervice[[:space:]]unavailable ]] || \
     [[ "$text" =~ [Gg]ateway_not_ready|fetch[[:space:]]failed|connection[[:space:]]refused ]] || \
     [[ "$text" =~ (^|[^0-9])(429|500|502|503)([^0-9]|$) ]]; then
    return 0
  fi
  return 1
}

validate_decision_json() {
  local file="$1"
  jq -e '
    (.selected_title // "" | type == "string") and
    (.selected_track // "" | type == "string") and
    (.reason // "" | type == "string") and
    (.onchain_write // "" | type == "string") and
    (.simulation // "" | type == "string") and
    (.task_split | type == "object") and
    ((.task_split.gpt // "") | type == "string" and test("\\S")) and
    ((.task_split.claude // "") | type == "string" and test("\\S")) and
    ((.task_split.gemini // "") | type == "string" and test("\\S")) and
    ((.task_split.grok // "") | type == "string" and test("\\S"))
  ' "$file" >/dev/null 2>&1
}

review_assignments_valid() {
  local file="$1"
  jq -e '
    (.review_assignments | type == "object") and
    ((.review_assignments.gpt // "") | type == "string" and test("^(gpt|claude|gemini|grok)$")) and
    ((.review_assignments.claude // "") | type == "string" and test("^(gpt|claude|gemini|grok)$")) and
    ((.review_assignments.gemini // "") | type == "string" and test("^(gpt|claude|gemini|grok)$")) and
    ((.review_assignments.grok // "") | type == "string" and test("^(gpt|claude|gemini|grok)$")) and
    (.review_assignments.gpt != "gpt") and
    (.review_assignments.claude != "claude") and
    (.review_assignments.gemini != "gemini") and
    (.review_assignments.grok != "grok") and
    ([.review_assignments.gpt, .review_assignments.claude, .review_assignments.gemini, .review_assignments.grok] | unique | length == 4)
  ' "$file" >/dev/null 2>&1
}

normalize_task_text() {
  local text="$1"
  text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ')"
  printf '%s\n' "$text" | xargs
}

decision_has_duplicate_tasks() {
  local file="$1"
  local agent task norm
  declare -A seen=()
  for agent in "${AGENTS[@]}"; do
    task="$(jq -r --arg a "$agent" '.task_split[$a] // ""' "$file")"
    norm="$(normalize_task_text "$task")"
    if [[ -z "$norm" ]]; then
      return 0
    fi
    if [[ -n "${seen[$norm]:-}" ]]; then
      return 0
    fi
    seen["$norm"]="$agent"
  done
  return 1
}

decision_duplicate_report() {
  local file="$1"
  local agent task norm
  declare -A seen=()
  declare -A task_text_by_agent=()
  for agent in "${AGENTS[@]}"; do
    task="$(jq -r --arg a "$agent" '.task_split[$a] // ""' "$file")"
    task_text_by_agent["$agent"]="$task"
    norm="$(normalize_task_text "$task")"
    if [[ -z "$norm" ]]; then
      printf -- '- %s has an empty or invalid task.\n' "$agent"
      continue
    fi
    if [[ -n "${seen[$norm]:-}" ]]; then
      printf -- '- %s overlaps with %s\n' "$agent" "${seen[$norm]}"
      printf '  task: %s\n' "${task_text_by_agent[$agent]}"
      printf '  overlap_task: %s\n' "${task_text_by_agent[${seen[$norm]}]}"
    else
      seen["$norm"]="$agent"
    fi
  done
}

apply_reviewer_defaults() {
  local file="$1"
  if review_assignments_valid "$file"; then
    return 0
  fi

  local count="${#AGENTS[@]}"
  local seed offset
  seed="$(printf '%s' "$cycle_id" | cksum | awk '{print $1}')"
  offset=$((seed % (count - 1) + 1))

  local reviewer_gpt reviewer_claude reviewer_gemini reviewer_grok
  reviewer_gpt="${AGENTS[$(((0 + offset) % count))]}"
  reviewer_claude="${AGENTS[$(((1 + offset) % count))]}"
  reviewer_gemini="${AGENTS[$(((2 + offset) % count))]}"
  reviewer_grok="${AGENTS[$(((3 + offset) % count))]}"

  local tmp="${file}.reviewers.tmp"
  jq \
    --arg rgpt "$reviewer_gpt" \
    --arg rclaude "$reviewer_claude" \
    --arg rgemini "$reviewer_gemini" \
    --arg rgrok "$reviewer_grok" \
    '
      .review_assignments = {
        gpt: $rgpt,
        claude: $rclaude,
        gemini: $rgemini,
        grok: $rgrok
      }
    ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

enrich_decision_json() {
  local file="$1"
  apply_reviewer_defaults "$file"

  local tmp="${file}.enriched.tmp"
  jq \
    --arg tenderly_plan_default "$tenderly_plan" \
    --arg evidence_default "$default_evidence_text" \
    --argjson openai_budget_default "$llm_budget_openai_usd" \
    --argjson anthropic_budget_default "$llm_budget_anthropic_usd" \
    --argjson google_budget_default "$llm_budget_google_usd" \
    --argjson xai_budget_default "$llm_budget_xai_usd" \
    --argjson other_budget_default "$other_paid_cost_budget_usd" \
    '
    .evidence_plan = ((.evidence_plan // {}) as $e | {
      gpt: ((($e.gpt // "") | tostring | gsub("^\\s+|\\s+$"; "")) as $v | if $v == "" then $evidence_default else $v end),
      claude: ((($e.claude // "") | tostring | gsub("^\\s+|\\s+$"; "")) as $v | if $v == "" then $evidence_default else $v end),
      gemini: ((($e.gemini // "") | tostring | gsub("^\\s+|\\s+$"; "")) as $v | if $v == "" then $evidence_default else $v end),
      grok: ((($e.grok // "") | tostring | gsub("^\\s+|\\s+$"; "")) as $v | if $v == "" then $evidence_default else $v end)
    })
    | .innovation_summary = (((.innovation_summary // .reason // "") | tostring | gsub("^\\s+|\\s+$"; "")))
    | .failure_modes_and_mitigations = (
        if (.failure_modes_and_mitigations | type) == "array" then
          [
            .failure_modes_and_mitigations[]?
            | select(type == "object")
            | {
                risk: ((.risk // "") | tostring | gsub("^\\s+|\\s+$"; "")),
                mitigation: ((.mitigation // "") | tostring | gsub("^\\s+|\\s+$"; "")),
                owner: ((.owner // "") | tostring | gsub("^\\s+|\\s+$"; ""))
              }
            | select((.risk != "") or (.mitigation != ""))
          ]
        else
          []
        end
      )
    | .optional_enablers = ((.optional_enablers // {}) as $o | {
        tenderly_virtual_networks: ((($o.tenderly_virtual_networks // {}) as $t | {
          use: (((($t.use // false) | tostring | ascii_downcase) == "true")),
          reason: ((($t.reason // "") | tostring | gsub("^\\s+|\\s+$"; ""))),
          implementation_note: ((($t.implementation_note // "") | tostring | gsub("^\\s+|\\s+$"; "")))
        })),
        world_id: ((($o.world_id // {}) as $w | {
          use: (((($w.use // false) | tostring | ascii_downcase) == "true")),
          reason: ((($w.reason // "") | tostring | gsub("^\\s+|\\s+$"; ""))),
          implementation_note: ((($w.implementation_note // "") | tostring | gsub("^\\s+|\\s+$"; "")))
        }))
      })
    | .cost_plan = ((.cost_plan // {}) as $c | {
        tenderly_plan: ((($c.tenderly_plan // "") | tostring | gsub("^\\s+|\\s+$"; ""))),
        llm_api_budget_usd: (
          if ($c.llm_api_budget_usd | type) == "object" then
            {
              openai_gpt: (($c.llm_api_budget_usd.openai_gpt // 0) | tonumber? // 0),
              anthropic_claude: (($c.llm_api_budget_usd.anthropic_claude // 0) | tonumber? // 0),
              google_gemini: (($c.llm_api_budget_usd.google_gemini // 0) | tonumber? // 0),
              xai_grok: (($c.llm_api_budget_usd.xai_grok // 0) | tonumber? // 0)
            }
          else
            {}
          end
        ),
        other_paid_cost_budget_usd_max: (($c.other_paid_cost_budget_usd_max // 0) | tonumber? // 0),
        single_server_strategy: ((($c.single_server_strategy // "") | tostring | gsub("^\\s+|\\s+$"; ""))),
        paid_api_budget_policy: ((($c.paid_api_budget_policy // "") | tostring | gsub("^\\s+|\\s+$"; ""))),
        local_first_components: (
          if ($c.local_first_components | type) == "array" then
            [ $c.local_first_components[]? | tostring | gsub("^\\s+|\\s+$"; "") | select(. != "") ]
          else
            []
          end
        )
      })
    | .cost_plan.tenderly_plan = (
        if .cost_plan.tenderly_plan == "" then
          $tenderly_plan_default
        else
          .cost_plan.tenderly_plan
        end
      )
    | .cost_plan.llm_api_budget_usd = {
        openai_gpt: (if (.cost_plan.llm_api_budget_usd.openai_gpt // 0) > 0 then .cost_plan.llm_api_budget_usd.openai_gpt else $openai_budget_default end),
        anthropic_claude: (if (.cost_plan.llm_api_budget_usd.anthropic_claude // 0) > 0 then .cost_plan.llm_api_budget_usd.anthropic_claude else $anthropic_budget_default end),
        google_gemini: (if (.cost_plan.llm_api_budget_usd.google_gemini // 0) > 0 then .cost_plan.llm_api_budget_usd.google_gemini else $google_budget_default end),
        xai_grok: (if (.cost_plan.llm_api_budget_usd.xai_grok // 0) > 0 then .cost_plan.llm_api_budget_usd.xai_grok else $xai_budget_default end)
      }
    | .cost_plan.other_paid_cost_budget_usd_max = (
        if (.cost_plan.other_paid_cost_budget_usd_max // 0) > 0 then
          .cost_plan.other_paid_cost_budget_usd_max
        else
          $other_budget_default
        end
      )
    | .cost_plan.single_server_strategy = (
        if .cost_plan.single_server_strategy == "" then
          "Use one scalable server (CPU/GPU) for core orchestration and inference workloads."
        else
          .cost_plan.single_server_strategy
        end
      )
    | .cost_plan.paid_api_budget_policy = (
        if .cost_plan.paid_api_budget_policy == "" then
          "Use Tenderly Pro. Keep OpenAI/Anthropic/Google/xAI each within the USD cap and keep other paid costs within the USD cap."
        else
          .cost_plan.paid_api_budget_policy
        end
      )
    | .cost_plan.local_first_components = (
        if (.cost_plan.local_first_components | length) == 0 then
          ["vLLM", "LangGraph", "open-source local tools"]
        else
          .cost_plan.local_first_components
        end
      )
    | .optional_enablers.tenderly_virtual_networks.reason = (
        if .optional_enablers.tenderly_virtual_networks.reason == "" then
          (if .optional_enablers.tenderly_virtual_networks.use then
            "Use Tenderly Virtual Networks for deterministic integration testing and reproducible simulations."
          else
            "Optional for this cycle; defer unless simulation/debug isolation is required."
          end)
        else
          .optional_enablers.tenderly_virtual_networks.reason
        end
      )
    | .optional_enablers.world_id.reason = (
        if .optional_enablers.world_id.reason == "" then
          (if .optional_enablers.world_id.use then
            "Use World ID where human-proof gating materially reduces Sybil/automation abuse risk."
          else
            "Optional for this cycle; defer unless strong human-proof gating is required."
          end)
        else
          .optional_enablers.world_id.reason
        end
      )
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

extract_json_candidate() {
  local raw="$1"
  local extracted

  extracted="$(awk '
    /^```json[[:space:]]*$/ {inblock=1; next}
    /^```[[:space:]]*$/ {if (inblock) exit}
    {if (inblock) print}
  ' "$raw")"
  if [[ -n "$extracted" ]]; then
    printf '%s\n' "$extracted"
    return 0
  fi

  extracted="$(awk '
    /^```/ {
      fence_count++;
      if (fence_count == 1) {inblock=1; next}
      if (fence_count == 2) exit
    }
    {if (inblock) print}
  ' "$raw")"
  if [[ -n "$extracted" ]]; then
    printf '%s\n' "$extracted"
    return 0
  fi

  cat "$raw"
}

decision_retries="${DECISION_RETRIES:-3}"
decision_retry_sleep="${DECISION_RETRY_SLEEP_SECONDS:-8}"
decision_allow_fallback="${DECISION_FALLBACK_TO_OTHER_AGENTS:-true}"

decision_agents=("$leader")
if [[ "$decision_allow_fallback" == "true" ]]; then
  for a in "${AGENTS[@]}"; do
    [[ "$a" == "$leader" ]] && continue
    decision_agents+=("$a")
  done
fi

decision_ok=false
decision_agent_used=""
decision_fail_note=""

for da in "${decision_agents[@]}"; do
  for ((attempt = 1; attempt <= decision_retries; attempt++)); do
    ensure_not_emergency_stopped
    ensure_no_pending_human_approvals

    attempt_raw="$cycle_dir/decision.${da}.attempt${attempt}.raw.txt"
    if decision_response="$(agent_prompt "$da" "$decision_prompt" 2>&1)"; then
      printf '%s\n' "$decision_response" > "$attempt_raw"
      cp "$attempt_raw" "$decision_raw"
      extract_json_candidate "$decision_raw" > "$decision_candidate"
      if jq -e . "$decision_candidate" > "$decision_json" 2>/dev/null && validate_decision_json "$decision_json"; then
        decision_ok=true
        decision_agent_used="$da"
        break 2
      fi
      decision_fail_note="non_json_or_invalid_schema"
      if is_transient_decision_error "$decision_response"; then
        decision_fail_note="transient_rate_limit_or_provider_error"
        log "Decision transient issue from $da (attempt $attempt/$decision_retries). Retrying in ${decision_retry_sleep}s..."
        sleep "$decision_retry_sleep"
        continue
      fi
      break
    else
      printf '%s\n' "$decision_response" > "$attempt_raw"
      cp "$attempt_raw" "$decision_raw"
      decision_fail_note="agent_prompt_failed"
      if is_transient_decision_error "$decision_response"; then
        decision_fail_note="transient_rate_limit_or_provider_error"
        log "Decision prompt transient failure from $da (attempt $attempt/$decision_retries). Retrying in ${decision_retry_sleep}s..."
        sleep "$decision_retry_sleep"
        continue
      fi
      break
    fi
  done
done

if [[ "$decision_ok" == "true" ]]; then
  if [[ "$cycle_mode" == "execution" ]]; then
    tmp_enforced="$decision_json.enforced.tmp"
    jq \
      --arg title "$project_title" \
      --arg track "$project_track" \
      '.selected_title = $title | .selected_track = $track' \
      "$decision_json" > "$tmp_enforced"
    mv "$tmp_enforced" "$decision_json"
  fi

  enrich_decision_json "$decision_json"
  "$SELF_DIR/scan-secrets.sh" --file "$decision_json"
  if [[ "$decision_agent_used" != "$leader" ]]; then
    log "Decision JSON saved via fallback agent: $decision_agent_used"
  else
    log "Decision JSON saved: $decision_json"
  fi
else
  if [[ "${AUTO_REQUEST_ON_BLOCKER:-true}" == "true" ]]; then
    detail="$(tr '\n' ' ' < "$decision_raw" | sed 's/[[:space:]]\+/ /g' | cut -c1-700)"
    "$SELF_DIR/request-human-approval.sh" \
      --reason "decision_generation_failed" \
      --context "run_cycle:decision" \
      --command "./scripts/autonomy/run-cycle.sh --execution" \
      --detail "note=${decision_fail_note}; detail=${detail}" >/dev/null 2>&1 || true
  fi
  cp "$decision_raw" "$cycle_dir/decision.txt" || true
  die "Decision generation failed or non-JSON output: $decision_raw"
fi

task_rebalance_retries="${TASK_REBALANCE_RETRIES:-2}"
if decision_has_duplicate_tasks "$decision_json"; then
  decision_duplicate_report "$decision_json" > "$cycle_dir/task-overlap.txt"
  log "Detected overlapping task assignments. Triggering leader rebalance."

  rebalanced=false
  for ((attempt = 1; attempt <= task_rebalance_retries; attempt++)); do
    ensure_not_emergency_stopped
    ensure_no_pending_human_approvals
    rebalance_prompt="You are leader '$leader'. The current task assignment has overlap and must be rebalanced.
Return ONLY JSON with this schema:
{
  \"selected_title\": \"...\",
  \"selected_track\": \"track label string\",
  \"reason\": \"...\",
  \"innovation_summary\": \"...\",
  \"onchain_write\": \"...\",
  \"simulation\": \"...\",
  \"failure_modes_and_mitigations\": [
    {
      \"risk\": \"...\",
      \"mitigation\": \"...\",
      \"owner\": \"gpt|claude|gemini|grok\"
    }
  ],
  \"optional_enablers\": {
    \"tenderly_virtual_networks\": {
      \"use\": true,
      \"reason\": \"...\",
      \"implementation_note\": \"...\"
    },
    \"world_id\": {
      \"use\": false,
      \"reason\": \"...\",
      \"implementation_note\": \"...\"
    }
  },
  \"cost_plan\": {
    \"tenderly_plan\": \"${tenderly_plan}\",
    \"llm_api_budget_usd\": {
      \"openai_gpt\": ${llm_budget_openai_usd},
      \"anthropic_claude\": ${llm_budget_anthropic_usd},
      \"google_gemini\": ${llm_budget_google_usd},
      \"xai_grok\": ${llm_budget_xai_usd}
    },
    \"other_paid_cost_budget_usd_max\": ${other_paid_cost_budget_usd},
    \"single_server_strategy\": \"...\",
    \"paid_api_budget_policy\": \"...\",
    \"local_first_components\": [\"vLLM\", \"LangGraph\", \"...\"]
  },
  \"task_split\": {
    \"gpt\": \"...\",
    \"claude\": \"...\",
    \"gemini\": \"...\",
    \"grok\": \"...\"
  },
  \"review_assignments\": {
    \"gpt\": \"claude|gemini|grok\",
    \"claude\": \"gpt|gemini|grok\",
    \"gemini\": \"gpt|claude|grok\",
    \"grok\": \"gpt|claude|gemini\"
  },
  \"evidence_plan\": {
    \"gpt\": \"concrete artifact path/command/output\",
    \"claude\": \"concrete artifact path/command/output\",
    \"gemini\": \"concrete artifact path/command/output\",
    \"grok\": \"concrete artifact path/command/output\"
  }
}

Rules:
- Keep same selected_title/selected_track unless impossible.
- task_split must be distinct and non-overlapping.
- If feedback_only_mode=${feedback_only_mode}, task_split must be review/analysis/advice-oriented (no implementation tasks).
- Each task must have exactly one owner and one reviewer.
- Reviewer must not be the same as owner.
- Each reviewer must be unique across the 4 tasks.
- Evidence plans must be concrete and testable.
- Keep optional enabler decisions coherent with current cycle goals.
- Keep Tenderly on '${tenderly_plan}', keep each LLM provider under its USD cap, and keep other paid costs under the USD cap.

Current decision JSON:
$(cat "$decision_json")

Overlap report:
$(cat "$cycle_dir/task-overlap.txt")"

    rebalance_raw="$cycle_dir/decision.rebalance.attempt${attempt}.raw.txt"
    if rebalance_response="$(agent_prompt "$leader" "$rebalance_prompt" 2>&1)"; then
      printf '%s\n' "$rebalance_response" > "$rebalance_raw"
      extract_json_candidate "$rebalance_raw" > "$decision_candidate"
      if jq -e . "$decision_candidate" > "$decision_json" 2>/dev/null && validate_decision_json "$decision_json"; then
        enrich_decision_json "$decision_json"
        if ! decision_has_duplicate_tasks "$decision_json"; then
          "$SELF_DIR/scan-secrets.sh" --file "$decision_json"
          rebalanced=true
          break
        fi
      fi
    else
      printf '%s\n' "$rebalance_response" > "$rebalance_raw"
      if is_transient_decision_error "$rebalance_response"; then
        log "Task rebalance transient issue (attempt $attempt/$task_rebalance_retries). Retrying in ${decision_retry_sleep}s..."
        sleep "$decision_retry_sleep"
        continue
      fi
    fi

    decision_duplicate_report "$decision_json" > "$cycle_dir/task-overlap.txt" || true
  done

  if [[ "$rebalanced" != "true" ]]; then
    if [[ "${AUTO_REQUEST_ON_BLOCKER:-true}" == "true" ]]; then
      detail="$(tr '\n' ' ' < "$cycle_dir/task-overlap.txt" | sed 's/[[:space:]]\+/ /g' | cut -c1-700)"
      "$SELF_DIR/request-human-approval.sh" \
        --reason "task_rebalance_failed" \
        --context "run_cycle:task_split" \
        --command "./scripts/autonomy/run-cycle.sh --execution" \
        --detail "overlap=${detail}" >/dev/null 2>&1 || true
    fi
    die "Task split remains overlapping after rebalance attempts: $cycle_dir/task-overlap.txt"
  fi

  log "Task split rebalanced successfully."
fi

project_title_cycle="$(jq -r '.selected_title // ""' "$decision_json")"
project_track_cycle="$(jq -r '.selected_track // ""' "$decision_json")"
project_reason_cycle="$(jq -r '.reason // ""' "$decision_json")"
project_onchain_cycle="$(jq -r '.onchain_write // ""' "$decision_json")"
project_simulation_cycle="$(jq -r '.simulation // ""' "$decision_json")"
requirements_analysis_cycle="$(jq -r '.requirements_analysis // ""' "$decision_json" | tr '\n' ' ' | cut -c1-900)"
next_cycle_focus_cycle="$(jq -r '.next_cycle_focus // ""' "$decision_json" | tr '\n' ' ' | cut -c1-700)"
innovation_summary_cycle="$(jq -r '.innovation_summary // ""' "$decision_json" | tr '\n' ' ' | cut -c1-700)"
tenderly_enabler_cycle="$(jq -c '.optional_enablers.tenderly_virtual_networks // {"use":false,"reason":"","implementation_note":""}' "$decision_json")"
world_id_enabler_cycle="$(jq -c '.optional_enablers.world_id // {"use":false,"reason":"","implementation_note":""}' "$decision_json")"
cost_plan_cycle="$(jq -c '.cost_plan // {"tenderly_plan":"","llm_api_budget_usd":{"openai_gpt":0,"anthropic_claude":0,"google_gemini":0,"xai_grok":0},"other_paid_cost_budget_usd_max":0,"single_server_strategy":"","paid_api_budget_policy":"","local_first_components":[]}' "$decision_json")"
decision_rel_path="$decision_json"
if [[ "$decision_json" == "$ROOT_DIR/"* ]]; then
  decision_rel_path="${decision_json#$ROOT_DIR/}"
fi

plan_src="$cycle_plan_file"
if [[ ! -f "$plan_src" ]]; then
  plan_src="$cycle_dir/cycle-plan.empty.json"
  printf '{}\n' > "$plan_src"
fi
plan_tmp="$cycle_dir/cycle-plan.updated.json"
jq \
  --arg mode "$cycle_mode" \
  --arg cycle_id "$cycle_id" \
  --arg now "$(now_utc)" \
  --arg decision_path "$decision_rel_path" \
  --arg title "$project_title_cycle" \
  --arg track "$project_track_cycle" \
  --arg reason "$project_reason_cycle" \
  --arg onchain "$project_onchain_cycle" \
  --arg simulation "$project_simulation_cycle" \
  --arg req "$requirements_analysis_cycle" \
  --arg focus "$next_cycle_focus_cycle" \
  --arg innovation "$innovation_summary_cycle" \
  --arg kickoff_topic_id "$kickoff_topic_id" \
  --arg kickoff_topic_title "$kickoff_topic_title" \
  --arg kickoff_track "$kickoff_track" \
  --argjson tenderly "$tenderly_enabler_cycle" \
  --argjson worldid "$world_id_enabler_cycle" \
  --argjson costplan "$cost_plan_cycle" \
  '
    .project = (
      if $mode == "kickoff" then
        {
          selected_title: $title,
          selected_track: $track,
          reason: $reason,
          onchain_write: $onchain,
          simulation: $simulation,
          kickoff_topic_id: $kickoff_topic_id,
          kickoff_topic_title: $kickoff_topic_title,
          kickoff_track_hint: $kickoff_track,
          kickoff_cycle_id: $cycle_id,
          kickoff_created_at: $now
        }
      else
        (.project // {
          selected_title: $title,
          selected_track: $track,
          reason: $reason,
          onchain_write: $onchain,
          simulation: $simulation,
          kickoff_topic_id: $kickoff_topic_id,
          kickoff_topic_title: $kickoff_topic_title,
          kickoff_track_hint: $kickoff_track,
          kickoff_cycle_id: $cycle_id,
          kickoff_created_at: $now
        })
      end
    )
    | .latest_cycle = {
      id: $cycle_id,
      mode: $mode,
      decision_path: $decision_path,
      selected_title: $title,
      selected_track: $track,
      requirements_analysis: $req,
      next_cycle_focus: $focus,
      innovation_summary: $innovation,
      optional_enablers: {
        tenderly_virtual_networks: $tenderly,
        world_id: $worldid
      },
      cost_plan: $costplan,
      updated_at: $now
    }
    | .history = ((.history // []) + [{
      id: $cycle_id,
      mode: $mode,
      decision_path: $decision_path,
      next_cycle_focus: $focus,
      updated_at: $now
    }])
    | .history = (if (.history | length) > 50 then .history[-50:] else .history end)
    | .cycle_count = ((.cycle_count // 0) + 1)
    | .updated_at = $now
  ' "$plan_src" > "$plan_tmp"
mv "$plan_tmp" "$cycle_plan_file"
cp "$cycle_plan_file" "$cycle_dir/cycle-plan.json"
log "Cycle plan updated: $cycle_plan_file (mode=$cycle_mode)"

decision_post_id=""
decision_post_url=""

if [[ "${AUTO_POST_TO_MOLTBOOK:-false}" == "true" ]]; then
  if [[ "$single_thread_mode" == "true" ]]; then
    feature_thread_file="$cycle_dir/feature-thread.md"
    {
      printf '# Feature Thread (%s)\n\n' "$cycle_id"
      printf -- '- leader: %s\n' "$leader"
      printf -- '- cycle_mode: %s\n' "$cycle_mode"
      printf -- '- selected_title: %s\n' "$(jq -r '.selected_title' "$decision_json")"
      printf -- '- selected_track: %s\n' "$(jq -r '.selected_track' "$decision_json")"
      printf -- '- source: proposals + consensus synthesis\n\n'
      printf '## Chosen Direction\n\n'
      printf -- '- reason: %s\n' "$(jq -r '.reason' "$decision_json")"
      innovation_line="$(jq -r '.innovation_summary // empty' "$decision_json")"
      if [[ -n "$innovation_line" ]]; then
        printf -- '- innovation_summary: %s\n' "$innovation_line"
      fi
      printf -- '- onchain_write: %s\n' "$(jq -r '.onchain_write' "$decision_json")"
      printf -- '- simulation: %s\n\n' "$(jq -r '.simulation' "$decision_json")"
      req_line="$(jq -r '.requirements_analysis // empty' "$decision_json")"
      next_focus_line="$(jq -r '.next_cycle_focus // empty' "$decision_json")"
      if [[ -n "$req_line" ]]; then
        printf -- '- requirements_analysis: %s\n' "$req_line"
      fi
      if [[ -n "$next_focus_line" ]]; then
        printf -- '- next_cycle_focus: %s\n' "$next_focus_line"
      fi
      printf '\n'
      printf '## Optional Enablers\n\n'
      printf -- '- tenderly_virtual_networks.use: %s\n' "$(jq -r '.optional_enablers.tenderly_virtual_networks.use // false' "$decision_json")"
      printf -- '- tenderly_virtual_networks.reason: %s\n' "$(jq -r '.optional_enablers.tenderly_virtual_networks.reason // "n/a"' "$decision_json")"
      printf -- '- world_id.use: %s\n' "$(jq -r '.optional_enablers.world_id.use // false' "$decision_json")"
      printf -- '- world_id.reason: %s\n\n' "$(jq -r '.optional_enablers.world_id.reason // "n/a"' "$decision_json")"
      printf '## Cost Strategy\n\n'
      printf -- '- tenderly_plan: %s\n' "$(jq -r '.cost_plan.tenderly_plan // "n/a"' "$decision_json")"
      printf -- '- llm_api_budget_usd.openai_gpt: %s\n' "$(jq -r '.cost_plan.llm_api_budget_usd.openai_gpt // 0' "$decision_json")"
      printf -- '- llm_api_budget_usd.anthropic_claude: %s\n' "$(jq -r '.cost_plan.llm_api_budget_usd.anthropic_claude // 0' "$decision_json")"
      printf -- '- llm_api_budget_usd.google_gemini: %s\n' "$(jq -r '.cost_plan.llm_api_budget_usd.google_gemini // 0' "$decision_json")"
      printf -- '- llm_api_budget_usd.xai_grok: %s\n' "$(jq -r '.cost_plan.llm_api_budget_usd.xai_grok // 0' "$decision_json")"
      printf -- '- other_paid_cost_budget_usd_max: %s\n' "$(jq -r '.cost_plan.other_paid_cost_budget_usd_max // 0' "$decision_json")"
      printf -- '- single_server_strategy: %s\n' "$(jq -r '.cost_plan.single_server_strategy // "n/a"' "$decision_json")"
      printf -- '- paid_api_budget_policy: %s\n' "$(jq -r '.cost_plan.paid_api_budget_policy // "n/a"' "$decision_json")"
      local_components="$(jq -r '(.cost_plan.local_first_components // []) | join(", ")' "$decision_json")"
      if [[ -n "$local_components" ]]; then
        printf -- '- local_first_components: %s\n\n' "$local_components"
      else
        printf -- '- local_first_components: n/a\n\n'
      fi
      if jq -e '(.failure_modes_and_mitigations // []) | length > 0' "$decision_json" >/dev/null 2>&1; then
        printf '## Failure Modes & Mitigations\n\n'
        jq -r '
          .failure_modes_and_mitigations[]
          | "- risk: \(.risk // \"\")\n  - mitigation: \(.mitigation // \"\")\n  - owner: \(.owner // \"unassigned\")"
        ' "$decision_json"
        printf '\n'
      fi
      printf '## Initial Task Split\n\n'
      for a in "${AGENTS[@]}"; do
        printf -- '- owner=%s reviewer=%s\n' "$a" "$(jq -r --arg a "$a" '.review_assignments[$a] // "unassigned"' "$decision_json")"
        printf '  - task: %s\n' "$(jq -r --arg a "$a" '.task_split[$a]' "$decision_json")"
        printf '  - evidence: %s\n' "$(jq -r --arg a "$a" --arg fallback "$default_evidence_text" '.evidence_plan[$a] // $fallback' "$decision_json")"
      done
      printf '\n## Discussion Rule\n\n'
      printf 'All agents must reply in comments on this same post with:\n'
      printf '1) agree/concern, 2) one improvement, 3) one dependency request, 4) one evidence artifact.\n'
    } > "$feature_thread_file"
    "$SELF_DIR/scan-secrets.sh" --file "$feature_thread_file"
    decision_title="$(jq -r '.selected_title // "feature"' "$decision_json" | tr '\n' ' ' | cut -c1-80)"
    decision_post_resp="$("$SELF_DIR/safe-moltbook-post.sh" "$leader" "$submolt" "[$cycle_id] feature thread: $decision_title" "$feature_thread_file" 2>/dev/null || true)"
  else
    decision_post_resp="$("$SELF_DIR/safe-moltbook-post.sh" "$leader" "$submolt" "[$cycle_id] final topic decision" "$decision_json" 2>/dev/null || true)"
  fi

  if [[ -n "$decision_post_resp" ]]; then
    printf '%s\n' "$decision_post_resp" > "$cycle_dir/decision-post-response.json"
    decision_post_id="$(jq -r '.post.id // .id // .data.id // .post_id // empty' <<<"$decision_post_resp" 2>/dev/null || true)"
    decision_post_url="$(jq -r '.post.url // .url // .data.url // empty' <<<"$decision_post_resp" 2>/dev/null || true)"
    if [[ -n "$decision_post_id" ]]; then
      if [[ "$single_thread_mode" == "true" ]]; then
        log "Feature thread post published (post_id=$decision_post_id)"
      else
        log "Decision post published (post_id=$decision_post_id)"
      fi
      if [[ -n "$decision_post_url" ]]; then
        log "Decision post url: $decision_post_url"
      fi
    fi
  fi
fi

# 2.5) Leader summary for non-selected topics (kickoff only) + optional git push.
if [[ "$cycle_mode" == "kickoff" ]] && [[ "${ALT_TOPICS_SUMMARY_ENABLED:-true}" == "true" ]]; then
  alt_topics_file="$cycle_dir/alternative-topics.${leader}.md"
  selected_title_for_summary="$(jq -r '.selected_title // "n/a"' "$decision_json")"
  selected_track_for_summary="$(jq -r '.selected_track // "n/a"' "$decision_json")"
  summary_prompt="You are leader '$leader' documenting kickoff outcomes.
Selected topic:
- title: $selected_title_for_summary
- track: $selected_track_for_summary

Produce markdown that summarizes non-selected topic ideas from proposals.
Requirements:
1) keep selected topic short (why selected in <=3 bullets)
2) list alternative topics (title, core idea, why not selected now, when to revisit)
3) include one section: how each alternative can leverage docs from Eliza/Rig/EZKL/Giza Orion/FinRL/Chronos/LangGraph/vLLM
4) include one section: cost fit under single-server + Tenderly '${tenderly_plan}' + per-provider LLM caps + other paid-cost cap
5) include one section: future experiment backlog (3-6 items)

Kickoff pack excerpt:
$(cat "$kickoff_pack_context_file")

Extended AI stack docs:
$(cat "$ai_stack_docs_context_file")

Infra/cost constraints:
$(cat "$infra_cost_constraints_file")

All proposals:
$all_proposals"

  if ! agent_prompt "$leader" "$summary_prompt" > "$alt_topics_file"; then
    {
      printf '# Alternative Topics Summary (%s)\n\n' "$cycle_id"
      printf -- '- leader: %s\n' "$leader"
      printf -- '- selected_title: %s\n' "$selected_title_for_summary"
      printf -- '- selected_track: %s\n\n' "$selected_track_for_summary"
      printf '## Fallback Summary\n\n'
      printf 'Leader summary generation failed. Please review proposal files manually:\n'
      for a in "${AGENTS[@]}"; do
        printf -- '- proposals/%s.md\n' "$a"
      done
    } > "$alt_topics_file"
  fi
  "$SELF_DIR/scan-secrets.sh" --file "$alt_topics_file"
  log "Alternative topics summary saved: $alt_topics_file"

  alt_topics_repo="$(agent_workdir "$leader")"
  if [[ ! -d "$alt_topics_repo/.git" ]]; then
    alt_topics_repo="$planning_repo"
  fi
  alt_topics_dir_rel="${ALT_TOPICS_SUMMARY_DIR:-coordination/topic-alternatives}"
  alt_topics_dest_dir="$alt_topics_repo/$alt_topics_dir_rel"
  mkdir -p "$alt_topics_dest_dir"
  alt_topics_dest_file="$alt_topics_dest_dir/${cycle_id}-alternative-topics.md"
  cp "$alt_topics_file" "$alt_topics_dest_file"
  "$SELF_DIR/scan-secrets.sh" --file "$alt_topics_dest_file"
  log "Alternative topics summary copied to repo: $alt_topics_dest_file"

  if [[ "${ALT_TOPICS_PUSH_ENABLED:-true}" == "true" ]]; then
    ensure_not_emergency_stopped
    ensure_no_pending_human_approvals

    push_branch="${ALT_TOPICS_PUSH_BRANCH:-agent/$leader}"
    current_branch="$(git -C "$alt_topics_repo" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [[ -z "$current_branch" ]]; then
      current_branch="$push_branch"
    fi

    if [[ "$current_branch" != "$push_branch" ]]; then
      if git -C "$alt_topics_repo" rev-parse --verify "$push_branch" >/dev/null 2>&1; then
        git -C "$alt_topics_repo" checkout "$push_branch" >/dev/null 2>&1 || {
          if [[ "${ALT_TOPICS_PUSH_REQUIRED:-true}" == "true" ]]; then
            die "Failed to checkout push branch '$push_branch' in $alt_topics_repo"
          else
            log "WARN: Failed to checkout push branch '$push_branch' in $alt_topics_repo"
          fi
        }
      elif git -C "$alt_topics_repo" rev-parse --verify "origin/$push_branch" >/dev/null 2>&1; then
        git -C "$alt_topics_repo" checkout -B "$push_branch" "origin/$push_branch" >/dev/null 2>&1 || {
          if [[ "${ALT_TOPICS_PUSH_REQUIRED:-true}" == "true" ]]; then
            die "Failed to create local branch '$push_branch' from origin in $alt_topics_repo"
          else
            log "WARN: Failed to create local branch '$push_branch' from origin in $alt_topics_repo"
          fi
        }
      else
        if [[ "${ALT_TOPICS_PUSH_REQUIRED:-true}" == "true" ]]; then
          die "Push branch '$push_branch' not found in $alt_topics_repo"
        else
          log "WARN: Push branch '$push_branch' not found in $alt_topics_repo (skipping push)"
        fi
      fi
    fi

    rel_file_for_git="$alt_topics_dir_rel/${cycle_id}-alternative-topics.md"
    git -C "$alt_topics_repo" add -- "$rel_file_for_git"
    if ! git -C "$alt_topics_repo" diff --cached --quiet -- "$rel_file_for_git"; then
      git -C "$alt_topics_repo" commit -m "[autonomy][$cycle_id] docs: summarize non-selected kickoff topics" >/dev/null 2>&1 || {
        if [[ "${ALT_TOPICS_PUSH_REQUIRED:-true}" == "true" ]]; then
          die "Failed to commit alternative topics summary in $alt_topics_repo"
        else
          log "WARN: Failed to commit alternative topics summary in $alt_topics_repo"
        fi
      }
      git -C "$alt_topics_repo" push origin "$push_branch" >/dev/null 2>&1 || {
        if [[ "${ALT_TOPICS_PUSH_REQUIRED:-true}" == "true" ]]; then
          die "Failed to push alternative topics summary to origin/$push_branch"
        else
          log "WARN: Failed to push alternative topics summary to origin/$push_branch"
        fi
      }
      log "Alternative topics summary pushed: repo=$alt_topics_repo branch=$push_branch file=$rel_file_for_git"
    else
      log "Alternative topics summary unchanged (no commit needed): $rel_file_for_git"
    fi
  fi
fi

# 3) Task files
for agent in "${AGENTS[@]}"; do
  ensure_not_emergency_stopped
  ensure_no_pending_human_approvals
  task="$(jq -r --arg a "$agent" --arg fallback "$default_task_text" '.task_split[$a] // $fallback' "$decision_json")"
  reviewer="$(jq -r --arg a "$agent" '.review_assignments[$a] // "unassigned"' "$decision_json")"
  evidence_plan="$(jq -r --arg a "$agent" --arg fallback "$default_evidence_text" '.evidence_plan[$a] // $fallback' "$decision_json")"
  cat > "$cycle_dir/tasks/$agent.md" <<TASK
# Task for $agent

Cycle: $cycle_id
Leader: $leader
Title: $(jq -r '.selected_title' "$decision_json")
Track: $(jq -r '.selected_track' "$decision_json")
Owner: $agent
Reviewer: $reviewer

Assigned task:
$task

Required evidence artifact:
- $evidence_plan

Optional enabler guidance:
- Tenderly Virtual Networks: use=$(jq -r '.optional_enablers.tenderly_virtual_networks.use // false' "$decision_json"), reason=$(jq -r '.optional_enablers.tenderly_virtual_networks.reason // "n/a"' "$decision_json")
- World ID: use=$(jq -r '.optional_enablers.world_id.use // false' "$decision_json"), reason=$(jq -r '.optional_enablers.world_id.reason // "n/a"' "$decision_json")

Cost constraints:
- tenderly_plan: $(jq -r '.cost_plan.tenderly_plan // "n/a"' "$decision_json")
- llm_api_budget_usd.openai_gpt: $(jq -r '.cost_plan.llm_api_budget_usd.openai_gpt // 0' "$decision_json")
- llm_api_budget_usd.anthropic_claude: $(jq -r '.cost_plan.llm_api_budget_usd.anthropic_claude // 0' "$decision_json")
- llm_api_budget_usd.google_gemini: $(jq -r '.cost_plan.llm_api_budget_usd.google_gemini // 0' "$decision_json")
- llm_api_budget_usd.xai_grok: $(jq -r '.cost_plan.llm_api_budget_usd.xai_grok // 0' "$decision_json")
- other_paid_cost_budget_usd_max: $(jq -r '.cost_plan.other_paid_cost_budget_usd_max // 0' "$decision_json")
- single_server_strategy: $(jq -r '.cost_plan.single_server_strategy // "n/a"' "$decision_json")
- paid_api_budget_policy: $(jq -r '.cost_plan.paid_api_budget_policy // "n/a"' "$decision_json")
- local_first_components: $(jq -r '(.cost_plan.local_first_components // []) | join(", ")' "$decision_json")

Mandatory completion checklist:
- [ ] Keep scope in virtual testnet discussion/planning only.
- [ ] Review current repository state and cite concrete paths/commits.
- [ ] Ensure secret scan passes for generated discussion artifacts.
- [ ] Include one actionable feedback item for the next cycle.
TASK

  "$SELF_DIR/scan-secrets.sh" --file "$cycle_dir/tasks/$agent.md"
done

# 3.5) Optional cycle comments on final decision/feature-thread post (visible multi-agent interaction).
if [[ "${AUTO_POST_TO_MOLTBOOK:-false}" == "true" ]] && \
   [[ "${AUTO_MOLTBOOK_CYCLE_COMMENTS:-true}" == "true" ]] && \
   [[ -n "${decision_post_id:-}" ]]; then
  mkdir -p "$cycle_dir/comments"
  comment_fail=0
  comment_ok=0
  discussion_round_goal="${AUTO_MOLTBOOK_DISCUSSION_ROUNDS:-3}"
  discussion_rounds="$discussion_round_goal"
  discussion_until_consensus="${AUTO_MOLTBOOK_UNTIL_CONSENSUS:-true}"
  discussion_max_rounds="${AUTO_MOLTBOOK_MAX_DISCUSSION_ROUNDS:-12}"
  leader_round_summaries="${AUTO_MOLTBOOK_LEADER_ROUND_SUMMARIES:-true}"
  if ! [[ "$discussion_round_goal" =~ ^[0-9]+$ ]]; then
    discussion_round_goal=3
  fi
  if ! [[ "$discussion_max_rounds" =~ ^[0-9]+$ ]]; then
    discussion_max_rounds=12
  fi
  if (( discussion_round_goal < 1 )); then discussion_round_goal=1; fi
  if (( discussion_round_goal > 40 )); then discussion_round_goal=40; fi
  if (( discussion_max_rounds < discussion_round_goal )); then
    discussion_max_rounds="$discussion_round_goal"
  fi
  if (( discussion_max_rounds > 40 )); then discussion_max_rounds=40; fi

  consensus_reached="false"
  consensus_reason=""
  actual_rounds=0

  build_round_history_bundle() {
    local until_round="$1"
    local bundle=""
    local prev rfile leader_file
    if (( until_round < 1 )); then
      printf '%s\n' "(no previous discussion rounds)"
      return 0
    fi
    for ((prev = 1; prev <= until_round; prev++)); do
      for a in "${AGENTS[@]}"; do
        rfile="$cycle_dir/comments/round-${prev}/${a}.md"
        [[ -f "$rfile" ]] || continue
        bundle+=$'\n\n'
        bundle+="## round-${prev} / ${a}\n"
        bundle+="$(cat "$rfile")"
      done
      leader_file="$cycle_dir/comments/round-${prev}/${leader}-round.md"
      if [[ -f "$leader_file" ]]; then
        bundle+=$'\n\n'
        bundle+="## round-${prev} / ${leader} (checkpoint)\n"
        bundle+="$(cat "$leader_file")"
      fi
    done
    if [[ -z "$bundle" ]]; then
      bundle="(no previous discussion rounds)"
    fi
    printf '%s\n' "$bundle"
  }

  if [[ "$single_thread_mode" == "true" ]]; then
    log "Cycle discussion mode: single-thread (until_consensus=${discussion_until_consensus}, min_rounds=${discussion_round_goal}, max_rounds=${discussion_max_rounds})"
    round=1
    while (( round <= discussion_max_rounds )); do
      round_dir="$cycle_dir/comments/round-${round}"
      mkdir -p "$round_dir"
      history_bundle="$(build_round_history_bundle $((round - 1)))"
      round_ok=0
      round_fail=0

      for agent in "${AGENTS[@]}"; do
        ensure_not_emergency_stopped
        ensure_no_pending_human_approvals
        task_text="$(jq -r --arg a "$agent" --arg fallback "$default_task_text" '.task_split[$a] // $fallback' "$decision_json")"
        reviewer_agent="$(jq -r --arg a "$agent" '.review_assignments[$a] // "unassigned"' "$decision_json")"
        evidence_plan="$(jq -r --arg a "$agent" --arg fallback "$default_evidence_text" '.evidence_plan[$a] // $fallback' "$decision_json")"
        comment_file="$round_dir/${agent}.md"
        discussion_prompt="You are agent '$agent' in a single-thread feature discussion.
Cycle: $cycle_id
Round: $round (min=$discussion_round_goal, max=$discussion_max_rounds)
Selected title: $(jq -r '.selected_title' "$decision_json")
Selected track: $(jq -r '.selected_track' "$decision_json")
Your assigned task: $task_text
Your reviewer: $reviewer_agent
Required evidence artifact: $evidence_plan

Previous discussion history:
$history_bundle

Write one concise markdown team comment (max 140 words).
Must include:
1) your current stance (agree/concern)
2) one concrete update since previous round
3) one dependency request or response to another agent
4) one next action with evidence artifact path/command/output."
        if ! agent_prompt "$agent" "$discussion_prompt" > "$comment_file"; then
          cat > "$comment_file" <<COMMENT
[$cycle_id][$agent][round-$round] discussion

- stance: agree
- update: refined feedback focus and reviewed latest repository state.
- dependency: waiting for an interface or artifact from one teammate.
- next action: produce one concrete evidence artifact for this round.
COMMENT
        fi
        if "$SELF_DIR/safe-moltbook-comment.sh" "$agent" "$decision_post_id" "$comment_file" >"$round_dir/${agent}.json" 2>"$round_dir/${agent}.err"; then
          round_ok=$((round_ok + 1))
          comment_ok=$((comment_ok + 1))
        else
          round_fail=$((round_fail + 1))
          comment_fail=$((comment_fail + 1))
        fi
      done

      if [[ "$leader_round_summaries" == "true" ]]; then
        round_bundle=""
        for a in "${AGENTS[@]}"; do
          round_bundle+=$'\n\n'
          round_bundle+="## ${a}\n"
          round_bundle+="$(cat "$round_dir/${a}.md" 2>/dev/null || true)"
        done
        leader_round_file="$round_dir/${leader}-round.md"
        leader_round_prompt="You are leader '$leader' writing a round checkpoint comment.
Cycle: $cycle_id
Round: $round (min=$discussion_round_goal, max=$discussion_max_rounds)
Title: $(jq -r '.selected_title' "$decision_json")

Based on round comments below, write concise markdown (max 120 words).
Include:
1) one agreed point
2) one unresolved blocker
3) one next-round focus instruction

Round comments:
$round_bundle"
        if ! agent_prompt "$leader" "$leader_round_prompt" > "$leader_round_file"; then
          cat > "$leader_round_file" <<LC
[$cycle_id][$leader][round-$round] checkpoint

- agreed: keep scope focused on one measurable milestone.
- unresolved blocker: dependency handoff timing between agents.
- next-round focus: resolve dependency and post artifact path.
LC
        fi
        if "$SELF_DIR/safe-moltbook-comment.sh" "$leader" "$decision_post_id" "$leader_round_file" >"$round_dir/${leader}-round.json" 2>"$round_dir/${leader}-round.err"; then
          comment_ok=$((comment_ok + 1))
        else
          comment_fail=$((comment_fail + 1))
        fi
      fi

      log "Round $round discussion comments: success=${round_ok}, failed=${round_fail}"
      actual_rounds="$round"

      if [[ "$discussion_until_consensus" == "true" ]]; then
        consensus_bundle="$(build_round_history_bundle "$round")"
        consensus_raw_file="$round_dir/consensus-check.raw.txt"
        consensus_candidate_file="$round_dir/consensus-check.candidate.json"
        consensus_file="$round_dir/consensus-check.json"
        consensus_prompt="You are leader '$leader' evaluating consensus status for the 4-agent thread.
Cycle: $cycle_id
Round: $round
Agents in scope: gpt, claude, gemini, grok
Minimum rounds before closure: $discussion_round_goal
Selected title: $(jq -r '.selected_title' "$decision_json")
Selected track: $(jq -r '.selected_track' "$decision_json")

Return ONLY JSON:
{
  \"consensus_reached\": true|false,
  \"reason\": \"one short sentence\",
  \"remaining_blockers\": [\"...\"],
  \"next_round_focus\": \"...\"
}

Rules:
- Evaluate only the 4 in-scope agents.
- consensus_reached=true only if direction, blockers, and next-step expectations are aligned enough to close this cycle.

Discussion history:
$consensus_bundle"
        if consensus_response="$(agent_prompt "$leader" "$consensus_prompt" 2>&1)"; then
          printf '%s\n' "$consensus_response" > "$consensus_raw_file"
          extract_json_candidate "$consensus_raw_file" > "$consensus_candidate_file"
          if jq -e '(.consensus_reached | type == "boolean") and ((.reason // "") | type == "string")' "$consensus_candidate_file" >/dev/null 2>&1; then
            cp "$consensus_candidate_file" "$consensus_file"
            consensus_reached="$(jq -r '.consensus_reached' "$consensus_file")"
            consensus_reason="$(jq -r '.reason // ""' "$consensus_file" | tr '\n' ' ' | cut -c1-240)"
          else
            consensus_reached="false"
            consensus_reason="invalid_consensus_json"
            jq -n \
              --argjson consensus false \
              --arg reason "$consensus_reason" \
              --arg round "$round" \
              '{consensus_reached:$consensus, reason:$reason, remaining_blockers:[], next_round_focus:("continue round " + $round)}' \
              > "$consensus_file"
          fi
        else
          printf '%s\n' "$consensus_response" > "$consensus_raw_file"
          consensus_reached="false"
          consensus_reason="consensus_prompt_failed"
          jq -n \
            --argjson consensus false \
            --arg reason "$consensus_reason" \
            --arg round "$round" \
            '{consensus_reached:$consensus, reason:$reason, remaining_blockers:[], next_round_focus:("continue round " + $round)}' \
            > "$consensus_file"
        fi

        if (( round >= discussion_round_goal )) && [[ "$consensus_reached" == "true" ]]; then
          log "Consensus reached at round $round: ${consensus_reason:-n/a}"
          break
        fi
      else
        if (( round >= discussion_round_goal )); then
          break
        fi
      fi

      round=$((round + 1))
    done
    discussion_rounds="$actual_rounds"
    if (( discussion_rounds < 1 )); then
      discussion_rounds="$discussion_round_goal"
    fi
  else
    for agent in "${AGENTS[@]}"; do
      ensure_not_emergency_stopped
      ensure_no_pending_human_approvals
      task_text="$(jq -r --arg a "$agent" --arg fallback "$default_task_text" '.task_split[$a] // $fallback' "$decision_json")"
      reviewer_agent="$(jq -r --arg a "$agent" '.review_assignments[$a] // "unassigned"' "$decision_json")"
      evidence_plan="$(jq -r --arg a "$agent" --arg fallback "$default_evidence_text" '.evidence_plan[$a] // $fallback' "$decision_json")"
      comment_file="$cycle_dir/comments/${agent}.md"
      next_action_text="${default_next_action_text//<agent>/$agent}"
      cat > "$comment_file" <<COMMENT
[$cycle_id][$agent] ACK

- assigned_task: $task_text
- reviewer: $reviewer_agent
- next_action: $next_action_text
- evidence_plan: $evidence_plan
COMMENT
      if "$SELF_DIR/safe-moltbook-comment.sh" "$agent" "$decision_post_id" "$comment_file" >"$cycle_dir/comments/${agent}.json" 2>"$cycle_dir/comments/${agent}.err"; then
        comment_ok=$((comment_ok + 1))
      else
        comment_fail=$((comment_fail + 1))
      fi
    done
  fi

  if [[ "$single_thread_mode" == "true" ]] && [[ "$discussion_until_consensus" == "true" ]] && [[ "$consensus_reached" != "true" ]]; then
    log "Consensus not reached within round window (rounds=${discussion_rounds}, max=${discussion_max_rounds}, reason=${consensus_reason:-n/a})"
    if [[ "${AUTO_REQUEST_ON_BLOCKER:-true}" == "true" ]]; then
      "$SELF_DIR/request-human-approval.sh" \
        --reason "discussion_consensus_not_reached" \
        --context "run_cycle:discussion" \
        --command "./scripts/autonomy/run-cycle.sh --execution" \
        --detail "cycle=${cycle_id}; rounds=${discussion_rounds}; reason=${consensus_reason:-unknown}" >/dev/null 2>&1 || true
    fi
  fi

  if [[ "$single_thread_mode" == "true" ]]; then
    leader_consensus_file="$cycle_dir/comments/${leader}-consensus.md"
    comments_bundle="$(build_round_history_bundle "$discussion_rounds")"
    leader_consensus_prompt="You are leader '$leader' finalizing a team comment consensus.
Cycle: $cycle_id
Title: $(jq -r '.selected_title' "$decision_json")
Rounds executed: $discussion_rounds
Consensus reached before close: $consensus_reached
Consensus check reason: ${consensus_reason:-n/a}

Based on agent discussion comments below, write one concise markdown consensus comment (max 140 words).
Must include:
1) agreed improvements (2 bullets max)
2) unresolved risk (1 bullet)
3) final execution order (numbered 3 steps)

Comments:
$comments_bundle"
    if ! agent_prompt "$leader" "$leader_consensus_prompt" > "$leader_consensus_file"; then
      cat > "$leader_consensus_file" <<LC
[$cycle_id][$leader] consensus

- agreed improvements: scope first milestone narrowly, standardize evidence paths.
- unresolved risk: provider/API rate limits can delay cycle completion.
1. finalize interface/contracts
2. complete cross-agent feedback loop and clarify blockers
3. request human trigger for the next cycle when ready
LC
    fi
    if "$SELF_DIR/safe-moltbook-comment.sh" "$leader" "$decision_post_id" "$leader_consensus_file" >"$cycle_dir/comments/${leader}-consensus.json" 2>"$cycle_dir/comments/${leader}-consensus.err"; then
      comment_ok=$((comment_ok + 1))
    else
      comment_fail=$((comment_fail + 1))
    fi
  fi

  if [[ "$comment_fail" -gt 0 ]]; then
    log "Cycle discussion comments: ${comment_ok} success, ${comment_fail} failed (see $cycle_dir/comments/*.err)"
  else
    if [[ "$single_thread_mode" == "true" ]]; then
      expected_comments=$((discussion_rounds * 4 + 1))
      if [[ "$leader_round_summaries" == "true" ]]; then
        expected_comments=$((expected_comments + discussion_rounds))
      fi
      log "Cycle single-thread discussion comments posted: ${comment_ok}/${expected_comments} (${discussion_rounds} rounds + final leader consensus, consensus_reached=${consensus_reached})"
    else
      log "Cycle discussion comments posted for all agents: ${comment_ok}/4"
    fi
  fi
fi

publish_leader_cycle_summary
if [[ "$leader_cycle_summary_enabled" == "true" ]]; then
  if [[ -n "$summary_rel_file" ]]; then
    log "Leader cycle summary saved: $summary_rel_file (status=$summary_merge_status, commit=${summary_commit_hash:-n/a})"
  else
    log "Leader cycle summary did not produce a file path (status=$summary_merge_status)"
  fi
fi

log "Cycle completed: $cycle_id"
printf '%s\n' "$cycle_id"
