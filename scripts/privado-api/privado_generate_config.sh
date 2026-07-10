#!/bin/bash
#
# privado_generate_config.sh — back-compat wrapper around the privado-wg CLI.
#
# The Privado API client was extracted to its own project:
#   https://github.com/aderaaij/privado-wg
# A copy is vendored alongside this script as `privado-wg`. The CLI does all
# the API work (auth, server list, WireGuard provisioning); only the
# stack-specific part lives here: writing the WIREGUARD_* variables into the
# stack .env with a timestamped backup.
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

usage() {
    echo "Usage: $0 <server_location> [update_env]"
    echo ""
    echo "  server_location: Country code, city, or server name (e.g., 'NL', 'Amsterdam', 'nl-1')"
    echo "  update_env:      Set to 'true' to automatically update .env file (default: false)"
    echo ""
    echo "Examples:"
    echo "  $0 NL              # Generate config for Netherlands"
    echo "  $0 Amsterdam true  # Generate config for Amsterdam and update .env"
    echo ""
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

LOCATION="$1"
UPDATE_ENV="${2:-false}"

export PRIVADO_WG_DATA_DIR="${PRIVADO_WG_DATA_DIR:-$SCRIPT_DIR/data}"

# Provision credentials via the CLI (auto-login + server list refresh as needed)
CONFIG_JSON=$("$SCRIPT_DIR/privado-wg" config "$LOCATION" --format json)

ENDPOINT_IP=$(jq -r '.wireguard.endpoint_ip' <<<"$CONFIG_JSON")
ENDPOINT_PORT=$(jq -r '.wireguard.endpoint_port' <<<"$CONFIG_JSON")
PUBLIC_KEY=$(jq -r '.wireguard.public_key' <<<"$CONFIG_JSON")
PRIVATE_KEY=$(jq -r '.wireguard.private_key' <<<"$CONFIG_JSON")
VPN_IP=$(jq -r '.wireguard.address' <<<"$CONFIG_JSON")
SERVER_INFO=$(jq -r '"\(.server.name) (\(.server.city), \(.server.country))"' <<<"$CONFIG_JSON")

for var in ENDPOINT_IP ENDPOINT_PORT PUBLIC_KEY PRIVATE_KEY VPN_IP; do
    val="${!var}"
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        echo "ERROR: Invalid WireGuard configuration received (missing $var)" >&2
        exit 104
    fi
done

echo "✓ WireGuard configuration generated:"
echo "  Server: $SERVER_INFO"
echo "  Endpoint: $ENDPOINT_IP:$ENDPOINT_PORT"
echo "  VPN IP: $VPN_IP"
echo "  Public Key: ${PUBLIC_KEY:0:20}..."
echo "  Private Key: [hidden]"

if [ "$UPDATE_ENV" = "true" ]; then
    BACKUP_FILE="$ROOT_DIR/backups/.env.backup.$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$ROOT_DIR/backups"
    cp "$ENV_FILE" "$BACKUP_FILE"
    echo "✓ Backup created: $BACKUP_FILE"

    # Update .env file (use | as delimiter to avoid issues with / in IP addresses)
    sed -i.tmp \
        -e "s|^WIREGUARD_ENDPOINT_IP=.*|WIREGUARD_ENDPOINT_IP=\"$ENDPOINT_IP\"|" \
        -e "s|^WIREGUARD_ENDPOINT_PORT=.*|WIREGUARD_ENDPOINT_PORT=\"$ENDPOINT_PORT\"|" \
        -e "s|^WIREGUARD_PUBLIC_KEY=.*|WIREGUARD_PUBLIC_KEY=\"$PUBLIC_KEY\"|" \
        -e "s|^WIREGUARD_PRIVATE_KEY=.*|WIREGUARD_PRIVATE_KEY=\"$PRIVATE_KEY\"|" \
        -e "s|^WIREGUARD_ADDRESSES=.*|WIREGUARD_ADDRESSES=\"$VPN_IP\"|" \
        "$ENV_FILE"

    rm -f "$ENV_FILE.tmp"

    echo "✓ .env file updated with new WireGuard configuration"
    echo "✓ Configuration updated successfully!"
else
    echo ""
    echo "To update your .env file, run:"
    echo "$0 $LOCATION true"
fi
