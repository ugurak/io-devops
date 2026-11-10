#!/bin/sh
# Kibana'ya hazır veri görünümü, kayıtlı aramalar, grafikler ve "İstanbul Ofset — API logları" panosunu yükler.
# Her açılışta çalışır; aynı kimlikli nesnelerin üzerine yazar (panoda elle yapılan değişiklikler sıfırlanır).
# KIBANA_URL, isteğe bağlı KIBANA_USER/KIBANA_PASSWORD ve JAEGER_URL (trace_id → iz bağlantısı) ortam değişkenleri.
set -eu
K="${KIBANA_URL:-http://kibana:5601}"
AUTH=""
[ -n "${KIBANA_USER:-}" ] && AUTH="-u ${KIBANA_USER}:${KIBANA_PASSWORD:-}"
echo "Kibana bekleniyor: $K"
until curl -sf $AUTH "$K/api/status" | grep -q '"level":"available"'; do sleep 5; done
curl -sf $AUTH -X POST "$K/api/saved_objects/_import?overwrite=true" -H 'kbn-xsrf: true' \
  --form file=@/setup/saved-objects.ndjson | grep -o '"successCount":[0-9]*'
curl -sf $AUTH -X POST "$K/api/data_views/default" -H 'kbn-xsrf: true' -H 'content-type: application/json' \
  -d '{"data_view_id":"istanbulofset-logs","force":true}' >/dev/null
if [ -n "${JAEGER_URL:-}" ]; then
  curl -sf $AUTH -X POST "$K/api/data_views/data_view/istanbulofset-logs/fields" -H 'kbn-xsrf: true' -H 'content-type: application/json' \
    -d "{\"fields\":{\"trace_id\":{\"format\":{\"id\":\"url\",\"params\":{\"urlTemplate\":\"${JAEGER_URL}/trace/{{value}}\",\"labelTemplate\":\"{{value}}\",\"openLinkInCurrentTab\":false}}}}}" >/dev/null
fi
echo "Kibana nesneleri yüklendi."
