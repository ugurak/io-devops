#!/usr/bin/env bash
# İstanbul Ofset — altyapı + uygulama sıralı kurulum
#
#   cd /var/istanbulofset/dev-ops
#   cp .env.example .env   # ilk kurulum
#   ./deploy.sh
#   ./deploy.sh --infra-only
#   ./deploy.sh --app-only
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$ROOT/_lib.sh"

INFRA_ONLY=false
APP_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --infra-only) INFRA_ONLY=true ;;
    --app-only) APP_ONLY=true ;;
    -h|--help)
      cat <<'EOF'
Kullanım: ./deploy.sh [--infra-only|--app-only]

  (argüman yok)   ELK → DB → MinIO → backup → app → Caddy
  --infra-only    uygulama ve Caddy hariç
  --app-only      yalnızca api + web (+ Caddy)
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

echo -e "${GREEN}=== İstanbul Ofset deployment ===${NC}"
echo "APP_ROOT=$APP_ROOT"
echo "SITE_DOMAIN=${SITE_DOMAIN:-}"
echo ""

if [[ "$APP_ONLY" != true ]]; then
  echo -e "${GREEN}1/5 ELK${NC}"
  compose elk up -d
  wait_healthy istanbulofset-elasticsearch 90 || true
  sleep 3

  echo -e "${GREEN}2/5 Veritabanları${NC}"
  compose db/postgres up -d
  wait_healthy istanbulofset-postgres 60
  compose db/redis up -d
  wait_healthy istanbulofset-redis 30

  echo -e "${GREEN}3/5 MinIO${NC}"
  compose minio up -d

  echo -e "${GREEN}4/5 Yedekleme${NC}"
  compose backup up -d
fi

if [[ "$INFRA_ONLY" != true ]]; then
  echo -e "${GREEN}5/5 Uygulama + Caddy${NC}"
  echo "  image: ${DOCKER_REGISTRY:-registry.veraius.com}/istanbulofset-*:${IMAGE_TAG:-latest}"
  compose app pull
  compose app up -d
  wait_healthy istanbulofset-api 90 || true
  compose caddy up -d
fi

echo ""
echo -e "${GREEN}✓ Deploy tamam${NC}"
stack_ps
echo ""
echo "Sağlık: https://${API_DOMAIN:-api.istanbulofset.net}/ready"
echo "Site:   https://${SITE_DOMAIN:-dev.istanbulofset.net}"
