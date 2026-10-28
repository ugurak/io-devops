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
