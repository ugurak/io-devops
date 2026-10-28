#!/usr/bin/env bash
# Yönlendirici — asıl script monorepo'da:
#   istanbulofset/.github/local-push.sh
#
#   cd /path/to/istanbulofset && ./.github/local-push.sh [api|web|all]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_app() {
  if [[ -n "${APP_ROOT:-}" && -x "$APP_ROOT/.github/local-push.sh" ]]; then
    echo "$APP_ROOT/.github/local-push.sh"
    return
  fi
  local candidates=(
    "$SCRIPT_DIR/../../../../istanbulofset/.github/local-push.sh"
    "/Users/akuqr/Documents/GitHub/istanbulofset/.github/local-push.sh"
    "/var/istanbulofset/.github/local-push.sh"
  )
  # APP_ROOT from parent .env
  local root_env="$SCRIPT_DIR/../.env"
  if [[ -f "$root_env" ]]; then
    local from_env
    from_env="$(grep -E '^APP_ROOT=' "$root_env" | head -1 | cut -d= -f2- | tr -d '\r"' || true)"
    if [[ -n "$from_env" && -x "$from_env/.github/local-push.sh" ]]; then
      echo "$from_env/.github/local-push.sh"
      return
    fi
  fi
  for f in "${candidates[@]}"; do
    if [[ -x "$f" ]]; then
      echo "$f"
      return
    fi
  done
  echo "" 
}

TARGET="$(resolve_app)"
if [[ -z "$TARGET" ]]; then
  echo "istanbulofset/.github/local-push.sh bulunamadı." >&2
  echo "  cd /Users/akuqr/Documents/GitHub/istanbulofset && ./.github/local-push.sh $*" >&2
  exit 1
fi

exec "$TARGET" "$@"
