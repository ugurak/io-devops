#!/usr/bin/env bash
# İlk / tekrarlı başlangıç: boş şifreleri üret, bağlantı varsayılanlarını yaz, stack’i aç.
#
#   ./start.sh                 # secrets (yalnızca boşlar) + deploy
#   ./start.sh --secrets-only  # yalnızca .env doldur, container yok
#   ./start.sh --force         # dolu secret’ları da yeniden üret (destructive)
#   ./start.sh --infra-only    # deploy --infra-only
#   ./start.sh --app-only      # deploy --app-only
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$ROOT/_lib.sh"

ENV_FILE="${ENV_FILE:-$ROOT/.env}"
EXAMPLE="$ROOT/.env.example"

SECRETS_ONLY=false
FORCE=false
DEPLOY_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --secrets-only) SECRETS_ONLY=true ;;
    --force) FORCE=true ;;
    --infra-only|--app-only) DEPLOY_ARGS+=("$arg") ;;
    -h|--help)
      cat <<'EOF'
Kullanım: ./start.sh [--secrets-only] [--force] [--infra-only|--app-only]

  Boş bırakılmış şifre / anahtarları openssl ile üretir, domain ve DB
  bağlantı varsayılanlarını yazar, ardından deploy.sh çalıştırır.

Üretilen (boşsa):
  POSTGRES_PASSWORD, REDIS_PASSWORD, MINIO_ROOT_PASSWORD,
  ELASTIC_PASSWORD, JWT_SIGNING_KEY, ADMIN_INITIAL_PASSWORD,
  INDEXNOW_KEY (uuid)
EOF
      exit 0
      ;;
    *)
      echo -e "${RED}Bilinmeyen argüman: $arg${NC}" >&2
      exit 1
      ;;
  esac
done

rand_b64() {
  local n="${1:-32}"
  openssl rand -base64 "$n" | tr -d '\n' | tr -d '\r'
}

rand_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null \
      || openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  fi
}

