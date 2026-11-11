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
       ├─ elasticsearch / logstash / kibana (+ hazır pano, site araması)
       ├─ backup (günlük pg_dump)
       ├─ gatus (çalışma süresi izleme, e-posta uyarısı)
       └─ EXTRA_STACKS: clamav · glitchtip · observability (otel/jaeger/prometheus/grafana)
```

| Katman | Klasör |
|--------|--------|
| Reverse proxy | veraius `nginx-proxy` (`VIRTUAL_HOST`) — `caddy/` kullanılmaz |
| Uygulama | `app/` (api + web build) |
| Veritabanı | `db/postgres`, `db/redis` |
| Nesne depolama | `minio/` |
| Logging | `elk/` (+ `kibana/` hazır pano, `elastic-setup.sh`) |
| Yedek | `backup/` |
| Çalışma süresi izleme | `monitoring/` (Gatus, her zaman açık) |
| Virüs taraması | `clamav/` (isteğe bağlı) |
| Hata takibi | `glitchtip/` (isteğe bağlı) |
| Metrik + iz | `observability/` (isteğe bağlı) |

### Kaynak bütçesi (8 CPU / 16 GB)

Compose `deploy.resources.limits` toplamı **8 CPU + 15G**; ~1G OS/nginx-proxy için boş.

| Servis | CPU | RAM |
|--------|-----|-----|
| api | 2.0 | 3G |
| web | 1.5 | 2G |
| postgres | 1.5 | 4G |
| redis | 0.5 | 1G |
| minio | 0.5 | 1G |
| elasticsearch | 1.0 | 2G (`ES_JAVA_OPTS` 1g) |
| logstash | 0.5 | 1G |
| kibana | 0.5 | 1G |
| gatus | 0.25 | 128M |
| *clamav* (isteğe bağlı) | 0.5 | 2G |
| *glitchtip* (isteğe bağlı) | 0.5 | 768M |
| *observability* (isteğe bağlı) | 1.0 | 1.25G (collector 256M, jaeger 384M, prometheus 384M, grafana 256M) |

Limitler üst sınırdır; gerçek kullanım çok daha düşüktür. Varsayılan `EXTRA_STACKS="glitchtip observability"`;
ClamAV imza veritabanını belleğe yüklediği için (~1,5G sürekli) yalnızca bellek yetiyorsa ekleyin.

### İsteğe bağlı yığınlar ve uygulama bağlantıları

`.env` → `EXTRA_STACKS` (boşlukla): `clamav`, `glitchtip`, `observability`. `deploy.sh` / `update.sh --infra`
yalnızca açık olanları kaldırır; `_lib.sh` (`derive_stack_env`) uygulamaya bağlantıları kendisi verir:

| Yığın | API / web ortamı |
|-------|------------------|
| observability | `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317` |
| glitchtip | `SENTRY_DSN_API=http://<GLITCHTIP_API_KEY>@glitchtip:8000/1`, `SENTRY_DSN_WEB=…/2` |
| clamav | `CLAMAV_ADDRESS=clamav:3310` (API `Uploads__ClamAv`) |

Web her zaman `ELASTICSEARCH_URL=http://elasticsearch:9200` ile site araması yapar (ES yoksa yerel aramaya düşer).
Yönetim panelindeki **Sistem durumu** bu bağlantıların hepsini (antivirus, error-tracking, tracing, logs, email…) gösterir.

