#!/bin/bash

# Parse WireGuard Configuration File and Update .env
# This script parses a Privado WireGuard .conf file and updates the .env file

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env

# Configuration (ROOT_DIR/ENV_FILE come from common.sh)
BACKUP_DIR="$ROOT_DIR/backups"
CONFIG_DIR="$ROOT_DIR/wireguard_configs"
LOG_FILE="$ROOT_DIR/logs/wireguard_updates.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"
}

# Find the most recent .conf file
find_config_file() {
    local config_file="$1"
    
    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
        echo "$config_file"
        return 0
    fi
    
    # Look for .conf files in the config directory
    local latest_conf=$(ls -t "$CONFIG_DIR"/*.conf 2>/dev/null | head -n1)
    
    if [ -n "$latest_conf" ] && [ -f "$latest_conf" ]; then
        echo "$latest_conf"
        return 0
    fi
    
    return 1
}

# Parse WireGuard configuration file
parse_wireguard_config() {
    local conf_file="$1"
    
    if [ ! -f "$conf_file" ]; then
        echo -e "${RED}Error: Configuration file not found: $conf_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Parsing WireGuard configuration from: $conf_file${NC}"
    
    # Extract values from the conf file
    CONF_PRIVATE_KEY=$(grep "^PrivateKey" "$conf_file" | sed 's/.*= *//')
    CONF_ADDRESS=$(grep "^Address" "$conf_file" | sed 's/.*= *//')
    CONF_PUBLIC_KEY=$(grep "^PublicKey" "$conf_file" | sed 's/.*= *//')
    CONF_ENDPOINT=$(grep "^Endpoint" "$conf_file" | sed 's/.*= *//')
    
    # Parse endpoint into IP and Port
    CONF_ENDPOINT_IP=$(echo "$CONF_ENDPOINT" | cut -d':' -f1)
    CONF_ENDPOINT_PORT=$(echo "$CONF_ENDPOINT" | cut -d':' -f2)
    
    # Validate extracted values
    if [ -z "$CONF_PRIVATE_KEY" ] || [ -z "$CONF_ADDRESS" ] || [ -z "$CONF_PUBLIC_KEY" ] || [ -z "$CONF_ENDPOINT_IP" ] || [ -z "$CONF_ENDPOINT_PORT" ]; then
        echo -e "${RED}Error: Failed to parse all required values from config file${NC}"
        echo "  Private Key: ${CONF_PRIVATE_KEY:0:10}..."
        echo "  Address: $CONF_ADDRESS"
        echo "  Public Key: ${CONF_PUBLIC_KEY:0:10}..."
        echo "  Endpoint IP: $CONF_ENDPOINT_IP"
        echo "  Endpoint Port: $CONF_ENDPOINT_PORT"
        return 1
    fi
    
    echo -e "${GREEN}Successfully parsed configuration:${NC}"
    echo "  Private Key: ${CONF_PRIVATE_KEY:0:10}..."
    echo "  Address: $CONF_ADDRESS"
    echo "  Public Key: ${CONF_PUBLIC_KEY:0:10}..."
    echo "  Endpoint: $CONF_ENDPOINT_IP:$CONF_ENDPOINT_PORT"
    
    return 0
}

# Get current values from .env file
get_current_values() {
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}Error: .env file not found at $ENV_FILE${NC}"
        return 1
    fi
    
    CURRENT_ENDPOINT_IP=$(grep "^WIREGUARD_ENDPOINT_IP=" "$ENV_FILE" | cut -d'"' -f2)
    CURRENT_ENDPOINT_PORT=$(grep "^WIREGUARD_ENDPOINT_PORT=" "$ENV_FILE" | cut -d'"' -f2)
    CURRENT_PUBLIC_KEY=$(grep "^WIREGUARD_PUBLIC_KEY=" "$ENV_FILE" | cut -d'"' -f2)
    CURRENT_PRIVATE_KEY=$(grep "^WIREGUARD_PRIVATE_KEY=" "$ENV_FILE" | cut -d'"' -f2)
    CURRENT_ADDRESSES=$(grep "^WIREGUARD_ADDRESSES=" "$ENV_FILE" | cut -d'"' -f2)
    
    echo -e "${BLUE}Current configuration in .env:${NC}"
    echo "  Private Key: ${CURRENT_PRIVATE_KEY:0:10}..."
    echo "  Address: $CURRENT_ADDRESSES"
    echo "  Public Key: ${CURRENT_PUBLIC_KEY:0:10}..."
    echo "  Endpoint: $CURRENT_ENDPOINT_IP:$CURRENT_ENDPOINT_PORT"
    
    return 0
}

# Compare configurations
compare_configs() {
    local changes_needed=false
    
    echo ""
    echo -e "${BLUE}Comparing configurations...${NC}"
    
    if [ "$CONF_ENDPOINT_IP" != "$CURRENT_ENDPOINT_IP" ]; then
        echo -e "${YELLOW}  Endpoint IP changed: $CURRENT_ENDPOINT_IP → $CONF_ENDPOINT_IP${NC}"
        changes_needed=true
    fi
    
    if [ "$CONF_ENDPOINT_PORT" != "$CURRENT_ENDPOINT_PORT" ]; then
        echo -e "${YELLOW}  Endpoint Port changed: $CURRENT_ENDPOINT_PORT → $CONF_ENDPOINT_PORT${NC}"
        changes_needed=true
    fi
    
    if [ "$CONF_PUBLIC_KEY" != "$CURRENT_PUBLIC_KEY" ]; then
        echo -e "${YELLOW}  Public Key changed${NC}"
        changes_needed=true
    fi
    
    if [ "$CONF_PRIVATE_KEY" != "$CURRENT_PRIVATE_KEY" ]; then
        echo -e "${YELLOW}  Private Key changed${NC}"
        changes_needed=true
    fi
    
    if [ "$CONF_ADDRESS" != "$CURRENT_ADDRESSES" ]; then
        echo -e "${YELLOW}  Address changed: $CURRENT_ADDRESSES → $CONF_ADDRESS${NC}"
        changes_needed=true
    fi
    
    if [ "$changes_needed" = false ]; then
        echo -e "${GREEN}  No changes needed - configuration is up to date${NC}"
        return 1
    fi
    
    return 0
}

