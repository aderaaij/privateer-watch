#!/bin/bash
#
# Privado VPN Generate Config Script - Adapted for Synology Environment
# Generates WireGuard configuration and updates .env file
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

# Configuration
CLIENT_API_URL="${CLIENT_API_URL:-https://client-api.privado.io/v1}"
USER_AGENT="${USER_AGENT:-App: 3.0.0 (576942783), macOS: Version 12.4 (Build 21F79)}"
PRIVADO_DATA_DIR="$SCRIPT_DIR/data"
LOGIN_TOKEN_FILE="$PRIVADO_DATA_DIR/token.json"
SERVERS_JSON="$PRIVADO_DATA_DIR/servers.json"

# Function to show usage
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

# Function to find server by location
find_server() {
    local location="$1"
    local location_lower=$(echo "$location" | tr '[:upper:]' '[:lower:]')
    
    # Try exact matches first (country code, city, server name)
    local server=$(jq -c --arg loc "$location_lower" '
        .servers[] | select(
            (.country | ascii_downcase) == $loc or
            (.city | ascii_downcase) == $loc or
            (.name | ascii_downcase) == $loc
        )
    ' "$SERVERS_JSON" | head -1)
    
    if [ -z "$server" ] || [ "$server" = "null" ]; then
        # Try partial matches
        server=$(jq -c --arg loc "$location_lower" '
            .servers[] | select(
                (.country | ascii_downcase | contains($loc)) or
                (.city | ascii_downcase | contains($loc)) or
                (.name | ascii_downcase | contains($loc))
            )
        ' "$SERVERS_JSON" | head -1)
    fi
    
    echo "$server"
}

# Function to login to WireGuard server (connects directly to server)
login_wireguard_server() {
    local server_name="$1"
    local wg_config_file="$PRIVADO_DATA_DIR/wg_config_$(echo "$server_name" | sed 's/[^a-zA-Z0-9]/_/g').json"
    
    # Ensure credentials are available
    if [ -z "$PRIVADO_USERNAME" ] || [ -z "$PRIVADO_PASSWORD" ]; then
        echo "ERROR: Privado credentials not available" >&2
        return 1
    fi
    
    echo "Requesting WireGuard credentials from server: $server_name" >&2
    echo "Server API URL: https://$server_name:44121/api/1.0/login" >&2
    
    # First, capture the response to a temporary file for debugging
    local temp_response="/tmp/privado_wg_$$"
    
    HTTP_CODE=$(curl "https://$server_name:44121/api/1.0/login" \
        --compressed --silent \
        -X POST \
        -H "User-Agent: $USER_AGENT" \
        -H 'Accept-Encoding: gzip, deflate, br' \
        -H 'Content-Type: application/json' \
        -w "%{http_code}" \
        -o "$temp_response" \
        -d "{
            \"Username\": \"$PRIVADO_USERNAME\",
            \"Password\": \"$PRIVADO_PASSWORD\"
        }")
    
    echo "WireGuard Server Response Code: $HTTP_CODE" >&2
    
    if [ "$HTTP_CODE" -eq 200 ]; then
        # Check if response is valid JSON
        if jq . "$temp_response" >/dev/null 2>&1; then
            # Ensure directory exists
            mkdir -p "$(dirname "$wg_config_file")" >&2
            
            # Debug: Show what we received
            echo "✓ Valid JSON response received" >&2
            echo "Response preview:" >&2
            jq . "$temp_response" | head -10 >&2
            
            # Save the config
            cat "$temp_response" > "$wg_config_file"
            rm -f "$temp_response"
            echo "$wg_config_file"
            return 0
        else
            echo "ERROR: Invalid JSON response from WireGuard server" >&2
            echo "Raw response:" >&2
            cat "$temp_response" >&2
            rm -f "$temp_response"
            return 1
        fi
    else
        echo "ERROR: WireGuard server request failed - HTTP $HTTP_CODE" >&2
        echo "Response content:" >&2
        cat "$temp_response" >&2
        rm -f "$temp_response"
        return 1
    fi
}

# Function to update .env file
update_env_file() {
    local endpoint_ip="$1"
    local endpoint_port="$2"
    local public_key="$3"
    local private_key="$4"
    local addresses="$5"
    local server_info="$6"
    
    local env_file="$ROOT_DIR/.env"
    local backup_file="$ROOT_DIR/backups/.env.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Create backup
    mkdir -p "$ROOT_DIR/backups"
    cp "$env_file" "$backup_file"
    echo "✓ Backup created: $backup_file"
    
    # Update .env file (use | as delimiter to avoid issues with / in IP addresses)
    sed -i.tmp \
        -e "s|^WIREGUARD_ENDPOINT_IP=.*|WIREGUARD_ENDPOINT_IP=\"$endpoint_ip\"|" \
        -e "s|^WIREGUARD_ENDPOINT_PORT=.*|WIREGUARD_ENDPOINT_PORT=\"$endpoint_port\"|" \
        -e "s|^WIREGUARD_PUBLIC_KEY=.*|WIREGUARD_PUBLIC_KEY=\"$public_key\"|" \
        -e "s|^WIREGUARD_PRIVATE_KEY=.*|WIREGUARD_PRIVATE_KEY=\"$private_key\"|" \
        -e "s|^WIREGUARD_ADDRESSES=.*|WIREGUARD_ADDRESSES=\"$addresses\"|" \
        "$env_file"
    
    rm -f "$env_file.tmp"
    
    echo "✓ .env file updated with new WireGuard configuration"
    echo "  Server: $server_info"
    echo "  Endpoint: $endpoint_ip:$endpoint_port"
    echo "  VPN IP: $addresses"
}

# Main script
if [ $# -lt 1 ]; then
    usage
fi

LOCATION="$1"
UPDATE_ENV="${2:-false}"

# Check dependencies
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required but not installed" >&2; exit 254; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed" >&2; exit 254; }

# Check if logged in
if [ ! -f "$LOGIN_TOKEN_FILE" ]; then
    echo "ERROR: Not logged in. Run privado_login.sh first" >&2
    exit 100
fi

# Check if servers list exists
if [ ! -f "$SERVERS_JSON" ]; then
    echo "ERROR: Server list not found. Run privado_get_servers.sh first" >&2
    exit 101
fi

# Find server
echo "Searching for server: $LOCATION"
SERVER=$(find_server "$LOCATION")

if [ -z "$SERVER" ] || [ "$SERVER" = "null" ]; then
    echo "ERROR: No server found for location: $LOCATION" >&2
    echo "Available locations:" >&2
    jq -r '.servers[] | "\(.country) - \(.city) - \(.name)"' "$SERVERS_JSON" | sort | uniq >&2
    exit 102
fi

# Extract server information
SERVER_ID=$(echo "$SERVER" | jq -r '.pop')
SERVER_NAME=$(echo "$SERVER" | jq -r '.name')
SERVER_CITY=$(echo "$SERVER" | jq -r '.city')
SERVER_COUNTRY=$(echo "$SERVER" | jq -r '.country')
SERVER_IP=$(echo "$SERVER" | jq -r '.ip_address')

echo "✓ Found server: $SERVER_NAME ($SERVER_CITY, $SERVER_COUNTRY)"

# Ensure data directory exists
mkdir -p "$PRIVADO_DATA_DIR"

# Login to WireGuard server and get configuration
WG_CONFIG_FILE=$(login_wireguard_server "$SERVER_NAME")

if [ -z "$WG_CONFIG_FILE" ] || [ ! -f "$WG_CONFIG_FILE" ]; then
    echo "ERROR: Failed to get WireGuard configuration" >&2
    echo "Expected file: $WG_CONFIG_FILE" >&2
    exit 103
fi

echo "✓ WireGuard configuration received: $WG_CONFIG_FILE"

# Extract WireGuard configuration details from server response
PRIVATE_KEY=$(jq -r '.WGPrivateKey' "$WG_CONFIG_FILE")
PUBLIC_KEY=$(jq -r '.ServerPublicKey' "$WG_CONFIG_FILE")
VPN_IP=$(jq -r '.WGIPAddress' "$WG_CONFIG_FILE")
ENDPOINT_PORT="51820"

if [ -z "$PRIVATE_KEY" ] || [ "$PRIVATE_KEY" = "null" ] || 
   [ -z "$PUBLIC_KEY" ] || [ "$PUBLIC_KEY" = "null" ] ||
   [ -z "$VPN_IP" ] || [ "$VPN_IP" = "null" ]; then
    echo "ERROR: Invalid WireGuard configuration received" >&2
    echo "Response content:" >&2
    cat "$WG_CONFIG_FILE" >&2
    exit 104
fi

# Add CIDR notation if not present
if [[ ! "$VPN_IP" =~ /[0-9]+$ ]]; then
    VPN_IP="$VPN_IP/32"
fi

echo "✓ WireGuard configuration generated:"
echo "  Server: $SERVER_NAME ($SERVER_CITY, $SERVER_COUNTRY)"
echo "  Endpoint: $SERVER_IP:$ENDPOINT_PORT"
echo "  VPN IP: $VPN_IP"
echo "  Public Key: ${PUBLIC_KEY:0:20}..."
echo "  Private Key: [hidden]"

# Update .env file if requested
if [ "$UPDATE_ENV" = "true" ]; then
    update_env_file "$SERVER_IP" "$ENDPOINT_PORT" "$PUBLIC_KEY" "$PRIVATE_KEY" "$VPN_IP" "$SERVER_NAME ($SERVER_CITY, $SERVER_COUNTRY)"
    echo "✓ Configuration updated successfully!"
else
    echo ""
    echo "To update your .env file, run:"
    echo "$0 $LOCATION true"
fi

echo ""
echo "WireGuard config saved to: $WG_CONFIG_FILE"