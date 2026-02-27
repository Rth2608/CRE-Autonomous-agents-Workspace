#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 <author_agent> [base_branch]

Example:
  $0 claude main
USAGE
}

[[ $# -ge 1 ]] || { usage; exit 1; }

author="$1"
base_branch="${2:-main}"

require_cmd jq
require_cmd git

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped
ensure_no_pending_human_approvals

write_review_failure() {
  local out_file="$1"
  local reviewer="$2"
  local severity="$3"
  local summary="$4"
  local issue="$5"
  local suggestion="$6"

  jq -n \
    --arg reviewer "$reviewer" \
    --arg severity "$severity" \
    --arg summary "$summary" \
    --arg issue "$issue" \
    --arg suggestion "$suggestion" \
    '{
      reviewer: $reviewer,
      decision: "request_changes",
      summary: $summary,
      findings: [
        {
          severity: $severity,
          file: "(n/a)",
          issue: $issue,
          suggestion: $suggestion
        }
      ]
    }' > "$out_file"
}

is_transient_reviewer_error() {
  local text="$1"
  if [[ "$text" =~ [Rr]ate[[:space:]-]limit ]] || \
     [[ "$text" =~ [Tt]oo[[:space:]]many[[:space:]]requests ]] || \
     [[ "$text" =~ [Pp]ermission[[:space:]]denied ]] || \
     [[ "$text" =~ [Ii]nvalid[[:space:]](api[[:space:]]key|x-api-key|credentials?) ]] || \
     [[ "$text" =~ [Uu]nauthorized|[Ff]orbidden ]] || \
     [[ "$text" =~ [Gg]ateway_not_ready|fetch[[:space:]]failed|connection[[:space:]]refused ]] || \
     [[ "$text" =~ (^|[^0-9])(401|403|429|500|502|503)([^0-9]|$) ]]; then
    return 0
  fi
  return 1
}

recover_review_from_text() {
  local out_file="$1"
  local reviewer="$2"
  local text="$3"
  local one_line decision

  one_line="$(printf '%s' "$text" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  decision="$(
    printf '%s\n' "$one_line" \
      | grep -oE '"decision"[[:space:]]*:[[:space:]]*"(approve|request_changes)"' \
      | head -n1 \
      | sed -E 's/.*"(approve|request_changes)".*/\1/'
  )"

  [[ -n "$decision" ]] || return 1

  jq -n \
    --arg reviewer "$reviewer" \
    --arg decision "$decision" \
    --arg summary "Recovered decision from non-strict reviewer JSON output." \
    '{
      reviewer: $reviewer,
      decision: $decision,
      summary: $summary,
      findings: []
    }' > "$out_file"

  return 0
}

extract_json_candidate() {
  local raw="$1"
  local extracted

  # Prefer explicit ```json fenced blocks when present.
  extracted="$(awk '
    /^```json[[:space:]]*$/ {inblock=1; next}
    /^```[[:space:]]*$/ {if (inblock) exit}
    {if (inblock) print}
  ' "$raw")"
  if [[ -n "$extracted" ]]; then
    printf '%s\n' "$extracted"
    return 0
  fi

  # Fallback: any fenced block.
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

case "$author" in
  gpt|claude|gemini|grok) ;;
  *) die "Unknown author agent: $author" ;;
esac

author_repo="$(agent_workdir "$author")"
author_branch="${SOURCE_BRANCH:-agent/$author}"

[[ -d "$author_repo/.git" ]] || die "Not a git repo: $author_repo"

git -C "$author_repo" fetch origin "$base_branch" >/dev/null 2>&1 || true

diff_text="$(git -C "$author_repo" diff --no-color "origin/$base_branch...$author_branch" || true)"
[[ -n "$diff_text" ]] || die "No diff between $author_branch and origin/$base_branch"

