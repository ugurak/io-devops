#!/usr/bin/env bash
# Registry'den api/web çekip ayağa kaldır
#
#   ./update.sh           # pull + up app + caddy
#   ./update.sh --infra   # infra da yeniden up
#   ./update.sh --infra-pull  # infra imajlarının güvenlik yamalarını çek + yeniden başlat (ayda bir)
#   ./update.sh --prune
#   ./update.sh --tag 4a1f83d   # geri dönüş: o commit'in imajı (CI her sürümü kısa SHA ile de etiketler)
#   ./update.sh --tag latest    # geri dönüşten sonra güncele dön
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$ROOT/_lib.sh"

DO_INFRA=false
DO_INFRA_PULL=false
DO_PRUNE=false

TAG_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  arg="$1"; shift
  case "$arg" in
    --pull) ;; # varsayılan davranış; geriye uyumluluk
    --infra) DO_INFRA=true ;;
    --infra-pull) DO_INFRA=true; DO_INFRA_PULL=true ;;
    --prune) DO_PRUNE=true ;;
    --tag) TAG_OVERRIDE="${1:?--tag için imaj etiketi (kısa SHA) gerekli}"; shift ;;
    -h|--help)
      cat <<'EOF'
Kullanım: ./update.sh [--infra] [--infra-pull] [--prune] [--tag <kısa-sha|latest>]

  --infra-pull  postgres:17-alpine, redis:7-alpine vb. ana sürümü sabit imajların yama sürümlerini çeker
                ve değişen konteynerleri yeniden başlatır (kısa kesinti). Ayda bir çalıştırın.

  --tag  Belirli sürüme geç / geri dön (ör. --tag 4a1f83d). Seçim .image-tag'de kalır; sonraki CI dağıtımı
         kendi commit'inin etiketini yazar. --tag latest seçimi kaldırır.

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

# Seçili sürüm .image-tag dosyasında tutulur (git dışı; .env'e dokunulmaz). --tag latest dosyayı siler.
TAG_FILE="$ROOT/.image-tag"
if [[ -n "$TAG_OVERRIDE" ]]; then
  if [[ "$TAG_OVERRIDE" == latest ]]; then rm -f "$TAG_FILE"; else printf '%s\n' "$TAG_OVERRIDE" >"$TAG_FILE"; fi
fi
load_image_tag
echo "  Çalışan sürüm: $(docker inspect -f '{{.Config.Image}}' istanbulofset-api 2>/dev/null || echo yok)"

echo -e "${GREEN}=== İstanbul Ofset update ===${NC}"
echo "  ${DOCKER_REGISTRY:-registry.veraius.com}/istanbulofset-*:${IMAGE_TAG:-latest}"

if [[ "$DO_INFRA" == true ]]; then
  while read -r d; do
    # Ana sürüm etiketi sabit (ör. postgres:17-alpine); --infra-pull aynı etiketin yamalı imajını çeker.
    [[ "$DO_INFRA_PULL" == true ]] && compose "$d" pull --ignore-pull-failures
    compose "$d" up -d
  done < <(infra_dirs)
fi

docker rm -f istanbulofset-caddy >/dev/null 2>&1 || true
ensure_registry_login
compose app pull
pre_deploy
compose app up -d --force-recreate

if [[ "$DO_PRUNE" == true ]]; then
  docker image prune -f || true
fi

echo -e "${GREEN}✓ Update tamam${NC}"
stack_ps
