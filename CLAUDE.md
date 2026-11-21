# CLAUDE.md

Guidance for Claude Code working in this repository. `README.md` lists every published file.

## What this is

The weekly data feed for the **RabbitEars** Android app (the app itself lives in the private repo `C:\Users\rderr\OneDrive\Documents\Claude\RabbitEars`, next to this folder; github.com/rderr27-del/rabbitears; read its CLAUDE.md for the app side). This repo is **public**, at github.com/rderr27-del/rabbitears-data, and is published by GitHub Pages at `https://rderr27-del.github.io/rabbitears-data/`. Never put anything private here: no keystore, nothing about users.

All data comes from TVMaze (CC BY-SA 4.0). The published files carry the same license, and the README and site say so.

## How it's built

`.github/workflows/weekly-data.yml` runs every Monday at 09:00 UTC, or by hand (`gh workflow run weekly-data.yml`). It runs on `windows-latest` with Windows PowerShell 5.1, because the poster resizing uses System.Drawing. The scripts, in order, each writing into `public/` (gitignored):

1. `tools/build-catalog.ps1`: TVMaze's full show index (~90,000 shows) → `catalog.tsv` and `catalog-meta.tsv`. Takes ~6 min.
2. `tools/build-discover.ps1`: ranks the Discover lists → `discover.json`, plus small resized posters in `discover/`. Takes ~20 min. `-ReuseTrending` re-ranks only the top and by-year lists.
3. `tools/build-posters.ps1`: TVMaze's medium posters, byte for byte, for every show with popularity weight ≥ 80 plus every Discover show (~8,500, ~150 MB) → `posters/<id>.jpg` and `posters/index.tsv`. It's incremental: the workflow keeps `public/posters` in the Actions cache (key `posters-<run id>`, newest restored), so only new or changed posters are downloaded. A first run, or a lost cache, takes about an hour. `-Limit N` caps downloads for trying it out.
4. `tools/build-feed.ps1`: gzips the catalog, zips the Discover posters, and writes `manifest.json` (a UTC build-time version plus each file's size and SHA-256) and `index.html`.

Then the workflow deletes the unpublished files, uploads `public/` as the Pages site, and commits `last-run.json`. That commit keeps GitHub from disabling the schedule after 60 quiet days.

## How the app uses it

- The app reads `manifest.json` at most once a day and downloads only files whose checksum changed. **Don't rename or reshape published files** without updating the app (`DataFeed.kt`, `Catalog.kt`, `Discover.kt`, `PosterSource.kt`): phones running older versions keep reading the old names.
- `posters/<id>.jpg` isn't in the manifest. The app requests a poster when a show is added and falls back to TVMaze on a 404.
- The app bundles a copy of the feed (its `tools/fetch-feed.ps1`) as a fallback for its first launch.

## Working here

- **Run `git pull --rebase` before pushing.** The workflow commits `last-run.json` every week, so the remote is usually ahead.
- The scripts also run on the owner's Windows PC (`powershell -ExecutionPolicy Bypass -File tools\<script>.ps1`), but that PC is slow. Prefer small trial runs, such as `build-posters.ps1 -Limit 5`, and let the workflow do full builds.
- TVMaze's API allows about 20 requests per 10 seconds and answers 429 beyond that. Scripts must pause and retry on 429, never hammer it.
- The owner isn't a developer. Explain changes in plain language and say what was and wasn't verified. Pushing here publishes, so confirm with them first.
