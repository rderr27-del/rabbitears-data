# RabbitEars data

Weekly show data for the RabbitEars Android app, built from [TVMaze](https://www.tvmaze.com/) and published at
**https://rderr27-del.github.io/rabbitears-data/**.

| File | What it is |
|---|---|
| `manifest.json` | Version (build date) plus each file's size and SHA-256. The app checks this first. |
| `catalog.tsv.gz` | Every show on TVMaze, for search: id, name, year, network, status, popularity, rating, poster id |
| `discover.json` | Discover lists: trending (week / month / 3 months / year), top 50 of all time, top 10 by year |
| `discover-posters.zip` | Small posters for every show on a Discover list |

## How it's built

`.github/workflows/weekly-data.yml` runs every Monday at 09:00 UTC (or on demand from the Actions tab →
*Weekly data* → *Run workflow*):

1. `tools/build-catalog.ps1`: TVMaze's full show index → `catalog.tsv` (~6 min)
2. `tools/build-discover.ps1`: ranks the Discover lists and resizes their posters (~20 min)
3. `tools/build-feed.ps1`: compresses everything and writes `manifest.json`

The same scripts run on a Windows PC; output goes to `public/`.

The app checks `manifest.json` at most once a day, downloads only files whose checksum changed, and
keeps the copy bundled with the app as a fallback. The requests carry nothing about the user.

## License

Show data © TVMaze contributors, licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
The files published here are derived from it and shared under the same license.
