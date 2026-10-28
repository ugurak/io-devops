# nginx-proxy (veraius)

Bu stack **Caddy kullanmaz**. Trafik sunucudaki veraius `nginx-proxy` üzerinden gelir (`veraius-proxy` ağı).

## Kurulum

1. `app` compose `VIRTUAL_HOST` / `LETSENCRYPT_*` ile api + web’i nginx’e tanıtır.
2. API gövde limiti için:

```bash
ln -sf /var/io/io-devops/nginx/vhost.d/api.istanbulofset.net_location \
       /var/veraius/dev-ops/nginx/vhost.d/api.istanbulofset.net_location
docker exec nginx-proxy nginx -s reload
```

3. DNS: `dev.istanbulofset.net`, `www.dev.istanbulofset.net`, `api.istanbulofset.net` → sunucu.

Caddy container’ı varsa kaldırın: `docker rm -f istanbulofset-caddy`
