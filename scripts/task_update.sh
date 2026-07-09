#!/bin/bash
#
# DSM Task Scheduler wrapper: daily WireGuard config update check.
# The scheduled task references this file by absolute path — keep it here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env

"$SCRIPT_DIR/update_wireguard.sh" >> "$ROOT_DIR/logs/task_update.log" 2>&1
