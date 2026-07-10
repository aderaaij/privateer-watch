#!/bin/bash
#
# Auto Update WireGuard Configuration Script
# Fully automated VPN configuration management for Privado VPN
# 
# Features:
# - Automatic server selection based on preferences
# - Intelligent failover to backup servers
# - Performance-based server rotation
# - Health checks and recovery
# - Integration with existing monitoring system
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# .env must exist (holds Privado credentials and WIREGUARD_* settings)
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE" >&2
    exit 1
fi
load_env

# Configuration (ROOT_DIR/ENV_FILE/COMPOSE come from common.sh)
PRIVADO_API_DIR="$SCRIPT_DIR/privado-api"
LOG_FILE="$ROOT_DIR/logs/auto_wireguard.log"
GLUETUN_CONTAINER="gluetun"

# Default preferences (can be overridden in .env)
PREFERRED_COUNTRIES="${WIREGUARD_PREFERRED_COUNTRIES:-NL,DE,UK,FR}"
PREFERRED_CITIES="${WIREGUARD_PREFERRED_CITIES:-Amsterdam,Berlin,London,Paris}"
AUTO_ROTATION_ENABLED="${WIREGUARD_AUTO_ROTATION:-true}"
ROTATION_INTERVAL_HOURS="${WIREGUARD_ROTATION_INTERVAL:-24}"
MAX_LATENCY_MS="${WIREGUARD_MAX_LATENCY:-150}"
MIN_SPEED_MBPS="${WIREGUARD_MIN_SPEED:-50}"

# Function to log messages
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE" >&2
}

# Function to send notification
send_notification() {
    local title="$1"
    local message="$2"
    local level="${3:-info}"
    
    log "$level" "$title: $message"
    
    # Send Discord notification if webhook is configured
    if [ -n "${PULLIO_DISCORD_WEBHOOK:-}" ]; then
        local color="65280"  # Green
        case "$level" in
            "warning") color="16776960" ;;  # Yellow
            "error") color="16711680" ;;    # Red
        esac
        
        curl -s -X POST "$PULLIO_DISCORD_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{
                \"embeds\": [{
                    \"title\": \"🔒 $title\",
                    \"description\": \"$message\",
                    \"color\": $color,
                    \"timestamp\": \"$(date -Iseconds)\"
                }]
            }" >/dev/null 2>&1 || true
    fi
}

# Function to check if container is running
is_container_running() {
    docker ps --filter name="$GLUETUN_CONTAINER" --format "{{.Names}}" | grep -q "$GLUETUN_CONTAINER"
}

# Function to restart Gluetun container and dependents.
# Delegates to restart_vpn_stack.sh — the single canonical restart path.
# qbittorrent/sabnzbd (network_mode: service:gluetun) are pinned to gluetun's
# container ID, so they must be REMOVED and RECREATED whenever gluetun is
# recreated; a stopped dependent of a recreated gluetun can never be started.
restart_gluetun() {
    log "info" "Restarting VPN stack (gluetun + dependent containers)..."

    if VPN_STACK_LOG="$LOG_FILE" DOCKERCONFDIR="$ROOT_DIR" \
        bash "$SCRIPT_DIR/restart_vpn_stack.sh"; then
        # Bring up the rest of the stack too (idempotent for running containers)
        (cd "$ROOT_DIR" && $COMPOSE up -d) 2>/dev/null || true
        log "info" "VPN stack restarted successfully"
        return 0
    else
        log "error" "VPN stack restart failed"
        return 1
    fi
}

