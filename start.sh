#!/usr/bin/env bash
# Sıfır kurulum: secrets → temizlik → deploy → seed kullanıcılar
#
#   ./start.sh                 # wipe + deploy + seed (önerilen)
#   ./start.sh --keep-data     # volume'ları silme (DB kalır)
#   ./start.sh --no-clean      # mevcut stack'e dokunma
#   ./start.sh --no-seed       # seed-role-users atla
#   ./start.sh --secrets-only  # yalnızca .env
#   ./start.sh --force         # secret'ları yeniden üret
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$ROOT/_lib.sh"

ENV_FILE="${ENV_FILE:-$ROOT/.env}"
EXAMPLE="$ROOT/.env.example"

SECRETS_ONLY=false
FORCE=false
DO_CLEAN=true
WIPE_VOLUMES=true
DO_SEED=true
DEPLOY_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --secrets-only) SECRETS_ONLY=true ;;
    --force) FORCE=true ;;
    --no-clean) DO_CLEAN=false ;;
    --keep-data) WIPE_VOLUMES=false ;;
    --no-seed) DO_SEED=false ;;
    --infra-only|--app-only) DEPLOY_ARGS+=("$arg") ;;
    -h|--help)
      cat <<'EOF'
Kullanım: ./start.sh [seçenekler]

  (varsayılan)     Temizlik (volume dahil) → deploy → seed (5× rol)
  --keep-data      Volume silme (DB/MinIO/ES kalır)
  --no-clean       Mevcut konteynerlere dokunma
  --no-seed        seed-role-users.sh çalıştırma
  --secrets-only   Yalnızca .env doldur
  --force          Dolu secret'ları da yeniden üret
  --infra-only / --app-only   deploy.sh'e iletilir

Seed: her rol (Customer, Operator, Admin) için 5 kullanıcı; şifreler ekranda +
  scripts/seed-role-users.credentials.txt
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
ensure_default LETSENCRYPT_EMAIL "admin@istanbulofset.net"
ensure_default APP_ROOT "/var/istanbulofset"
ensure_default DOCKER_REGISTRY "registry.veraius.com"
ensure_default IMAGE_TAG "latest"
ensure_default REGISTRY_USER "admin"
ensure_default POSTGRES_DB "istanbulofset"
ensure_default POSTGRES_USER "istanbulofset"
ensure_default MINIO_ROOT_USER "istanbulofset"
ensure_default MINIO_BUCKET "istanbulofset-uploads"
ensure_default ES_JAVA_OPTS "-Xms1g -Xmx1g"
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

current_index="$(env_get INDEXNOW_KEY)"
if [[ -z "$current_index" || "$FORCE" == true ]]; then
  env_set INDEXNOW_KEY "$(rand_uuid)"
  echo -e "  ${GREEN}+${NC} INDEXNOW_KEY"
else
  echo -e "  ${GREEN}✓${NC} INDEXNOW_KEY (mevcut)"
fi

# Registry şifresi yoksa veraius varsayılanı
if [[ -z "$(env_get REGISTRY_PASSWORD)" ]]; then
  env_set REGISTRY_PASSWORD "lKEdWWoXlX6h5CEtJlXlj7WT!"
  echo -e "  ${GREEN}+${NC} REGISTRY_PASSWORD"
fi

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
  Images        ${DOCKER_REGISTRY}/istanbulofset-*:${IMAGE_TAG}
  Admin e-posta ${ADMIN_EMAIL}
  Temizlik      clean=${DO_CLEAN} wipe_volumes=${WIPE_VOLUMES}
  Seed          ${DO_SEED}
  .env          ${ENV_FILE}
EOF

if [[ -z "$(env_get SMTP_HOST)" ]]; then
  echo ""
  echo -e "${YELLOW}Uyarı: SMTP_HOST boştu → localhost${NC}"
  env_set SMTP_HOST "localhost"
fi

if [[ "$SECRETS_ONLY" == true ]]; then
  echo ""
  echo -e "${GREEN}✓ Secrets yazıldı (--secrets-only)${NC}"
  exit 0
fi

# .env'i deploy/seed için yükle
load_env

if [[ "$DO_CLEAN" == true ]]; then
  echo ""
  clean_stack "$WIPE_VOLUMES"
fi

echo ""
echo -e "${YELLOW}Deploy başlıyor…${NC}"
"$ROOT/deploy.sh" "${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"}"

if [[ "$DO_SEED" == true ]]; then
  echo ""
  echo -e "${YELLOW}=== Seed kullanıcılar ===${NC}"
  wait_healthy istanbulofset-postgres 30 || true
  wait_healthy istanbulofset-api 90 || true
  wait_http_ready "https://${API_DOMAIN}/ready" 40 || wait_http_ready "http://127.0.0.1:8080/ready" 5 || true

  export API_URL="https://${API_DOMAIN}"
  export PGPASSWORD="$(env_get POSTGRES_PASSWORD)"
  export PGDATABASE="$(env_get POSTGRES_DB)"
  export PGUSER="$(env_get POSTGRES_USER)"
  export DOCKER_POSTGRES=istanbulofset-postgres
  export CRED_FILE="$ROOT/scripts/seed-role-users.credentials.txt"

  if [[ -x "$ROOT/scripts/seed-role-users.sh" ]]; then
    # Ortak okunabilir seed şifresi (Identity kurallarına uygun)
    "$ROOT/scripts/seed-role-users.sh" --api "$API_URL" --password "${SEED_PASSWORD:-SeedUser1a}" || {
      echo -e "${YELLOW}Seed kısmen başarısız olabilir (API/TLS henüz hazır değil). Tekrar:${NC}" >&2
      echo "  API_URL=$API_URL PGPASSWORD=… ./scripts/seed-role-users.sh --password SeedUser1a" >&2
    }
  else
    echo -e "${RED}scripts/seed-role-users.sh yok${NC}" >&2
  fi
fi

echo ""
echo -e "${GREEN}✓ start tamam${NC}"
stack_ps
