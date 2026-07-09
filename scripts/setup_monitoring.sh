#!/bin/bash

# Setup Script for WireGuard Monitoring on Synology NAS
# This script prepares the environment and sets up monitoring

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env
BASE_DIR="$ROOT_DIR"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "   WireGuard Monitoring Setup for Synology NAS"
echo "═══════════════════════════════════════════════════════"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}This script must be run as root (use sudo)${NC}"
    exit 1
fi

# Create necessary directories
echo -e "${BLUE}Creating directory structure...${NC}"
mkdir -p "$BASE_DIR/scripts"
mkdir -p "$BASE_DIR/wireguard_configs"
mkdir -p "$BASE_DIR/backups"
mkdir -p "$BASE_DIR/logs"
mkdir -p "$BASE_DIR/gluetun"
mkdir -p "$BASE_DIR/wireguard_configs/processed"

echo -e "${GREEN}✓ Directories created${NC}"

# Make scripts executable
echo -e "${BLUE}Setting script permissions...${NC}"
chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null
chmod +x "$SCRIPT_DIR"/privado-api/*.sh 2>/dev/null

echo -e "${GREEN}✓ Scripts are now executable${NC}"

# Test Docker access
echo -e "${BLUE}Testing Docker access...${NC}"
if docker ps >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Docker is accessible${NC}"
else
    echo -e "${RED}✗ Cannot access Docker. Please ensure Docker is installed and running${NC}"
    exit 1
fi

# Check if Gluetun container exists
echo -e "${BLUE}Checking for Gluetun container...${NC}"
if docker ps -a --format "{{.Names}}" | grep -q "^gluetun$"; then
    echo -e "${GREEN}✓ Gluetun container found${NC}"
    
    # Check if it's running
    if docker ps --format "{{.Names}}" | grep -q "^gluetun$"; then
        echo -e "${GREEN}  Status: Running${NC}"
    else
        echo -e "${YELLOW}  Status: Not running${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Gluetun container not found${NC}"
    echo "  Please ensure your docker-compose.yml is configured correctly"
fi

# Test VPN connection
echo ""
echo -e "${BLUE}Testing VPN connection...${NC}"
if [ -f "$SCRIPT_DIR/check_vpn.sh" ]; then
    $SCRIPT_DIR/check_vpn.sh
else
    echo -e "${YELLOW}⚠ VPN check script not found${NC}"
fi

# Check for Discord webhook
echo ""
echo -e "${BLUE}Checking notification settings...${NC}"
if [ -f "$BASE_DIR/.env" ]; then
    DISCORD_WEBHOOK=$(grep "PULLIO_DISCORD_WEBHOOK=" "$BASE_DIR/.env" | cut -d'=' -f2 | tr -d '"')
    if [ -n "$DISCORD_WEBHOOK" ]; then
        echo -e "${GREEN}✓ Discord webhook configured${NC}"
    else
        echo -e "${YELLOW}⚠ No Discord webhook found in .env${NC}"
        echo "  Notifications will use Synology DSM notifications only"
    fi
else
    echo -e "${YELLOW}⚠ .env file not found${NC}"
fi

# Create initial log files
echo ""
echo -e "${BLUE}Initializing log files...${NC}"
touch "$BASE_DIR/logs/wireguard_monitor.log"
touch "$BASE_DIR/logs/wireguard_updates.log"
echo -e "${GREEN}✓ Log files created${NC}"

# The DSM Task Scheduler wrappers (task_monitor.sh / task_update.sh) ship
# with the repo; just confirm they're present and executable.
echo ""
echo -e "${BLUE}Checking DSM Task Scheduler wrapper scripts...${NC}"
for wrapper in "$SCRIPT_DIR/task_monitor.sh" "$SCRIPT_DIR/task_update.sh"; do
    if [ -f "$wrapper" ]; then
        chmod +x "$wrapper"
        echo "  $(basename "$wrapper") ready"
    else
        echo -e "${YELLOW}  ⚠ $(basename "$wrapper") missing — re-clone the repo${NC}"
    fi
done

echo -e "${GREEN}✓ Task scheduler scripts ready${NC}"

# Display setup summary
echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "${GREEN}   Setup Complete!${NC}"
echo "═══════════════════════════════════════════════════════"
echo ""
echo -e "${BLUE}Scripts installed:${NC}"
echo "  • wireguard_monitor.sh - Main monitoring script"
echo "  • check_vpn.sh - Quick VPN status check"
echo "  • parse_wireguard_conf.sh - Manual config update"
echo "  • update_wireguard.sh - Automated config update"
echo ""
echo -e "${BLUE}Directory structure:${NC}"
echo "  • Scripts: $SCRIPT_DIR"
echo "  • Configs: $BASE_DIR/wireguard_configs"
echo "  • Backups: $BASE_DIR/backups"
echo "  • Logs: $BASE_DIR/logs"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo "1. ${BLUE}Set up DSM Task Scheduler:${NC}"
echo "   • Open DSM Control Panel → Task Scheduler"
echo "   • Create new → Scheduled Task → User-defined script"
echo ""
echo "   ${GREEN}Task 1: VPN Monitor (every 30 minutes)${NC}"
echo "   • General: Task name: 'WireGuard VPN Monitor'"
echo "   • Schedule: Every 30 minutes"
echo "   • Task Settings:"
echo "     User: root"
echo "     Script: $SCRIPT_DIR/task_monitor.sh"
echo ""
echo "   ${GREEN}Task 2: Config Update Check (daily at 3 AM)${NC}"
echo "   • General: Task name: 'WireGuard Config Update'"
echo "   • Schedule: Daily at 03:00"
echo "   • Task Settings:"
echo "     User: root"
echo "     Script: $SCRIPT_DIR/task_update.sh"
echo ""
echo "2. ${BLUE}To manually update WireGuard config:${NC}"
echo "   • Download new .conf file from Privado"
echo "   • Place it in: $BASE_DIR/wireguard_configs/"
echo "   • Run: $SCRIPT_DIR/parse_wireguard_conf.sh"
echo ""
echo "3. ${BLUE}To check VPN status manually:${NC}"
echo "   • Run: $SCRIPT_DIR/check_vpn.sh"
echo ""
echo "4. ${BLUE}To check logs:${NC}"
echo "   • Monitor log: tail -f $BASE_DIR/logs/wireguard_monitor.log"
echo "   • Update log: tail -f $BASE_DIR/logs/wireguard_updates.log"
echo ""
echo -e "${GREEN}Setup complete! Your WireGuard monitoring is ready.${NC}"
echo ""