#!/bin/sh
# pg_dump özel biçimde günlük yedek; geri yükleme: ./backup/restore.sh
# Sonuç Gatus'a bildirilir (yedekleme_veritabani): başarısızlıkta veya 26 saat sinyal gelmezse e-posta uyarısı.
set -u

notify() {
  [ -n "${BACKUP_HEARTBEAT_URL:-}" ] || return 0
  # busybox wget: --post-data ile POST (Gatus external endpoint).
  wget -q -O /dev/null --post-data="" --header="Authorization: Bearer ${BACKUP_HEARTBEAT_TOKEN:-}" \
    "${BACKUP_HEARTBEAT_URL}?success=$1${2:+&error=$2}" \
    || echo "[yedek] uyarı: izleme sinyali gönderilemedi"
}

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
