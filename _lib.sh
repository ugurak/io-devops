#!/usr/bin/env bash
# Ortak yardımcılar — deploy.sh / stop.sh / update.sh / down.sh / app/up.sh / start.sh
# shellcheck disable=SC2034

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_NAME="${NETWORK_NAME:-istanbulofset-proxy}"
# Her compose dizini ayrı proje adı → orphan uyarısı yok (container/volume name'ler sabit)
COMPOSE_PROJECT_PREFIX="${COMPOSE_PROJECT_PREFIX:-io}"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

require_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}Eksik: $ENV_FILE${NC}" >&2
    echo "  cp .env.example .env  # sonra değerleri doldurun" >&2
    exit 1
  fi
}

load_env() {
  require_env
  set -a
  # shellcheck disable=SC1090
  # Boşluklu değerler tırnaklı olmalı (örn. ES_JAVA_OPTS="-Xms512m -Xmx512m")
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  APP_ROOT="${APP_ROOT:-/var/istanbulofset}"
  load_image_tag
  derive_stack_env
}

# ./update.sh --tag <sha> ile seçilen sürüm (.image-tag, git dışı) .env'deki IMAGE_TAG'in önüne geçer;
# deploy.sh / start.sh de aynı sürümü kullanır.
load_image_tag() {
  if [[ -f "$ROOT/.image-tag" ]]; then
    IMAGE_TAG="$(tr -d ' \r\n' <"$ROOT/.image-tag")"
    export IMAGE_TAG
  fi
}

# İsteğe bağlı yığınlar (.env EXTRA_STACKS, boşlukla ayrılmış): clamav glitchtip observability
# Gatus (monitoring) her zaman açıktır. Bellek: clamav ~1,5G, glitchtip ~0,5G, observability ~0,7G.
OPTIONAL_STACKS=(clamav glitchtip observability)

stack_enabled() {
  [[ " ${EXTRA_STACKS:-} " == *" $1 "* ]]
}

# Açık yığınlara göre uygulama bağlantılarını üretir (.env'de elle verilmişse ona dokunmaz).
# Kabuk ortamı --env-file'dan önce gelir; compose bu değerleri görür.
derive_stack_env() {
  if stack_enabled observability; then
    export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://otel-collector:4317}"
  fi
  if stack_enabled clamav; then
    export CLAMAV_ADDRESS="${CLAMAV_ADDRESS:-clamav:3310}"
  fi
  if stack_enabled glitchtip; then
    [[ -n "${GLITCHTIP_API_KEY:-}" ]] && export SENTRY_DSN_API="${SENTRY_DSN_API:-http://${GLITCHTIP_API_KEY}@glitchtip:8000/1}"
    [[ -n "${GLITCHTIP_WEB_KEY:-}" ]] && export SENTRY_DSN_WEB="${SENTRY_DSN_WEB:-http://${GLITCHTIP_WEB_KEY}@glitchtip:8000/2}"
    [[ -n "${GLITCHTIP_HOST:-}" ]] && export GLITCHTIP_DOMAIN="${GLITCHTIP_DOMAIN:-https://${GLITCHTIP_HOST}}"
  fi
  return 0
}

# Altyapı sırası (deploy/update/stop/down/clean). İsteğe bağlılar yalnızca açıksa.
infra_dirs() {
  local dirs=(elk db/postgres db/redis minio backup monitoring) s
  for s in "${OPTIONAL_STACKS[@]}"; do
    stack_enabled "$s" && dirs+=("$s")
  done
  printf '%s\n' "${dirs[@]}"
}

ensure_network() {
  if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}Ağ oluşturuluyor: $NETWORK_NAME${NC}"
    docker network create "$NETWORK_NAME"
  fi
  if ! docker network inspect veraius-proxy >/dev/null 2>&1; then
    echo -e "${RED}veraius-proxy ağı yok. Önce veraius devops nginx'i ayağa kaldırın.${NC}" >&2
    exit 1
  fi
}

ensure_registry_login() {
  local registry="${DOCKER_REGISTRY:-registry.veraius.com}"
  local user="${REGISTRY_USER:-${DOCKER_REGISTRY_USERNAME:-admin}}"
  local pass="${REGISTRY_PASSWORD:-${DOCKER_REGISTRY_PASSWORD:-}}"
  if [[ -z "$pass" ]]; then
    echo -e "${RED}REGISTRY_PASSWORD boş — .env içine yazın veya:${NC}" >&2
    echo "  docker login $registry -u $user" >&2
    exit 1
  fi
  echo -e "${YELLOW}Registry login: ${registry} (${user})${NC}"
  if ! echo "$pass" | docker login "$registry" -u "$user" --password-stdin; then
    echo -e "${RED}docker login başarısız${NC}" >&2
    exit 1
  fi
  echo -e "${GREEN}✓ Registry oturumu açık${NC}"
}

# dir → proje adı: db/postgres → io-db-postgres
compose_project_for() {
  local dir="$1"
  echo "${COMPOSE_PROJECT_PREFIX}-$(echo "$dir" | tr '/.' '-')"
}

compose() {
  local dir="$1"
  shift
  local project
  project="$(compose_project_for "$dir")"
  (cd "$ROOT/$dir" && docker compose \
    --project-name "$project" \
    --env-file "$ENV_FILE" \
    -f docker-compose.yaml \
    "$@")
}

