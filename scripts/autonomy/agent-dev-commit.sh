#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 <agent> <task_file>

Runs one autonomous coding attempt:
- prompts the selected agent for a unified diff
- applies patch to that agent workdir
- secret-scan on staged changes
- commits if safe
USAGE
}

[[ $# -eq 2 ]] || { usage; exit 1; }

require_cmd git
require_cmd jq

agent="$1"
task_file="$2"

[[ -f "$task_file" ]] || die "Task file not found: $task_file"

load_autonomy_config
ensure_virtual_mode
ensure_not_emergency_stopped
ensure_no_pending_human_approvals

repo="$(agent_workdir "$agent")"
branch="${SOURCE_BRANCH:-agent/$agent}"

[[ -d "$repo/.git" ]] || die "Not a git repo: $repo"

# Stay on agent branch.
current_branch="$(git -C "$repo" symbolic-ref --short HEAD)"
if [[ "$current_branch" != "$branch" ]]; then
  git -C "$repo" checkout "$branch" >/dev/null 2>&1 || die "Cannot checkout $branch"
fi

task="$(cat "$task_file")"
run_id="dev_$(stamp)_$agent"
out_dir="$STATE_DIR/dev/$run_id"
mkdir -p "$out_dir"

prompt_base="You are coding autonomously in branch '$branch'.
Return ONLY a unified diff patch (no markdown fences, no explanation).
Constraints:
- Allowed paths: agents/, src/, workflows/, docs/, coordination/
- Do not modify secrets or credentials files.
- Do not include API keys, private keys, tokens, or seed phrases.
- Use virtual testnet assumptions only.
- If a file already exists, modify it (do not mark it as a new file).

Task:
$task"

extract_patch() {
  local src="$1"
  local dst="$2"

  if grep -nE '^```diff' "$src" >/dev/null 2>&1; then
    awk '
      /^```diff/ {inblock=1; next}
      /^```/ {if (inblock) exit}
      {if (inblock) print}
    ' "$src" > "$dst"
    return 0
  fi

  if grep -nE '^diff --git ' "$src" >/dev/null 2>&1; then
    awk '
      /^diff --git / {inpatch=1}
      {if (inpatch) print}
    ' "$src" > "$dst"
    return 0
  fi

  cat "$src" > "$dst"
}

ensure_diff_headers() {
  local src="$1"
  local dst="$2"
  # If headers already exist, keep as-is.
  if grep -nE '^diff --git ' "$src" >/dev/null 2>&1; then
    cp "$src" "$dst"
    return 0
  fi

  # Add diff --git headers for legacy patches that only include ---/+++ pairs.
  awk '
    function strip_prefix(p) {
      gsub(/^a\//, "", p)
      gsub(/^b\//, "", p)
      return p
    }
    {
      if ($0 ~ /^--- /) {
        oldline = $0
        if (getline nextline > 0) {
          if (nextline ~ /^\+\+\+ /) {
            oldp = substr(oldline, 5)
            newp = substr(nextline, 5)
            oldn = strip_prefix(oldp)
            newn = strip_prefix(newp)
            if (oldp == "/dev/null") oldn = newn
            if (newp == "/dev/null") newn = oldn
            if (oldn != "" && newn != "") {
              print "diff --git a/" oldn " b/" newn
            }
            print oldline
            print nextline
            next
          }
          print oldline
          print nextline
          next
        }
        print oldline
        next
      }
      print
    }
  ' "$src" > "$dst"
}

sanitize_patch() {
  local src="$1"
  local dst="$2"
  awk '
    BEGIN { in_hunk=0 }
    /^diff --git / { in_hunk=0; print; next }
    /^@@ / { in_hunk=1; print; next }
    /^--- / || /^\+\+\+ / { in_hunk=0; print; next }
    {
      if (in_hunk && $0 !~ /^[- +\\]/) {
        print "+" $0
      } else {
        print
      }
    }
  ' "$src" > "$dst"
}

build_file_snapshots() {
  local patch="$1"
  local out="$2"
  : > "$out"

  mapfile -t files < <(
    {
      awk '/^diff --git /{print $3; print $4}' "$patch"
      awk '/^\+\+\+ /{print $2}' "$patch"
      awk '/^--- /{print $2}' "$patch"
    } | sed 's#^[ab]/##' | sed 's#"##g' | grep -v '^/dev/null$' | sort -u
  )

  # Fallback: seed snapshots from file paths explicitly mentioned in task text.
  if [[ ${#files[@]} -eq 0 ]]; then
    mapfile -t files < <(printf '%s\n' "$task" | grep -oE '(agents|coordination|docs|src|workflows)/[A-Za-z0-9._/-]+' | sort -u || true)
  fi

  for f in "${files[@]}"; do
    [[ -n "$f" ]] || continue
    printf '=== %s ===\n' "$f" >> "$out"
    if [[ -f "$repo/$f" ]]; then
      sed -n '1,200p' "$repo/$f" >> "$out"
    else
      printf '(missing in working tree)\n' >> "$out"
    fi
    printf '\n' >> "$out"
  done
}

collect_patch_files() {
  local patch="$1"
  {
    awk '/^diff --git /{print $3; print $4}' "$patch"
    awk '/^\+\+\+ /{print $2}' "$patch"
    awk '/^--- /{print $2}' "$patch"
  } | sed 's#^[ab]/##' | sed 's#"##g' | grep -v '^/dev/null$' | sort -u
}

apply_patch_and_stage() {
  local patch="$1"
  local errfile="$2"
  local noindex_err="${errfile}.noindex"

  if git -C "$repo" apply --index --recount "$patch" 2>"$errfile"; then
    return 0
  fi

  # Fallback for new-file patches that may fail with --index.
  if grep -qiE 'dev/null: does not exist in index|new file .* depends on old contents|No valid patches in input' "$errfile"; then
    if git -C "$repo" apply --recount "$patch" 2>"$noindex_err"; then
      mapfile -t patch_files < <(collect_patch_files "$patch")
      if [[ ${#patch_files[@]} -gt 0 ]]; then
        git -C "$repo" add -- "${patch_files[@]}"
      else
        git -C "$repo" add -A
      fi
      return 0
    fi
    cat "$noindex_err" > "$errfile"
  fi

  return 1
}

response="$(agent_prompt "$agent" "$prompt_base")"
printf '%s\n' "$response" > "$out_dir/response.txt"

# Fail fast on local gateway connectivity/runtime issues.
if grep -nEi 'No response from OpenClaw|fetch failed|is restarting|is not running|couldn.t connect|connection refused' "$out_dir/response.txt" >/dev/null 2>&1; then
  die "Agent gateway/service is not ready. Check container status/logs first. Details: $out_dir/response.txt"
fi

# Fail fast on common provider/auth errors so caller does not continue to PR step.
if grep -nEi 'incorrect api key|invalid api key|unauthorized|forbidden|rate limit|insufficient quota|401|403|429' "$out_dir/response.txt" >/dev/null 2>&1; then
  die "Agent response indicates provider/auth failure. See: $out_dir/response.txt"
fi

# Try to extract raw diff if wrapped.
patch_file="$out_dir/change.patch"
extract_patch "$out_dir/response.txt" "$patch_file"
patch_with_headers="$out_dir/change.with-headers.patch"
ensure_diff_headers "$patch_file" "$patch_with_headers"
patch_sanitized="$out_dir/change.sanitized.patch"
sanitize_patch "$patch_with_headers" "$patch_sanitized"

[[ -s "$patch_sanitized" ]] || die "Empty patch from agent"

# Guardrail: scan patch text itself.
"$SELF_DIR/scan-secrets.sh" --file "$patch_sanitized"

apply_err="$out_dir/apply.err"
if ! apply_patch_and_stage "$patch_sanitized" "$apply_err"; then
  # One structured retry with concrete error + current file snapshots.
  snapshots="$out_dir/file-snapshots.txt"
  build_file_snapshots "$patch_sanitized" "$snapshots"

  retry_prompt="Your previous patch did not apply.
Error:
$(cat "$apply_err")

Regenerate a corrected unified diff patch that applies cleanly to the current branch.
Rules:
- Return ONLY unified diff (no markdown).
- Keep edits within allowed paths.
- For existing files, use exact context from snapshots below.
- Ensure hunk line counts are correct.
- Use explicit git diff headers: diff --git a/<path> b/<path>.
- For existing files, NEVER use /dev/null or 'new file mode'.

Original task:
$task

Current file snapshots:
$(cat "$snapshots")"

  retry_response="$(agent_prompt "$agent" "$retry_prompt")"
  printf '%s\n' "$retry_response" > "$out_dir/response.retry1.txt"

  if grep -nEi 'No response from OpenClaw|fetch failed|is restarting|is not running|couldn.t connect|connection refused|incorrect api key|invalid api key|unauthorized|forbidden|rate limit|insufficient quota|401|403|429' "$out_dir/response.retry1.txt" >/dev/null 2>&1; then
    die "Retry response indicates gateway/provider failure. See: $out_dir/response.retry1.txt"
  fi

  patch_retry="$out_dir/change.retry1.patch"
  extract_patch "$out_dir/response.retry1.txt" "$patch_retry"
  patch_retry_with_headers="$out_dir/change.retry1.with-headers.patch"
  ensure_diff_headers "$patch_retry" "$patch_retry_with_headers"
  patch_retry_sanitized="$out_dir/change.retry1.sanitized.patch"
  sanitize_patch "$patch_retry_with_headers" "$patch_retry_sanitized"
  [[ -s "$patch_retry_sanitized" ]] || die "Empty retry patch from agent"
  "$SELF_DIR/scan-secrets.sh" --file "$patch_retry_sanitized"

  if ! apply_patch_and_stage "$patch_retry_sanitized" "$out_dir/apply.retry1.err"; then
    die "Patch apply failed for $agent after retry. Review: $patch_sanitized and $patch_retry_sanitized"
  fi
fi

# Guardrail: scan staged result before commit.
"$SELF_DIR/scan-secrets.sh" --staged "$repo"

if [[ -z "$(git -C "$repo" diff --cached --name-only)" ]]; then
  die "No staged changes after apply"
fi

msg="feat(agent/$agent): autonomous update $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git -C "$repo" commit -m "$msg" >/dev/null

log "Committed for $agent on $branch"
git -C "$repo" log --oneline -1
