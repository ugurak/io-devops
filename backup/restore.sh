#!/usr/bin/env bash
# Kullanım: ./backup/restore.sh istanbulofset-20261026T000000Z.dump
# Dikkat: veritabanını SİLİP yedekten yeniden kurar (api/web önce durdurulur).
# Veritabanı baştan oluşturulur: daha yeni migration'ların bıraktığı tablolar kalmaz, API açılışta yedeğin
# migration geçmişinden devam eder. Hata olursa işlem durur (yarım geri yükleme bırakılmaz).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../_lib.sh
source "$ROOT/_lib.sh"

[[ $# -eq 1 ]] || { echo "Kullanım: $0 <yedek-dosyası>"; exit 1; }
load_env
DB="${POSTGRES_DB:-istanbulofset}"
OWNER="${POSTGRES_USER:-istanbulofset}"

compose backup exec -T backup test -f "/backups/$1" || { echo -e "${RED}yedek bulunamadı: /backups/$1${NC}"; exit 1; }
# Önce dosyanın okunabilir olduğunu doğrula (bozuk yedekle veritabanını silme).
compose backup exec -T backup pg_restore --list "/backups/$1" >/dev/null

echo -e "${YELLOW}api/web durduruluyor...${NC}"
compose app stop || true

echo -e "${YELLOW}$DB silinip yeniden oluşturuluyor, geri yükleniyor: $1${NC}"
compose backup exec -T backup psql --dbname=postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB' AND pid <> pg_backend_pid();" \
  -c "DROP DATABASE IF EXISTS \"$DB\";" \
  -c "CREATE DATABASE \"$DB\" OWNER \"$OWNER\";"
compose backup exec -T backup pg_restore --no-owner --exit-on-error --single-transaction --dbname="$DB" "/backups/$1"

echo -e "${GREEN}geri yüklendi: $1${NC}"
echo "şimdi: compose app start  veya  ./deploy.sh --app-only"
