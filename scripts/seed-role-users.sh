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

API_URL="${API_URL:-http://localhost:5180}"
DOMAIN="${SEED_DOMAIN:-seed.istanbulofset.local}"
COUNT="${SEED_COUNT:-5}"
SHARED_PASSWORD="${SEED_PASSWORD:-}"
DOCKER_POSTGRES="${DOCKER_POSTGRES:-istanbulofset-postgres}"
PGDATABASE="${PGDATABASE:-istanbulofset}"
PGUSER="${PGUSER:-istanbulofset}"
# Yerel compose: host 5434 / parola: container içi
PGHOST="${PGHOST:-}"
PGPORT="${PGPORT:-}"
PGPASSWORD="${PGPASSWORD:-}"

ROLES=(Customer Operator Admin)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password) SHARED_PASSWORD="${2:?}"; shift 2 ;;
    --count) COUNT="${2:?}"; shift 2 ;;
    --domain) DOMAIN="${2:?}"; shift 2 ;;
    --api) API_URL="${2:?}"; shift 2 ;;
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
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -c "$sql"
  elif docker inspect "$DOCKER_POSTGRES" >/dev/null 2>&1; then
    docker exec -i "$DOCKER_POSTGRES" \
      env PGPASSWORD="${PGPASSWORD:-}" \
      psql -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -c "$sql"
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
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"password":sys.argv[2],"fullName":sys.argv[3],"companyName":"Seed Co","acceptedKvkk":True}))' "$email" "$password" "$full_name")"
  local code
  code="$(curl -sS -o /tmp/io-seed-reg.json -w '%{http_code}' \
    -X POST "$API_URL/api/v1/auth/register" \
    -H 'content-type: application/json' \
    -d "$body" || true)"
  case "$code" in
    200) echo "ok" ;;
    409)
      # zaten var — şifreyi bilemeyiz; atla veya yeniden kullan
      echo "exists"
      ;;
    *)
      echo "fail:$code:$(head -c 200 /tmp/io-seed-reg.json 2>/dev/null || true)" >&2
      return 1
      ;;
  esac
}

echo "=== İstanbul Ofset seed kullanıcılar ==="
echo "  API     : $API_URL"
echo "  Domain  : $DOMAIN"
echo "  Adet/rol: $COUNT"
echo "  Roller  : ${ROLES[*]}"
echo ""

# Başlık
printf '%-12s  %-42s  %-24s  %s\n' "ROL" "E-POSTA" "ŞİFRE" "DURUM"
printf '%-12s  %-42s  %-24s  %s\n' "------------" "------------------------------------------" "------------------------" "----------"

CRED_FILE="${CRED_FILE:-$(pwd)/seed-role-users.credentials.txt}"
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
    printf '%-12s  %-42s  %-24s  %s\n' "$role" "$email" "$password" "$status"
    if [[ "$password" != "—" && "$password" != "(mevcut — bilinmiyor)" ]]; then
      printf '%s\t%s\t%s\n' "$role" "$email" "$password" >>"$CRED_FILE"
    fi
  done
done

echo ""
echo "Toplam hedef: $(( ${#ROLES[@]} * COUNT )) kullanıcı"
echo "Kimlik bilgileri dosyası: $CRED_FILE"
echo ""
echo "Not: Personel (Admin/Operator) için Security:RequireStaffMfa açıksa yönetim paneli MFA ister."
echo "     Giriş: $API_URL → /api/v1/auth/login  veya web /giris"
