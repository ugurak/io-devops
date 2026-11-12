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

# Önce depodaki son yapılandırmayı al (git pull), sonra güncel betikle yeniden başla. NO_PULL=1 ile atlanır.
if [[ -z "${IO_DEPLOY_PULLED:-}" && -z "${NO_PULL:-}" && -d "$ROOT/.git" ]]; then
  echo "git pull ($ROOT)…"
  if git -C "$ROOT" pull --ff-only; then
    IO_DEPLOY_PULLED=1 exec "$ROOT/deploy.sh" "$@"
  fi
  echo "UYARI: git pull başarısız; mevcut dosyalarla devam ediliyor" >&2
fi

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

  (argüman yok)   ELK → DB → MinIO → backup → izleme (Gatus) → [EXTRA_STACKS] → app
                  EXTRA_STACKS (.env): clamav glitchtip observability
  --infra-only    uygulama hariç
  --app-only      yalnızca api + web
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
echo "TLS via: veraius nginx-proxy (Caddy yok)"
echo ""

# Eski Caddy denemesi 80'i kapmasın
docker rm -f istanbulofset-caddy >/dev/null 2>&1 || true

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

  echo -e "${GREEN}4/5 Yedekleme + izleme${NC}"
  compose backup up -d
  compose monitoring up -d

  # İsteğe bağlı yığınlar (.env EXTRA_STACKS)
  for s in "${OPTIONAL_STACKS[@]}"; do
    if stack_enabled "$s"; then
      echo -e "${GREEN}   + $s${NC}"
      compose "$s" up -d
    fi
  done
fi

if [[ "$INFRA_ONLY" != true ]]; then
  echo -e "${GREEN}5/5 Uygulama (nginx VIRTUAL_HOST)${NC}"
  echo "  image: ${DOCKER_REGISTRY:-registry.veraius.com}/istanbulofset-*:${IMAGE_TAG:-latest}"
  echo "  web:   https://${SITE_DOMAIN}"
  echo "  api:   https://${API_DOMAIN}"
  ensure_registry_login
  pull_app_images
  pre_deploy
  compose app up -d
  wait_healthy istanbulofset-api 90 || true
  # vhost body-size snippet (varsa)
  if [[ -d /var/veraius/dev-ops/nginx/vhost.d ]]; then
    ln -sfn "$ROOT/nginx/vhost.d/api.istanbulofset.net_location" \
      /var/veraius/dev-ops/nginx/vhost.d/api.istanbulofset.net_location
    # Sunucu düzeyi ek (/health, /ready dışarıya 404). Kopyalanır: nginx-proxy konteyneri io-devops yolunu görmez.
    # nginx -t başarısızsa dosya geri alınır; proxy bozuk yapılandırmayla yeniden yüklenmez.
    vhost=/var/veraius/dev-ops/nginx/vhost.d/api.istanbulofset.net
    install -m 644 "$ROOT/nginx/vhost.d/api.istanbulofset.net" "$vhost"
    if ! docker exec nginx-proxy nginx -t >/dev/null 2>&1; then
      echo -e "${YELLOW}nginx -t başarısız; $vhost geri alındı${NC}"
      rm -f "$vhost"
    fi
    docker exec nginx-proxy nginx -s reload 2>/dev/null || true
  fi
fi

echo ""
echo -e "${GREEN}✓ Deploy tamam${NC}"
stack_ps
echo ""
echo "Sağlık: https://${API_DOMAIN:-api.istanbulofset.net}/live  (/ready ve /health yalnızca iç ağdan)"
echo "Site:   https://${SITE_DOMAIN:-test.istanbulofset.net}"
echo "Not:    TLS = veraius nginx-proxy + acme-companion"
