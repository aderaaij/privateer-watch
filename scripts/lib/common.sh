#!/bin/bash
#
# common.sh - shared helpers for the mediastack scripts.
#
# Source from a script in scripts/:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/common.sh"
# (from scripts/privado-api/, source "$SCRIPT_DIR/../lib/common.sh")
#
# Provides:
#   ROOT_DIR     stack root: $DOCKERCONFDIR, else the parent of scripts/
#   ENV_FILE     $ROOT_DIR/.env
#   COMPOSE      "docker-compose" (v1) or "docker compose" (v2) - use unquoted
#   load_env     allexport-source .env and re-resolve ROOT_DIR
#   env_or_dotenv VAR [default]   resolve: environment > .env > default
#   log MSG...   timestamped line to stderr, appended to $LOG_FILE if set
#                ($LOG_PREFIX adds a "[prefix]" component)
#   discord_notify MSG            plain-content Discord webhook message
#   dsm_notify TITLE MSG          Synology DSM notification (no-op elsewhere)
#
# Safe under `set -euo pipefail`; sets no shell options itself.

# Guard against double-sourcing
[ -n "${MEDIASTACK_COMMON_LOADED:-}" ] && return 0
MEDIASTACK_COMMON_LOADED=1

_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$_COMMON_LIB_DIR/.." && pwd)"
ROOT_DIR="${DOCKERCONFDIR:-$(cd "$SCRIPTS_DIR/.." && pwd)}"
ENV_FILE="$ROOT_DIR/.env"

# docker compose v1 binary vs v2 plugin. Use unquoted: $COMPOSE up -d ...
if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    COMPOSE="docker compose"
fi

# Source .env (exporting everything) and re-resolve ROOT_DIR in case it set
# DOCKERCONFDIR. No-op when .env doesn't exist.
load_env() {
    if [ -f "$ENV_FILE" ]; then
        set -o allexport
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +o allexport
        ROOT_DIR="${DOCKERCONFDIR:-$ROOT_DIR}"
        ENV_FILE="$ROOT_DIR/.env"
    fi
}

# Resolve a setting: environment wins, then .env, then the given default.
# Useful for scripts run with an empty environment (DSM Task Scheduler).
env_or_dotenv() {
    local val="${!1:-}"
    if [ -z "$val" ] && [ -f "$ENV_FILE" ]; then
        val=$(grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed 's/#.*//' | tr -d '"' | xargs)
    fi
    echo "${val:-${2:-}}"
}

# Timestamped log line: always to stderr (safe inside command substitution),
# appended to $LOG_FILE when set. $LOG_PREFIX tags the source, e.g. [offbox].
log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')]${LOG_PREFIX:+ [$LOG_PREFIX]} $*"
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$line" >> "$LOG_FILE"
    fi
    echo "$line" >&2
}

# Plain-content Discord message via $DISCORD_WEBHOOK or $PULLIO_DISCORD_WEBHOOK.
# Silently does nothing when no webhook is configured.
discord_notify() {
    local hook="${DISCORD_WEBHOOK:-${PULLIO_DISCORD_WEBHOOK:-}}"
    [ -n "$hook" ] || return 0
    curl -H "Content-Type: application/json" -X POST \
         -d "{\"content\":\"$1\"}" \
         "$hook" >/dev/null 2>&1 || true
}

# Synology DSM notification. No-op when synodsmnotify isn't available (i.e.
# any non-Synology system) or SYNOLOGY_NOTIFY=false.
dsm_notify() {
    [ "${SYNOLOGY_NOTIFY:-true}" = true ] || return 0
    command -v synodsmnotify >/dev/null 2>&1 || return 0
    synodsmnotify -t "$1" -m "$2" 2>/dev/null || true
}
