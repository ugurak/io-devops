# nginx-proxy (veraius)

Bu stack **Caddy kullanmaz**. Trafik sunucudaki veraius `nginx-proxy` üzerinden gelir (`veraius-proxy` ağı).

## Kurulum

1. `app` compose `VIRTUAL_HOST` / `LETSENCRYPT_*` ile api + web’i nginx’e tanıtır.
2. API gövde limiti (`vhost.d/api.istanbulofset.net_location`): `deploy.sh` / `update.sh` kopyalar (aşağıda 4).

3. `/health` ve `/ready` dışarıya kapalı (server düzeyi `vhost.d/api.istanbulofset.net`, `deploy.sh` kopyalar):

```bash
install -m 644 /var/io/io-devops/nginx/vhost.d/api.istanbulofset.net /var/veraius/dev-ops/nginx/vhost.d/
docker exec nginx-proxy nginx -t && docker exec nginx-proxy nginx -s reload
```

4. Sürüm geçişinde eksik parça yedeği (`vhost.d/web_location`): `deploy.sh` ve `update.sh`, rolling update'ten önce
   `install_proxy_snippets` ile bunu `${SITE_DOMAIN}_location` (ve `${SITE_WWW_HOST}_location`) adıyla kopyalar.
   Eski ve yeni web konteyneri birlikte yayındayken bir sürümün sayfası diğerinin `/_next/static` parçasını isterse
   404 yerine istek diğer konteynere gider. Tüm ekler kopyalanır (sembolik bağ değil: nginx-proxy konteyneri
   io-devops yolunu görmez); location ekleri kurulmadan önce proxy'nin nginx'iyle denenir.

5. DNS: `test.istanbulofset.net`, `www.test.istanbulofset.net`, `api.istanbulofset.net` → sunucu.

Caddy container’ı varsa kaldırın: `docker rm -f istanbulofset-caddy`
