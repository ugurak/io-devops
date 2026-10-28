# İstanbul Ofset — DevOps

veraius `dev-ops` düzenini referans alan, `istanbulofset` üretim yığını için ayrılmış altyapı deposu (`io-devops`).

Kaynak uygulama: monorepo (`APP_ROOT`, varsayılan `/var/istanbulofset`). Bu repo yalnızca Docker Compose, Caddy, yedekleme ve orkestrasyon script’lerini tutar.

---

## Mimari

```
Client (HTTPS)
  │
  ▼
Caddy (Let's Encrypt, 80/443)
  ├─ SITE_DOMAIN  → web:3000
  └─ API_DOMAIN   → api:8080
       │
       ▼
  istanbulofset-proxy (external Docker network)
       │
       ├─ postgres / redis / minio
       ├─ elasticsearch / logstash / kibana
       └─ backup (günlük pg_dump)
```

| Katman | Klasör |
|--------|--------|
| Reverse proxy | veraius `nginx-proxy` (`VIRTUAL_HOST`) — `caddy/` kullanılmaz |
| Uygulama | `app/` (api + web build) |
| Veritabanı | `db/postgres`, `db/redis` |
| Nesne depolama | `minio/` |
| Logging | `elk/` |
| Yedek | `backup/` |

---

## Klasör yapısı

```
dev-ops/
├── README.md
├── .env / .env.example
├── _lib.sh
├── deploy.sh          # sıralı kurulum
├── update.sh          # app rebuild
├── stop.sh / down.sh
├── db/postgres/
├── db/redis/
├── minio/
├── elk/               # + logstash/pipeline.conf
├── nginx/vhost.d/     # api body-size → veraius nginx'e symlink
├── caddy/             # (eski; kullanılmaz — nginx-proxy)
├── app/               # api + web (+ VIRTUAL_HOST)
└── backup/            # backup.sh / restore.sh
```

---

## İlk kurulum

1. DNS: `dev.istanbulofset.net`, `www.dev.istanbulofset.net`, `api.istanbulofset.net` → sunucu A kaydı  
2. Monorepo sunucuda: `/var/istanbulofset` (veya `.env` içinde `APP_ROOT`)  
3. Bu repo: `/var/istanbulofset/dev-ops` (veya ayrı clone)  
4. `.env` değerlerini doldurun (`POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `JWT_SIGNING_KEY`, MinIO, Elastic, SMTP, …)  
5. Başlat (önerilen — boş şifreleri üretir, sonra deploy):

```bash
cd /var/istanbulofset/dev-ops
chmod +x start.sh deploy.sh stop.sh down.sh update.sh app/up.sh backup/restore.sh backup/backup.sh registry/local-push.sh
./start.sh                 # secrets + deploy
./start.sh --secrets-only  # yalnızca .env doldur
./start.sh --force         # secret’ları yeniden üret
```

Sıra: ELK → Postgres/Redis → MinIO → backup → api/web (registry pull) → Caddy.

```bash
./deploy.sh --infra-only   # yalnızca altyapı
./deploy.sh --app-only     # api/web + caddy (pull)
./update.sh                # registry pull + recreate
./stop.sh                  # stop
./down.sh                  # app+caddy down
./down.sh --all            # tüm stack
./down.sh --all -v         # volume’lar dahil (destructive)
```

### İmaj build + push (geliştirici makinesi)

Script monorepo’da: `istanbulofset/.github/local-push.sh`

```bash
cd /Users/akuqr/Documents/GitHub/istanbulofset
./.github/local-push.sh            # api + web → registry.veraius.com
./.github/local-push.sh api
./.github/local-push.sh web
./.github/local-push.sh --tag $(git rev-parse --short HEAD) all
```

İmajlar: `registry.veraius.com/istanbulofset-api`, `…/istanbulofset-web`. Auth: `.github/config.env`.  
`io/dev-ops/registry/local-push.sh` aynı scripte yönlendirir.

---

## Sağlık

| Uç | Anlam |
|----|--------|
| `https://api.istanbulofset.net/live` | süreç ayakta |
| `https://api.istanbulofset.net/ready` | Postgres + Redis |
| `https://dev.istanbulofset.net/` | Next.js |

Kibana / MinIO console / ES prod’da dışarı açılmaz (yalnızca `istanbulofset-proxy`).

---

## Yedekleme

- `backup` servisi her 24 saatte `pg_dump` (custom); `BACKUP_RETENTION_DAYS` (varsayılan 14).  
- Yedekleri sunucu dışına kopyalayın; MinIO `miniodata` ayrı yedeklenmeli.

```bash
./backup/restore.sh istanbulofset-20261026T000000Z.dump
```

---

## veraius ile farklar

| | veraius | istanbulofset (bu repo) |
|--|---------|-------------------------|
| Proxy | nginx-proxy + ACME | Caddy |
| Gateway | Kong (multi-tenant) | yok (doğrudan Caddy → api/web) |
| Ağ | `veraius-proxy` | `istanbulofset-proxy` |
| Kapsam | onlarca servis + tenant | tek ürün yığını (`deploy/` ihtiyaçları) |

Monolitik referans: uygulama reposundaki `deploy/docker-compose.prod.yml`. Bu depo aynı servisleri veraius tarzı modüler klasörlere böler.

---

## Kaynak eşlemesi

| Eski (`istanbulofset/deploy`) | Yeni |
|-------------------------------|------|
| `docker-compose.prod.yml` | `db/*`, `minio/`, `elk/`, `app/`, `caddy/`, `backup/` |
| `Caddyfile` | `caddy/Caddyfile` |
| `.env.example` | kök `.env` / `.env.example` |
| `backup.sh` / `restore.sh` | `backup/` |
| `logstash/pipeline.conf` | `elk/logstash/pipeline.conf` |
