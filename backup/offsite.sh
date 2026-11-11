#!/bin/sh
# Sunucu dışı yedek (rclone, S3 uyumlu hedef: Cloudflare R2, Backblaze B2, Wasabi, AWS S3…).
# Hedefe giden her şey istemci tarafında şifrelenir (rclone crypt; dosya adları dahil).
#
#   offsite.sh                      # pg_dump yedeklerini kopyala + MinIO bucket'ını eşitle (servis her gün çağırır)
#   offsite.sh list                 # hedefteki veritabanı yedeklerini listele
#   offsite.sh fetch-db <dosya>     # bir yedeği /backups'a indir (sonra ./restore.sh <dosya>)
#   offsite.sh restore-media        # hedefteki medyayı MinIO bucket'ına geri yükle (yalnızca eksik/farklı olanlar)
#
# OFFSITE_S3_BUCKET boşsa hiçbir şey yapmaz (uyarı yazar); yerel pg_dump yedeği yine çalışır.
set -eu

log() { echo "[offsite $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Gatus sinyali (monitoring/gatus.yaml → yedekleme_offsite): eşitleme bitince başarı/başarısızlık bildirilir;
# 26 saat sinyal gelmezse veya başarısızsa e-posta uyarısı. Yalnızca günlük eşitlemede (sync) çalışır.
report() {
  [ -n "${GATUS_OFFSITE_URL:-}" ] || return 0
  wget -q -O /dev/null --post-data="" --header="Authorization: Bearer ${BACKUP_HEARTBEAT_TOKEN:-}" \
    "${GATUS_OFFSITE_URL}?success=$1${2:+&error=$2}" || log "UYARI: izleme sinyali gönderilemedi"
}
if [ "${1:-sync}" = sync ]; then
  trap 'rc=$?; if [ "$rc" -eq 0 ]; then report true; else report false "offsite-basarisiz"; fi' EXIT
fi

if [ -z "${OFFSITE_S3_BUCKET:-}" ]; then
  log "UYARI: OFFSITE_S3_BUCKET tanımlı değil — yedekler yalnızca bu sunucuda (sunucu dışı kopya yok)"
  trap - EXIT
  report false "yapilandirilmamis"
  exit 0
fi
: "${OFFSITE_S3_ENDPOINT:?OFFSITE_S3_ENDPOINT gerekli}"
: "${OFFSITE_S3_ACCESS_KEY:?OFFSITE_S3_ACCESS_KEY gerekli}"
: "${OFFSITE_S3_SECRET_KEY:?OFFSITE_S3_SECRET_KEY gerekli}"
: "${OFFSITE_ENCRYPTION_PASSWORD:?OFFSITE_ENCRYPTION_PASSWORD gerekli (kaybedilirse yedekler açılamaz)}"
: "${MINIO_BUCKET:?MINIO_BUCKET gerekli}"

# Uzak tanımları ortam değişkenleriyle (yapılandırma dosyası yok)
export RCLONE_CONFIG=/dev/null
export RCLONE_CONFIG_MINIO_TYPE=s3 RCLONE_CONFIG_MINIO_PROVIDER=Minio \
  RCLONE_CONFIG_MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}" \
  RCLONE_CONFIG_MINIO_ACCESS_KEY_ID="$MINIO_ROOT_USER" RCLONE_CONFIG_MINIO_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"
export RCLONE_CONFIG_REMOTE_TYPE=s3 RCLONE_CONFIG_REMOTE_PROVIDER="${OFFSITE_S3_PROVIDER:-Other}" \
  RCLONE_CONFIG_REMOTE_ENDPOINT="$OFFSITE_S3_ENDPOINT" RCLONE_CONFIG_REMOTE_REGION="${OFFSITE_S3_REGION:-auto}" \
  RCLONE_CONFIG_REMOTE_ACCESS_KEY_ID="$OFFSITE_S3_ACCESS_KEY" RCLONE_CONFIG_REMOTE_SECRET_ACCESS_KEY="$OFFSITE_S3_SECRET_KEY" \
  RCLONE_CONFIG_REMOTE_NO_CHECK_BUCKET=true
RCLONE_CONFIG_SECURE_PASSWORD="$(rclone obscure "$OFFSITE_ENCRYPTION_PASSWORD")"
export RCLONE_CONFIG_SECURE_TYPE=crypt RCLONE_CONFIG_SECURE_PASSWORD \
  RCLONE_CONFIG_SECURE_REMOTE="remote:$OFFSITE_S3_BUCKET/${OFFSITE_PREFIX:-istanbulofset}"

retention="${OFFSITE_RETENTION_DAYS:-30}"

case "${1:-sync}" in
  sync)
    log "veritabanı yedekleri gönderiliyor"
    rclone copy /backups secure:db --include 'istanbulofset-*.dump' --stats-one-line --stats 0
    rclone delete secure:db --min-age "${retention}d"

    # Silinen/üzerine yazılan medya ${retention} gün media-deleted/<tarih> altında tutulur (yanlışlıkla silmeye karşı).
    log "medya eşitleniyor: minio:$MINIO_BUCKET"
    rclone sync "minio:$MINIO_BUCKET" secure:media \
      --backup-dir "secure:media-deleted/$(date -u +%Y%m%d)" --fast-list --stats-one-line --stats 0
    rclone delete secure:media-deleted --min-age "${retention}d" --rmdirs

    count="$(rclone lsf secure:db | wc -l | tr -d ' ')"
    log "tamam — hedefte $count veritabanı yedeği"
    if [ -n "${OFFSITE_HEARTBEAT_URL:-}" ]; then
      wget -q -O /dev/null "$OFFSITE_HEARTBEAT_URL" || log "UYARI: heartbeat gönderilemedi"
    fi
    ;;
  list)
    out="$(rclone lsl secure:db | sort -k2,3)"
    if [ -z "$out" ]; then
      log "hedefte yedek görünmüyor — bucket/önek boş ya da OFFSITE_ENCRYPTION_PASSWORD yanlış (yanlış parolada dosyalar gizlenir)"
      exit 1
    fi
    echo "$out"
    ;;
  fetch-db)
    : "${2:?dosya adı gerekli (offsite.sh list)}"
    rclone copy "secure:db/$2" /backups
    log "indirildi: /backups/$2 — şimdi: ./backup/restore.sh $2"
    ;;
  restore-media)
    rclone copy secure:media "minio:$MINIO_BUCKET" --stats-one-line --stats 10s
    log "medya geri yüklendi: minio:$MINIO_BUCKET"
    ;;
  *)
    echo "Kullanım: offsite.sh [sync|list|fetch-db <dosya>|restore-media]" >&2
    exit 2
    ;;
esac
