#!/bin/sh
# Kibana 8 "elastic" süper kullanıcısıyla açılmaz: yerleşik kibana_system kullanıcısının şifresini ayarlar.
# Elasticsearch güvenlik dizini hazır olana kadar tekrar dener.
set -eu
body="{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}"
for i in $(seq 1 30); do
  code=$(curl -s -o /tmp/out -w '%{http_code}' -u "elastic:${ELASTIC_PASSWORD}" -X POST \
    http://elasticsearch:9200/_security/user/kibana_system/_password -H 'content-type: application/json' -d "$body")
  if [ "$code" = "200" ]; then echo "kibana_system hazır"; exit 0; fi
  echo "deneme $i: HTTP $code $(head -c 300 /tmp/out)"
  # 4xx (ör. kısa şifre, yanlış elastic şifresi) tekrar denemekle düzelmez.
  case "$code" in 4*) exit 1;; esac
  sleep 5
done
exit 1
