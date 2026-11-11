#!/bin/sh
# pg_dump özel biçimde günlük yedek; geri yükleme: ./backup/restore.sh
# Sonuç Gatus'a bildirilir (yedekleme_veritabani): başarısızlıkta veya 26 saat sinyal gelmezse e-posta uyarısı.
set -u

# $1 = adres, $2 = true/false, $3 = hata kodu (isteğe bağlı)
signal() {
  [ -n "$1" ] || return 0
  # busybox wget: --post-data ile POST (Gatus external endpoint).
  wget -q -O /dev/null --post-data="" --header="Authorization: Bearer ${BACKUP_HEARTBEAT_TOKEN:-}" \
    "$1?success=$2${3:+&error=$3}" \
    || echo "[yedek] uyarı: izleme sinyali gönderilemedi"
}
notify() { signal "${BACKUP_HEARTBEAT_URL:-}" "$@"; }

# Disk doluluğu (yedek diski = Docker birimlerinin diski): DISK_ALERT_PERCENT (varsayılan 85) aşılınca Gatus e-posta atar.
check_disk() {
  used="$(df -P /backups | awk 'NR==2 { gsub("%", "", $5); print $5 }')"
  limit="${DISK_ALERT_PERCENT:-85}"
  if [ -n "$used" ] && [ "$used" -ge "$limit" ]; then
    echo "[yedek] UYARI: disk %$used dolu (sınır %$limit)"
    signal "${DISK_HEARTBEAT_URL:-}" false "disk-yuzde-$used"
  else
    signal "${DISK_HEARTBEAT_URL:-}" true
  fi
}
check_disk

file="/backups/istanbulofset-$(date -u +%Y%m%dT%H%M%SZ).dump"
if ! pg_dump --format=custom --no-owner --file="$file.partial"; then
  rm -f "$file.partial"
  echo "[yedek] HATA: pg_dump başarısız"
  notify false "pg_dump-basarisiz"
  exit 1
fi
mv "$file.partial" "$file"
find /backups -name 'istanbulofset-*.dump' -mtime +"${RETENTION_DAYS:-14}" -delete
echo "yedek alındı: $file ($(du -h "$file" | cut -f1))"
notify true
