#!/bin/bash
#
# restart_vpn_stack.sh - Canonical way to restart gluetun and apply new config.
#
# qbittorrent and sabnzbd use "network_mode: service:gluetun", which Docker
# pins to gluetun's CONTAINER ID at creation time. Recreating gluetun
# invalidates that ID permanently: the dependents can then never be *started*
# again ("cannot join network of a non running container") — they must be
# removed and recreated. Every script that needs to bounce gluetun must go
# through this script instead of calling docker compose directly.
#
# Steps:
#   1. Remove (not just stop) qbittorrent + sabnzbd
#   2. Force-recreate gluetun (picks up new WIREGUARD_* values from .env)
#   3. Poll until gluetun reports healthy (or timeout)
#   4. Recreate the dependents against the new gluetun container
#   5. Verify both are running; one forced retry each before failing
#
# Usage: bash restart_vpn_stack.sh
# Environment overrides:
#   DOCKERCONFDIR          - stack root (default: parent of scripts/)
#   VPN_STACK_LOG          - log file (default $ROOT/logs/vpn_stack.log)
#   GLUETUN_HEALTH_TIMEOUT - seconds to wait for gluetun health (default 180)
#
# Exit codes: 0 = stack healthy and dependents running, 1 = failure
# (dependents are left down only if gluetun itself never became healthy).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

LOG_FILE="${VPN_STACK_LOG:-$ROOT_DIR/logs/vpn_stack.log}"
LOG_PREFIX="vpn-stack"
HEALTH_TIMEOUT="${GLUETUN_HEALTH_TIMEOUT:-180}"
DEPENDENTS="qbittorrent sabnzbd"

cd "$ROOT_DIR" || { log "ERROR: cannot cd to $ROOT_DIR"; exit 1; }

log "Removing dependent containers ($DEPENDENTS) so they can be recreated against the new gluetun"
# shellcheck disable=SC2086  # intentional word splitting
$COMPOSE rm -sf $DEPENDENTS >/dev/null 2>&1 || true

log "Recreating gluetun (--force-recreate ensures fresh .env values are applied)"
if ! $COMPOSE up -d --force-recreate gluetun; then
    log "ERROR: compose failed to start gluetun"
    exit 1
fi

log "Waiting up to ${HEALTH_TIMEOUT}s for gluetun to become healthy..."
waited=0
status="unknown"
while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    status=$(docker inspect gluetun --format='{{.State.Health.Status}}' 2>/dev/null || echo "missing")
    if [ "$status" = "healthy" ]; then
        break
    fi
    sleep 5
    waited=$((waited + 5))
done

if [ "$status" != "healthy" ]; then
    log "ERROR: gluetun not healthy after ${HEALTH_TIMEOUT}s (last status: $status); leaving $DEPENDENTS down"
    exit 1
fi
log "gluetun healthy after ${waited}s"

log "Recreating dependent containers: $DEPENDENTS"
# shellcheck disable=SC2086
$COMPOSE up -d $DEPENDENTS

failed=""
for container in $DEPENDENTS; do
    state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
    if [ "$state" != "running" ]; then
        log "WARNING: $container not running after up (state: $state); forcing recreate"
        $COMPOSE rm -sf "$container" >/dev/null 2>&1 || true
        $COMPOSE up -d "$container"
        state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
    fi
    if [ "$state" != "running" ]; then
        failed="$failed $container"
    fi
done

if [ -n "$failed" ]; then
    log "ERROR: containers failed to start after recreate:$failed"
    exit 1
fi

log "VPN stack restart complete: gluetun healthy, $DEPENDENTS running"
exit 0
