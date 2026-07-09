#!/bin/bash
#
# pullio_with_recovery.sh - DSM Task Scheduler wrapper for pullio.
#
# Runs /usr/local/bin/pullio, then detects whether gluetun was recreated as
# a side-effect of updating one of its network_mode dependents
# (qbittorrent/sabnzbd). If so, recreates those dependents so they rejoin
# gluetun's new network namespace -- pullio only recreates services whose
# image it pulled, not services orphaned by depends_on cascades.
#
# Replaces the previous DSM task command:
#   /usr/local/bin/pullio > $DOCKERCONFDIR/pullio/pullio.log 2>&1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PULLIO_LOG="$ROOT_DIR/pullio/pullio.log"
LOG_FILE="$ROOT_DIR/logs/pullio_recovery.log"
DEPENDENTS="qbittorrent sabnzbd"

mkdir -p "$(dirname "$PULLIO_LOG")" "$(dirname "$LOG_FILE")"

/usr/local/bin/pullio > "$PULLIO_LOG" 2>&1
pullio_status=$?

if grep -qE 'Container[[:space:]]+gluetun[[:space:]]+Recreated' "$PULLIO_LOG"; then
    log "gluetun was recreated by pullio; recreating dependents ($DEPENDENTS)"
    if ! cd "$ROOT_DIR"; then
        log "ERROR: cannot cd to $ROOT_DIR"
        exit 1
    fi
    # shellcheck disable=SC2086
    $COMPOSE rm -sf $DEPENDENTS >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    if $COMPOSE up -d $DEPENDENTS; then
        log "Dependents recreated successfully"
    else
        log "ERROR: compose up -d failed for dependents"
        exit 1
    fi
fi

exit "$pullio_status"
