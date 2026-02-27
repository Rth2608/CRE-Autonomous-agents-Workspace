#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

if [[ -f "autonomy/config.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "autonomy/config.env"
  set +a
fi

exec python3 "$ROOT_DIR/scripts/autonomy/telegram-controller.py"
