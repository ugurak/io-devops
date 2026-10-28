#!/usr/bin/env bash
# Servisleri ters sırada durdur (container'lar kalır; down değil stop)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$ROOT/_lib.sh"

require_env

echo -e "${YELLOW}=== İstanbul Ofset stop ===${NC}"

compose caddy stop || true
compose app stop || true
compose backup stop || true
compose minio stop || true
compose db/redis stop || true
compose db/postgres stop || true
compose elk stop || true

echo -e "${GREEN}✓ Durduruldu${NC}"
stack_ps
