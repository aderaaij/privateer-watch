#!/bin/bash

# WireGuard VPN Monitor for Synology NAS with Gluetun
# This script monitors the Gluetun container and VPN connection status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env

# Configuration (ROOT_DIR/ENV_FILE/COMPOSE come from common.sh)
LOG_FILE="$ROOT_DIR/logs/wireguard_monitor.log"
STATUS_FILE="$ROOT_DIR/gluetun/vpn_status.txt"
AUTO_UPDATE_SCRIPT="$SCRIPT_DIR/auto_update_wireguard.sh"

DISCORD_WEBHOOK="$(env_or_dotenv PULLIO_DISCORD_WEBHOOK)"

# Auto-recovery settings (env_or_dotenv strips inline comments and quotes)
AUTO_RECOVERY_ENABLED="$(env_or_dotenv WIREGUARD_AUTO_RECOVERY true)"
MAX_RESTART_ATTEMPTS="$(env_or_dotenv WIREGUARD_MAX_RESTART_ATTEMPTS 3)"
AUTO_SERVER_SWITCH="$(env_or_dotenv WIREGUARD_AUTO_SERVER_SWITCH true)"

# Discord alerts from the monitor carry a standard prefix
send_discord_notification() {
    discord_notify "🔔 **WireGuard VPN Alert**\n$1"
}

# Check if Gluetun container is running
check_container_status() {
    local status=$(docker inspect -f '{{.State.Status}}' gluetun 2>/dev/null)
    if [ "$status" != "running" ]; then
        return 1
    fi
    return 0
}

# Check if Gluetun container is healthy
check_container_health() {
    local health=$(docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null)
    if [ "$health" != "healthy" ]; then
        return 1
    fi
    return 0
}

# Validate that a string looks like an IPv4 or IPv6 address
is_valid_ip() {
    local input="$1"
    # IPv4: 1-3 digits separated by dots
    if echo "$input" | grep -qP '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'; then
        return 0
    fi
    # IPv6: hex groups separated by colons (simplified check)
    if echo "$input" | grep -qP '^[0-9a-fA-F:]+$' && echo "$input" | grep -q ':'; then
        return 0
    fi
    return 1
}

