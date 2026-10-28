#!/usr/bin/env bash
# Ortak yardımcılar — deploy.sh / stop.sh / update.sh / down.sh / app/up.sh
# shellcheck disable=SC2034

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_NAME="${NETWORK_NAME:-istanbulofset-proxy}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-istanbulofset}"
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
  # nginx-proxy (veraius) — api/web VIRTUAL_HOST keşfi için zorunlu
  if ! docker network inspect veraius-proxy >/dev/null 2>&1; then
    echo -e "${RED}veraius-proxy ağı yok. Önce veraius devops nginx'i ayağa kaldırın.${NC}" >&2
    exit 1
  fi
}

# registry.veraius.com Basic auth — pull öncesi zorunlu
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

compose() {
  local dir="$1"
  shift
  (cd "$ROOT/$dir" && docker compose \
    --project-name "$COMPOSE_PROJECT" \
    --env-file "$ENV_FILE" \
    -f docker-compose.yaml \
    "$@")
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
      # healthcheck yoksa running kabul
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

stack_ps() {
  echo -e "${YELLOW}=== istanbulofset stack ===${NC}"
  docker ps --filter "label=com.istanbulofset.stack=true" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
}
