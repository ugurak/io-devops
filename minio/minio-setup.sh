#!/bin/sh
# MinIO uygulama kullanıcısı (her açılışta güvenle tekrar çalışır):
# API root kullanıcısıyla değil, yalnızca MINIO_BUCKET'a okuma/yazma yetkili MINIO_APP_USER ile bağlanır.
# MINIO_APP_USER/MINIO_APP_PASSWORD boşsa hiçbir şey yapmaz (uygulama root kullanıcısıyla devam eder).
set -eu

if [ -z "${MINIO_APP_USER:-}" ] || [ -z "${MINIO_APP_PASSWORD:-}" ]; then
  echo "MINIO_APP_USER/MINIO_APP_PASSWORD tanımlı değil — uygulama kullanıcısı oluşturulmadı (root kullanılıyor)"
  exit 0
fi

for i in $(seq 1 30); do
  mc alias set io http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 && break
  echo "MinIO bekleniyor ($i)"; sleep 3
done

mc mb --ignore-existing "io/$MINIO_BUCKET"

cat > /tmp/policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::${MINIO_BUCKET}"] },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::${MINIO_BUCKET}/*"] }
  ]
}
JSON

mc admin policy create io istanbulofset-app /tmp/policy.json
mc admin user add io "$MINIO_APP_USER" "$MINIO_APP_PASSWORD"
mc admin policy attach io istanbulofset-app --user "$MINIO_APP_USER" 2>/dev/null || true
echo "MinIO uygulama kullanıcısı hazır: $MINIO_APP_USER → $MINIO_BUCKET"
