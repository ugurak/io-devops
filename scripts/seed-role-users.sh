#!/usr/bin/env bash
# Her Identity rolü için 5 kullanıcı oluşturur ve şifreleri ekrana yazar.
#
# Roller: Customer, Operator, Admin  (Roles.All)
#
# Kullanım:
#   ./scripts/seed-role-users.sh
#   API_URL=https://api.istanbulofset.net ./scripts/seed-role-users.sh
#   ./scripts/seed-role-users.sh --password 'OrtakSifre1a'
#   ./scripts/seed-role-users.sh --count 5 --domain seed.istanbulofset.local
#
# Operator/Admin ataması: kayıt sonrası Customer kalır; rol SQL ile yükseltilir.
#   PG* veya DOCKER_POSTGRES (varsayılan: istanbulofset-postgres) gerekir.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
env_get() {
  local key="$1" f val
  for f in .env "$ROOT/.env"; do
    [[ -f "$f" ]] || continue
    val="$(grep -E "^${key}=" "$f" | head -1 | cut -d= -f2- | sed 's/\r$//; s/^"//; s/"$//')"
    [[ -n "$val" ]] && { printf '%s' "$val"; return 0; }
  done
  return 1
}

if [[ -z "${API_URL:-}" ]]; then
  if d="$(env_get API_DOMAIN 2>/dev/null)"; then
    API_URL="https://${d}"
  else
    API_URL="http://localhost:5180"
  fi
fi
DOMAIN="${SEED_DOMAIN:-seed.istanbulofset.local}"
COUNT="${SEED_COUNT:-5}"
SHARED_PASSWORD="${SEED_PASSWORD:-}"
DOCKER_POSTGRES="${DOCKER_POSTGRES:-istanbulofset-postgres}"
PGDATABASE="${PGDATABASE:-$(env_get POSTGRES_DB 2>/dev/null || echo istanbulofset)}"
PGUSER="${PGUSER:-$(env_get POSTGRES_USER 2>/dev/null || echo istanbulofset)}"
# Yerel compose: host 5434 / parola: container içi
PGHOST="${PGHOST:-}"
PGPORT="${PGPORT:-}"
PGPASSWORD="${PGPASSWORD:-$(env_get POSTGRES_PASSWORD 2>/dev/null || true)}"

ROLES=(Customer Operator Admin)
# auth rate limit: 10/dk — kayıtlar arası boşluk
SLEEP_BETWEEN="${SEED_SLEEP_BETWEEN:-7}"
SLEEP_ON_429="${SEED_SLEEP_ON_429:-65}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password) SHARED_PASSWORD="${2:?}"; shift 2 ;;
    --count) COUNT="${2:?}"; shift 2 ;;
    --domain) DOMAIN="${2:?}"; shift 2 ;;
    --api) API_URL="${2:?}"; shift 2 ;;
    --roles)
      IFS=',' read -r -a ROLES <<<"${2:?}"
      shift 2
      ;;
    --sleep) SLEEP_BETWEEN="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "Bilinmeyen argüman: $1" >&2
      exit 1
      ;;
  esac
done

rand_password() {
  # Identity: ≥8, büyük/küçük harf + rakam
  local a b
  a="$(openssl rand -base64 9 | tr -d '/+=' | head -c 10)"
  b="$(printf '%02d' $((RANDOM % 100)))"
  printf 'Io%s%sA1' "$a" "$b"
}

slug_role() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

# psql: docker exec veya host PG*
psql_exec() {
  local sql="$1"
  if [[ -n "$PGHOST" ]]; then
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -q -c "$sql" >/dev/null
  elif docker inspect "$DOCKER_POSTGRES" >/dev/null 2>&1; then
    docker exec -i "$DOCKER_POSTGRES" \
      env PGPASSWORD="${PGPASSWORD:-}" \
      psql -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -q -c "$sql" >/dev/null
  else
    echo "Postgres yok: PGHOST=… veya çalışan container DOCKER_POSTGRES=$DOCKER_POSTGRES" >&2
    return 1
  fi
}

