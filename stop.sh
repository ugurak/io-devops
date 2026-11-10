#!/usr/bin/env bash
# Servisleri ters sırada durdur (container'lar kalır; down değil stop)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$ROOT/_lib.sh"

load_env

echo -e "${YELLOW}=== İstanbul Ofset stop ===${NC}"

compose app stop || true
docker stop istanbulofset-caddy >/dev/null 2>&1 || true
# Altyapı ters sırada (isteğe bağlılar önce)
DIRS=(); while read -r d; do DIRS+=("$d"); done < <(infra_dirs)
for (( i=${#DIRS[@]}-1; i>=0; i-- )); do
  compose "${DIRS[$i]}" stop || true
done

echo -e "${GREEN}✓ Durduruldu${NC}"
stack_ps