# Function to get IP through container
get_container_ip() {
    local container=$1
    local ip=""

    # Try curl first (redirect both stdout and stderr from docker exec,
    # capture only stdout — some Docker versions send OCI errors to stdout).
    # Use ifconfig.me/ip: the bare domain returns HTML to non-curl clients.
    ip=$(docker exec "$container" curl -s --max-time 10 ifconfig.me/ip 2>&1 | head -1)

    # If curl fails or returned an error, try wget
    if ! is_valid_ip "$ip"; then
        ip=$(docker exec "$container" wget -qO- --timeout=10 ifconfig.me/ip 2>&1 | head -1)
    fi

    # If both fail, try using the Gluetun API if it's the gluetun container
    if ! is_valid_ip "$ip" && [ "$container" = "gluetun" ]; then
        # Try to get the public IP from Gluetun's control server
        ip=$(curl -s --max-time 10 http://localhost:8005/v1/publicip/ip 2>/dev/null | grep -oP '"public_ip":"\K[^"]+')
    fi

    # Final validation — only return if it looks like an actual IP
    if is_valid_ip "$ip"; then
        echo "$ip"
    fi
}

# Get VPN IP address through Gluetun
get_vpn_ip() {
    local ip=$(get_container_ip gluetun)
    
    # If we can't get VPN IP through gluetun, try through a service using the VPN
    if [ -z "$ip" ]; then
        ip=$(get_container_ip qbittorrent)
    fi
    
    if [ -z "$ip" ]; then
        ip=$(get_container_ip sabnzbd)
    fi
    
    echo "$ip"
}

# Get real IP address (not through VPN)
get_real_ip() {
    local ip=$(curl -s --max-time 10 ifconfig.me/ip 2>/dev/null)

    # If curl fails or returned garbage, try wget
    if ! is_valid_ip "$ip"; then
        ip=$(wget -qO- --timeout=10 ifconfig.me/ip 2>/dev/null)
    fi

    # Only return if valid
    if is_valid_ip "$ip"; then
        echo "$ip"
    fi
}

# Check VPN connectivity
check_vpn_connection() {
    local vpn_ip=$(get_vpn_ip)
    local real_ip=$(get_real_ip)
    
    if [ -z "$vpn_ip" ]; then
        log "ERROR: Unable to get VPN IP - VPN may be down"
        return 1
    fi
    
    if [ -z "$real_ip" ]; then
        log "WARNING: Unable to get real IP for comparison"
        return 2
    fi
    
    if [ "$vpn_ip" = "$real_ip" ]; then
        log "ERROR: VPN IP matches real IP - VPN is not working!"
        return 1
    fi
    
    log "VPN is working. VPN IP: $vpn_ip, Real IP: $real_ip"
    return 0
}

# Get Privado server location from VPN IP
get_vpn_location() {
    local vpn_ip=$(get_vpn_ip)
    if [ -n "$vpn_ip" ]; then
        # Try getting location info from host
        local location_info=$(curl -s "http://ip-api.com/json/$vpn_ip" 2>/dev/null)
        
        # If curl fails, try wget
        if [ -z "$location_info" ]; then
            location_info=$(wget -qO- "http://ip-api.com/json/$vpn_ip" 2>/dev/null)
        fi
        
        echo "$location_info" | \
            grep -oP '"city":"[^"]*"|"country":"[^"]*"' | \
            sed 's/"//g' | sed 's/:/: /g' | paste -sd', '
    fi
}

# Save status to file
save_status() {
    local status="$1"
    local vpn_ip="$2"
    local location="$3"
    cat > "$STATUS_FILE" <<EOF
STATUS=$status
LAST_CHECK=$(date '+%Y-%m-%d %H:%M:%S')
VPN_IP=$vpn_ip
LOCATION=$location
EOF
}

# Read previous status
read_previous_status() {
    if [ -f "$STATUS_FILE" ]; then
        grep "^STATUS=" "$STATUS_FILE" 2>/dev/null | cut -d'=' -f2
    else
        echo "unknown"
    fi
}

# Restart Gluetun container and dependents.
# Delegates to restart_vpn_stack.sh — the single canonical restart path.
# qbittorrent/sabnzbd (network_mode: service:gluetun) are pinned to gluetun's
# container ID and must be removed + recreated whenever gluetun is recreated.
restart_gluetun() {
    log "Restarting VPN stack (gluetun + dependent containers)..."

    if VPN_STACK_LOG="$LOG_FILE" DOCKERCONFDIR="$ROOT_DIR" \
        bash "$SCRIPT_DIR/restart_vpn_stack.sh"; then
        log "VPN stack restart completed"
        return 0
    else
        log "ERROR: VPN stack restart failed"
        return 1
    fi
}

# Get restart attempt count
get_restart_count() {
    local restart_count_file="$ROOT_DIR/logs/restart_count.txt"
    if [ -f "$restart_count_file" ]; then
        local last_restart_date=$(head -1 "$restart_count_file")
        local today=$(date +%Y-%m-%d)
        
        if [ "$last_restart_date" = "$today" ]; then
            tail -1 "$restart_count_file"
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

# Increment restart count
increment_restart_count() {
    local restart_count_file="$ROOT_DIR/logs/restart_count.txt"
    local today=$(date +%Y-%m-%d)
    local current_count=$(get_restart_count)
    local new_count=$((current_count + 1))
    
    echo "$today" > "$restart_count_file"
    echo "$new_count" >> "$restart_count_file"
    echo "$new_count"
}

# Reset restart count
reset_restart_count() {
    local restart_count_file="$ROOT_DIR/logs/restart_count.txt"
    local today=$(date +%Y-%m-%d)
    
    echo "$today" > "$restart_count_file"
    echo "0" >> "$restart_count_file"
}

# Auto switch to different server
auto_switch_server() {
    log "Attempting automatic server switch for recovery..."
    
    if [ ! -f "$AUTO_UPDATE_SCRIPT" ]; then
        log "ERROR: Auto update script not found at $AUTO_UPDATE_SCRIPT"
        return 1
    fi
    
    # Try switching to a different server
    if "$AUTO_UPDATE_SCRIPT" force; then
        log "Successfully switched to different server"
        send_discord_notification "🔄 Automatically switched to different VPN server for recovery"
        dsm_notify "VPN Server Switched" "Automatically switched to different server to restore connectivity"
        reset_restart_count
        return 0
    else
        log "Failed to switch to different server"
        send_discord_notification "❌ Failed to switch to different server - manual intervention required"
        return 1
    fi
}

# Enhanced recovery function
attempt_recovery() {
    local issue_type="$1"
    
    if [ "$AUTO_RECOVERY_ENABLED" != "true" ]; then
        log "Auto-recovery is disabled in configuration"
        return 1
    fi
    
    local restart_count=$(get_restart_count)
    log "Current restart attempts today: $restart_count"
    
    # If we've reached max restart attempts, try server switch instead
    if [ "$restart_count" -ge "$MAX_RESTART_ATTEMPTS" ]; then
        if [ "$AUTO_SERVER_SWITCH" = "true" ]; then
            log "Max restart attempts reached ($MAX_RESTART_ATTEMPTS), attempting server switch..."
            return $(auto_switch_server)
        else
            log "Max restart attempts reached and server switching disabled"
            send_discord_notification "🚨 Max restart attempts reached ($MAX_RESTART_ATTEMPTS) - manual intervention required"
            return 1
        fi
    fi
    
    # Attempt regular restart
    log "Attempting recovery via container restart (attempt $((restart_count + 1))/$MAX_RESTART_ATTEMPTS)"
    
    # Check if we've restarted in the last hour
    last_restart_file="$ROOT_DIR/logs/last_restart.txt"
    current_time=$(date +%s)
    
    if [ -f "$last_restart_file" ]; then
        last_restart=$(cat "$last_restart_file")
        time_diff=$((current_time - last_restart))

        if [ "$time_diff" -lt 3600 ]; then
            # A recent restart didn't fix things. Don't just wait an hour
            # doing nothing — escalate straight to a server switch if enabled,
            # since another restart on the same broken endpoint won't help.
            if [ "$AUTO_SERVER_SWITCH" = "true" ]; then
                log "Recent restart didn't recover VPN; escalating to server switch"
                if auto_switch_server; then
                    return 0
                else
                    return 1
                fi
            fi
            log "Skipping restart - already attempted within the last hour"
            return 1
        fi
    fi
    
    # Perform restart
    restart_gluetun
    increment_restart_count
    echo "$current_time" > "$last_restart_file"
    
    # Wait and verify — check both container health and VPN connection
    sleep 30
    if check_container_health && check_vpn_connection; then
        log "Recovery successful - VPN is now working"
        send_discord_notification "✅ VPN recovered successfully after restart"
        dsm_notify "VPN Recovered" "VPN connection restored after automatic restart"
        return 0
    else
        log "Recovery failed - container still unhealthy or VPN not working after restart"
        
        # If this was the last restart attempt and server switching is enabled, try that next
        local new_count=$(get_restart_count)
        if [ "$new_count" -ge "$MAX_RESTART_ATTEMPTS" ] && [ "$AUTO_SERVER_SWITCH" = "true" ]; then
            log "Final restart attempt failed, will try server switch on next check"
        fi
        return 1
    fi
}

# Ensure dependent containers (qbittorrent, sabnzbd) are running AND attached
# to the current gluetun container. network_mode: service:gluetun pins them to
# gluetun's container ID; after gluetun is recreated they are either stopped
# and unstartable, or running inside a dead network namespace with no
# connectivity. Either way the fix is the same: remove + recreate.
ensure_dependents_running() {
    local dependents="qbittorrent sabnzbd"
    local needs_recreate=""
    local gluetun_id=$(docker inspect -f '{{.Id}}' gluetun 2>/dev/null)

    for container in $dependents; do
        local status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
        local netmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$container" 2>/dev/null)

        if [ "$status" != "running" ]; then
            log "WARNING: Dependent container $container is not running (status: ${status:-not found})"
            needs_recreate="$needs_recreate $container"
        elif [ -n "$gluetun_id" ] && \
             [ "$netmode" != "container:$gluetun_id" ] && \
             [ "$netmode" != "container:gluetun" ]; then
            log "WARNING: $container is attached to a stale gluetun network namespace ($netmode)"
            needs_recreate="$needs_recreate $container"
        fi
    done

    if [ -n "$needs_recreate" ]; then
        log "Recreating dependent containers:$needs_recreate"
        cd "$ROOT_DIR"
        # rm + up (not just up/start): a dependent pinned to a dead gluetun
        # container ID can never be started, only recreated.
        (cd "$ROOT_DIR" && $COMPOSE rm -sf $needs_recreate) 2>/dev/null || true
        (cd "$ROOT_DIR" && $COMPOSE up -d $needs_recreate)
        log "Dependent containers recreated"
        send_discord_notification "🔄 Recreated dependent containers ($needs_recreate) to rejoin gluetun's network"
    fi
}

# Main monitoring function
main() {
    log "Starting WireGuard VPN monitoring check..."
    
    local previous_status=$(read_previous_status)
    local current_status="ok"
    local alert_message=""
    local needs_restart=false
    
    # Check if container is running
    if ! check_container_status; then
        current_status="container_down"
        alert_message="Gluetun container is not running!"
        needs_restart=true
        log "ERROR: $alert_message"
    # Check if container is healthy
    elif ! check_container_health; then
        current_status="unhealthy"
        alert_message="Gluetun container is unhealthy!"
        needs_restart=true
        log "ERROR: $alert_message"
    # Check VPN connection
    elif ! check_vpn_connection; then
        current_status="vpn_down"
        alert_message="VPN connection is down or not working properly!"
        needs_restart=true
        log "ERROR: $alert_message"
    else
        # Everything is OK
        local vpn_ip=$(get_vpn_ip)
        local location=$(get_vpn_location)
        save_status "ok" "$vpn_ip" "$location"

        # Send recovery notification if previously down
        if [ "$previous_status" != "ok" ] && [ "$previous_status" != "unknown" ]; then
            recovery_message="VPN connection restored! IP: $vpn_ip, Location: $location"
            log "$recovery_message"
            send_discord_notification "✅ $recovery_message"
            dsm_notify "VPN Restored" "$recovery_message"
        else
            log "All checks passed. VPN is operational."
        fi

        # Check dependent containers - they can lose connectivity if Docker's
        # restart policy restarted gluetun without cascading to dependents
        ensure_dependents_running

        exit 0
    fi
    
    # Handle error conditions
    save_status "$current_status" "" ""
    
    # Send alert if this is a new issue
    if [ "$previous_status" = "ok" ] || [ "$previous_status" = "unknown" ]; then
        send_discord_notification "⚠️ $alert_message"
        dsm_notify "VPN Alert" "$alert_message"
    fi
    
    # Attempt recovery if needed
    if [ "$needs_restart" = true ]; then
        if attempt_recovery "$current_status"; then
            log "Recovery successful"
            
            # Re-check status after successful recovery
            if check_container_health && check_vpn_connection; then
                local vpn_ip=$(get_vpn_ip)
                local location=$(get_vpn_location)
                save_status "ok" "$vpn_ip" "$location"
                log "VPN fully restored. IP: $vpn_ip, Location: $location"
            fi
        else
            log "Recovery failed - manual intervention may be required"
            send_discord_notification "🚨 VPN recovery failed - please check system manually"
            dsm_notify "VPN Recovery Failed" "Automatic recovery attempts have failed. Manual intervention required."
        fi
    fi
}

# Run main function
main