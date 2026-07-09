#!/bin/bash

# Automated WireGuard Configuration Update Script
# This script checks for changes and updates the configuration automatically

# .env is treated as a data file here (grep'd and sed-edited in place, then
# backed up), so it is deliberately NOT sourced.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Configuration (ROOT_DIR and ENV_FILE come from common.sh)
BACKUP_DIR="$ROOT_DIR/backups"
CONFIG_DIR="$ROOT_DIR/wireguard_configs"
LOG_FILE="$ROOT_DIR/logs/wireguard_updates.log"
STATUS_FILE="$ROOT_DIR/gluetun/update_status.txt"

DISCORD_WEBHOOK="$(env_or_dotenv PULLIO_DISCORD_WEBHOOK)"

# Check if a new config file exists
check_for_new_config() {
    local latest_conf=$(ls -t "$CONFIG_DIR"/*.conf 2>/dev/null | head -n1)
    
    if [ -n "$latest_conf" ] && [ -f "$latest_conf" ]; then
        echo "$latest_conf"
        return 0
    fi
    
    return 1
}

# Parse and compare configuration
check_config_changes() {
    local conf_file="$1"
    
    # Extract values from the conf file
    CONF_PRIVATE_KEY=$(grep "^PrivateKey" "$conf_file" | sed 's/.*= *//')
    CONF_ADDRESS=$(grep "^Address" "$conf_file" | sed 's/.*= *//')
    CONF_PUBLIC_KEY=$(grep "^PublicKey" "$conf_file" | sed 's/.*= *//')
    CONF_ENDPOINT=$(grep "^Endpoint" "$conf_file" | sed 's/.*= *//')
    
    # Parse endpoint
    CONF_ENDPOINT_IP=$(echo "$CONF_ENDPOINT" | cut -d':' -f1)
    CONF_ENDPOINT_PORT=$(echo "$CONF_ENDPOINT" | cut -d':' -f2)
    
    # Get current values from .env
    CURRENT_ENDPOINT_IP=$(grep "^WIREGUARD_ENDPOINT_IP=" "$ENV_FILE" | cut -d'"' -f2)
    CURRENT_ENDPOINT_PORT=$(grep "^WIREGUARD_ENDPOINT_PORT=" "$ENV_FILE" | cut -d'"' -f2)
    CURRENT_PUBLIC_KEY=$(grep "^WIREGUARD_PUBLIC_KEY=" "$ENV_FILE" | cut -d'"' -f2)
    CURRENT_PRIVATE_KEY=$(grep "^WIREGUARD_PRIVATE_KEY=" "$ENV_FILE" | cut -d'"' -f2)
    CURRENT_ADDRESSES=$(grep "^WIREGUARD_ADDRESSES=" "$ENV_FILE" | cut -d'"' -f2)
    
    # Check if any values changed
    if [ "$CONF_ENDPOINT_IP" != "$CURRENT_ENDPOINT_IP" ] || \
       [ "$CONF_ENDPOINT_PORT" != "$CURRENT_ENDPOINT_PORT" ] || \
       [ "$CONF_PUBLIC_KEY" != "$CURRENT_PUBLIC_KEY" ] || \
       [ "$CONF_PRIVATE_KEY" != "$CURRENT_PRIVATE_KEY" ] || \
       [ "$CONF_ADDRESS" != "$CURRENT_ADDRESSES" ]; then
        return 0  # Changes detected
    fi
    
    return 1  # No changes
}

# Backup current .env file
backup_env_file() {
    local backup_file="$BACKUP_DIR/env_backup_$(date +%Y%m%d_%H%M%S).env"
    cp "$ENV_FILE" "$backup_file"
    
    if [ $? -eq 0 ]; then
        log "Backup created: $backup_file"
        return 0
    else
        log "ERROR: Failed to create backup"
        return 1
    fi
}

# Update .env file
update_env_file() {
    log "Updating .env file with new configuration..."
    
    # Build change summary
    local changes=""
    
    if [ "$CONF_ENDPOINT_IP" != "$CURRENT_ENDPOINT_IP" ]; then
        changes="${changes}IP: $CURRENT_ENDPOINT_IP → $CONF_ENDPOINT_IP\n"
    fi
    if [ "$CONF_ENDPOINT_PORT" != "$CURRENT_ENDPOINT_PORT" ]; then
        changes="${changes}Port: $CURRENT_ENDPOINT_PORT → $CONF_ENDPOINT_PORT\n"
    fi
    if [ "$CONF_ADDRESS" != "$CURRENT_ADDRESSES" ]; then
        changes="${changes}Address: $CURRENT_ADDRESSES → $CONF_ADDRESS\n"
    fi
    if [ "$CONF_PUBLIC_KEY" != "$CURRENT_PUBLIC_KEY" ]; then
        changes="${changes}Public Key changed\n"
    fi
    if [ "$CONF_PRIVATE_KEY" != "$CURRENT_PRIVATE_KEY" ]; then
        changes="${changes}Private Key changed\n"
    fi
    
    # Update the values
    sed -i "s|^WIREGUARD_ENDPOINT_IP=.*|WIREGUARD_ENDPOINT_IP=\"$CONF_ENDPOINT_IP\"|" "$ENV_FILE"
    sed -i "s|^WIREGUARD_ENDPOINT_PORT=.*|WIREGUARD_ENDPOINT_PORT=\"$CONF_ENDPOINT_PORT\"|" "$ENV_FILE"
    sed -i "s|^WIREGUARD_PUBLIC_KEY=.*|WIREGUARD_PUBLIC_KEY=\"$CONF_PUBLIC_KEY\"|" "$ENV_FILE"
    sed -i "s|^WIREGUARD_PRIVATE_KEY=.*|WIREGUARD_PRIVATE_KEY=\"$CONF_PRIVATE_KEY\"|" "$ENV_FILE"
    sed -i "s|^WIREGUARD_ADDRESSES=.*|WIREGUARD_ADDRESSES=\"$CONF_ADDRESS\"|" "$ENV_FILE"
    
    log "Configuration updated with changes:\n$changes"
    
    # Send notification
    discord_notify "🔄 **WireGuard Configuration Updated**\n\nChanges:\n$changes\nRestarting VPN container..."
    
    return 0
}

# Restart Gluetun container and dependents to apply the new .env.
# NOTE: "docker-compose restart gluetun" would NOT re-read .env — the
# container must be recreated. restart_vpn_stack.sh force-recreates gluetun
# and also recreates qbittorrent/sabnzbd, which are pinned to gluetun's
# container ID via network_mode: service:gluetun.
restart_gluetun() {
    log "Restarting VPN stack to apply new configuration..."

    VPN_STACK_LOG="$LOG_FILE" bash "$SCRIPT_DIR/restart_vpn_stack.sh"

    if [ $? -eq 0 ]; then
        log "VPN stack restarted successfully"

        # Wait for the tunnel to settle
        sleep 15

        # Check if VPN is working via the Gluetun control API (the gluetun
        # container has no curl/wget, so docker exec can't be used here)
        VPN_IP=$(curl -s --max-time 10 http://localhost:8005/v1/publicip/ip 2>/dev/null | grep -oP '"public_ip":"\K[^"]+')
        if [ -n "$VPN_IP" ]; then
            log "VPN is working with IP: $VPN_IP"
            discord_notify "✅ **VPN Restarted Successfully**\n\nNew VPN IP: $VPN_IP"
            return 0
        else
            log "WARNING: VPN may not be working after restart"
            discord_notify "⚠️ **VPN Restart Warning**\n\nVPN may not be working properly after configuration update. Please check manually."
            return 1
        fi
    else
        log "ERROR: Failed to restart VPN stack"
        discord_notify "❌ **VPN Restart Failed**\n\nFailed to restart VPN stack after configuration update. qBittorrent/SABnzbd may be down."
        return 1
    fi
}

# Archive processed config file
archive_config() {
    local config_file="$1"
    local archive_dir="$CONFIG_DIR/processed"
    
    mkdir -p "$archive_dir"
    mv "$config_file" "$archive_dir/$(basename "$config_file").$(date +%Y%m%d_%H%M%S)"
    log "Config file archived to: $archive_dir"
}

# Main function
main() {
    log "Starting automated WireGuard configuration check..."
    
    # Check for new config file
    CONFIG_FILE=$(check_for_new_config)
    
    if [ $? -ne 0 ]; then
        log "No new configuration file found in $CONFIG_DIR"
        
        # Update status file
        cat > "$STATUS_FILE" <<EOF
LAST_CHECK=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=no_new_config
MESSAGE=No new configuration file found
EOF
        exit 0
    fi
    
    log "Found configuration file: $CONFIG_FILE"
    
    # Check if configuration has changed
    if ! check_config_changes "$CONFIG_FILE"; then
        log "Configuration is already up to date"
        
        # Archive the config file anyway
        archive_config "$CONFIG_FILE"
        
        # Update status file
        cat > "$STATUS_FILE" <<EOF
LAST_CHECK=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=no_changes
MESSAGE=Configuration already up to date
CONFIG_FILE=$CONFIG_FILE
EOF
        exit 0
    fi
    
    log "Configuration changes detected - updating..."
    
    # Backup current configuration
    if ! backup_env_file; then
        log "Failed to create backup - aborting update"
        discord_notify "❌ **WireGuard Update Failed**\n\nFailed to create backup of current configuration."
        exit 1
    fi
    
    # Update the .env file
    if ! update_env_file; then
        log "Failed to update .env file"
        discord_notify "❌ **WireGuard Update Failed**\n\nFailed to update configuration file."
        exit 1
    fi
    
    # Restart Gluetun
    restart_gluetun
    
    # Archive the processed config file
    archive_config "$CONFIG_FILE"
    
    # Update status file
    cat > "$STATUS_FILE" <<EOF
LAST_CHECK=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=updated
MESSAGE=Configuration updated and applied
CONFIG_FILE=$CONFIG_FILE
CHANGES=See log file for details
EOF
    
    log "WireGuard configuration update completed"
}

# Run main function
main