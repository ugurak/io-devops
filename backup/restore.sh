#!/usr/bin/env bash
# Kullanım: ./restore.sh istanbulofset-20261026T000000Z.dump
# Dikkat: mevcut veritabanının üzerine yazar. Önce API'yi durdurun.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../_lib.sh
source "$ROOT/_lib.sh"

: "${1:?yedek dosyası adı gerekli}"
require_env

echo -e "${YELLOW}api/web durduruluyor...${NC}"
compose app stop || true

echo -e "${YELLOW}geri yükleniyor: $1${NC}"
compose backup exec -T backup \
  pg_restore --clean --if-exists --no-owner --dbname="${POSTGRES_DB:-istanbulofset}" "/backups/$1"

echo -e "${GREEN}geri yüklendi: $1${NC}"
echo "şimdi: compose app start  veya  ./deploy.sh --app-only"
