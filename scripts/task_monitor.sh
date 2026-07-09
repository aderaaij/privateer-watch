#!/bin/bash
#
# DSM Task Scheduler wrapper: VPN health monitor (every 30 minutes).
# The scheduled task references this file by absolute path — keep it here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env

"$SCRIPT_DIR/wireguard_monitor.sh" >> "$ROOT_DIR/logs/task_monitor.log" 2>&1
