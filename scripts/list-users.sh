#!/usr/bin/env bash
# Identity kullanıcılarını rollerle listeler (Postgres).
#
# Kullanım:
#   ./scripts/list-users.sh
#   ./scripts/list-users.sh --seed          # yalnızca *@seed.* / Seed* adlar
#   ./scripts/list-users.sh --role Admin
#   PGPASSWORD=… ./scripts/list-users.sh
#   DOCKER_POSTGRES=istanbulofset-postgres ./scripts/list-users.sh
#
set -euo pipefail

DOCKER_POSTGRES="${DOCKER_POSTGRES:-istanbulofset-postgres}"
PGDATABASE="${PGDATABASE:-istanbulofset}"
PGUSER="${PGUSER:-istanbulofset}"
PGHOST="${PGHOST:-}"
PGPORT="${PGPORT:-}"
PGPASSWORD="${PGPASSWORD:-}"

FILTER_SEED=false
ROLE_FILTER=""
LIMIT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed) FILTER_SEED=true; shift ;;
    --role) ROLE_FILTER="${2:?}"; shift 2 ;;
    --limit) LIMIT="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Bilinmeyen argüman: $1" >&2
      exit 1
      ;;
  esac
done

# .env'den parola (cwd veya repo kökü)
if [[ -z "$PGPASSWORD" ]]; then
  for f in .env "$(cd "$(dirname "$0")/.." && pwd)/.env"; do
    if [[ -f "$f" ]] && grep -q '^POSTGRES_PASSWORD=' "$f"; then
      PGPASSWORD="$(grep '^POSTGRES_PASSWORD=' "$f" | head -1 | cut -d= -f2-)"
      PGPASSWORD="${PGPASSWORD%\"}"
      PGPASSWORD="${PGPASSWORD#\"}"
      export PGPASSWORD
      break
    fi
  done
fi

psql_exec() {
  local sql="$1"
  if [[ -n "$PGHOST" ]]; then
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -c "$sql"
  elif docker inspect "$DOCKER_POSTGRES" >/dev/null 2>&1; then
    docker exec -i -e PGPASSWORD="$PGPASSWORD" "$DOCKER_POSTGRES" \
      psql -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -c "$sql"
  else
    echo "Postgres yok: PGHOST=… veya çalışan container DOCKER_POSTGRES=$DOCKER_POSTGRES" >&2
    return 1
  fi
}

WHERE="TRUE"
if [[ "$FILTER_SEED" == true ]]; then
  WHERE="$WHERE AND (u.\"Email\" ILIKE '%@seed.%' OR u.\"FullName\" ILIKE 'Seed %')"
fi
if [[ -n "$ROLE_FILTER" ]]; then
  # rol adı tek tırnak kaçışı
  safe_role="${ROLE_FILTER//\'/\'\'}"
  WHERE="$WHERE AND EXISTS (
    SELECT 1 FROM identity.\"AspNetUserRoles\" ur2
    JOIN identity.\"AspNetRoles\" r2 ON r2.\"Id\" = ur2.\"RoleId\"
    WHERE ur2.\"UserId\" = u.\"Id\" AND r2.\"Name\" = '$safe_role'
  )"
fi

LIMIT_SQL=""
if [[ -n "$LIMIT" ]]; then
  LIMIT_SQL="LIMIT ${LIMIT}"
fi

SQL="
SET search_path TO identity, public;
SELECT
  COALESCE(string_agg(DISTINCT r.\"Name\", ',' ORDER BY r.\"Name\"), '(rol yok)') AS roles,
  u.\"Email\" AS email,
  COALESCE(u.\"FullName\", '') AS full_name,
  CASE WHEN u.\"EmailConfirmed\" THEN 'evet' ELSE 'hayır' END AS email_ok,
  CASE WHEN u.\"LockoutEnd\" IS NOT NULL AND u.\"LockoutEnd\" > now() THEN 'kilitli' ELSE 'aktif' END AS durum,
  to_char(u.\"CreatedAt\" AT TIME ZONE 'Europe/Istanbul', 'YYYY-MM-DD HH24:MI') AS olusturma
FROM identity.\"AspNetUsers\" u
LEFT JOIN identity.\"AspNetUserRoles\" ur ON ur.\"UserId\" = u.\"Id\"
LEFT JOIN identity.\"AspNetRoles\" r ON r.\"Id\" = ur.\"RoleId\"
WHERE $WHERE
GROUP BY u.\"Id\", u.\"Email\", u.\"FullName\", u.\"EmailConfirmed\", u.\"LockoutEnd\", u.\"CreatedAt\"
ORDER BY
  CASE
    WHEN bool_or(r.\"Name\" = 'Admin') THEN 1
    WHEN bool_or(r.\"Name\" = 'Operator') THEN 2
    WHEN bool_or(r.\"Name\" = 'Customer') THEN 3
    ELSE 9
  END,
  u.\"Email\"
$LIMIT_SQL;
"

echo "=== İstanbul Ofset kullanıcılar ==="
if [[ "$FILTER_SEED" == true ]]; then echo "  Filtre : seed"; fi
if [[ -n "$ROLE_FILTER" ]]; then echo "  Rol    : $ROLE_FILTER"; fi
echo ""

psql_exec "$SQL"

echo ""
echo "Özet:"
psql_exec "
SET search_path TO identity, public;
SELECT COALESCE(r.\"Name\", '(rol yok)') AS rol, count(DISTINCT u.\"Id\") AS adet
FROM identity.\"AspNetUsers\" u
LEFT JOIN identity.\"AspNetUserRoles\" ur ON ur.\"UserId\" = u.\"Id\"
LEFT JOIN identity.\"AspNetRoles\" r ON r.\"Id\" = ur.\"RoleId\"
GROUP BY r.\"Name\"
ORDER BY adet DESC, rol;
"
