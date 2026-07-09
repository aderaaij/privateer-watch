# Discord Webhook Setup for Docker Notifications

> **`<stack-root>`** in this document = the directory where this repository lives on your machine (your `DOCKERCONFDIR`).

## Quick Setup Guide

### Step 1: Create Discord Webhook

1. **Open Discord** and go to your server
2. **Right-click on a channel** where you want notifications
3. **Select "Edit Channel"**
4. **Go to "Integrations" tab**
5. **Click "Create Webhook"**
6. **Name it** (e.g., "Docker Updates")
7. **Copy the Webhook URL** (looks like: `https://discord.com/api/webhooks/123456789/abcdef...`)

### Step 2: Add to Environment File

Edit `<stack-root>/.env`:

```bash
# Find this line and add your webhook URL:
PULLIO_DISCORD_WEBHOOK=https://discord.com/api/webhooks/YOUR_WEBHOOK_URL_HERE
```

### Step 3: Apply Changes

```bash
cd <stack-root>
docker-compose down && docker-compose up -d
```

## What You'll Receive

### Pullio Update Notifications
- 📦 Container update started
- ✅ Update completed successfully
- ❌ Update failed with errors
- 📊 Summary of updated containers

### WireGuard VPN Notifications
- 🔴 VPN connection down
- 🟢 VPN connection restored
- 🔄 VPN container restarted
- ⚙️ Configuration updated

## Testing

### Test Pullio Notifications
```bash
# Run update script manually
sudo bash <stack-root>/scripts/pullio_with_recovery.sh
```

### Test VPN Notifications
```bash
# Run VPN monitor manually
sudo bash <stack-root>/scripts/wireguard_monitor.sh
```

## Webhook Security

⚠️ **Important**: Keep your webhook URL private
- Don't share in public repos
- Don't post in public channels
- Regenerate if compromised

## Troubleshooting

### No Messages Received
1. **Check webhook URL** - make sure it's complete and correct
2. **Test webhook** with curl:
   ```bash
   curl -H "Content-Type: application/json" \
        -d '{"content":"Test message"}' \
        YOUR_WEBHOOK_URL
   ```
3. **Check Discord permissions** - webhook needs "Send Messages" permission
4. **Verify channel** - make sure the channel still exists

### Messages Going to Wrong Channel
- Webhook is tied to specific channel
- Create new webhook for different channel
- Update .env with new webhook URL

## Message Examples

### Successful Update
```
📦 Pullio Update: Container updates completed. 3 containers were updated.
```

### VPN Alert
```
🔴 VPN Alert: Gluetun container is unhealthy - VPN connection may be down
```

### Configuration Update
```
⚙️ WireGuard: Configuration updated to Amsterdam, NL (91.148.248.128)
```