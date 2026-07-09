#!/bin/bash
#
# Privado VPN Get Servers Script - Adapted for Synology Environment
# Retrieves list of available VPN servers from Privado API
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
load_env

# Configuration
CLIENT_API_URL="${CLIENT_API_URL:-https://client-api.privado.io/v1}"
USER_AGENT="${USER_AGENT:-App: 3.0.0 (576942783), macOS: Version 12.4 (Build 21F79)}"
PRIVADO_DATA_DIR="$SCRIPT_DIR/data"
LOGIN_TOKEN_FILE="$PRIVADO_DATA_DIR/token.json"
SERVERS_JSON="$PRIVADO_DATA_DIR/servers.json"

# Check dependencies
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required but not installed" >&2; exit 254; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed" >&2; exit 254; }

# Check if logged in
if [ ! -f "$LOGIN_TOKEN_FILE" ]; then
    echo "ERROR: Not logged in. Run privado_login.sh first" >&2
    exit 100
fi

# Get access token
AUTH_TOKEN=$(jq -r '.access_token' "$LOGIN_TOKEN_FILE" 2>/dev/null)
if [ -z "$AUTH_TOKEN" ] || [ "$AUTH_TOKEN" = "null" ]; then
    echo "ERROR: Invalid auth token. Please login again" >&2
    exit 101
fi

# Create data directory
mkdir -p "$(dirname "$SERVERS_JSON")"

# Get server list
echo "Retrieving server list from Privado VPN..."

# First, capture the response to a temporary file for debugging
TEMP_RESPONSE="/tmp/privado_servers_$$"

# Make the API request
HTTP_CODE=$(curl "$CLIENT_API_URL/servers?nodes=all&includegeo=1" \
    --compressed --silent \
    -H "User-Agent: $USER_AGENT" \
    -H 'Accept-Encoding: gzip, deflate, br' \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -w "%{http_code}" \
    -o "$TEMP_RESPONSE")

echo "HTTP Response Code: $HTTP_CODE"

# Check if we got a successful HTTP response
if [ "$HTTP_CODE" -eq 200 ]; then
    # Check if response is valid JSON
    if jq . "$TEMP_RESPONSE" >/dev/null 2>&1; then
        # Copy valid JSON to servers file
        cat "$TEMP_RESPONSE" > "$SERVERS_JSON"
        
        # Verify the response contains servers
        SERVER_COUNT=$(jq '.servers | length' "$SERVERS_JSON" 2>/dev/null || echo "0")
        if [ "$SERVER_COUNT" -gt 0 ]; then
            echo "✓ Successfully retrieved $SERVER_COUNT servers"
            echo "Servers saved to: $SERVERS_JSON"
            rm -f "$TEMP_RESPONSE"
            exit 0
        else
            echo "ERROR: No servers found in response" >&2
            echo "Response content:" >&2
            cat "$TEMP_RESPONSE" >&2
            rm -f "$TEMP_RESPONSE"
            exit 1
        fi
    else
        echo "ERROR: Failed to retrieve server list - invalid JSON response" >&2
        echo "Raw response:" >&2
        cat "$TEMP_RESPONSE" >&2
        rm -f "$TEMP_RESPONSE"
        exit 1
    fi
else
    echo "ERROR: Failed to retrieve server list - HTTP $HTTP_CODE" >&2
    echo "Response content:" >&2
    cat "$TEMP_RESPONSE" >&2
    rm -f "$TEMP_RESPONSE"
    exit 1
fi