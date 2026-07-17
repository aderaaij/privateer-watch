# Audiobooks

The audiobook library is **mixed-source** and mostly lives outside this repo.
The NAS only stores the files; everything that manages them runs on **ardencore**.

```
Audible ──> Libation ─┐
                      ├─> /volume1/data/media/audiobooks ──> Audiobookshelf
Prowlarr ──> qBittorrent ─┘        (on the NAS)                (on ardencore)
```

| Piece | Host | Notes |
|---|---|---|
| Libation (`rmcrackan/libation`) | ardencore | Audible purchases, de-DRM. Writes `Title [ASIN]/` + `.m4b`/`.jpg`/`.csv` |
| Audiobookshelf 2.35.1 | ardencore | Library "Audiobooks", `:13378`, runs as uid 1027 |
| qBittorrent | NAS | `audiobooks` category, saves to `/data/media/audiobooks` |
| Prowlarr | NAS | Search tab -> grab -> qBittorrent |

ardencore mounts the NAS over NFS: `192.168.1.3:/volume1/data` on
`/mnt/synology_data`. Both libation and audiobookshelf bind
`/mnt/synology_data/media/audiobooks`.

As of 2026-07-16: 111 folders / 112 ABS items / 62GB. Naming is deliberately
mixed and ABS copes with all of it — ~102 Libation `Title [ASIN]`, ~7 flat
scene-style (`Star Wars - 12 - 67 BBY - Darth Plagueis`), and a couple in
`Author/Title/` (`J.R.R. Tolkien/The Hobbit/`).

## The NFS + inotify gap (already handled — don't "fix" it)

ABS's file watcher uses inotify, which only reports changes made through the
*local* kernel's VFS. Libation runs on ardencore and writes *through* the NFS
client, so the watcher fires for it. qBittorrent writes on the NAS directly, so
ardencore's kernel never sees it and the watcher stays silent — even though ABS
can read the files fine (it runs as uid 1027, same as qBittorrent).

**This is already solved by external periodic scans**, which hit the ABS scan
API every 30 minutes (hence the `scan` API key in ABS, and the
`[LibraryController] Scan complete` lines in its log — not ABS's own scheduler).
Verified 2026-07-16: a grab at ~20:5x was in the library by the 21:00 scan.

That's why the library's `autoScanCronExpression` is `null` and
`disableWatcher` is `false`. **Both are correct — leave them alone.** ABS's
built-in scheduler isn't used here.

Reading its log: `0 Added | 0 Updated | 0 Missing` on every scan is the normal
steady state, not a failure. It means nothing new since the last scan.

## Grabbing a book

Books don't get "new releases", so there's no *arr here by design — nothing to
monitor. It's a search, not a subscription.

1. Prowlarr -> Search, query the title
2. Grab -> goes to qBittorrent's `audiobooks` category -> saves straight into
   `/data/media/audiobooks` (and seeds from there)
3. Wait for the scheduled ABS scan, then use ABS's **Match** to pull proper
   metadata/cover from Audible — this is why sloppy release naming doesn't matter

**Search without a category filter.** Category 3030 (Audio/Audiobook) returns
0 results because the configured public trackers don't tag properly; a bare
title query works. Audiobook coverage is currently poor — essentially just
LimeTorrents. **MyAnonaMouse** is available in Prowlarr's indexer list (private,
torrent, granular `Audiobooks - *` categories) and is the real fix; joining
requires passing an interview.

## Gotchas

- `/volume1/data/media/audiobooks` is `drwx------` owned by **UID 1027**. The
  SSH login user is 1026, so `ls`/`du`/`find` over plain SSH silently report
  empty. Always inspect via a container (`docker exec qbittorrent ls /data/media/audiobooks`).
  ABS and qBittorrent both run as 1027, so they're fine.
- Readarr was removed 2026-07-16 (retired upstream; couldn't auth with
  qBittorrent 5.2+, which returns HTTP 204 on login instead of 200 `Ok.`). It
  had downloaded nothing in its entire life. Old appdata is at
  `/volume1/docker/appdata/readarr/` (gitignored) pending deletion.
- qBittorrent seeds from inside the library directory. That's intentional —
  don't "clean up" `/data/media/audiobooks` expecting it to be torrent-free.
