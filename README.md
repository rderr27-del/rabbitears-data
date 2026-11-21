# RabbitEars data

Weekly show data for the RabbitEars Android app, built from [TVMaze](https://www.tvmaze.com/) and published at
**https://rderr27-del.github.io/rabbitears-data/**.

| File | What it is |
|---|---|
| `manifest.json` | Version (build date) plus each file's size and SHA-256. The app checks this first. |
| `catalog.tsv.gz` | Every show on TVMaze, for search: id, name, year, network, status, popularity, rating, poster id |
| `discover.json` | Discover lists: trending (week / month / 3 months / year), top 50 of all time, top 10 by year |
| `discover-posters.zip` | Small posters for every show on a Discover list |
| `posters/<id>.jpg` | TVMaze's poster for every popular show (weight ≥ 80, ~8,500 shows) and every Discover show, fetched by the app when a show is added. Not listed in the manifest. |

## How it's built

`.github/workflows/weekly-data.yml` runs every Monday at 09:00 UTC (or on demand from the Actions tab →
*Weekly data* → *Run workflow*):

1. `tools/build-catalog.ps1`: TVMaze's full show index → `catalog.tsv` (~6 min)
2. `tools/build-discover.ps1`: ranks the Discover lists and resizes their posters. For trending it reads only the TV schedule days it hasn't seen yet, remembering earlier ones in `history/last-aired.tsv` (committed each week), with a full one-year rescan every 4 weeks (a few minutes; ~20 min with a full rescan)
3. `tools/build-posters.ps1`: copies new or changed posters of popular shows (kept between runs in the Actions cache; a full download takes ~30–60 min)
4. `tools/build-feed.ps1`: compresses everything and writes `manifest.json`

`.github/workflows/cache-keepalive.yml` opens the poster cache every Thursday, so GitHub's 7-day cache expiry can't delete it between weekly runs.

The same scripts run on a Windows PC; output goes to `public/`.

The app checks `manifest.json` at most once a day, downloads only files whose checksum changed, and
keeps the copy bundled with the app as a fallback. The requests carry nothing about the user.

## License

Show data © TVMaze contributors, licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
The files published here are derived from it and shared under the same license.
