#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 --file <path>
  $0 --stdin
  $0 --staged <repo_path>

Exit code 0: no secrets found
Exit code 2: potential secrets found
USAGE
}

patterns=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '-----BEGIN OPENSSH PRIVATE KEY-----'
  'ghp_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9_]{30,}'
  'moltbook_(sk|pk)_[A-Za-z0-9_-]{16,}'
  'sk-[A-Za-z0-9]{20,}'
  'sk-proj-[A-Za-z0-9_-]{20,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'AKIA[0-9A-Z]{16}'
  'ASIA[0-9A-Z]{16}'
  'AIza[0-9A-Za-z_-]{35}'
)

placeholder_regex='(replace_with|example|changeme|dummy|placeholder|your_|<.*>)'

scan_stream() {
  local label="$1"
  local input_file="$2"
  local hit=0
  local has_rg=0
  if command -v rg >/dev/null 2>&1; then
    has_rg=1
  fi

  for p in "${patterns[@]}"; do
    if [[ $has_rg -eq 1 ]]; then
      rg -n --pcre2 -e "$p" "$input_file" >/tmp/secret_hits.$$ 2>/dev/null || true
    else
      grep -nE "$p" "$input_file" >/tmp/secret_hits.$$ 2>/dev/null || true
    fi
    if [[ -s /tmp/secret_hits.$$ ]]; then
      log "Secret-like pattern detected in $label (pattern: $p)"
      sed 's/^/  /' /tmp/secret_hits.$$ >&2
      hit=1
    fi
  done

  # Detect KEY/TOKEN/SECRET assignments with non-placeholder values.
  while IFS= read -r line; do
    if [[ "$line" =~ ^[A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*([^#[:space:]]+) ]]; then
      value="${BASH_REMATCH[2]}"
      value="${value%\"}"
      value="${value#\"}"
      if [[ ${#value} -ge 12 ]] && [[ ! "$value" =~ $placeholder_regex ]]; then
        log "Secret-like assignment detected in $label"
        printf '  %s\n' "$line" >&2
        hit=1
      fi
    fi
  done < "$input_file"

  rm -f /tmp/secret_hits.$$ || true

  if [[ $hit -eq 1 ]]; then
    return 2
  fi
  return 0
}

scan_staged_repo() {
  local repo="$1"
  [[ -d "$repo/.git" ]] || die "Not a git repository: $repo"

  local found=0
  local tmpdir
  tmpdir="$(mktemp -d)"

  mapfile -t files < <(git -C "$repo" diff --cached --name-only --diff-filter=ACMR)

  for f in "${files[@]}"; do
    local out="$tmpdir/$(echo "$f" | tr '/' '_')"
    if git -C "$repo" show ":$f" >"$out" 2>/dev/null; then
      if ! scan_stream "$repo:$f" "$out"; then
        found=1
      fi
    fi
  done

  rm -rf "$tmpdir"

  if [[ $found -eq 1 ]]; then
    return 2
  fi
  return 0
}

[[ $# -ge 1 ]] || { usage; exit 1; }

case "$1" in
  --file)
    [[ $# -eq 2 ]] || { usage; exit 1; }
    [[ -f "$2" ]] || die "File not found: $2"
    if scan_stream "$2" "$2"; then
      exit 0
    fi
    exit 2
    ;;
  --stdin)
    [[ $# -eq 1 ]] || { usage; exit 1; }
    tmp="$(mktemp)"
    cat >"$tmp"
    if scan_stream "stdin" "$tmp"; then
      rm -f "$tmp"
      exit 0
    fi
    rm -f "$tmp"
    exit 2
    ;;
  --staged)
    [[ $# -eq 2 ]] || { usage; exit 1; }
    if scan_staged_repo "$2"; then
      exit 0
    fi
    exit 2
    ;;
  *)
    usage
    exit 1
    ;;
esac
