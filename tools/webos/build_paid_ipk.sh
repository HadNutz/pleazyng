#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PLEZY_WEBOS_BILLING_MODE=paid
exec "$SCRIPT_DIR/build_ipk.sh" "$@"
