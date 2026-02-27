#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
interval_sec="${1:-1800}"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

if ! [[ "$interval_sec" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 [interval_seconds]" >&2
  exit 1
fi

load_autonomy_config
ensure_virtual_mode

while true; do
  if is_emergency_stopped; then
    log "Emergency stop active. Skipping cycle tick."
    sleep "$interval_sec"
    continue
  fi

  if has_pending_human_approvals; then
    log "Pending human approval exists. Skipping cycle tick."
    sleep "$interval_sec"
    continue
  fi

  if ! "$SELF_DIR/run-cycle.sh"; then
    log "run-cycle failed (continuing loop)"
  fi

  sleep "$interval_sec"
done
