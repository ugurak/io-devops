#!/bin/sh
# pg_dump özel biçimde günlük yedek; geri yükleme: ./restore.sh
set -eu
file="/backups/istanbulofset-$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump --format=custom --no-owner --file="$file.partial"
mv "$file.partial" "$file"
find /backups -name 'istanbulofset-*.dump' -mtime +"${RETENTION_DAYS:-14}" -delete
echo "yedek alındı: $file ($(du -h "$file" | cut -f1))"
