#!/bin/bash
#
# Privado VPN Login Script - Adapted for Synology Environment
# Authenticates with Privado API and stores access token
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

# Validate required variables
if [ -z "${PRIVADO_USERNAME:-}" ]; then
    echo "ERROR: PRIVADO_USERNAME not set in .env file" >&2
    exit 1
fi

if [ -z "${PRIVADO_PASSWORD:-}" ]; then
    echo "ERROR: PRIVADO_PASSWORD not set in .env file" >&2
    exit 1
fi

# Configuration
API_KEY="${API_KEY:-9f994c466340e8f2ed60a99396fecb6a}"
CLIENT_API_URL="${CLIENT_API_URL:-https://client-api.privado.io/v1}"
PRIVADO_DATA_DIR="$SCRIPT_DIR/data"
LOGIN_TOKEN_FILE="$PRIVADO_DATA_DIR/token.json"
USER_AGENT="${USER_AGENT:-App: 3.0.0 (576942783), macOS: Version 12.4 (Build 21F79)}"

# Debug: Show what credentials we're using (mask password)
echo "Using username: $PRIVADO_USERNAME"
echo "Using password: ${PRIVADO_PASSWORD:0:4}****${PRIVADO_PASSWORD: -2}"
echo "Using API key: ${API_KEY:0:8}****${API_KEY: -4}"

# Check dependencies
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required but not installed" >&2; exit 254; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed" >&2; exit 254; }

# Create data directory
mkdir -p "$PRIVADO_DATA_DIR"

# Login to Privado API
echo "Authenticating with Privado VPN..."

# First, capture the response to a temporary file for debugging
TEMP_RESPONSE="/tmp/privado_response_$$"

# Make the API request
HTTP_CODE=$(curl "$CLIENT_API_URL/login" \
    --compressed --silent \
    -X POST \
    -H "User-Agent: $USER_AGENT" \
    -H 'Accept-Encoding: gzip, deflate, br' \
    -H 'Content-Type: application/json' \
    -w "%{http_code}" \
    -o "$TEMP_RESPONSE" \
    -d "{
        \"api_key\": \"$API_KEY\",
        \"password\": \"$PRIVADO_PASSWORD\",
        \"username\": \"$PRIVADO_USERNAME\"
    }")

echo "HTTP Response Code: $HTTP_CODE"

# Check if we got a successful HTTP response
if [ "$HTTP_CODE" -eq 200 ]; then
    # Check if response is valid JSON
    if jq . "$TEMP_RESPONSE" >/dev/null 2>&1; then
        # Copy valid JSON to token file
        cat "$TEMP_RESPONSE" > "$LOGIN_TOKEN_FILE"
        
        # Verify token is valid
        ACCESS_TOKEN=$(jq -r '.access_token' "$LOGIN_TOKEN_FILE" 2>/dev/null)
        if [ "$ACCESS_TOKEN" != "null" ] && [ -n "$ACCESS_TOKEN" ]; then
            echo "✓ Successfully authenticated with Privado VPN"
            echo "Token saved to: $LOGIN_TOKEN_FILE"
            rm -f "$TEMP_RESPONSE"
            exit 0
        else
            echo "ERROR: Authentication failed - no access token in response" >&2
            echo "Response content:" >&2
            cat "$TEMP_RESPONSE" >&2
            rm -f "$TEMP_RESPONSE" "$LOGIN_TOKEN_FILE"
            exit 1
        fi
    else
        echo "ERROR: Authentication failed - invalid JSON response" >&2
        echo "Raw response:" >&2
        cat "$TEMP_RESPONSE" >&2
        rm -f "$TEMP_RESPONSE"
        exit 1
    fi
else
    echo "ERROR: Authentication failed - HTTP $HTTP_CODE" >&2
    echo "Response content:" >&2
    cat "$TEMP_RESPONSE" >&2
    rm -f "$TEMP_RESPONSE"
    exit 1
fi