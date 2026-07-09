# Pullio Docker Container Auto-Update Setup

> **`<stack-root>`** in this document = the directory where this repository lives on your machine (your `DOCKERCONFDIR`).

## Overview

Pullio automatically updates Docker containers with `org.hotio.pullio` labels. Your containers are already configured with these labels, but Pullio needs to be scheduled to run periodically.

## Current Configuration Status

✅ **Container Labels**: All containers have Pullio labels configured  
✅ **Environment Variables**: PULLIO_UPDATE=true, PULLIO_NOTIFY=true  
✅ **Update Script**: `<stack-root>/scripts/pullio_with_recovery.sh` — runs pullio, then recreates qbittorrent/sabnzbd if pullio recreated gluetun (they're pinned to gluetun's network namespace and get orphaned otherwise)  
⚠️ **Missing**: Scheduled execution and Discord webhook

## Quick Setup

### 1. Set up DSM Scheduled Task

1. **Open DSM Control Panel**
   - Go to **Control Panel → Task Scheduler**

2. **Create New Task**
   - Click **Create → Scheduled Task → User-defined script**

3. **General Tab**
   - **Task**: `Pullio Container Updates`
   - **User**: `root` (Required for Docker access)
   - **Enabled**: ✓ Check this box

4. **Schedule Tab**
   - **Date**: `Daily` or `Weekly` (recommended)
   - **Time**: `03:00` (3 AM when system is idle)
   - **Frequency**: `Does not repeat` (for daily) or select day for weekly

5. **Task Settings Tab**
   - **User-defined script**:
     ```bash
     <stack-root>/scripts/pullio_with_recovery.sh
     ```

6. **Click OK** to save

### 2. Configure Discord Notifications (Optional)

1. **Create Discord Webhook**
   - In your Discord server, go to Server Settings → Integrations
   - Click "Create Webhook" or "View Webhooks"
   - Copy the webhook URL

2. **Add to Environment**
   Edit `<stack-root>/.env`:
   ```bash
   PULLIO_DISCORD_WEBHOOK=https://discord.com/api/webhooks/YOUR_WEBHOOK_URL
   ```

3. **Restart containers** to apply the new webhook:
   ```bash
   cd <stack-root>
   docker-compose down && docker-compose up -d
   ```

## Manual Testing

### Test the Update Script
```bash
# Run manually to test
sudo bash <stack-root>/scripts/pullio_with_recovery.sh
```

### Check Logs
```bash
# View Pullio output
tail -f <stack-root>/pullio/pullio.log

# View gluetun-dependent recovery log
tail -f <stack-root>/logs/pullio_recovery.log
```

### Test DSM Task
1. Go to **Control Panel → Task Scheduler**
2. Select your **Pullio Container Updates** task
3. Click **Run**
4. Check logs for output

## How It Works

### Container Detection
Pullio looks for containers with these labels (already configured):
```yaml
labels:
  - org.hotio.pullio.update=${PULLIO_UPDATE}
  - org.hotio.pullio.notify=${PULLIO_NOTIFY}
  - org.hotio.pullio.discord.webhook=${PULLIO_DISCORD_WEBHOOK}
```

### Update Process
1. **Check**: Compares local image versions with registry
2. **Pull**: Downloads newer images if available
3. **Update**: Recreates containers with new images
4. **Notify**: Sends Discord/DSM notifications
5. **Cleanup**: Removes old unused images

### Affected Containers
Every service in `docker-compose.yml` that carries the `org.hotio.pullio.*`
labels — the *arrs, download clients, gluetun, and the companion services
(recyclarr, scoutarr, cleanuparr, mediastack-mcp, mediastack-dashboard).

**gluetun special case**: qbittorrent and sabnzbd share gluetun's network
namespace (`network_mode: service:gluetun`). When pullio recreates gluetun,
they end up pointing at a dead namespace — `pullio_with_recovery.sh` detects
this in pullio's log and recreates them.

## Customization

### Update Frequency
- **Daily**: Good for active development environments
- **Weekly**: Recommended for stable production setups
- **Bi-weekly**: Conservative approach

### Notification Types
```bash
# In .env file
PULLIO_UPDATE=true          # Enable updates
PULLIO_NOTIFY=true          # Enable notifications
PULLIO_DISCORD_WEBHOOK=     # Discord webhook URL (optional)
```

### Exclude Containers
To exclude a container from updates, remove its Pullio labels or set:
```yaml
labels:
  - org.hotio.pullio.update=false
```

## Troubleshooting

### Updates Not Working
1. **Check task runs as root**:
   ```bash
   sudo docker ps
   ```

2. **Verify script permissions**:
   ```bash
   ls -la <stack-root>/scripts/pullio_with_recovery.sh
   chmod +x <stack-root>/scripts/pullio_with_recovery.sh
   ```

3. **Test Docker access**:
   ```bash
   docker run --rm hello-world
   ```

### No Notifications
1. **Discord webhook**: Verify URL is correct and not expired
2. **DSM notifications**: Check Control Panel → Notification settings
3. **Test manually**: Run script and check if notifications are sent

### Containers Not Updating
1. **Check labels**: Ensure containers have `org.hotio.pullio.update=true`
2. **Check images**: Verify image URLs are correct (like the Prowlarr fix)
3. **Registry access**: Ensure Docker can access ghcr.io and other registries

### Log Analysis
```bash
# Check for recovery errors
grep ERROR <stack-root>/logs/pullio_recovery.log

# Check what was updated
grep "Pulled\|Updated\|Recreated" <stack-root>/pullio/pullio.log

# Monitor real-time
tail -f <stack-root>/pullio/pullio.log
```

## Security Notes

- ✅ Script runs with minimal required permissions
- ✅ Docker socket access is controlled
- ✅ Webhook URLs should be kept private
- ✅ Logs don't contain sensitive information

## Next Steps

1. **Set up the DSM scheduled task** using the instructions above
2. **Add Discord webhook** for notifications (optional)
3. **Test the setup** by running manually first
4. **Monitor logs** for the first few automated runs

Your containers will now be automatically updated while you sleep! 🚀