# Function to test server performance
test_server_performance() {
    local server_ip="$1"
    local timeout=5
    
    # Test latency
    local latency=$(ping -c 3 -W "$timeout" "$server_ip" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' | cut -d'.' -f1)
    
    if [ -z "$latency" ] || [ "$latency" = "" ]; then
        echo "999"  # High latency to indicate failure
    else
        echo "$latency"
    fi
}

# Function to get server performance metrics
get_server_metrics() {
    local server_json="$1"
    local server_ip=$(echo "$server_json" | jq -r '.ip_address')
    local server_name=$(echo "$server_json" | jq -r '.name')
    local server_load=$(echo "$server_json" | jq -r '.capacity // 0')
    
    # Test latency
    local latency=$(test_server_performance "$server_ip")
    
    # Calculate score (lower is better)
    # Score = latency + (load * 10)
    local score=$((latency + (server_load * 10)))
    
    echo "$score|$latency|$server_load|$server_name"
}

# Function to emit candidate locations (one per line, in preference order).
# For "auto", emits all preferred cities then countries so callers can try
# each in sequence until one yields a working VPN.
select_best_location() {
    local location_filter="$1"

    log "info" "Selecting best location for: '$location_filter'"

    # Specific location requested — emit just that one
    if [ "$location_filter" != "auto" ]; then
        echo "$location_filter"
        return 0
    fi

    IFS=',' read -ra CITIES <<< "$PREFERRED_CITIES"
    IFS=',' read -ra COUNTRIES <<< "$PREFERRED_COUNTRIES"

    log "info" "Preferred cities: ${CITIES[*]}"
    log "info" "Preferred countries: ${COUNTRIES[*]}"

    local emitted=0
    for city in "${CITIES[@]}"; do
        city=$(echo "$city" | xargs)
        if [ -n "$city" ]; then
            echo "$city"
            emitted=$((emitted + 1))
        fi
    done
    for country in "${COUNTRIES[@]}"; do
        country=$(echo "$country" | xargs)
        if [ -n "$country" ]; then
            echo "$country"
            emitted=$((emitted + 1))
        fi
    done

    if [ "$emitted" -eq 0 ]; then
        log "info" "No preferences configured; using fallback: Amsterdam"
        echo "Amsterdam"
    fi
    return 0
}

# Function to check if rotation is needed
needs_rotation() {
    local last_rotation_file="$ROOT_DIR/logs/last_rotation"
    
    if [ ! -f "$last_rotation_file" ]; then
        return 0  # No rotation record, needs rotation
    fi
    
    local last_rotation=$(cat "$last_rotation_file")
    local current_time=$(date +%s)
    local rotation_interval=$((ROTATION_INTERVAL_HOURS * 3600))
    
    if [ $((current_time - last_rotation)) -ge "$rotation_interval" ]; then
        return 0  # Time for rotation
    else
        return 1  # Not time yet
    fi
}

# Function to update rotation timestamp
update_rotation_timestamp() {
    local last_rotation_file="$ROOT_DIR/logs/last_rotation"
    date +%s > "$last_rotation_file"
}

# Function to authenticate with Privado
authenticate_privado() {
    if [ ! -f "$PRIVADO_API_DIR/data/token.json" ]; then
        log "info" "Authenticating with Privado VPN..."
        if ! "$PRIVADO_API_DIR/privado_login.sh"; then
            log "error" "Failed to authenticate with Privado VPN"
            return 1
        fi
    else
        # Check if token is still valid (simple check).
        # GNU stat (Synology) uses -c %Y; BSD/macOS stat uses -f %m.
        local token_file="$PRIVADO_API_DIR/data/token.json"
        local token_mtime
        token_mtime=$(stat -c %Y "$token_file" 2>/dev/null || stat -f %m "$token_file" 2>/dev/null || echo 0)
        local token_age=$(( $(date +%s) - token_mtime ))
        if [ "$token_age" -gt 3600 ]; then  # Token older than 1 hour
            log "info" "Token expired, re-authenticating..."
            if ! "$PRIVADO_API_DIR/privado_login.sh"; then
                log "error" "Failed to re-authenticate with Privado VPN"
                return 1
            fi
        fi
    fi
    
    return 0
}

# Function to update server list
update_server_list() {
    log "info" "Updating server list..."
    if ! "$PRIVADO_API_DIR/privado_get_servers.sh"; then
        log "error" "Failed to update server list"
        return 1
    fi
    return 0
}

# Function to apply new configuration
apply_new_config() {
    local server_location="$1"
    local force="${2:-false}"
    
    log "info" "Applying new WireGuard configuration for: $server_location"

    if ! "$PRIVADO_API_DIR/privado_generate_config.sh" "$server_location" true; then
        log "error" "Failed to generate new configuration"
        return 1
    fi

    # The script-level `set -o allexport; source .env` at startup exported the
    # OLD WIREGUARD_* values into this shell. docker-compose uses exported
    # env vars in preference to .env file values, so without clearing them
    # gluetun would come back up on the previous endpoint. Reload from the
    # freshly-rewritten .env so docker-compose sees the new server.
    unset WIREGUARD_ENDPOINT_IP WIREGUARD_ENDPOINT_PORT \
          WIREGUARD_PUBLIC_KEY WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES
    set -o allexport
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +o allexport
    log "info" "Reloaded .env after config rewrite (endpoint: ${WIREGUARD_ENDPOINT_IP:-unknown})"

    # Restart container to apply new configuration
    if ! restart_gluetun; then
        log "error" "Failed to restart VPN container"
        return 1
    fi
    
    # Wait for VPN to establish
    sleep 30
    
    # Verify VPN is working
    if "$SCRIPT_DIR/check_vpn.sh" >/dev/null 2>&1; then
        send_notification "VPN Configuration Updated" "Successfully switched to new server: $server_location" "info"
        update_rotation_timestamp
        return 0
    else
        log "error" "New VPN configuration is not working"
        return 1
    fi
}

# Main function for automatic update
auto_update() {
    local mode="${1:-auto}"  # auto, force, or specific location
    
    log "info" "Starting automatic WireGuard update (mode: $mode)"
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Authenticate with Privado
    if ! authenticate_privado; then
        send_notification "VPN Update Failed" "Failed to authenticate with Privado VPN" "error"
        return 1
    fi
    
    # Update server list
    if ! update_server_list; then
        send_notification "VPN Update Failed" "Failed to update server list" "error"
        return 1
    fi
    
    # Determine if update is needed
    local needs_update=false
    local reason=""
    
    case "$mode" in
        "force")
            needs_update=true
            reason="Manual force update"
            ;;
        "auto")
            if [ "$AUTO_ROTATION_ENABLED" = "true" ] && needs_rotation; then
                needs_update=true
                reason="Scheduled rotation"
            fi
            ;;
        *)
            needs_update=true
            reason="Manual location change to: $mode"
            ;;
    esac
    
    if [ "$needs_update" = "false" ]; then
        log "info" "No update needed at this time"
        return 0
    fi
    
    log "info" "Update needed: $reason"
    
    # Select best location
    local location_filter="auto"
    if [ "$mode" != "auto" ] && [ "$mode" != "force" ]; then
        location_filter="$mode"
    fi
    
    local candidates
    candidates=$(select_best_location "$location_filter")
    if [ -z "$candidates" ]; then
        send_notification "VPN Update Failed" "Failed to select suitable location" "error"
        return 1
    fi

    local last_tried=""
    while IFS= read -r selected_location; do
        [ -z "$selected_location" ] && continue
        log "info" "Trying location: $selected_location"
        last_tried="$selected_location"
        if apply_new_config "$selected_location"; then
            log "info" "Successfully updated to location: $selected_location"
            return 0
        fi
        log "warning" "Location $selected_location failed; trying next candidate"
    done <<< "$candidates"

    # Best effort: don't leave the download clients down after a total failure.
    # If gluetun is unhealthy this won't start them (depends_on: service_healthy),
    # but the monitor's ensure_dependents_running will pick them up once gluetun
    # recovers.
    log "warning" "All candidates failed; attempting best-effort stack start"
    (cd "$ROOT_DIR" && $COMPOSE up -d) 2>/dev/null || true

    send_notification "VPN Update Failed" "All candidate locations failed (last attempt: $last_tried). Download clients (qBittorrent/SABnzbd) may be down until VPN recovers." "error"
    return 1
}

