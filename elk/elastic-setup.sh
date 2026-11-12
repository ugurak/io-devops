#!/bin/sh
# Elasticsearch kullanıcı hazırlığı (her açılışta güvenle tekrar çalışır):
# - Kibana 8 "elastic" süper kullanıcısıyla açılmaz: yerleşik kibana_system şifresi ayarlanır.
# - Web site araması ve Logstash, yalnızca kendi dizinlerine yetkili ayrı kullanıcılarla bağlanır
#   (elastic süper kullanıcısı yalnızca yönetim/Kibana girişi için kalır).
# Elasticsearch güvenlik dizini hazır olana kadar tekrar dener.
set -eu

ES=http://elasticsearch:9200

# $1 = yöntem, $2 = yol, $3 = gövde, $4 = açıklama. Başarısızlıkta 1 döner; zorunlu adımlar "|| exit 1" ile durdurur.
call() {
  for i in $(seq 1 30); do
    code=$(curl -s -o /tmp/out -w '%{http_code}' -u "elastic:${ELASTIC_PASSWORD}" -X "$1" \
      "$ES$2" -H 'content-type: application/json' -d "$3") || code=000
    case "$code" in
      200|201) echo "$4 hazır"; return 0;;
      # 401: yeniden başlatmada sağlık denetimi geçse de .security dizini birkaç saniye hazır değildir ve
      # "elastic" kimliği doğrulanamaz; beklenir (şifre gerçekten yanlışsa 30 denemede vazgeçilir).
      401) ;;
      # Diğer 4xx (ör. kısa şifre, hatalı gövde) tekrar denemekle düzelmez.
      4*) echo "HATA $4: HTTP $code $(head -c 500 /tmp/out 2>/dev/null)"; return 1;;
    esac
    echo "$4 deneme $i: HTTP $code $(head -c 300 /tmp/out 2>/dev/null)"
    sleep 5
  done
  return 1
}
# İsteğe bağlı adım: başarısızsa uyarır, Kibana/Logstash açılışını engellemez.
optional() { call "$@" || echo "UYARI: $4 atlandı (Kibana/Logstash etkilenmez)"; }

call POST /_security/user/kibana_system/_password "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}" "kibana_system" || exit 1

# Site araması: istanbulofset-site-<hash> dizinlerini kurar, takma adı değiştirir, eskileri siler.
call PUT /_security/role/istanbulofset_site_search \
  '{"indices":[{"names":["istanbulofset-site*"],"privileges":["all"]}]}' "istanbulofset_site_search rolü" || exit 1
call PUT /_security/user/istanbulofset_web \
  "{\"password\":\"${SEARCH_ES_PASSWORD}\",\"roles\":[\"istanbulofset_site_search\"],\"full_name\":\"Web site araması\"}" "istanbulofset_web" || exit 1

# Logstash: yalnızca günlük dizinlerine yazar (Elastic'in önerdiği logstash_writer yetkileri).
call PUT /_security/role/istanbulofset_log_writer \
  '{"cluster":["monitor","manage_index_templates","manage_ilm"],"indices":[{"names":["istanbulofset-logs-*"],"privileges":["write","create","create_index","manage","manage_ilm"]}]}' "istanbulofset_log_writer rolü" || exit 1
call PUT /_security/user/istanbulofset_logstash \
  "{\"password\":\"${LOGSTASH_ES_PASSWORD}\",\"roles\":[\"istanbulofset_log_writer\"],\"full_name\":\"Logstash\"}" "istanbulofset_logstash" || exit 1

# İzleme (Gatus): yalnızca küme sağlığını okur (cluster:monitor); _cluster/health "red" olunca e-posta.
optional PUT /_security/role/istanbulofset_monitor '{"cluster":["monitor"]}' "istanbulofset_monitor rolü"
optional PUT /_security/user/istanbulofset_monitor \
  "{\"password\":\"${MONITOR_ES_PASSWORD}\",\"roles\":[\"istanbulofset_monitor\"],\"full_name\":\"Gatus izleme\"}" "istanbulofset_monitor"

# Günlük saklama: istanbulofset-logs-YYYY.MM.dd dizinleri LOG_RETENTION_DAYS (varsayılan 30) gün sonra silinir; disk dolmaz.
# Şablon yeni dizinlere, _settings çağrısı mevcut dizinlere uygular.
days="${LOG_RETENTION_DAYS:-30}"
optional PUT /_ilm/policy/istanbulofset-logs \
  "{\"policy\":{\"phases\":{\"hot\":{\"actions\":{}},\"delete\":{\"min_age\":\"${days}d\",\"actions\":{\"delete\":{}}}}}}" "istanbulofset-logs ILM ($days gün)"
optional PUT /_index_template/istanbulofset-logs \
  '{"index_patterns":["istanbulofset-logs-*"],"priority":200,"template":{"settings":{"index.lifecycle.name":"istanbulofset-logs","number_of_replicas":0}}}' "istanbulofset-logs şablonu"
optional PUT '/istanbulofset-logs-*/_settings?allow_no_indices=true' \
  '{"index.lifecycle.name":"istanbulofset-logs"}' "mevcut günlük dizinleri"
