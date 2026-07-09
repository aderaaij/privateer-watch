# Space Saver — automatic replacement of oversized media

Set up 2026-07-06. Replaces remuxes and bloated files in Radarr/Sonarr with
same-resolution, tier-1 encodes (~20 GB for 4K movies, ~9 GB for 1080p movies,
~1.5 GB per 1080p TV episode). Estimated reclaim: ~8 TB.

## How it works

Radarr/Sonarr never downgrade across quality tiers. The trick is in the
quality profiles (declared in `recyclarr/recyclarr.yml`):

1. **Merged quality groups** — Remux/2160p qualities sit in the same quality
   group as encodes, so they compare by custom-format score instead of tier.
2. **Penalty custom formats** — "Remux Penalty" (−1000, both apps) and
   "2160p Penalty" (−10000, Sonarr WEB-1080p only) push existing bloated files
   far below any decent encode. Remux is a soft penalty so a remux stays
   grabbable as a last resort; 2160p is hard, below the −2000 floor. Created by
   `scripts/setup_space_saver_profiles.sh` (idempotent; re-run after a fresh
   recyclarr sync if profiles are ever recreated).
3. **TRaSH custom formats** (synced by the `recyclarr` container daily) make
   sure only proven release groups score positively — smaller never means junk.
   Gap worth knowing: TRaSH's "Dubs Only" regex needs a word boundary before
   `dub`, so it misses language-prefixed tags like `HebDub`. "Foreign Dub
   Penalty" (−10000, both apps) closes that. A bare `DUBBED` tag is still
   allowed on purpose — on anime that's the English dub.
4. **Scoutarr** batch-triggers the searches that make the *arrs re-evaluate
   each item. When a better-scoring smaller release is found it is downloaded,
   imported, and the old file is deleted (recycle bins are disabled).

## Profiles

| App | Profile | Who's on it |
|---|---|---|
| Radarr | UHD Bluray + WEB | movies staying 4K (encodes replace remuxes) |
| Radarr | HD Bluray + WEB | 1080p movies (incl. former 1080p remuxes) |
| Radarr | Ultra-HD (stock, no upgrades) | remux keepers — never touched |
| Sonarr | WEB-2160p | shows staying 4K |
| Sonarr | WEB-1080p | everything else; also demotes 4K files to 1080p |

## Scoutarr (web UI: `http://<nas-ip>:5839`)

Config lives in Scoutarr's own database (not a file). Four instances, each
filtered by quality profile name so keepers and untouched items are never
searched: Radarr UHD (3/run), Radarr HD (3/run), Sonarr 4K (1/run),
Sonarr 1080p (2/run). Scheduler: every 6 hours, unattended.

- Processed items get the `scoutarr` tag (won't be searched again).
- To exclude an item manually, give it the `scoutarr-skip` tag in Radarr/Sonarr.
- Manual ops: `POST :5839/api/sync/all` (refresh library DB),
  `POST :5839/api/search/run` (run a batch now).
- To pause the sweep: disable the scheduler in the Scoutarr UI settings.

## Notes & gotchas

- Scoutarr needs its **library sync** before searches find anything
  (runs nightly at 03:00; trigger manually after big library changes).
- The bind-mount dir `${DOCKERCONFDIR}/scoutarr` must exist before the
  container starts (Synology doesn't auto-create mount sources).
- `recyclarr/recyclarr.yml` reads API keys from container env vars
  (`RADARR_API_KEY` / `SONARR_API_KEY`, wired to `MCP_*` values in `.env`).
- Known churn: an item whose current release is from an unranked group may be
  re-downloaded at a similar size to reach a ranked group. Bounded, harmless.
- Sizes in Radarr/Sonarr quality definitions are TRaSH values (MB/min caps).