set_role() {
  local email="$1"
  local role="$2"
  # E-posta onaylı yap; hedef rol yoksa ekle (Customer register ile gelir)
  psql_exec "
SET search_path TO identity, public;
UPDATE \"AspNetUsers\" SET \"EmailConfirmed\" = true WHERE lower(\"Email\") = lower('$email');
WITH u AS (SELECT \"Id\" AS id FROM \"AspNetUsers\" WHERE lower(\"Email\") = lower('$email')),
     r AS (SELECT \"Id\" AS id FROM \"AspNetRoles\" WHERE \"Name\" = '$role')
INSERT INTO \"AspNetUserRoles\" (\"UserId\", \"RoleId\")
SELECT u.id, r.id FROM u, r
WHERE NOT EXISTS (
  SELECT 1 FROM \"AspNetUserRoles\" ur WHERE ur.\"UserId\" = u.id AND ur.\"RoleId\" = r.id
);
"
  # Personel: Customer rolünü kaldır (panel personeli gibi)
  if [[ "$role" == "Admin" || "$role" == "Operator" ]]; then
    psql_exec "
SET search_path TO identity, public;
WITH u AS (SELECT \"Id\" AS id FROM \"AspNetUsers\" WHERE lower(\"Email\") = lower('$email')),
     cust AS (SELECT \"Id\" AS id FROM \"AspNetRoles\" WHERE \"Name\" = 'Customer')
DELETE FROM \"AspNetUserRoles\" ur
USING u, cust
WHERE ur.\"UserId\" = u.id AND ur.\"RoleId\" = cust.id;
"
  fi
}

register_user() {
  local email="$1"
  local password="$2"
  local full_name="$3"
  local body attempt=1 code
  body="$(python3 -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"password":sys.argv[2],"fullName":sys.argv[3],"companyName":"Seed Co","acceptedKvkk":True}))' "$email" "$password" "$full_name")"
  while true; do
    code="$(curl -sS -o /tmp/io-seed-reg.json -w '%{http_code}' \
      -X POST "$API_URL/api/v1/auth/register" \
      -H 'content-type: application/json' \
      -d "$body" || true)"
    case "$code" in
      200) echo "ok"; return 0 ;;
      409) echo "exists"; return 0 ;;
      429)
        if (( attempt >= 6 )); then
          echo "fail:429:rate-limit" >&2
          return 1
        fi
        echo "  rate-limit, ${SLEEP_ON_429}s bekleniyor (deneme $attempt/5)…" >&2
        sleep "$SLEEP_ON_429"
        attempt=$((attempt + 1))
        ;;
      *)
        echo "fail:$code:$(head -c 200 /tmp/io-seed-reg.json 2>/dev/null || true)" >&2
        return 1
        ;;
    esac
  done
}

echo "=== İstanbul Ofset seed kullanıcılar ==="
echo "  API     : $API_URL"
echo "  Domain  : $DOMAIN"
echo "  Adet/rol: $COUNT"
echo "  Roller  : ${ROLES[*]}"
echo "  Sleep   : ${SLEEP_BETWEEN}s (429→${SLEEP_ON_429}s)"
echo ""

# Başlık
printf '%-12s  %-42s  %-24s  %s\n' "ROL" "E-POSTA" "ŞİFRE" "DURUM"
printf '%-12s  %-42s  %-24s  %s\n' "------------" "------------------------------------------" "------------------------" "----------"

CRED_FILE="${CRED_FILE:-$ROOT/scripts/seed-role-users.credentials.txt}"
: >"$CRED_FILE"
echo "# üretildi: $(date -u +%Y-%m-%dT%H:%M:%SZ)  api=$API_URL" >>"$CRED_FILE"
printf '%s\t%s\t%s\n' "role" "email" "password" >>"$CRED_FILE"

for role in "${ROLES[@]}"; do
  slug="$(slug_role "$role")"
  for i in $(seq 1 "$COUNT"); do
    email="${slug}${i}@${DOMAIN}"
    if [[ -n "$SHARED_PASSWORD" ]]; then
      password="$SHARED_PASSWORD"
    else
      password="$(rand_password)"
    fi
    name="Seed ${role} ${i}"
    status="?"
    if out="$(register_user "$email" "$password" "$name")"; then
      case "$out" in
        ok)
          status="oluşturuldu"
          if ! set_role "$email" "$role"; then
            status="kayıt-ok; rol-SQL-hata"
          elif [[ "$role" != "Customer" ]]; then
            status="oluşturuldu+rol"
          fi
          ;;
        exists)
          status="zaten-var"
          # Rolü yine de hizala; şifre bilinmiyor → dosyaya yazma uyarı
          set_role "$email" "$role" >/dev/null 2>&1 || true
          password="(mevcut — bilinmiyor)"
          ;;
      esac
    else
      status="hata"
      password="—"
    fi
    # Ortak şifre verildiyse mevcut hesapları da credentials'a yaz
    if [[ "$status" == "zaten-var" && -n "$SHARED_PASSWORD" ]]; then
      password="$SHARED_PASSWORD"
    fi
    printf '%-12s  %-42s  %-24s  %s\n' "$role" "$email" "$password" "$status"
    if [[ "$password" != "—" && "$password" != "(mevcut — bilinmiyor)" ]]; then
      printf '%s\t%s\t%s\n' "$role" "$email" "$password" >>"$CRED_FILE"
    fi
    sleep "$SLEEP_BETWEEN"
  done
done

echo ""
echo "Toplam hedef: $(( ${#ROLES[@]} * COUNT )) kullanıcı"
echo "Kimlik bilgileri dosyası: $CRED_FILE"
echo ""
echo "Not: Personel (Admin/Operator) için Security:RequireStaffMfa açıksa yönetim paneli MFA ister."
echo "     Giriş: $API_URL → /api/v1/auth/login  veya web /giris"