# KEY değerini oku; tırnakları soy, satır-içi # yorumunu at
env_get() {
  local key="$1" raw
  [[ -f "$ENV_FILE" ]] || { printf ''; return; }
  raw="$(grep -E "^${key}=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '\r' || true)"
  raw="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ "$raw" == \"*\" ]]; then
    raw="${raw#\"}"
    raw="${raw%\"}"
  elif [[ "$raw" == \'*\' ]]; then
    raw="${raw#\'}"
    raw="${raw%\'}"
  else
    raw="${raw%%#*}"
    raw="$(printf '%s' "$raw" | sed -e 's/[[:space:]]*$//')"
  fi
  printf '%s' "$raw"
}

# KEY=value yaz. Boşluk / shell metakarakter varsa çift tırnak (bash source güvenli).
env_set() {
  local key="$1"
  local val="$2"
  local stored="$val"
  if [[ "$val" =~ [[:space:]\$\`\"\\\<\>\|\&\;\(\)] ]]; then
    stored="\"$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
  fi
  local tmp
  tmp="$(mktemp)"
  if [[ ! -f "$ENV_FILE" ]]; then
    printf '%s=%s\n' "$key" "$stored" >"$ENV_FILE"
    return
  fi
  if grep -qE "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$stored" '
      index($0, k "=") == 1 { print k "=" v; next }
      { print }
    ' "$ENV_FILE" >"$tmp" && mv "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$stored" >>"$ENV_FILE"
    rm -f "$tmp"
  fi
}

# Boşsa (veya --force) üret
ensure_secret() {
  local key="$1"
  local bytes="${2:-32}"
  local current
  current="$(env_get "$key")"
  if [[ -n "$current" && "$FORCE" != true ]]; then
    echo -e "  ${GREEN}✓${NC} $key (mevcut)"
    return
  fi
  local generated
  generated="$(rand_b64 "$bytes")"
  env_set "$key" "$generated"
  if [[ -n "$current" && "$FORCE" == true ]]; then
    echo -e "  ${YELLOW}↻${NC} $key (yeniden üretildi)"
  else
    echo -e "  ${GREEN}+${NC} $key"
  fi
}

ensure_default() {
  local key="$1"
  local default="$2"
  local current
  current="$(env_get "$key")"
  if [[ -n "$current" && "$FORCE" != true ]]; then
    return
  fi
  if [[ -z "$current" || "$FORCE" == true ]]; then
    env_set "$key" "$default"
    echo -e "  ${GREEN}+${NC} $key=$default"
  fi
}

echo -e "${GREEN}=== İstanbul Ofset start ===${NC}"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$EXAMPLE" ]]; then
    cp "$EXAMPLE" "$ENV_FILE"
    echo -e "${YELLOW}.env yoktu → .env.example kopyalandı${NC}"
  else
    touch "$ENV_FILE"
    echo -e "${YELLOW}Boş .env oluşturuldu${NC}"
  fi
fi

echo ""
echo -e "${YELLOW}Bağlantı / kimlik varsayılanları${NC}"
ensure_default SITE_DOMAIN "dev.istanbulofset.net"
ensure_default API_DOMAIN "api.istanbulofset.net"
ensure_default APP_ROOT "/var/istanbulofset"
ensure_default DOCKER_REGISTRY "registry.veraius.com"
ensure_default IMAGE_TAG "latest"
ensure_default POSTGRES_DB "istanbulofset"
ensure_default POSTGRES_USER "istanbulofset"
ensure_default MINIO_ROOT_USER "istanbulofset"
ensure_default MINIO_BUCKET "istanbulofset-uploads"
ensure_default ES_JAVA_OPTS "-Xms512m -Xmx512m"
ensure_default BACKUP_RETENTION_DAYS "14"
ensure_default SMTP_PORT "587"
ensure_default SMTP_SECURITY "StartTls"
ensure_default SMTP_FROM "İstanbul Ofset <siparis@istanbulofset.net>"
ensure_default PAYMENT_PROVIDER "iyzico"
ensure_default IYZICO_BASE_URL "https://api.iyzipay.com"
ensure_default CARGO_PROVIDER "manual"
ensure_default CARGO_COMPANY "Yurtiçi Kargo"
ensure_default EINVOICE_PROVIDER "manual"
ensure_default ALLOW_AI_TRAINING "true"
ensure_default IOS_BUNDLE_ID "net.istanbulofset.app"
ensure_default ANDROID_PACKAGE_NAME "net.istanbulofset.app"
ensure_default ADMIN_EMAIL "admin@dev.istanbulofset.net"

echo ""
echo -e "${YELLOW}Şifreler / anahtarlar${NC}"
ensure_secret POSTGRES_PASSWORD 32
ensure_secret REDIS_PASSWORD 24
ensure_secret MINIO_ROOT_PASSWORD 32
ensure_secret ELASTIC_PASSWORD 24
ensure_secret JWT_SIGNING_KEY 48
ensure_secret ADMIN_INITIAL_PASSWORD 24

# IndexNow — uuid
current_index="$(env_get INDEXNOW_KEY)"
if [[ -z "$current_index" || "$FORCE" == true ]]; then
  env_set INDEXNOW_KEY "$(rand_uuid)"
  echo -e "  ${GREEN}+${NC} INDEXNOW_KEY"
else
  echo -e "  ${GREEN}✓${NC} INDEXNOW_KEY (mevcut)"
fi

# Özet bağlantılar (secret’ları echo etme — yalnızca host/db/user)
SITE_DOMAIN="$(env_get SITE_DOMAIN)"
API_DOMAIN="$(env_get API_DOMAIN)"
POSTGRES_DB="$(env_get POSTGRES_DB)"
POSTGRES_USER="$(env_get POSTGRES_USER)"
MINIO_ROOT_USER="$(env_get MINIO_ROOT_USER)"
MINIO_BUCKET="$(env_get MINIO_BUCKET)"
DOCKER_REGISTRY="$(env_get DOCKER_REGISTRY)"
IMAGE_TAG="$(env_get IMAGE_TAG)"
ADMIN_EMAIL="$(env_get ADMIN_EMAIL)"

echo ""
echo -e "${GREEN}Bağlantı özeti${NC}"
cat <<EOF
  Site          https://${SITE_DOMAIN}
  API           https://${API_DOMAIN}
  Postgres      Host=postgres;Database=${POSTGRES_DB};Username=${POSTGRES_USER};Password=***
  Redis         redis:6379,password=***
  MinIO         minio:9000  user=${MINIO_ROOT_USER}  bucket=${MINIO_BUCKET}
  Elasticsearch http://elasticsearch:9200  user=elastic
  Logstash      http://logstash:8080
  Images        ${DOCKER_REGISTRY}/istanbulofset-*:${IMAGE_TAG}
  Admin e-posta ${ADMIN_EMAIL}
  .env          ${ENV_FILE}
EOF

# SMTP — compose SMTP_HOST ister; boşsa placeholder
if [[ -z "$(env_get SMTP_HOST)" ]]; then
  echo ""
  echo -e "${YELLOW}Uyarı: SMTP_HOST boştu → localhost (gerçek SMTP ile değiştirin)${NC}"
  env_set SMTP_HOST "localhost"
  echo -e "  ${GREEN}+${NC} SMTP_HOST=localhost"
fi

if [[ "$SECRETS_ONLY" == true ]]; then
  echo ""
  echo -e "${GREEN}✓ Secrets yazıldı (--secrets-only; deploy atlandı)${NC}"
  exit 0
fi

echo ""
echo -e "${YELLOW}Deploy başlıyor…${NC}"
exec "$ROOT/deploy.sh" "${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"}"
