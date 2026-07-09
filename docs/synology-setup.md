# Synology DSM Setup Guide

> **`<stack-root>`** in this document = the directory where this repository lives on your machine (your `DOCKERCONFDIR`).

This guide walks you through setting up WireGuard VPN monitoring on Synology DSM using Task Scheduler.

## Prerequisites

- ✅ Synology NAS with Docker package installed
- ✅ SSH access to your NAS (or DSM Terminal)
- ✅ Docker Compose setup with Gluetun already running
- ✅ Admin/root access for Task Scheduler

## Installation Steps

### 1. Install the Monitoring Scripts

Connect to your Synology via SSH and run:

```bash
# Navigate to your Docker directory
cd <stack-root>

# Run the setup script
sudo bash scripts/setup_monitoring.sh
```

This will:
- Create necessary directories
- Set correct permissions
- Test Docker access
- Initialize log files
- Create task wrapper scripts

### 2. Configure DSM Task Scheduler

#### Task 1: VPN Monitor (Every 30 Minutes)

1. **Open DSM Control Panel**
   - Go to **Control Panel → Task Scheduler**

2. **Create New Task**
   - Click **Create → Scheduled Task → User-defined script**

3. **General Tab**
   - **Task**: `WireGuard VPN Monitor`
   - **User**: `root` (⚠️ **Important**: Must be root for Docker access)
   - **Enabled**: ✓ Check this box

4. **Schedule Tab**
   - **Date**: Run on the following days: `Daily`
   - **First run time**: `00:00` (or any time)
   - **Frequency**: `Every 30 minute(s)`
   - **Last run time**: `23:30`

5. **Task Settings Tab**
   - **Send run details by email**: (optional, configure if desired)
   - **User-defined script**:
     ```bash
     <stack-root>/scripts/task_monitor.sh
     ```

6. **Click OK** to save

#### Task 2: Config Update Check (Daily)

1. **Create Second Task**
   - Click **Create → Scheduled Task → User-defined script**

2. **General Tab**
   - **Task**: `WireGuard Config Update Check`
   - **User**: `root`
   - **Enabled**: ✓

3. **Schedule Tab**
   - **Date**: `Daily`
   - **Time**: `03:00` (3 AM, when system is typically idle)

4. **Task Settings Tab**
   - **User-defined script**:
     ```bash
     <stack-root>/scripts/task_update.sh
     ```

5. **Click OK** to save

### 3. Test the Setup

#### Manual Test
```bash
# Test VPN check script
sudo bash <stack-root>/scripts/check_vpn.sh

# Test monitoring script
sudo bash <stack-root>/scripts/wireguard_monitor.sh
```

#### Task Scheduler Test
1. Go to **Control Panel → Task Scheduler**
2. Select your **WireGuard VPN Monitor** task
3. Click **Run**
4. Check the **Action** column for status

### 4. Monitor Logs

View the logs to ensure everything is working:

```bash
# Real-time monitoring log
tail -f <stack-root>/logs/wireguard_monitor.log

# Task scheduler output
tail -f <stack-root>/logs/task_monitor.log

# Config update log
tail -f <stack-root>/logs/task_update.log
```

## Configuration Options

### Environment Variables

Key settings in `<stack-root>/.env`:

```bash
# Discord webhook for notifications (optional)
PULLIO_DISCORD_WEBHOOK=https://discord.com/api/webhooks/YOUR_WEBHOOK

# WireGuard settings (managed by update scripts)
WIREGUARD_ENDPOINT_IP="91.148.248.128"
WIREGUARD_ENDPOINT_PORT="51820"
WIREGUARD_PUBLIC_KEY="your_public_key"
WIREGUARD_PRIVATE_KEY="your_private_key"
WIREGUARD_ADDRESSES="100.64.1.115/32"
```

### Notification Settings

#### Discord Notifications
1. Create a Discord webhook in your server
2. Add the webhook URL to your `.env` file:
   ```bash
   PULLIO_DISCORD_WEBHOOK=https://discord.com/api/webhooks/YOUR_WEBHOOK_URL
   ```

#### DSM Notifications
1. Go to **Control Panel → Notification**
2. Configure your preferred notification methods
3. Notifications will be sent via `synodsmnotify` command

## Usage

### Manual VPN Status Check
```bash
# Quick colored status check
bash <stack-root>/scripts/check_vpn.sh
```

### Update WireGuard Configuration
When your VPN provider updates their config:

1. **Download** the new `.conf` file from your VPN provider
2. **Place** it in `<stack-root>/wireguard_configs/`
3. **Run** the interactive updater:
   ```bash
   sudo bash <stack-root>/scripts/parse_wireguard_conf.sh
   ```
4. **Review** the changes shown and confirm
5. **Done!** The script will backup, update, and restart automatically

### Automated Updates
The daily task will automatically check for new config files in the `wireguard_configs` folder and apply them if found.

## Troubleshooting

### Common Issues

#### Task Shows "Interrupted" Status
- **Cause**: Usually a permissions issue
- **Solution**: Ensure task runs as `root` user

#### Scripts Can't Access Docker
- **Cause**: Permission or path issues
- **Solution**: 
  ```bash
  # Test Docker access
  sudo docker ps
  
  # Check script permissions
  ls -la <stack-root>/scripts/
  
  # Fix permissions if needed
  sudo chmod +x <stack-root>/scripts/*.sh
  ```

#### No Notifications Received
- **Discord**: Verify webhook URL is correct in `.env`
- **DSM**: Check notification settings in Control Panel
- **Test**: Run monitoring script manually to see if notifications work

#### VPN Monitor Not Detecting Issues
1. **Check logs**:
   ```bash
   tail -n 50 <stack-root>/logs/wireguard_monitor.log
   ```

2. **Test manually**:
   ```bash
   sudo bash <stack-root>/scripts/check_vpn.sh
   ```

3. **Verify container status**:
   ```bash
   docker ps | grep gluetun
   docker logs gluetun --tail 20
   ```

### Log Locations

| Log File | Purpose |
|----------|---------|
| `<stack-root>/logs/wireguard_monitor.log` | Main monitoring activities |
| `<stack-root>/logs/wireguard_updates.log` | Configuration updates |
| `<stack-root>/logs/task_monitor.log` | Task scheduler output for monitoring |
| `<stack-root>/logs/task_update.log` | Task scheduler output for updates |

## Advanced Configuration

### Modify Monitoring Frequency

To change from every 30 minutes:

1. **Edit the task** in DSM Task Scheduler
2. **Change frequency** in Schedule tab
3. **Recommended**: Don't go below 15 minutes to avoid excessive checking

### Custom Notification Scripts

You can modify the notification functions in `wireguard_monitor.sh` to add:
- Email notifications
- Slack webhooks  
- Custom APIs
- SMS via services like Twilio

### Multiple VPN Locations

To monitor multiple WireGuard configs:
1. Duplicate the Gluetun container in docker-compose
2. Create separate monitoring scripts for each
3. Use different ports and container names

## Security Considerations

- ✅ Scripts never log private keys
- ✅ Config backups stored locally only
- ✅ Processed configs are archived, not deleted
- ✅ Webhook URLs should be kept private
- ⚠️ Ensure `.env` file is not world-readable

## Support

If you encounter issues:

1. **Check logs** first
2. **Test manually** with the check script
3. **Verify** your VPN provider config format
4. **Open an issue** on GitHub with logs (redact sensitive info)

## Next Steps

- Set up the monitoring and let it run for a few days
- Test the update process with a new config file
- Configure Discord notifications for alerts
- Consider implementing API automation if available for your VPN provider