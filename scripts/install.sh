#!/usr/bin/env bash
# Public installer entrypoint. Canonical implementation lives under backend/.
# Keep this path stable — curl install URLs and docs use scripts/install.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/../backend/scripts/install.sh" "$@"
