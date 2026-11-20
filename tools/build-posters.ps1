<#
  Copies the posters of popular shows from TVMaze's image server into the feed, so
  the RabbitEars app gets them from this site instead of asking TVMaze each time a
  show is added or a backup is restored. Run it after build-catalog.ps1, whose
  catalog.tsv it reads from the same output folder:

      powershell -ExecutionPolicy Bypass -File tools\build-posters.ps1

  Writes (to public/ unless -OutDir says otherwise):
    posters/<id>.jpg    TVMaze's medium poster (210x295), byte for byte, for every
                        show with popularity weight >= -MinWeight (~8,500 shows,
                        ~150 MB) plus every show in the Discover pools
    posters/index.tsv   id <TAB> TVMaze image path, so the next run re-downloads
                        only posters that are new or changed

  Less popular shows aren't covered; the app falls back to TVMaze for those.

  Incremental: posters already in the folder whose TVMaze image hasn't changed are
  kept, and posters of shows no longer covered are deleted. The weekly workflow
  keeps the folder between runs in the Actions cache. A first run (or a lost cache)
  downloads everything, which takes ~30-60 minutes.

  -Limit N downloads at most N posters (for trying the script out).
#>
param(
    [int]$MinWeight = 80,
    [int]$Limit = 0,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public')
)

$ErrorActionPreference = 'Stop'

$posterDir = Join-Path $OutDir 'posters'
$indexPath = Join-Path $posterDir 'index.tsv'
New-Item -ItemType Directory -Force $posterDir | Out-Null

# ── Which shows: popular ones, plus anything on a Discover list ───────────────
# catalog.tsv: id, name, year, network, status, weight, rating, image
$wanted = @{}
foreach ($line in [IO.File]::ReadLines((Join-Path $OutDir 'catalog.tsv'))) {
    $f = $line.Split("`t")
    if ($f.Count -lt 8 -or -not $f[7]) { continue }
    if ([int]$f[5] -ge $MinWeight) { $wanted[[int]$f[0]] = $f[7] }
}
$discoverPath = Join-Path $OutDir 'discover.json'
if (Test-Path $discoverPath) {
    $discover = [IO.File]::ReadAllText($discoverPath) | ConvertFrom-Json
    foreach ($p in $discover.shows.PSObject.Properties) {
        if ($p.Value.image) { $wanted[[int]$p.Name] = $p.Value.image }
    }
}

# ── What the last run saved ───────────────────────────────────────────────────
$have = @{}
if (Test-Path $indexPath) {
    foreach ($line in [IO.File]::ReadLines($indexPath)) {
        $f = $line.Split("`t")
        if ($f.Count -eq 2 -and (Test-Path (Join-Path $posterDir "$($f[0]).jpg"))) { $have[[int]$f[0]] = $f[1] }
    }
}

# Shows no longer covered: delete their posters so the site doesn't grow forever.
$removed = 0
foreach ($file in Get-ChildItem $posterDir -Filter *.jpg) {
    $id = [int]$file.BaseName
    if (-not $wanted.ContainsKey($id)) { Remove-Item $file.FullName; $have.Remove($id); $removed++ }
}

# ── Download new and changed posters ──────────────────────────────────────────
$todo = @($wanted.Keys | Where-Object { $have[$_] -ne $wanted[$_] } | Sort-Object)
if ($Limit -gt 0) { $todo = @($todo | Select-Object -First $Limit) }
Write-Host "posters: $($wanted.Count) covered, $($todo.Count) to download, $removed removed"

$client = New-Object Net.WebClient
$client.Headers['User-Agent'] = 'rabbitears-data weekly build'
$failed = 0
$done = 0
foreach ($id in $todo) {
    $dest = Join-Path $posterDir "$id.jpg"
    $part = "$dest.part"
    $url = "https://static.tvmaze.com/uploads/images/medium_portrait/$($wanted[$id]).jpg"
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $client.DownloadFile($url, $part)
            Move-Item -Force $part $dest
            $have[$id] = $wanted[$id]
            break
        } catch {
            if (Test-Path $part) { Remove-Item $part }
            $code = $_.Exception.InnerException.Response.StatusCode.value__
            if ($code -eq 429 -and $attempt -lt 4) { Start-Sleep -Seconds 10; continue }
            if ($code -ne 404) { Write-Host "poster failed for $id ($code)" }
            $failed++
            break
        }
    }
    $done++
    if ($done % 500 -eq 0) { Write-Host "  $done / $($todo.Count)" }
}

# Saved last, so an interrupted run only loses the list, not the posters: the next
# run simply downloads the unlisted ones again.
$lines = $have.Keys | Sort-Object | ForEach-Object { "$_`t$($have[$_])" }
[IO.File]::WriteAllLines($indexPath, [string[]]@($lines), (New-Object Text.UTF8Encoding $false))

$size = (Get-ChildItem $posterDir -Filter *.jpg | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Wrote posters: {0} files ({1:N0} MB), {2} failed" -f $have.Count, $size, $failed)
