#!/usr/bin/env bash
# api + web (registry pull) — TLS: veraius nginx-proxy
#
#   ./up.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../_lib.sh
source "$ROOT/_lib.sh"

for arg in "$@"; do
  case "$arg" in
    --build) echo -e "${YELLOW}--build kaldırıldı; imajlar registry'den gelir. Yerelde: .github/local-push.sh${NC}" ;;
    --with-caddy) echo -e "${YELLOW}Caddy yok; veraius nginx-proxy kullanılıyor.${NC}" ;;
    -h|--help)
      cat <<'EOF'
Kullanım: ./up.sh
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
docker rm -f istanbulofset-caddy >/dev/null 2>&1 || true

echo -e "${GREEN}→ app pull/up (${DOCKER_REGISTRY:-registry.veraius.com}/istanbulofset-*:${IMAGE_TAG:-latest})${NC}"
compose app pull
compose app up -d

stack_ps