Arayüzler dışarı açılmaz; SSH tüneliyle bakılır (konteyner IP'si: `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' istanbulofset-grafana`):
Kibana 5601 (elastic), Grafana 3000 (admin / `GRAFANA_ADMIN_PASSWORD`), Jaeger 16686, Gatus 8080,
GlitchTip 8000 (`GLITCHTIP_ADMIN_EMAIL` / `GLITCHTIP_ADMIN_PASSWORD`; `GLITCHTIP_HOST` verilirse nginx-proxy ile yayınlanır).

Kesinti e-postaları (Gatus) ve sipariş e-postaları için `SMTP_HOST` gerçek bir sunucu olmalı (`localhost` ile gönderilmez).

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
├── elk/               # + logstash/pipeline.conf, kibana/ (pano), elastic-setup.sh
├── monitoring/        # Gatus (gatus.yaml)
├── clamav/            # isteğe bağlı
├── glitchtip/         # isteğe bağlı (provision.py)
├── observability/     # isteğe bağlı (otel-collector, prometheus, grafana/)
├── nginx/vhost.d/     # api body-size → veraius nginx'e symlink
├── caddy/             # (eski; kullanılmaz — nginx-proxy)
├── app/               # api + web (+ VIRTUAL_HOST)
└── backup/            # backup.sh / restore.sh
```

---

## İlk kurulum

1. DNS: `test.istanbulofset.net`, `www.test.istanbulofset.net`, `api.istanbulofset.net` → sunucu A kaydı  
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

Sıra: ELK → Postgres/Redis → MinIO → backup → Gatus → EXTRA_STACKS → api/web (registry pull).

> **Dikkat:** `./start.sh` argümansız **volume'ları siler** (sıfır kurulum). Çalışan sunucuda yeni anahtarları
> eklemek için `./start.sh --secrets-only`, ardından `./deploy.sh` kullanın.

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
| `https://test.istanbulofset.net/` | Next.js |

Kibana / MinIO console / ES prod’da dışarı açılmaz (yalnızca `istanbulofset-proxy`).

---

## Yedekleme

- `backup` servisi her 24 saatte `pg_dump` (custom); `BACKUP_RETENTION_DAYS` (varsayılan 14).  
- `offsite` servisi (rclone) günde bir, pg_dump'tan ~1 saat sonra: yedekleri ve MinIO bucket'ını S3 uyumlu bir hedefe
  (R2/B2/Wasabi/S3) **istemci tarafında şifreleyip** kopyalar. `.env` içinde `OFFSITE_*` değişkenleri; `OFFSITE_S3_BUCKET`
  boşsa yalnızca uyarı yazar. Hedefte `OFFSITE_RETENTION_DAYS` (30) gün tutulur; silinen medya `media-deleted/<tarih>` altında kalır.
- `OFFSITE_ENCRYPTION_PASSWORD` kaybolursa uzak yedekler açılamaz: parola yöneticisine kaydedin.
- İlk kurulum / değişiklik sonrası: `./update.sh --infra` (normal `update.sh` yalnızca api/web'i yeniler).

```bash
./backup/restore.sh istanbulofset-20261026T000000Z.dump          # yerel yedekten geri yükle

# Sunucu kaybında (yeni sunucu, .env aynı): uzak yedekten
docker exec istanbulofset-offsite sh /offsite.sh list
docker exec istanbulofset-offsite sh /offsite.sh fetch-db istanbulofset-20261026T000000Z.dump
./backup/restore.sh istanbulofset-20261026T000000Z.dump
docker exec istanbulofset-offsite sh /offsite.sh restore-media
docker logs istanbulofset-offsite --tail 20                         # son çalışmanın sonucu
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
| `elastic-setup.sh`, `kibana/` | `elk/elastic-setup.sh`, `elk/kibana/` |
| `gatus/config.yaml` | `monitoring/gatus.yaml` |
| `glitchtip/provision.py` | `glitchtip/provision.py` |
| `observability/*` | `observability/*` |
| profil `clamav` / `glitchtip` / `observability` | `EXTRA_STACKS` |

## Sürüm geri alma

CI her sürümü `latest` ile birlikte commit'in kısa SHA'sıyla da etiketler ve sunucuda tam o etiketi kurar.

```bash
./update.sh --tag 4a1f83d   # önceki sürüme dön (etiket: git log --oneline)
./update.sh --tag latest    # seçimi kaldır, güncele dön
```

Seçilen etiket `.image-tag` dosyasında durur (git dışı); `deploy.sh` ve `start.sh` de onu kullanır.
Veritabanı geçişleri geri alınmaz: eski sürüm yeni şemayla çalışır (geçişler yalnızca ekleme yapar).

## MinIO uygulama kullanıcısı

API, root yerine yalnızca `MINIO_BUCKET`'a yetkili `MINIO_APP_USER` ile bağlanır. `.env`'e
`MINIO_APP_USER` ve `MINIO_APP_PASSWORD` yazıp `./deploy.sh` çalıştırın; `minio-setup` kullanıcıyı ve
ilkeyi oluşturur. Boş bırakılırsa API root kullanıcısıyla devam eder.

## Saklama ve disk

- Elasticsearch günlükleri `LOG_RETENTION_DAYS` (30) gün sonra silinir (ILM, `elk/elastic-setup.sh`).
- Teslim edilmiş/iptal siparişlerin baskı dosyaları 365 gün sonra MinIO'dan silinir (`Uploads__ArtworkRetentionDays`, 0 = kapalı).
- Denetim kayıtları 2 yıl tutulur.
- `backup.sh` diski günde bir ölçer; `DISK_ALERT_PERCENT` (85) aşılırsa Gatus "sunucu / disk" e-posta atar.
- Kalıcı başarısız outbox işi (ör. e-fatura kesilemedi) `/health`'i 503 yapar → Gatus "Tüm bağımlılıklar" uyarısı.
