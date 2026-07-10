# WireGuard VPN Automation Features

> **`<stack-root>`** in this document = the directory where this repository lives on your machine (your `DOCKERCONFDIR`).

## Overview

The Privateer Watch system now includes full automation capabilities for VPN management, eliminating the need for manual server configuration updates. The system can automatically authenticate with Privado VPN, select optimal servers, and maintain connectivity without user intervention.

## ✨ New Features

### 🤖 Fully Automated Server Management
- **Automatic Authentication**: Connects to Privado API using credentials from `.env`
- **Smart Server Selection**: Chooses best servers based on latency and load
- **Performance Monitoring**: Tests server performance before switching
- **Automatic Failover**: Switches servers when current one fails

### 🔄 Intelligent Recovery System
- **Multi-Level Recovery**: Tries restart → server switch → manual intervention
- **Rate Limiting**: Prevents excessive restart attempts
- **Smart Retry Logic**: Uses escalating recovery strategies
- **Performance Thresholds**: Only switches if server meets quality standards

### 📅 Scheduled Server Rotation
- **Privacy Enhancement**: Automatically rotates servers for better privacy
- **Configurable Intervals**: Set rotation frequency (default: 24 hours)
- **Location Preferences**: Stick to preferred countries/cities
- **Load Balancing**: Distributes usage across servers

## 🛠️ Configuration

### Environment Variables

Add these settings to your `.env` file:

```bash
## WireGuard Automation Settings
# Server preferences for automatic selection (comma-separated)
WIREGUARD_PREFERRED_COUNTRIES="NL,DE,UK,FR"
WIREGUARD_PREFERRED_CITIES="Amsterdam,Berlin,London,Paris"

# Automatic rotation settings
WIREGUARD_AUTO_ROTATION="true"
WIREGUARD_ROTATION_INTERVAL="24"  # Hours between automatic rotations

# Auto-recovery settings
WIREGUARD_AUTO_RECOVERY="true"
WIREGUARD_MAX_RESTART_ATTEMPTS="3"  # Max restarts per day before switching servers
WIREGUARD_AUTO_SERVER_SWITCH="true"  # Enable automatic server switching on failure

# Performance thresholds
WIREGUARD_MAX_LATENCY="150"  # Maximum acceptable latency in milliseconds
WIREGUARD_MIN_SPEED="50"     # Minimum acceptable speed in Mbps (future use)
```

### Server Preferences

**Countries**: Use 2-letter country codes (NL, DE, UK, FR, US, etc.)
**Cities**: Use full city names (Amsterdam, Berlin, London, Paris, etc.)

The system will prefer servers from these locations when selecting automatically.

## 📋 New Scripts

### 1. Auto Update Script (`auto_update_wireguard.sh`)

**Main automation script** - Handles all automatic VPN configuration updates.

```bash
# Automatic update (only if scheduled)
<stack-root>/scripts/auto_update_wireguard.sh

# Force immediate rotation to best available server
<stack-root>/scripts/auto_update_wireguard.sh force

# Switch to specific location
<stack-root>/scripts/auto_update_wireguard.sh NL
<stack-root>/scripts/auto_update_wireguard.sh Amsterdam
```

**Features:**
- Smart server selection based on performance
- Automatic configuration backup
- Container restart and verification
- Discord/DSM notifications
- Comprehensive logging

### 2. Privado API CLI (`scripts/privado-api/privado-wg`)