# Backup current .env file
backup_env_file() {
    local backup_file="$BACKUP_DIR/env_backup_$(date +%Y%m%d_%H%M%S).env"
    
    echo -e "${BLUE}Creating backup of .env file...${NC}"
    cp "$ENV_FILE" "$backup_file"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}  Backup created: $backup_file${NC}"
        log_message "Backup created: $backup_file"
        return 0
    else
        echo -e "${RED}  Failed to create backup${NC}"
        return 1
    fi
}

# Update .env file with new values
update_env_file() {
    echo -e "${BLUE}Updating .env file with new configuration...${NC}"
    
    # Use sed to update the values
    sed -i.tmp "s|^WIREGUARD_ENDPOINT_IP=.*|WIREGUARD_ENDPOINT_IP=\"$CONF_ENDPOINT_IP\"|" "$ENV_FILE"
    sed -i.tmp "s|^WIREGUARD_ENDPOINT_PORT=.*|WIREGUARD_ENDPOINT_PORT=\"$CONF_ENDPOINT_PORT\"|" "$ENV_FILE"
    sed -i.tmp "s|^WIREGUARD_PUBLIC_KEY=.*|WIREGUARD_PUBLIC_KEY=\"$CONF_PUBLIC_KEY\"|" "$ENV_FILE"
    sed -i.tmp "s|^WIREGUARD_PRIVATE_KEY=.*|WIREGUARD_PRIVATE_KEY=\"$CONF_PRIVATE_KEY\"|" "$ENV_FILE"
    sed -i.tmp "s|^WIREGUARD_ADDRESSES=.*|WIREGUARD_ADDRESSES=\"$CONF_ADDRESS\"|" "$ENV_FILE"
    
    # Remove temporary files
    rm -f "$ENV_FILE.tmp"
    
    echo -e "${GREEN}  .env file updated successfully${NC}"
    log_message "Updated .env with new WireGuard configuration"
    
    return 0
}

# Restart Gluetun container and dependents to apply the new .env.
# NOTE: "docker-compose restart gluetun" would NOT re-read .env — the
# container must be recreated. restart_vpn_stack.sh force-recreates gluetun
# and also recreates qbittorrent/sabnzbd, which are pinned to gluetun's
# container ID via network_mode: service:gluetun.
restart_gluetun() {
    echo -e "${BLUE}Restarting VPN stack to apply new configuration...${NC}"

    if bash "$SCRIPT_DIR/restart_vpn_stack.sh"; then
        echo -e "${GREEN}  VPN stack restarted successfully${NC}"
        log_message "VPN stack restarted"

        # Check if VPN is working
        "$SCRIPT_DIR/check_vpn.sh"

        return 0
    else
        echo -e "${RED}  Failed to restart VPN stack${NC}"
        log_message "Failed to restart VPN stack"
        return 1
    fi
}

# Main function
main() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "   WireGuard Configuration Update Tool"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    # Find config file
    CONFIG_FILE=$(find_config_file "$1")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: No WireGuard configuration file found${NC}"
        echo ""
        echo "Usage: $0 [config_file.conf]"
        echo ""
        echo "Or place your .conf file in: $CONFIG_DIR"
        echo ""
        exit 1
    fi
    
    log_message "Starting WireGuard configuration update process"
    log_message "Using config file: $CONFIG_FILE"
    
    # Parse the new configuration
    if ! parse_wireguard_config "$CONFIG_FILE"; then
        log_message "Failed to parse configuration file"
        exit 1
    fi
    
    echo ""
    
    # Get current values
    if ! get_current_values; then
        log_message "Failed to read current configuration"
        exit 1
    fi
    
    # Compare configurations
    if ! compare_configs; then
        log_message "No changes needed - configuration is already up to date"
        echo ""
        echo -e "${GREEN}✓ Configuration is already up to date!${NC}"
        echo ""
        exit 0
    fi
    
    echo ""
    
    # Ask for confirmation
    echo -e "${YELLOW}Do you want to apply these changes? (y/n)${NC}"
    read -r response
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Update cancelled by user"
        log_message "Update cancelled by user"
        exit 0
    fi
    
    # Backup current configuration
    if ! backup_env_file; then
        echo -e "${RED}Failed to create backup - aborting update${NC}"
        log_message "Failed to create backup - update aborted"
        exit 1
    fi
    
    # Update the .env file
    if ! update_env_file; then
        echo -e "${RED}Failed to update .env file${NC}"
        log_message "Failed to update .env file"
        exit 1
    fi
    
    # Restart Gluetun
    if ! restart_gluetun; then
        echo -e "${RED}Warning: Container restart may have failed${NC}"
        echo "Please check the container status manually"
    fi
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✓ WireGuard configuration updated successfully!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Archive the processed config file
    if [ -f "$CONFIG_FILE" ]; then
        archive_dir="$CONFIG_DIR/processed"
        mkdir -p "$archive_dir"
        mv "$CONFIG_FILE" "$archive_dir/$(basename "$CONFIG_FILE").$(date +%Y%m%d_%H%M%S)"
        echo "Config file archived to: $archive_dir"
    fi
    
    log_message "WireGuard configuration update completed successfully"
}

# Run main function
main "$@"