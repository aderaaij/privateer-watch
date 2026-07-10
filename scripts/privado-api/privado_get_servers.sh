#!/bin/bash
#
# privado_get_servers.sh — back-compat wrapper around the privado-wg CLI.
#
# The Privado API client was extracted to its own project:
#   https://github.com/aderaaij/privado-wg
# A copy is vendored alongside this script as `privado-wg`. This wrapper only
# loads credentials from the stack .env and keeps the documented command line
# (docs, DSM tasks, auto_update_wireguard.sh) stable.
#
# Always refreshes the cached server list, matching the old script's behavior.
# The location table normally printed by `privado-wg servers` is suppressed to
# keep task logs quiet.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# .env must exist (holds the Privado credentials)
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE" >&2
    exit 1
fi
load_env

export PRIVADO_WG_DATA_DIR="${PRIVADO_WG_DATA_DIR:-$SCRIPT_DIR/data}"
exec "$SCRIPT_DIR/privado-wg" servers --refresh "$@" >/dev/null