The Privado API client is a standalone project,
[privado-wg](https://github.com/aderaaij/privado-wg), vendored as a single
file. `auto_update_wireguard.sh` calls it for authentication, server lists,
and WireGuard provisioning. It can also be driven manually — it reads the
Privado credentials from the environment:

```bash
# Load credentials, then e.g.:
sudo bash -c 'set -a; . <stack-root>/.env; set +a; \
  <stack-root>/scripts/privado-api/privado-wg servers'

# Other commands: login [--force], config <location> [--format conf|gluetun-env|json]
```

### 3. Enhanced Monitor Script (`wireguard_monitor.sh`)

**Enhanced monitoring** with automatic recovery capabilities:

- **Multi-Level Recovery**: Restart → Server Switch → Alert
- **Rate Limiting**: Prevents restart loops
- **Performance Tracking**: Monitors server quality
- **Automatic Failover**: Switches to better servers

## 🔄 Automation Workflows

### 1. Scheduled Rotation

```
Every 24 hours (configurable):
├── Check if rotation is due
├── Authenticate with Privado API
├── Get server list and test performance
├── Select best server from preferred locations
├── Generate new WireGuard configuration
├── Update .env file and restart container
└── Verify connectivity and send notifications
```

### 2. Failure Recovery

```
On VPN failure:
├── Attempt 1-3: Container restart (rate limited)
├── Attempt 4+: Automatic server switch
├── Success: Reset counters and notify
└── Failure: Manual intervention alert
```

### 3. Performance Monitoring

```
Server Selection Criteria:
├── Latency < 150ms (configurable)
├── Server load factor
├── Preferred location match
├── Performance score calculation
└── Fallback to any working server
```

## 📊 Monitoring and Logging

### Log Files

- **Main Automation**: `<stack-root>/logs/auto_wireguard.log`
- **VPN Monitoring**: `<stack-root>/logs/wireguard_monitor.log`
- **System Status**: `<stack-root>/gluetun/vpn_status.txt`

### Status Tracking

- **Restart Attempts**: Tracked per day to prevent loops
- **Last Rotation**: Timestamp for scheduled rotations
- **Server Performance**: Latency and load metrics
- **Recovery State**: Current automation status

### Notifications

**Discord Notifications** (if webhook configured):
- ✅ Successful server switches
- 🔄 Automatic rotations
- ⚠️ VPN failures and recovery attempts
- 🚨 Manual intervention required

**Synology DSM Notifications**:
- Native system notifications
- VPN status changes
- Recovery success/failure alerts

## 🎛️ DSM Task Scheduler Setup

### 1. VPN Monitoring (Every 30 minutes)

```bash
Task: VPN Monitor with Auto-Recovery
Script: <stack-root>/scripts/wireguard_monitor.sh
Schedule: Every 30 minutes
User: root
```

### 2. Automatic Rotation (Daily)

```bash
Task: Automatic VPN Rotation
Script: <stack-root>/scripts/auto_update_wireguard.sh auto
Schedule: Daily at 3:00 AM
User: root
```

### 3. Manual Server Check (Optional)

```bash
Task: Force Server Check
Script: <stack-root>/scripts/auto_update_wireguard.sh force
Schedule: Manual trigger
User: root
```

## 🚀 Getting Started

### 1. Test the System

```bash
# Run the test suite
sudo <stack-root>/scripts/test_automation.sh

# Test manual server switch
sudo <stack-root>/scripts/auto_update_wireguard.sh force

# Check current VPN status
sudo <stack-root>/scripts/check_vpn.sh
```

### 2. Enable Automation

Add automation settings to your `.env` file and restart the monitoring tasks in DSM Task Scheduler.

### 3. Monitor Activity

```bash
# Watch automation logs
tail -f <stack-root>/logs/auto_wireguard.log

# Monitor VPN status
tail -f <stack-root>/logs/wireguard_monitor.log

# Check current status
cat <stack-root>/gluetun/vpn_status.txt
```

## 🔧 Troubleshooting

### Common Issues

**Authentication Fails**
- Check PRIVADO_USERNAME and PRIVADO_PASSWORD in .env
- Verify Privado account is active
- Test login manually: `sudo bash -c 'set -a; . <stack-root>/.env; set +a; <stack-root>/scripts/privado-api/privado-wg login --force'`

**No Servers Found**
- Check internet connectivity
- Verify Privado API is accessible
- Test server list: `sudo bash -c 'set -a; . <stack-root>/.env; set +a; <stack-root>/scripts/privado-api/privado-wg servers --refresh'`

**Automation Not Running**
- Check DSM Task Scheduler tasks are enabled
- Verify script permissions: `chmod +x <stack-root>/scripts/*.sh`
- Review logs for error messages

**Performance Issues**
- Adjust WIREGUARD_MAX_LATENCY threshold
- Modify preferred countries/cities list
- Check server load during peak hours

### Log Analysis

```bash
# Check for errors
grep "ERROR" <stack-root>/logs/auto_wireguard.log

# Monitor server switches
grep "switched" <stack-root>/logs/auto_wireguard.log

# Track performance metrics
grep "latency" <stack-root>/logs/auto_wireguard.log
```

## 🎯 Benefits

### Before Automation
- ❌ Manual config downloads from Privado website
- ❌ Manual server selection and testing
- ❌ Multi-day outages when servers change
- ❌ No automatic recovery from failures

### After Automation
- ✅ **Zero Manual Intervention**: Fully automated server management
- ✅ **Proactive Rotation**: Regular server changes for privacy
- ✅ **Intelligent Recovery**: Multi-level failure handling
- ✅ **Performance Optimization**: Always uses best available servers
- ✅ **Comprehensive Monitoring**: Real-time status and notifications

## 🔮 Future Enhancements

- **Speed Testing**: Automatic bandwidth testing for server selection
- **Geo-Location Routing**: Different servers for different services
- **Usage Analytics**: Historical performance and usage metrics
- **API Rate Limiting**: Intelligent API usage to prevent blocking
- **Multi-Provider Support**: Support for additional VPN providers

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Privateer Watch                         │
├─────────────────────────────────────────────────────────────┤
│  DSM Task Scheduler                                         │
│  ├── Monitor (30 min) → wireguard_monitor.sh              │
│  └── Rotation (daily) → auto_update_wireguard.sh          │
├─────────────────────────────────────────────────────────────┤
│  Automation Scripts                                        │
│  ├── auto_update_wireguard.sh (main automation)           │
│  ├── wireguard_monitor.sh (enhanced monitoring)           │
│  └── privado-api/ (API integration)                       │
│      └── privado-wg (vendored CLI)                        │
├─────────────────────────────────────────────────────────────┤
│  Data & Configuration                                      │
│  ├── .env (credentials & preferences)                     │
│  ├── logs/ (automation & monitoring logs)                 │
│  └── backups/ (automatic config backups)                  │
├─────────────────────────────────────────────────────────────┤
│  External Services                                         │
│  ├── Privado VPN API (server list & configs)             │
│  ├── Discord Webhook (notifications)                      │
│  └── Synology DSM (native notifications)                  │
└─────────────────────────────────────────────────────────────┘
```

The system is now **completely autonomous** and will maintain optimal VPN connectivity without any manual intervention!