#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo ".env not found. Run: cp .env.example .env"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source ./.env
set +a

if [[ -z "${GEMINI_VERTEX_SA_JSON:-}" ]]; then
  echo "GEMINI_VERTEX_SA_JSON is empty."
  echo "Set GEMINI_VERTEX_SA_JSON in .env (single-line JSON with escaped \\n)."
  exit 1
fi

OUTPUT_PATH="${GEMINI_VERTEX_CREDENTIALS_FILE:-./secrets/gemini-vertex-sa.json}"
mkdir -p "$(dirname "$OUTPUT_PATH")"
printf '%b' "$GEMINI_VERTEX_SA_JSON" > "$OUTPUT_PATH"
chmod 600 "$OUTPUT_PATH"

echo "Wrote Vertex service account JSON to $OUTPUT_PATH"
