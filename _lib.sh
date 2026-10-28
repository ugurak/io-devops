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

  local dirs=(elk db/postgres db/redis minio backup app caddy)
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
