#!/bin/bash
#
# backup_offbox.sh - Copy the un-git-tracked crown jewels off the NAS.
#
# Everything in this repo lives on GitHub, but the files that actually make the
# stack *start* and hold its state are gitignored and sit only on the NAS:
#   - .env                          (WireGuard key, Privado creds, all API keys)
#   - <app>/Backups/scheduled/*.zip (Sonarr/Radarr/Prowlarr/... config + DB)
# A dead volume takes all of it, including the local backups/ copies. This
# script bundles those files into one dated tarball and rsyncs it to another
# host (configured via BACKUP_* in .env), then prunes old copies on both ends.
#
# Restore (total loss): git clone the repo, drop the .env from the newest
# tarball in place, then per app: bring it up and use its UI
# System -> Backup -> Restore with that app's zip. See docs/space-saver.md
# neighbours / README for the full runbook.
#
# Usage: bash backup_offbox.sh
# Configuration: set BACKUP_* in the stack's .env, or export as environment
# variables (environment wins over .env):
#   BACKUP_REMOTE_HOST   - destination host (REQUIRED)
#   BACKUP_REMOTE_USER   - ssh user on the destination (REQUIRED)
#   BACKUP_REMOTE_DIR    - destination dir (default ~/backups/mediastack)
#   BACKUP_REMOTE_PORT   - ssh port (default 22)
#   BACKUP_KEEP          - dated tarballs to retain on the remote (default 14)
# Environment-only overrides:
#   DOCKERCONFDIR        - stack root (default: parent of scripts/)
#   OFFBOX_LOG           - log file (default $ROOT/logs/backup_offbox.log)
#
# Prerequisite: passwordless SSH key from the account running this task
# (root, under DSM Task Scheduler) to BACKUP_REMOTE_USER@BACKUP_REMOTE_HOST.
#
# Exit codes: 0 = tarball shipped and verified, 1 = failure (nothing pruned).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

LOG_FILE="${OFFBOX_LOG:-$ROOT_DIR/logs/backup_offbox.log}"
LOG_PREFIX="offbox"

# DSM Task Scheduler runs this with an empty environment, so the BACKUP_*
# settings normally come from .env (via env_or_dotenv in common.sh).
REMOTE_HOST="$(env_or_dotenv BACKUP_REMOTE_HOST)"
REMOTE_USER="$(env_or_dotenv BACKUP_REMOTE_USER)"
REMOTE_DIR="$(env_or_dotenv BACKUP_REMOTE_DIR backups/mediastack)"   # relative = under remote $HOME
REMOTE_PORT="$(env_or_dotenv BACKUP_REMOTE_PORT 22)"
KEEP="$(env_or_dotenv BACKUP_KEEP 14)"

# Apps that keep their own scheduled backup zips. cleanuparr/scoutarr/seerr
# have no such zips, so their whole config dir would be needed - out of scope
# for a "tiny" helper; they rebuild fast from the web UI.
ARR_APPS="sonarr radarr prowlarr readarr bazarr"

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
SSH="ssh -p ${REMOTE_PORT} -o BatchMode=yes -o ConnectTimeout=10"

cd "$ROOT_DIR" || { log "ERROR: cannot cd to $ROOT_DIR"; exit 1; }

if [ ! -f "$ROOT_DIR/.env" ]; then
    log "ERROR: $ROOT_DIR/.env not found - nothing to back up"
    exit 1
fi

if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_USER" ]; then
    log "ERROR: BACKUP_REMOTE_HOST / BACKUP_REMOTE_USER not set - add them to $ROOT_DIR/.env"
    exit 1
fi

STAMP="$(date '+%Y%m%d_%H%M%S')"
TARBALL_NAME="mediastack-config-${STAMP}.tar.gz"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/offbox.XXXXXX")" || { log "ERROR: mktemp failed"; exit 1; }
TARBALL="${STAGE}.tar.gz"
trap 'rm -rf "$STAGE" "$TARBALL"' EXIT

# --- Preflight: confirm the remote is reachable before we stage anything ---
if ! $SSH "$REMOTE" "mkdir -p '$REMOTE_DIR'" 2>>"$LOG_FILE"; then
    log "ERROR: cannot reach $REMOTE (need passwordless SSH key). Aborting."
    exit 1
fi

# --- Stage: .env + newest zip per app, plus a manifest for the restorer ---
cp -p "$ROOT_DIR/.env" "$STAGE/.env"
MANIFEST="$STAGE/MANIFEST.txt"
{
    echo "mediastack off-box config backup"
    echo "created: $STAMP  from: $(hostname)  root: $ROOT_DIR"
    echo "---"
    echo ".env ($(wc -c <"$ROOT_DIR/.env" | tr -d ' ') bytes)"
} >"$MANIFEST"

for app in $ARR_APPS; do
    # *arr apps use Backups/{scheduled,manual}/; bazarr uses backup/ (lowercase).
    zip="$(ls -1t "$ROOT_DIR/$app"/Backups/scheduled/*.zip \
                    "$ROOT_DIR/$app"/Backups/manual/*.zip \
                    "$ROOT_DIR/$app"/backup/*.zip 2>/dev/null | head -1)"
    if [ -n "$zip" ]; then
        cp -p "$zip" "$STAGE/"
        echo "$app -> $(basename "$zip") ($(du -h "$zip" | cut -f1))" >>"$MANIFEST"
    else
        log "WARN: no backup zip found for $app (skipping)"
        echo "$app -> MISSING" >>"$MANIFEST"
    fi
done

# --- Bundle (dotglob so .env is included) and ship ---
( shopt -s dotglob; tar -czf "$TARBALL" -C "$STAGE" . ) || { log "ERROR: tar failed"; exit 1; }
SIZE="$(du -h "$TARBALL" | cut -f1)"

if ! rsync -a -e "$SSH" "$TARBALL" "$REMOTE:$REMOTE_DIR/$TARBALL_NAME" 2>>"$LOG_FILE"; then
    log "ERROR: rsync to $REMOTE:$REMOTE_DIR failed"
    exit 1
fi

# --- Verify the remote file exists and is non-empty, then prune old ones ---
if ! $SSH "$REMOTE" "test -s '$REMOTE_DIR/$TARBALL_NAME'" 2>>"$LOG_FILE"; then
    log "ERROR: uploaded $TARBALL_NAME missing/empty on remote"
    exit 1
fi
$SSH "$REMOTE" \
    "ls -1t '$REMOTE_DIR'/mediastack-config-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f" \
    2>>"$LOG_FILE" || log "WARN: remote prune step had a problem (backup itself is safe)"

log "OK: shipped $TARBALL_NAME ($SIZE) to $REMOTE:$REMOTE_DIR (keeping newest $KEEP)"
exit 0
