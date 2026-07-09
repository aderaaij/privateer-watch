# WireGuard VPN Monitoring for Synology NAS

> **`<stack-root>`** in this document = the directory where this repository lives on your machine (your `DOCKERCONFDIR`).

This suite of scripts provides automated monitoring and configuration management for your WireGuard VPN connection through Gluetun on Synology NAS.

## Features

- 🔍 **Automatic VPN monitoring** - Checks connection status every 30 minutes
- 🔄 **Auto-restart on failure** - Attempts to restore connection automatically
- 📝 **Configuration updates** - Parse and apply new WireGuard configs from Privado
- 📊 **Status reporting** - Get detailed VPN connection information
- 🔔 **Notifications** - Discord webhooks and Synology DSM alerts
- 💾 **Automatic backups** - Saves working configurations before updates

## Portability

The scripts are written for Synology DSM but run on any Linux box with bash,
curl, jq and Docker:

- **Paths**: everything resolves relative to the repo checkout (stack root =
  parent of `scripts/`); set `DOCKERCONFDIR` to override.
- **Compose**: `lib/common.sh` auto-detects `docker-compose` (v1) vs
  `docker compose` (v2).
- **Synology-only bits degrade gracefully**: DSM notifications are a no-op
  when `synodsmnotify` doesn't exist; use cron instead of DSM Task Scheduler
  for the two scheduled entry points (`task_monitor.sh`, `task_update.sh`).

Shared helpers (logging, notifications, `.env` loading) live in
`lib/common.sh` — new scripts should source it rather than reimplementing.

## Installation

1. **Run the setup script as root:**
   ```bash
   sudo <stack-root>/scripts/setup_monitoring.sh
   ```

2. **Configure DSM Task Scheduler** (see below)

## Scripts Overview

### 1. `wireguard_monitor.sh`
Main monitoring script that checks VPN health and sends alerts.
- Checks container status
- Verifies VPN connectivity
- Sends notifications on failures
- Attempts automatic recovery

### 2. `auto_update_wireguard.sh`
Automated server rotation and selection using the Privado API.
```bash
# Force immediate server rotation
sudo <stack-root>/scripts/auto_update_wireguard.sh force

# Switch to specific location
sudo <stack-root>/scripts/auto_update_wireguard.sh Amsterdam

# Automatic rotation (scheduled via DSM)
sudo <stack-root>/scripts/auto_update_wireguard.sh auto
```

### 3. `restart_vpn_stack.sh`
The single canonical way to restart gluetun. qBittorrent and SABnzbd use
`network_mode: service:gluetun`, which pins them to gluetun's **container ID**
— once gluetun is recreated they can never be started again, only recreated.
This script removes the dependents, force-recreates gluetun (so new `.env`
values are applied), waits for it to become healthy, then recreates the
dependents. All other scripts delegate to it; never bounce gluetun with
`docker-compose restart` or `docker restart` directly.
```bash
bash <stack-root>/scripts/restart_vpn_stack.sh
```

### 4. `check_vpn.sh`
Quick manual check of VPN status.
```bash
<stack-root>/scripts/check_vpn.sh
```

### 5. `parse_wireguard_conf.sh`
Interactive config updater from a downloaded .conf file.
```bash
# Download new config from Privado and place in wireguard_configs folder
# Then run:
<stack-root>/scripts/parse_wireguard_conf.sh
```

### 6. `update_wireguard.sh`
Automated configuration update checker (runs via Task Scheduler).

### 7. `setup_monitoring.sh`
Initial setup script to configure the monitoring system.

