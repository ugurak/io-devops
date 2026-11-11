#!/bin/sh
# Elasticsearch kullanıcı hazırlığı (her açılışta güvenle tekrar çalışır):
# - Kibana 8 "elastic" süper kullanıcısıyla açılmaz: yerleşik kibana_system şifresi ayarlanır.
# - Web site araması ve Logstash, yalnızca kendi dizinlerine yetkili ayrı kullanıcılarla bağlanır
#   (elastic süper kullanıcısı yalnızca yönetim/Kibana girişi için kalır).
# Elasticsearch güvenlik dizini hazır olana kadar tekrar dener.
set -eu

ES=http://elasticsearch:9200

# $1 = yöntem, $2 = yol, $3 = gövde, $4 = açıklama
call() {
  for i in $(seq 1 30); do
    code=$(curl -s -o /tmp/out -w '%{http_code}' -u "elastic:${ELASTIC_PASSWORD}" -X "$1" \
      "$ES$2" -H 'content-type: application/json' -d "$3")
    case "$code" in
      200|201) echo "$4 hazır"; return 0;;
      # 4xx (ör. kısa şifre, yanlış elastic şifresi) tekrar denemekle düzelmez.
      4*) echo "$4: HTTP $code $(head -c 300 /tmp/out)"; exit 1;;
    esac
    echo "$4 deneme $i: HTTP $code $(head -c 300 /tmp/out)"
    sleep 5
  done
  exit 1
}

call POST /_security/user/kibana_system/_password "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}" "kibana_system"

# Site araması: istanbulofset-site-<hash> dizinlerini kurar, takma adı değiştirir, eskileri siler.
call PUT /_security/role/istanbulofset_site_search \
  '{"indices":[{"names":["istanbulofset-site*"],"privileges":["all"]}]}' "istanbulofset_site_search rolü"
call PUT /_security/user/istanbulofset_web \
  "{\"password\":\"${SEARCH_ES_PASSWORD}\",\"roles\":[\"istanbulofset_site_search\"],\"full_name\":\"Web site araması\"}" "istanbulofset_web"

# Logstash: yalnızca günlük dizinlerine yazar (Elastic'in önerdiği logstash_writer yetkileri).
call PUT /_security/role/istanbulofset_log_writer \
  '{"cluster":["monitor","manage_index_templates","manage_ilm"],"indices":[{"names":["istanbulofset-logs-*"],"privileges":["write","create","create_index","manage","manage_ilm"]}]}' "istanbulofset_log_writer rolü"
call PUT /_security/user/istanbulofset_logstash \
  "{\"password\":\"${LOGSTASH_ES_PASSWORD}\",\"roles\":[\"istanbulofset_log_writer\"],\"full_name\":\"Logstash\"}" "istanbulofset_logstash"