max_chars="${MAX_DIFF_CHARS:-30000}"
if [[ ${#diff_text} -gt $max_chars ]]; then
  diff_text="${diff_text:0:max_chars}\n\n[TRUNCATED]"
fi

run_id="review_$(stamp)_${author}"
out_dir="$STATE_DIR/reviews/$run_id"
mkdir -p "$out_dir"

printf '%s\n' "$diff_text" > "$out_dir/diff.patch"

approvals=0
high_count=0
reviewers=()
include_author="${REVIEW_INCLUDE_AUTHOR:-false}"

for agent in "${AGENTS[@]}"; do
  if [[ "$include_author" != "true" ]] && [[ "$agent" == "$author" ]]; then
    continue
  fi
  reviewers+=("$agent")

  prompt="You are acting as a strict code reviewer for branch '$author_branch' against '$base_branch'.
Return ONLY JSON with this schema:
{
  \"reviewer\": \"$agent\",
  \"decision\": \"approve\" | \"request_changes\",
  \"summary\": \"short summary\",
  \"findings\": [
    {\"severity\": \"low\"|\"medium\"|\"high\", \"file\": \"path\", \"issue\": \"text\", \"suggestion\": \"text\"}
  ]
}
Mark decision=request_changes if there are correctness, security, data-loss, or deployment risks.

Diff:
$diff_text"

  raw="$out_dir/${agent}.raw.txt"
  json="$out_dir/${agent}.json"

  if ! response="$(agent_prompt "$agent" "$prompt")"; then
    write_review_failure \
      "$json" \
      "$agent" \
      "medium" \
      "Reviewer call failed" \
      "LLM call failed" \
      "Retry reviewer after fixing model/API connectivity."
    continue
  fi

  printf '%s\n' "$response" > "$raw"
  candidate_json="$out_dir/${agent}.candidate.json.txt"
  extract_json_candidate "$raw" > "$candidate_json"

  # Parse potentially multi-document JSON safely.
  if parsed_docs="$(jq -sc . < "$candidate_json" 2>/dev/null)"; then
    # Accept exactly one JSON object with a string "decision" field.
    if jq -e 'length == 1 and (.[0] | type == "object") and ((.[0].decision? // "") | type == "string")' \
      <<<"$parsed_docs" >/dev/null 2>&1; then
      printf '%s\n' "$parsed_docs" | jq '.[0]' > "$json"
      decision="$(jq -r '.decision // "request_changes"' "$json")"
      highs="$(jq '[.findings[]? | select((.severity // "") == "high")] | length' "$json")"
      if [[ "$decision" == "approve" ]]; then
        approvals=$((approvals + 1))
      fi
      high_count=$((high_count + highs))
    else
      short_raw="$(printf '%s' "$response" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
      if recover_review_from_text "$json" "$agent" "$response"; then
        decision="$(jq -r '.decision // "request_changes"' "$json")"
        if [[ "$decision" == "approve" ]]; then
          approvals=$((approvals + 1))
        fi
        continue
      fi
      sev="high"
      if is_transient_reviewer_error "$short_raw"; then
        sev="medium"
      fi
      write_review_failure \
        "$json" \
        "$agent" \
        "$sev" \
        "Invalid reviewer schema" \
        "Reviewer returned JSON, but not a single object with a decision field: $short_raw" \
        "Fix reviewer API key/model config and retry."
      if [[ "$sev" == "high" ]]; then
        high_count=$((high_count + 1))
      fi
    fi
  else
    short_raw="$(printf '%s' "$response" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
    if recover_review_from_text "$json" "$agent" "$response"; then
      decision="$(jq -r '.decision // "request_changes"' "$json")"
      if [[ "$decision" == "approve" ]]; then
        approvals=$((approvals + 1))
      fi
      continue
    fi
    sev="high"
    if is_transient_reviewer_error "$short_raw"; then
      sev="medium"
    fi
    write_review_failure \
      "$json" \
      "$agent" \
      "$sev" \
      "Invalid JSON response" \
      "Reviewer did not return valid JSON: $short_raw" \
      "Fix reviewer API key/model config and retry."
    if [[ "$sev" == "high" ]]; then
      high_count=$((high_count + 1))
    fi
  fi
done

min_approvals="${REVIEW_MIN_APPROVALS:-2}"
block_on_high="${REVIEW_BLOCK_ON_HIGH:-true}"

pass=true
reason=""
if (( approvals < min_approvals )); then
  pass=false
  reason="Not enough approvals: $approvals/$min_approvals"
fi

if [[ "$block_on_high" == "true" ]] && (( high_count > 0 )); then
  pass=false
  if [[ -n "$reason" ]]; then
    reason="$reason; high severity findings: $high_count"
  else
    reason="High severity findings: $high_count"
  fi
fi

summary="$out_dir/summary.json"
jq -n \
  --arg author "$author" \
  --arg branch "$author_branch" \
  --arg base "$base_branch" \
  --arg run_id "$run_id" \
  --argjson approvals "$approvals" \
  --argjson min_approvals "$min_approvals" \
  --argjson high_count "$high_count" \
  --arg pass "$pass" \
  --arg reason "$reason" \
  '{author:$author, branch:$branch, base:$base, run_id:$run_id, approvals:$approvals, min_approvals:$min_approvals, high_count:$high_count, pass:($pass=="true"), reason:$reason}' > "$summary"

cat "$summary"

if [[ "$pass" == "true" ]]; then
  exit 0
fi

exit 2
