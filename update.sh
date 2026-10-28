#!/usr/bin/env bash
# Registry'den api/web çekip ayağa kaldır
#
#   ./update.sh           # pull + up app + caddy
#   ./update.sh --infra   # infra da yeniden up
#   ./update.sh --prune
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$ROOT/_lib.sh"

DO_INFRA=false
DO_PRUNE=false

for arg in "$@"; do
  case "$arg" in
    --pull) ;; # varsayılan davranış; geriye uyumluluk
    --infra) DO_INFRA=true ;;
    --prune) DO_PRUNE=true ;;
    -h|--help)
      cat <<'EOF'
Kullanım: ./update.sh [--infra] [--prune]

  Registry imajları: istanbulofset-api / istanbulofset-web
  Yerel build+push:  registry/local-push.sh
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

echo -e "${GREEN}=== İstanbul Ofset update ===${NC}"
echo "  ${DOCKER_REGISTRY:-registry.veraius.com}/istanbulofset-*:${IMAGE_TAG:-latest}"

if [[ "$DO_INFRA" == true ]]; then
  compose elk up -d
  compose db/postgres up -d
  compose db/redis up -d
  compose minio up -d
  compose backup up -d
fi

docker rm -f istanbulofset-caddy >/dev/null 2>&1 || true
ensure_registry_login
compose app pull
compose app up -d --force-recreate

if [[ "$DO_PRUNE" == true ]]; then
  docker image prune -f || true
fi

echo -e "${GREEN}✓ Update tamam${NC}"
stack_ps
