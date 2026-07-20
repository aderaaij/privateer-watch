#!/bin/bash
# qBittorrent "Run on torrent finished" hook. Arg 1 = category (%L).
#
# Audiobook grabs save straight into the ABS library, but ABS on ardencore
# watches it over NFS where inotify never fires for NAS-side writes
# (see docs/audiobooks.md). This pokes ABS's scan API immediately instead of
# waiting for the 30-min timer. Requires gluetun FIREWALL_OUTBOUND_SUBNETS
# to include 192.168.1.0/24, or the request silently times out.

[ "${1:-}" = "audiobooks" ] || exit 0

ABS_URL="http://192.168.1.122:13378"
LIBRARY_ID="c97c4fb0-816d-4fff-8dfe-d491188d1857"  # "Audiobooks"
TOKEN="$(tr -d ' \t\r\n' < /config/abs-token)"
LOG=/config/abs-scan-hook.log

sleep 5  # give qbit a moment to finish fsync/moving before ABS reads over NFS

if curl -fsS -m 30 -X POST -H "Authorization: Bearer $TOKEN" \
    "$ABS_URL/api/libraries/$LIBRARY_ID/scan" > /dev/null 2>> "$LOG"; then
  echo "$(date '+%F %T') scan triggered (torrent finished, category=$1)" >> "$LOG"
else
  echo "$(date '+%F %T') ERROR: scan trigger failed (category=$1)" >> "$LOG"
fi
