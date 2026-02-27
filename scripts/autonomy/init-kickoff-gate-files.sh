#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 [--repo <path>] [--force]

Creates kickoff-gate files in target repository:
- coordination/KICKOFF_PACK.md
- coordination/ACK/gpt.md
- coordination/ACK/claude.md
- coordination/ACK/gemini.md
- coordination/ACK/grok.md
- coordination/START.md

Defaults:
- --repo: $ROOT_DIR/workdirs/gpt
USAGE
}

target_repo="$ROOT_DIR/workdirs/gpt"
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

[[ -d "$target_repo" ]] || die "Repo path not found: $target_repo"
[[ -d "$target_repo/.git" ]] || die "Not a git repo: $target_repo"

tpl_dir="$ROOT_DIR/autonomy/templates/kickoff"
[[ -f "$tpl_dir/KICKOFF_PACK.md" ]] || die "Missing template: $tpl_dir/KICKOFF_PACK.md"
[[ -f "$tpl_dir/ACK_TEMPLATE.md" ]] || die "Missing template: $tpl_dir/ACK_TEMPLATE.md"
[[ -f "$tpl_dir/START.md" ]] || die "Missing template: $tpl_dir/START.md"

mkdir -p "$target_repo/coordination/ACK"

copy_file() {
  local src="$1"
  local dst="$2"
  if [[ -f "$dst" && "$force" != "true" ]]; then
    log "Keep existing: $dst"
    return 0
  fi
  cp "$src" "$dst"
  log "Wrote: $dst"
}

copy_file "$tpl_dir/KICKOFF_PACK.md" "$target_repo/coordination/KICKOFF_PACK.md"
copy_file "$tpl_dir/START.md" "$target_repo/coordination/START.md"

for agent in "${AGENTS[@]}"; do
  ack_file="$target_repo/coordination/ACK/${agent}.md"
  if [[ -f "$ack_file" && "$force" != "true" ]]; then
    log "Keep existing: $ack_file"
    continue
  fi
  sed \
    -e "s/__AGENT__/$agent/g" \
    -e "s/__AGENT_UPPER__/$(printf '%s' "$agent" | tr '[:lower:]' '[:upper:]')/g" \
    "$tpl_dir/ACK_TEMPLATE.md" > "$ack_file"
  log "Wrote: $ack_file"
done

echo
echo "Kickoff gate files initialized at: $target_repo"
echo "Next:"
echo "1) Fill coordination/KICKOFF_PACK.md"
echo "2) Set each coordination/ACK/*.md to ACK_STATUS: READY"
echo "3) Set coordination/START.md START_APPROVED: true"
