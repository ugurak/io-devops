#!/usr/bin/env bash
# api + web (registry pull) + isteğe bağlı Caddy
#
#   ./up.sh
#   ./up.sh --with-caddy
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../_lib.sh
source "$ROOT/_lib.sh"

WITH_CADDY=false

for arg in "$@"; do
  case "$arg" in
    --build) echo -e "${YELLOW}--build kaldırıldı; imajlar registry'den gelir. Yerelde: registry/local-push.sh${NC}" ;;
    --with-caddy) WITH_CADDY=true ;;
    -h|--help)
      cat <<'EOF'
Kullanım: ./up.sh [--with-caddy]
EOF
      exit 0
      ;;
    *)
      echo -e "${RED}Bilinmeyen argüman: $arg${NC}" >&2
      exit 1
      ;;
  esac
done

load_env
ensure_network
ensure_registry_login

echo -e "${GREEN}→ app pull/up (${DOCKER_REGISTRY:-registry.veraius.com}/istanbulofset-*:${IMAGE_TAG:-latest})${NC}"
compose app pull
compose app up -d

if [[ "$WITH_CADDY" == true ]]; then
  echo -e "${GREEN}→ caddy${NC}"
  compose caddy up -d
fi

stack_ps
