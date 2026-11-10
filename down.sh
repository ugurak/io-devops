#!/usr/bin/env bash
# Compose down — TEK giriş
#
#   ./down.sh              # yalnızca app + caddy
#   ./down.sh --all        # tüm stack
#   ./down.sh --all -v     # volume'lar dahil (destructive)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$ROOT/_lib.sh"

DO_ALL=false
DO_VOLUMES=false
DO_APP=true

usage() {
  cat <<'EOF'
Kullanım: ./down.sh [hedefler] [-v|--volumes]

  (argüman yok)     app
  --all             altyapı (elk, db, minio, backup, monitoring, EXTRA_STACKS) + app
  --infra           yalnızca altyapı
  --app
  -v|--volumes      compose down -v
EOF
}

ANY=false
for arg in "$@"; do
  case "$arg" in
    --all) DO_ALL=true; ANY=true ;;
    --infra) DO_ALL=false; DO_APP=false; DO_INFRA=true; ANY=true ;;
    --app) DO_APP=true; ANY=true ;;
    --caddy) echo -e "${YELLOW}Caddy artık yok (nginx-proxy)${NC}" ;;
    -v|--volumes) DO_VOLUMES=true ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo -e "${RED}Bilinmeyen argüman: $arg${NC}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

DO_INFRA="${DO_INFRA:-false}"
if [[ "$DO_ALL" == true ]]; then
  DO_INFRA=true
  DO_APP=true
fi

load_env
VOL_FLAG=()
[[ "$DO_VOLUMES" == true ]] && VOL_FLAG=(-v)

echo -e "${GREEN}=== İstanbul Ofset down ===${NC}"

docker rm -f istanbulofset-caddy >/dev/null 2>&1 || true

if [[ "$DO_APP" == true ]]; then
  echo -e "${YELLOW}→ app${NC}"
  compose app down "${VOL_FLAG[@]}" || true
fi
if [[ "$DO_INFRA" == true ]]; then
  DIRS=(); while read -r d; do DIRS+=("$d"); done < <(infra_dirs)
  echo -e "${YELLOW}→ ${DIRS[*]}${NC}"
  for (( i=${#DIRS[@]}-1; i>=0; i-- )); do
    compose "${DIRS[$i]}" down "${VOL_FLAG[@]+"${VOL_FLAG[@]}"}" || true
  done
fi

echo -e "${GREEN}✓ Down tamam${NC}"
stack_ps
