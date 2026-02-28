#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 [--repo <path>] [--force]

Publishes one Moltbook kickoff discussion thread (leader post + 4 agent comments)
when KICKOFF_PACK is LOCKED.
USAGE
}

target_repo="${AUTONOMY_REPO_PATH:-$ROOT_DIR/workdirs/gemini}"
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      target_repo="$2"
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd jq
require_cmd docker
require_cmd git

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped

if [[ "${AUTO_POST_TO_MOLTBOOK:-false}" != "true" ]]; then
  die "AUTO_POST_TO_MOLTBOOK is false. Refusing kickoff discussion post."
fi

[[ -d "$target_repo/.git" ]] || die "Not a git repo: $target_repo"

leader="$(leader_agent)"
submolt="${MOLTBOOK_SUBMOLT:-cre-hackaton-rth2608}"
require_main_locked="${MOLTBOOK_REQUIRE_MAIN_LOCKED:-true}"
kickoff_file="$target_repo/coordination/KICKOFF_PACK.md"
[[ -f "$kickoff_file" ]] || die "Missing kickoff file: $kickoff_file"

get_field() {
  local file="$1"
  local key="$2"
  grep -E "^${key}:" "$file" | tail -n1 | cut -d: -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

kickoff_status="$(get_field "$kickoff_file" "KICKOFF_STATUS" || true)"
topic_id="$(get_field "$kickoff_file" "TOPIC_ID" || true)"
topic_title="$(get_field "$kickoff_file" "TOPIC_TITLE" || true)"

[[ -n "$topic_id" ]] || die "TOPIC_ID is empty in $kickoff_file"
if [[ "$kickoff_status" != *"LOCKED"* ]]; then
  die "KICKOFF_STATUS is not LOCKED: $kickoff_status"
fi

if [[ "$require_main_locked" == "true" ]]; then
  main_tmp="$(mktemp)"
  if ! git -C "$target_repo" fetch origin main >/dev/null 2>&1; then
    rm -f "$main_tmp"
    die "Failed to fetch origin/main for kickoff lock verification"
  fi
  if ! git -C "$target_repo" show "origin/main:coordination/KICKOFF_PACK.md" >"$main_tmp" 2>/dev/null; then
    rm -f "$main_tmp"
    die "origin/main does not contain coordination/KICKOFF_PACK.md"
  fi
  main_status="$(get_field "$main_tmp" "KICKOFF_STATUS" || true)"
  main_topic="$(get_field "$main_tmp" "TOPIC_ID" || true)"
  rm -f "$main_tmp"
  if [[ "$main_status" != *"LOCKED"* ]]; then
    die "Kickoff on origin/main is not LOCKED: $main_status"
  fi
  if [[ -n "$main_topic" && "$main_topic" != "$topic_id" ]]; then
    die "Topic mismatch between working tree ($topic_id) and origin/main ($main_topic)"
  fi
fi

topic_slug="$(sed 's/[^A-Za-z0-9._-]/_/g' <<<"$topic_id")"
state_dir="$STATE_DIR/moltbook"
state_file="$state_dir/kickoff_${topic_slug}.json"
mkdir -p "$state_dir"

if [[ -f "$state_file" ]] && [[ "$force" != "true" ]]; then
  if jq -e '.published == true' "$state_file" >/dev/null 2>&1; then
    log "Kickoff discussion already published for topic: $topic_id"
    printf '%s\n' "$state_file"
    exit 0
  fi
fi

if ! wait_for_agent_services "${AGENT_SERVICES_READY_TIMEOUT_SECONDS:-60}" 3; then
  die "OpenClaw containers are not in running state"
fi

run_id="kickoff_discussion_$(stamp)"
run_dir="$state_dir/$run_id"
mkdir -p "$run_dir/comments"

max_lines="${MOLTBOOK_KICKOFF_MAX_LINES:-220}"
kickoff_excerpt_file="$run_dir/kickoff_excerpt.md"
sed -n "1,${max_lines}p" "$kickoff_file" > "$kickoff_excerpt_file"

leader_post_file="$run_dir/leader_post.md"
cat > "$leader_post_file" <<EOF
# Kickoff Discussion

- topic_id: $topic_id
- topic_title: ${topic_title:-n/a}
- kickoff_status: $kickoff_status
- leader: $leader

## Kickoff Excerpt

$(cat "$kickoff_excerpt_file")

## Discussion Goal

All 4 agents should comment with:
1) one risk to address first
2) one concrete implementation step
3) one evidence artifact to produce
EOF

"$SELF_DIR/scan-secrets.sh" --file "$leader_post_file"
post_title="[${topic_id}] kickoff discussion"
post_resp="$("$SELF_DIR/safe-moltbook-post.sh" "$leader" "$submolt" "$post_title" "$leader_post_file")"
printf '%s\n' "$post_resp" > "$run_dir/post-response.json"

post_id="$(jq -r '.post.id // .id // .data.id // .post_id // empty' <<<"$post_resp" 2>/dev/null || true)"
post_url="$(jq -r '.post.url // .url // .data.url // empty' <<<"$post_resp" 2>/dev/null || true)"
[[ -n "$post_id" ]] || die "Could not parse post_id from Moltbook response: $post_resp"

comment_fail=0
for agent in "${AGENTS[@]}"; do
  ensure_not_emergency_stopped
  comment_file="$run_dir/comments/${agent}.md"
  prompt="You are agent '$agent' in kickoff discussion.
Leader agent: $leader
Topic ID: $topic_id
Topic Title: $topic_title

Based on this kickoff excerpt, write one concise comment for Moltbook.
Must include:
1) Primary risk
2) Next concrete step
3) Evidence artifact to produce
4) Proposed role for yourself

Return markdown, max 140 words.

Kickoff excerpt:
$(cat "$kickoff_excerpt_file")"

  if ! agent_prompt "$agent" "$prompt" > "$comment_file"; then
    cat > "$comment_file" <<FALLBACK
Primary risk: requirements drift before submission.
Next concrete step: lock one testnet workflow milestone and assign owner/reviewer.
Evidence artifact: simulation log + tx hash + explorer link.
Proposed role: $agent executes assigned backlog item and publishes evidence.
FALLBACK
  fi

  if "$SELF_DIR/safe-moltbook-comment.sh" "$agent" "$post_id" "$comment_file" > "$run_dir/comments/${agent}.json" 2>"$run_dir/comments/${agent}.err"; then
    :
  else
    comment_fail=$((comment_fail + 1))
  fi
done

jq -n \
  --arg run_id "$run_id" \
  --arg created_at "$(now_utc)" \
  --arg topic_id "$topic_id" \
  --arg topic_title "$topic_title" \
  --arg post_id "$post_id" \
  --arg post_url "$post_url" \
  --arg leader "$leader" \
  --arg submolt "$submolt" \
  --arg kickoff_file "$kickoff_file" \
  --arg run_dir "$run_dir" \
  --argjson comment_fail "$comment_fail" \
  '{
    published:true,
    run_id:$run_id,
    created_at:$created_at,
    topic_id:$topic_id,
    topic_title:$topic_title,
    post_id:$post_id,
    post_url:$post_url,
    leader:$leader,
    submolt:$submolt,
    kickoff_file:$kickoff_file,
    run_dir:$run_dir,
    comment_fail:$comment_fail
  }' > "$state_file"

if [[ "$comment_fail" -gt 0 ]]; then
  log "Kickoff discussion post published but some comments failed: $comment_fail"
else
  log "Kickoff discussion completed with 4 comments."
fi

printf '%s\n' "$state_file"
