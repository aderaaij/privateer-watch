#!/bin/bash
#
# setup_offbox_backup.sh - One-time setup for backup_offbox.sh.
#
# DSM Task Scheduler runs the backup as root, so ROOT needs a passwordless SSH
# key trusted by the destination host. This script:
#   1. Ensures root has an ed25519 key (creates one if missing)
#   2. Installs root's public key into the remote's authorized_keys
#      (idempotent; asks for the remote password ONCE here)
#   3. Verifies passwordless SSH works
#   4. Offers to run a first backup end-to-end
#   5. Prints the DSM Task Scheduler entry to create
#
# Run this ONCE, as root, on the NAS:
#   sudo bash <stack-root>/scripts/setup_offbox_backup.sh
#
# Configuration (must match what backup_offbox.sh will use): set BACKUP_* in
# the stack's .env, or export as environment variables (environment wins):
#   BACKUP_REMOTE_HOST   - destination host (REQUIRED)
#   BACKUP_REMOTE_USER   - ssh user on the destination (REQUIRED)
#   BACKUP_REMOTE_PORT   - ssh port (default 22)
#
# Exit codes: 0 = passwordless SSH verified, 1 = setup failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

KEY="/root/.ssh/id_ed25519"
PUB="${KEY}.pub"
BACKUP_SCRIPT="$SCRIPT_DIR/backup_offbox.sh"

say()  { echo "[setup] $*"; }
fail() { echo "[setup] ERROR: $*" >&2; exit 1; }

REMOTE_HOST="$(env_or_dotenv BACKUP_REMOTE_HOST)"
REMOTE_USER="$(env_or_dotenv BACKUP_REMOTE_USER)"
REMOTE_PORT="$(env_or_dotenv BACKUP_REMOTE_PORT 22)"
[ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_USER" ] \
    || fail "BACKUP_REMOTE_HOST / BACKUP_REMOTE_USER not set - add them to $ROOT_DIR/.env"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

# --- 1. Must be root (the account DSM will run the backup as) ---
[ "$(id -u)" -eq 0 ] || fail "run as root:  sudo bash $0"

# --- 2. Ensure root has an SSH key ---
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [ ! -f "$KEY" ]; then
    say "No key at $KEY - generating one..."
    ssh-keygen -t ed25519 -N "" -f "$KEY" -C "mediastack-backup@$(hostname)" \
        || fail "ssh-keygen failed"
else
    say "Reusing existing key at $KEY"
fi

# --- 3. Is passwordless SSH already working? ---
verify() { ssh -p "$REMOTE_PORT" -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" 'echo ok' 2>/dev/null; }

if [ "$(verify)" = "ok" ]; then
    say "Passwordless SSH to $REMOTE already works - nothing to install."
else
    say "Installing root's public key on $REMOTE."
    say "You will be asked for ${REMOTE}'s password ONCE now:"
    PUBKEY="$(cat "$PUB")"
    # Portable + idempotent: only appends if the key isn't already present.
    # accept-new auto-trusts the host key on first contact (safe over Tailscale).
    ssh -p "$REMOTE_PORT" -o StrictHostKeyChecking=accept-new "$REMOTE" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
         touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
         grep -qxF '$PUBKEY' ~/.ssh/authorized_keys || printf '%s\n' '$PUBKEY' >> ~/.ssh/authorized_keys" \
        || fail "could not install key on $REMOTE (wrong password / host unreachable?)"

    # --- 4. Verify it now works without a password ---
    [ "$(verify)" = "ok" ] || fail "key installed but passwordless SSH still fails to $REMOTE"
    say "Passwordless SSH to $REMOTE confirmed."
fi

# --- 5. Offer a first end-to-end backup ---
if [ -x "$BACKUP_SCRIPT" ] || [ -f "$BACKUP_SCRIPT" ]; then
    read -r -p "[setup] Run a first backup now to verify end-to-end? [Y/n] " ans
    case "${ans:-Y}" in
        [Nn]*) say "Skipped. Run it later:  sudo bash $BACKUP_SCRIPT" ;;
        *) say "Running $BACKUP_SCRIPT ..."
           bash "$BACKUP_SCRIPT" && say "First backup succeeded." \
               || fail "first backup failed - check logs/backup_offbox.log" ;;
    esac
else
    say "WARN: $BACKUP_SCRIPT not found - skipping first-backup test."
fi

# --- 6. Print the DSM Task Scheduler entry ---
cat <<EOF

[setup] Done. Now add the recurring job in DSM:

  Control Panel -> Task Scheduler -> Create -> Scheduled Task -> User-defined script
    User:     root
    Schedule: daily (.env changes on every VPN rotation; the tarball is ~30 MB)
    Command:  bash $BACKUP_SCRIPT

Verify anytime with:  tail -5 $(cd "$SCRIPT_DIR/.." && pwd)/logs/backup_offbox.log
EOF
