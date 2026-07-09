#!/bin/bash

# Simple VPN Health Check Script
# Quick check to verify VPN is working

# Colors for output (if running in terminal)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Validate that a string looks like an IPv4 or IPv6 address (filters out
# HTML error pages and docker exec error text)
is_valid_ip() {
    local input="$1"
    if echo "$input" | grep -qP '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'; then
        return 0
    fi
    if echo "$input" | grep -qP '^[0-9a-fA-F:]+$' && echo "$input" | grep -q ':'; then
        return 0
    fi
    return 1
}

# Function to get IP through container
# Uses ifconfig.me/ip (plain text for any client) — the bare ifconfig.me
# returns a full HTML page to wget.
get_container_ip() {
    local container=$1
    local ip=""

    # Try curl first
    ip=$(docker exec "$container" curl -s --max-time 10 ifconfig.me/ip 2>/dev/null | head -1)

    # If curl fails, try wget
    if ! is_valid_ip "$ip"; then
        ip=$(docker exec "$container" wget -qO- --timeout=10 ifconfig.me/ip 2>/dev/null | head -1)
    fi

    # If both fail, try using the Gluetun API if it's the gluetun container
    if ! is_valid_ip "$ip" && [ "$container" = "gluetun" ]; then
        # Try to get the public IP from Gluetun's control server
        ip=$(curl -s --max-time 10 http://localhost:8005/v1/publicip/ip 2>/dev/null | grep -oP '"public_ip":"\K[^"]+')
    fi

    if is_valid_ip "$ip"; then
        echo "$ip"
    fi
}

# Get VPN IP through Gluetun
echo "Checking VPN connection status..."
VPN_IP=$(get_container_ip gluetun)

# If we can't get VPN IP through container, try through a service using the VPN
if [ -z "$VPN_IP" ]; then
    echo "  Trying alternative method through qbittorrent..."
    VPN_IP=$(get_container_ip qbittorrent)
fi

if [ -z "$VPN_IP" ]; then
    echo "  Trying alternative method through sabnzbd..."
    VPN_IP=$(get_container_ip sabnzbd)
fi

if [ -z "$VPN_IP" ]; then
    echo -e "${RED}✗ Unable to get VPN IP - VPN may be down or containers missing curl/wget${NC}"
    echo "  Attempting to check container status..."
    CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' gluetun 2>/dev/null)
    CONTAINER_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null)
    echo "  Gluetun container: $CONTAINER_STATUS ($CONTAINER_HEALTH)"
    exit 1
fi

# Get real IP
echo "Getting real IP for comparison..."
REAL_IP=$(curl -s --max-time 10 ifconfig.me/ip 2>/dev/null)

# If curl fails, try wget
if ! is_valid_ip "$REAL_IP"; then
    REAL_IP=$(wget -qO- --timeout=10 ifconfig.me/ip 2>/dev/null)
fi

if ! is_valid_ip "$REAL_IP"; then
    REAL_IP=""
fi

if [ -z "$REAL_IP" ]; then
    echo -e "${YELLOW}⚠ Unable to get real IP for comparison${NC}"
    echo -e "${YELLOW}  VPN IP obtained: $VPN_IP${NC}"
    echo -e "${YELLOW}  Cannot verify if VPN is protecting traffic${NC}"
    exit 2
fi

# Compare IPs
if [ "$VPN_IP" = "$REAL_IP" ]; then
    echo -e "${RED}✗ VPN is NOT working!${NC}"
    echo "  VPN IP:  $VPN_IP"
    echo "  Real IP: $REAL_IP"
    echo "  IPs match - traffic is not going through VPN!"
    exit 1
fi

# Get location info
echo "Getting VPN location info..."
LOCATION_INFO=$(curl -s "http://ip-api.com/json/$VPN_IP" 2>/dev/null)
if [ -z "$LOCATION_INFO" ]; then
    LOCATION_INFO=$(wget -qO- "http://ip-api.com/json/$VPN_IP" 2>/dev/null)
fi
CITY=$(echo "$LOCATION_INFO" | grep -oP '"city":"[^"]*"' | cut -d'"' -f4)
COUNTRY=$(echo "$LOCATION_INFO" | grep -oP '"country":"[^"]*"' | cut -d'"' -f4)
ISP=$(echo "$LOCATION_INFO" | grep -oP '"isp":"[^"]*"' | cut -d'"' -f4)

# Check container health
CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' gluetun 2>/dev/null)
CONTAINER_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null)

# Display results
echo ""
echo -e "${GREEN}✓ VPN is working correctly!${NC}"
echo "────────────────────────────────────"
echo "  VPN IP:      $VPN_IP"
echo "  Real IP:     $REAL_IP"
echo "  Location:    $CITY, $COUNTRY"
echo "  ISP:         $ISP"
echo "  Container:   $CONTAINER_STATUS ($CONTAINER_HEALTH)"
echo "────────────────────────────────────"

# Check which services are using the VPN
echo ""
echo "Services using VPN tunnel:"
for service in qbittorrent sabnzbd; do
    if docker ps --format "{{.Names}}" | grep -q "^$service$"; then
        SERVICE_IP=$(get_container_ip "$service")
        
        if [ -z "$SERVICE_IP" ]; then
            echo -e "  ${YELLOW}?${NC} $service - Unable to check IP (no curl/wget in container)"
        elif [ "$SERVICE_IP" = "$VPN_IP" ]; then
            echo -e "  ${GREEN}✓${NC} $service - Protected (IP: $SERVICE_IP)"
        elif [ "$SERVICE_IP" != "$REAL_IP" ] && [ -n "$SERVICE_IP" ]; then
            # Service has different IP than real IP, so it's using VPN (just different detection method)
            echo -e "  ${GREEN}✓${NC} $service - Protected (IP: $SERVICE_IP)"
        elif [ "$SERVICE_IP" = "$REAL_IP" ]; then
            echo -e "  ${RED}✗${NC} $service - NOT Protected (IP: $SERVICE_IP matches real IP)"
        else
            echo -e "  ${YELLOW}?${NC} $service - Status unclear (IP: $SERVICE_IP)"
        fi
    else
        echo -e "  ${YELLOW}-${NC} $service - Not running"
    fi
done

echo ""
echo "Last check: $(date '+%Y-%m-%d %H:%M:%S')"

exit 0