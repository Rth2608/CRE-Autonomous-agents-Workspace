#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

scanner="$SELF_DIR/scan-secrets.sh"
[[ -x "$scanner" ]] || die "Secret scanner missing: $scanner"

install_hooks_for_repo() {
  local repo="$1"
  local hook_dir="$repo/.git/hooks"
  mkdir -p "$hook_dir"

  cat > "$hook_dir/pre-commit" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
repo="\$(git rev-parse --show-toplevel)"
"$scanner" --staged "\$repo"
HOOK

  cat > "$hook_dir/pre-push" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
repo="\$(git rev-parse --show-toplevel)"
"$scanner" --staged "\$repo"
HOOK

  chmod +x "$hook_dir/pre-commit" "$hook_dir/pre-push"
}

for agent in "${AGENTS[@]}"; do
  wd="$(agent_workdir "$agent")"
  if [[ -d "$wd/.git" ]]; then
    install_hooks_for_repo "$wd"
    log "Installed hooks for $agent at $wd"
  else
    log "Skipped $agent (missing git repo): $wd"
  fi
done

log "Done"