# Sıfır kurulum: konteynerler (+ isteğe bağlı volume) + eski app imajları
#   wipe_volumes=true  → named volume'lar silinir (DB/MinIO/ES sıfır)
clean_stack() {
  local wipe_volumes="${1:-true}"
  echo -e "${YELLOW}=== Temizlik (sıfır kurulum) ===${NC}"

  docker rm -f istanbulofset-caddy >/dev/null 2>&1 || true

  # İsteğe bağlılar kapalı olsa da temizlenir
  local dirs=(elk db/postgres db/redis minio backup monitoring clamav glitchtip observability app caddy)
  local d
  for d in "${dirs[@]}"; do
    [[ -f "$ROOT/$d/docker-compose.yaml" ]] || continue
    if [[ "$wipe_volumes" == true ]]; then
      compose "$d" down -v --remove-orphans 2>/dev/null || true
    else
      compose "$d" down --remove-orphans 2>/dev/null || true
    fi
  done

  # İsimle kalan konteynerler
  local ids
  ids="$(docker ps -aq --filter 'name=istanbulofset-' 2>/dev/null || true)"
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    docker rm -f $ids >/dev/null 2>&1 || true
  fi
  ids="$(docker ps -aq --filter 'label=com.istanbulofset.stack=true' 2>/dev/null || true)"
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    docker rm -f $ids >/dev/null 2>&1 || true
  fi

  if [[ "$wipe_volumes" == true ]]; then
    local vols
    vols="$(docker volume ls -q --filter 'name=istanbulofset_' 2>/dev/null || true)"
    if [[ -n "$vols" ]]; then
      # shellcheck disable=SC2086
      docker volume rm $vols >/dev/null 2>&1 || true
      echo -e "  ${GREEN}✓${NC} volume'lar silindi"
    fi
  fi

  # Eski app imajları (yeniden pull edilecek)
  docker image rm -f \
    "${DOCKER_REGISTRY:-registry.veraius.com}/istanbulofset-api:${IMAGE_TAG:-latest}" \
    "${DOCKER_REGISTRY:-registry.veraius.com}/istanbulofset-web:${IMAGE_TAG:-latest}" \
    "istanbulofset-api:latest" "istanbulofset-web:latest" \
    >/dev/null 2>&1 || true

  echo -e "${GREEN}✓ Temizlik bitti${NC}"
}

wait_healthy() {
  local service="$1"
  local max_attempts="${2:-60}"
  local attempt=0
  echo -e "${YELLOW}Sağlık bekleniyor: $service${NC}"
  while (( attempt < max_attempts )); do
    local status
    status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$service" 2>/dev/null || true)"
    if [[ "$status" == "healthy" || "$status" == "running" ]]; then
      if [[ "$status" == "healthy" ]]; then
        echo -e "${GREEN}✓ $service healthy${NC}"
        return 0
      fi
      if ! docker inspect --format='{{json .State.Health}}' "$service" 2>/dev/null | grep -q '{'; then
        echo -e "${GREEN}✓ $service running${NC}"
        return 0
      fi
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  echo -e "${RED}✗ $service sağlıklı olmadı (${max_attempts} deneme)${NC}" >&2
  return 1
}

wait_http_ready() {
  local url="$1"
  local max_attempts="${2:-60}"
  local attempt=0
  echo -e "${YELLOW}HTTP bekleniyor: $url${NC}"
  while (( attempt < max_attempts )); do
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "$url" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      echo -e "${GREEN}✓ $url → 200${NC}"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 3
  done
  echo -e "${YELLOW}Uyarı: $url henüz 200 değil (devam)${NC}" >&2
  return 1
}

stack_ps() {
  echo -e "${YELLOW}=== istanbulofset stack ===${NC}"
  docker ps --filter "label=com.istanbulofset.stack=true" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  docker ps --filter "name=istanbulofset-" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
}

# Uygulama yeniden oluşturulmadan önce: (1) geri dönüş için anlık veritabanı yedeği, (2) yeni imajla yalnızca
# veritabanı geçişleri. Geçiş başarısız olursa betik durur ve çalışan eski sürüm yerinde kalır (site kapanmaz).
pre_deploy() {
  if docker ps --format '{{.Names}}' | grep -qx istanbulofset-backup; then
    echo "Dağıtım öncesi veritabanı yedeği…"
    docker exec istanbulofset-backup sh -c \
      'f=/backups/predeploy-$(date -u +%Y%m%dT%H%M%SZ).dump; pg_dump --format=custom --no-owner --file="$f" && echo "  $f"; find /backups -name "predeploy-*.dump" -mtime +2 -delete' \
      || echo -e "${YELLOW}UYARI: dağıtım öncesi yedek alınamadı; devam ediliyor${NC}" >&2
  fi
  # f1fb59e'den eski imajlar --migrate-only bilmez (sunucuyu açar, bitmez): onlara geri dönerken NO_MIGRATE=1.
  if [[ -n "${NO_MIGRATE:-}" ]]; then
    echo "NO_MIGRATE=1: geçiş adımı atlandı"
    return 0
  fi
  echo "Veritabanı geçişleri (yeni imaj, --migrate-only)…"
  if ! timeout 900 docker compose --project-name "$(compose_project_for app)" --env-file "$ENV_FILE" \
      -f "$ROOT/app/docker-compose.yaml" run --rm --no-deps -T api --migrate-only; then
    echo -e "${RED}Veritabanı geçişi başarısız — uygulama güncellenmedi, eski sürüm çalışıyor.${NC}" >&2
    echo "Geri dönmek için yedek: docker exec istanbulofset-backup ls /backups | grep predeploy" >&2
    return 1
  fi
}