# Function to show usage
usage() {
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  auto     - Automatic update based on rotation schedule (default)"
    echo "  force    - Force immediate rotation to best available server"
    echo "  <location> - Switch to specific location (country code, city, or server name)"
    echo ""
    echo "Examples:"
    echo "  $0                # Auto update (only if scheduled)"
    echo "  $0 auto           # Same as above"
    echo "  $0 force          # Force immediate rotation"
    echo "  $0 NL             # Switch to Netherlands"
    echo "  $0 Amsterdam      # Switch to Amsterdam"
    echo ""
    echo "Environment variables (set in .env):"
    echo "  WIREGUARD_PREFERRED_COUNTRIES  - Comma-separated list (default: NL,DE,UK,FR)"
    echo "  WIREGUARD_PREFERRED_CITIES     - Comma-separated list (default: Amsterdam,Berlin,London,Paris)"
    echo "  WIREGUARD_AUTO_ROTATION        - Enable/disable rotation (default: true)"
    echo "  WIREGUARD_ROTATION_INTERVAL    - Hours between rotations (default: 24)"
    echo "  WIREGUARD_MAX_LATENCY          - Max acceptable latency in ms (default: 150)"
    echo ""
    exit 1
}

# Main execution
case "${1:-auto}" in
    "help"|"-h"|"--help")
        usage
        ;;
    "auto"|"force")
        auto_update "${1:-auto}"
        ;;
    *)
        auto_update "$1"
        ;;
esac