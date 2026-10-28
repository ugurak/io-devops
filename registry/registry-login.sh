#!/usr/bin/env bash
# Private registry Basic auth (registry.veraius.com htpasswd).
#
#   ./registry-login.sh
#   REGISTRY_USER=admin REGISTRY_PASSWORD=... ./registry-login.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../_lib.sh
source "$ROOT/_lib.sh"

load_env
ensure_registry_login
echo "  Sonraki: cd $ROOT && ./update.sh   veya   ./start.sh"