### 8. `pullio_with_recovery.sh`
DSM wrapper for [pullio](https://hotio.dev/pullio/) container updates: runs
pullio, then recreates qbittorrent/sabnzbd if pullio recreated gluetun (they
are pinned to gluetun's container ID and get orphaned otherwise).

### 9. `task_monitor.sh` / `task_update.sh`
Wrapper scripts for DSM Task Scheduler to call the monitor and update scripts.

### 10. `backup_offbox.sh` / `setup_offbox_backup.sh`
Nightly off-box backup of `.env` + the *arr scheduled backup zips to another
host over SSH. Run the setup script once as root to install the SSH key;
configure the destination via `BACKUP_REMOTE_*` in `.env`.

### 11. `setup_space_saver_profiles.sh`
Creates the penalty custom formats for the space-saver quality profiles
(see `docs/space-saver.md`) — idempotent, run after a fresh recyclarr sync
if the profiles are ever recreated.

### 12. `privado-api/`
Privado VPN API integration scripts for automated server management:
- `privado_login.sh` - Authenticate with Privado API
- `privado_get_servers.sh` - Fetch available server list
- `privado_generate_config.sh` - Generate WireGuard config from API
- `data/` - Cached API data (gitignored — contains tokens)

### 13. `lib/common.sh`
Shared helpers sourced by the other scripts: path/`.env` resolution,
logging, Discord/DSM notifications, compose v1/v2 detection.

## DSM Task Scheduler Setup

### Task 1: VPN Monitor (Every 30 minutes)

1. Open **Control Panel → Task Scheduler**
2. Click **Create → Scheduled Task → User-defined script**
3. Configure:
   - **General Tab:**
     - Task: `WireGuard VPN Monitor`
     - User: `root`
     - Enabled: ✓
   - **Schedule Tab:**
     - Run on: Daily
     - Frequency: Every 30 minutes
   - **Task Settings Tab:**
     - User-defined script:
       ```bash
       <stack-root>/scripts/task_monitor.sh
       ```
     - Send run details by email: (optional)

### Task 2: Config Update Check (Daily)

1. Create another scheduled task
2. Configure:
   - **General Tab:**
     - Task: `WireGuard Config Update`
     - User: `root`
     - Enabled: ✓
   - **Schedule Tab:**
     - Run on: Daily
     - Time: 03:00
   - **Task Settings Tab:**
     - User-defined script:
       ```bash
       <stack-root>/scripts/task_update.sh
       ```

## Manual Configuration Update Process

When Privado changes their WireGuard configuration:

1. **Download the new config:**
   - Log into Privado VPN website
   - Download the WireGuard configuration file (.conf)

2. **Place config file:**
   ```bash
   # Copy to the wireguard_configs directory
   cp ~/Downloads/privado-wireguard.conf <stack-root>/wireguard_configs/
   ```

3. **Run the update script:**
   ```bash
   sudo <stack-root>/scripts/parse_wireguard_conf.sh
   ```

4. **Follow the prompts** to review and apply changes

## Directory Structure

```
<stack-root>/
├── scripts/                    # All monitoring scripts
│   ├── lib/
│   │   └── common.sh           # Shared helpers (paths, .env, log, notify, compose)
│   ├── wireguard_monitor.sh
│   ├── auto_update_wireguard.sh
│   ├── restart_vpn_stack.sh
│   ├── check_vpn.sh
│   ├── parse_wireguard_conf.sh
│   ├── update_wireguard.sh
│   ├── setup_monitoring.sh
│   ├── setup_space_saver_profiles.sh
│   ├── backup_offbox.sh
│   ├── setup_offbox_backup.sh
│   ├── pullio_with_recovery.sh
│   ├── task_monitor.sh
│   ├── task_update.sh
│   ├── test_automation.sh
│   └── privado-api/            # Privado VPN API integration
│       ├── privado_login.sh
│       ├── privado_get_servers.sh
│       ├── privado_generate_config.sh
│       └── data/
├── wireguard_configs/          # Place new .conf files here
│   └── processed/              # Archived processed configs
├── backups/                    # Automatic .env backups
├── logs/                       # All log files
│   ├── wireguard_monitor.log
│   ├── wireguard_updates.log
│   ├── auto_wireguard.log
│   ├── vpn_stack.log
│   ├── automation_test.log
│   ├── task_monitor.log
│   ├── task_update.log
│   └── last_rotation
└── gluetun/                    # VPN status files
    └── vpn_status.txt
```

## Monitoring and Logs

### Check VPN Status
```bash
# Quick status check
<stack-root>/scripts/check_vpn.sh

# View current status file
cat <stack-root>/gluetun/vpn_status.txt
```

### View Logs
```bash
# Monitor log (real-time)
tail -f <stack-root>/logs/wireguard_monitor.log

# Update log
tail -f <stack-root>/logs/wireguard_updates.log

# Task scheduler logs
tail -f <stack-root>/logs/task_monitor.log
tail -f <stack-root>/logs/task_update.log
```

## Notifications

### Discord Webhook
Add your Discord webhook URL to the `.env` file:
```bash
PULLIO_DISCORD_WEBHOOK=https://discord.com/api/webhooks/YOUR_WEBHOOK_URL
```

### Synology DSM Notifications
Notifications are sent automatically through DSM's notification system.
Configure in: **Control Panel → Notification**

## Troubleshooting

### Gluetun Unhealthy / VPN Not Connecting

This is the most common issue. Privado periodically rotates their server configurations, which causes the WireGuard endpoint in `.env` to go stale. Symptoms:
- `dependency failed to start: container gluetun is unhealthy`
- Monitor log shows repeated "ERROR: Gluetun container is unhealthy!" entries
- Gluetun restarts but keeps going unhealthy within 30 minutes

**Step 1: Force a server rotation** (preferred fix)
```bash
sudo <stack-root>/scripts/auto_update_wireguard.sh force
```
This re-authenticates with Privado's API, fetches a fresh server, updates `.env`, and restarts gluetun.

**Step 2: If the Privado API token is expired**, re-login first:
```bash
sudo bash <stack-root>/scripts/privado-api/privado_login.sh
```

**Step 3: Bring containers back up.** After login or manual `.env` changes, gluetun may not restart automatically. Always run:
```bash
cd <stack-root>
docker-compose up -d
```
This ensures gluetun and all dependent containers (qbittorrent, sabnzbd) are recreated with the new config.

**Step 4: Verify**
```bash
docker logs gluetun --tail 20
bash <stack-root>/scripts/check_vpn.sh
```

### Quick Diagnostics
```bash
# Check container status and health
docker ps | grep gluetun
docker logs gluetun --tail 50

# Verify current WireGuard config
grep WIREGUARD <stack-root>/.env

# Check when the last server rotation happened
tail -20 <stack-root>/logs/auto_wireguard.log
```

### Scripts Not Running
1. Check permissions:
   ```bash
   ls -la <stack-root>/scripts/
   ```

2. Make executable if needed:
   ```bash
   chmod +x <stack-root>/scripts/*.sh
   ```

### Task Scheduler Issues
1. Check task history in DSM Task Scheduler
2. Verify running as `root` user
3. Check logs in `<stack-root>/logs/`

## Configuration Values

The scripts manage these WireGuard settings in your `.env` file:
- `WIREGUARD_ENDPOINT_IP` - VPN server IP
- `WIREGUARD_ENDPOINT_PORT` - VPN server port
- `WIREGUARD_PUBLIC_KEY` - Server public key
- `WIREGUARD_PRIVATE_KEY` - Your private key
- `WIREGUARD_ADDRESSES` - Your VPN IP address

## Security Notes

- Private keys are never logged or sent in notifications
- Backups are stored locally with restricted permissions
- Old configs are archived, not deleted
- Always verify VPN is working after updates

## Support

For issues or questions:
1. Check the logs first
2. Run `check_vpn.sh` for current status
3. Verify your Privado account is active
4. Ensure Docker and Gluetun are running properly

## License

These scripts are provided as-is for personal use with your Synology NAS and Docker setup.