<#
  Builds RabbitEars' Discover data from TVMaze (https://www.tvmaze.com/api,
  CC BY-SA 4.0). Run it after build-catalog.ps1, whose catalog.tsv and
  catalog-meta.tsv it reads from the same output folder:

      powershell -ExecutionPolicy Bypass -File tools\build-discover.ps1

  Writes (to public/ unless -OutDir says otherwise):
    discover.json        the lists (show ids + display info)
    discover/<id>.jpg    a small poster for every show on a default (unfiltered) list

  How the lists are made (also explained on the app's Info page):
    Top 50 of all time  Highest TVMaze rating among widely followed shows
                        (popularity weight >= 97), so a high score from a handful
                        of votes can't sneak in.
    Top 10 by year      Same, per premiere year, among shows with weight >= 90
                        (>= 97 for this year and last, where brand-new shows can
                        carry a high rating from only a few votes).
    Trending            TVMaze has no viewing counts, so "trending" means the most
                        popular shows that released new episodes in that window
                        (US TV schedule + worldwide streaming schedule), ranked by
                        popularity weight, then rating.
  News, talk, sports and award shows are left out of every list.

  Besides each default list, discover.json carries the full ranked "pool" behind
  it (topPool, yearPools, trendingPools) plus every pooled show's categories and
  network, so the app can filter by category and streaming service on the phone.
  The default lists (top, byYear, trending) are kept for older app versions.

  Trending history (history/last-aired.tsv, committed to the repo): for every show
  that aired in the last -Days days, the latest date it released an episode, plus
  the date the history covers up to and the date of its last full scan. Instead of
  re-reading a whole year of schedules every week (~730 requests), a run reads only
  the days since the history's date, plus the last -Overlap days again because
  TVMaze sometimes adds episodes to past dates late (~20 requests a week). Every
  -FullScanEvery days, or whenever the history is missing or doesn't look right, it
  does a full scan instead and starts the history afresh, so a mistake can't carry
  on for more than a few weeks. -FullScan forces one.

  Takes ~10-20 minutes with a full scan, a few minutes otherwise (TVMaze allows ~20
  requests per 10 s). To re-rank only the top and by-year lists, keeping the
  trending pools (and their date) from the current discover.json, add
  -ReuseTrending (~1 minute).

  Discover thumbnails are made from the full-size posters build-posters.ps1 keeps in
  posters/ (restored from the Actions cache) when they're there and current, and
  downloaded from TVMaze otherwise.

  -AsOf yyyy-MM-dd pretends today is that date (UTC), for testing the history.
#>
param(
    [int]$Days = 365,          # schedule history to scan for trending
    [int]$FirstYear = 1950,
    [switch]$ReuseTrending,
    [switch]$FullScan,
    [int]$Overlap = 14,        # days already in the history to read again
    [int]$FullScanEvery = 28,  # days between full scans
    [int]$MinHistory = 1000,   # fewer shows than this in the history means something went wrong
    [string]$AsOf = '',
    [string]$HistoryPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'history\last-aired.tsv'),
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$posterDir = Join-Path $OutDir 'discover'
$jsonPath = Join-Path $OutDir 'discover.json'
$excludedTypes = @('News', 'Talk Show', 'Sports', 'Award Show')
# Show types offered as categories alongside TVMaze's genres.
$typeCategories = @('Animation', 'Documentary', 'Reality')
$trendingPoolSize = 300

function Get-Json([string]$url) {
    while ($true) {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing $url
            Start-Sleep -Milliseconds 550
            return [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -eq 429) { Start-Sleep -Seconds 5; continue }
            if ($code -eq 404) { return $null }
            throw
        }
    }
}

# ── Catalog + meta ────────────────────────────────────────────────────────
$catalog = @{}
foreach ($line in [IO.File]::ReadAllLines((Join-Path $OutDir 'catalog.tsv'), [Text.Encoding]::UTF8)) {
    $f = $line -split "`t"
    $catalog[[int]$f[0]] = [pscustomobject]@{
        id = [int]$f[0]; name = $f[1]; year = $f[2]; network = $f[3]; status = $f[4]
        weight = [int]$f[5]; rating = if ($f.Count -gt 6 -and $f[6]) { [double]$f[6] } else { $null }
        image = if ($f.Count -gt 7) { $f[7] } else { '' }
        type = ''; cats = @()
    }
}
foreach ($line in [IO.File]::ReadAllLines((Join-Path $OutDir 'catalog-meta.tsv'), [Text.Encoding]::UTF8)) {
    $f = $line -split "`t"
    $c = $catalog[[int]$f[0]]
    if (-not $c) { continue }
    $c.type = $f[1]
    $genres = if ($f.Count -gt 2 -and $f[2]) { $f[2] -split '\|' } else { @() }
    $c.cats = @($genres) + @($typeCategories | Where-Object { $_ -eq $c.type })
}
Write-Host "catalog: $($catalog.Count) shows"

$listable = $catalog.Values | Where-Object { $excludedTypes -notcontains $_.type }
$rated = $listable | Where-Object { $null -ne $_.rating }

function Rank-ByRating($shows, [int]$take) {
    return , @($shows | Sort-Object @{ e = 'rating'; Descending = $true }, @{ e = 'weight'; Descending = $true }, name |
        Select-Object -First $take | ForEach-Object { $_.id })
}

# ── Top of all time ───────────────────────────────────────────────────────
# Deep enough that a filtered list (one category on one service) still finds 50.
$topPool = Rank-ByRating ($rated | Where-Object { $_.weight -ge 97 }) 1500
Write-Host "top pool: $($topPool.Count)"

# ── Top by premiere year ──────────────────────────────────────────────────
$thisYear = (Get-Date).Year
$yearPools = [ordered]@{}
for ($y = $thisYear; $y -ge $FirstYear; $y--) {
    # Brand-new shows can carry a high rating from few votes, so the two most recent
    # years need the same popularity bar as the all-time list.
    $cutoff = if ($y -ge $thisYear - 1) { 97 } else { 90 }
    $ids = Rank-ByRating ($rated | Where-Object { $_.year -eq "$y" -and $_.weight -ge $cutoff }) 150
    if ($ids.Count -gt 0) { $yearPools["$y"] = $ids }
}
Write-Host "years: $($yearPools.Count), pooled shows: $(($yearPools.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum)"

# ── Trending: scan the schedules ──────────────────────────────────────────
# UTC, like the GitHub runner, so dates agree wherever this runs.
$today = if ($AsOf) { [datetime]::ParseExact($AsOf, 'yyyy-MM-dd', $null) } else { (Get-Date).ToUniversalTime().Date }
$previous = if ($ReuseTrending) { [IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } else { $null }
$trendingPools = [ordered]@{}
$historyLines = $null   # set when the history changes; written once discover.json is
if ($previous -and $previous.trendingPools) {
    foreach ($w in 'week', 'month', 'quarter', 'year') { $trendingPools[$w] = @($previous.trendingPools.$w) }
    $today = [datetime]::ParseExact($previous.updated, 'yyyy-MM-dd', $null)   # trending is still as of then
    Write-Host "reusing trending pools from $($previous.updated)"
} else {
    # For each show, the latest date (UTC) it released an episode. Kept between runs
    # in the history file, so a run only reads the days the history doesn't cover yet.
    $lastAired = @{}
    $covered = $null; $lastFull = $null
    $why = $null   # why this run does a full scan
    if ($FullScan) { $why = 'asked for (-FullScan)' }
    elseif (-not (Test-Path $HistoryPath)) { $why = 'no history yet' }
    else {
        try {
            foreach ($line in [IO.File]::ReadAllLines($HistoryPath)) {
                if (-not $line -or $line.StartsWith('#')) { continue }
                $f = $line -split "`t"
                if ($f.Count -ne 2) { throw "bad line: $line" }
                $date = [datetime]::ParseExact($f[1], 'yyyy-MM-dd', $null)
                switch ($f[0]) {
                    'covered'  { $covered = $date }
                    'fullscan' { $lastFull = $date }
                    default    { $lastAired[[int]$f[0]] = $date }
                }
            }
            if (-not $covered -or -not $lastFull) { $why = 'history has no dates' }
            elseif ($lastAired.Count -lt $MinHistory) { $why = "history has only $($lastAired.Count) shows" }
            elseif ($covered -gt $today -or $lastFull -gt $covered) { $why = 'history dates are in the future' }
            elseif ($covered -le $today.AddDays(-$Days)) { $why = "history is too old ($($covered.ToString('yyyy-MM-dd')))" }
            elseif (($today - $lastFull).Days -ge $FullScanEvery) { $why = "last full scan was $($lastFull.ToString('yyyy-MM-dd'))" }
        } catch {
            $why = "history unreadable ($($_.Exception.Message))"
        }
    }
    if ($why) {
        Write-Host "trending: full scan of $Days days ($why)"
        $lastAired = @{}
        $lastFull = $today
        $start = $today.AddDays( - ($Days - 1))
    } else {
        $start = $covered.AddDays(1 - $Overlap)
        Write-Host ("trending: history covers to {0} ({1} shows, full scan {2}); reading {3} days" -f
            $covered.ToString('yyyy-MM-dd'), $lastAired.Count, $lastFull.ToString('yyyy-MM-dd'), (($today - $start).Days + 1))
    }

    $seen = 0
    for ($day = $start; $day -le $today; $day = $day.AddDays(1)) {
        $date = $day.ToString('yyyy-MM-dd')
        $ids = @()
        $us = Get-Json "https://api.tvmaze.com/schedule?country=US&date=$date"
        if ($us) { $ids += $us | ForEach-Object { $_.show.id } }
        $web = Get-Json "https://api.tvmaze.com/schedule/web?date=$date"
        if ($web) { $ids += $web | ForEach-Object { $_._embedded.show.id } }
        foreach ($id in $ids) {
            if ($null -eq $id) { continue }
            $id = [int]$id
            $seen++
            if (-not $lastAired.ContainsKey($id) -or $lastAired[$id] -lt $day) { $lastAired[$id] = $day }
        }
        if ($day.Day -eq 1) { Write-Host "schedule $date : $($lastAired.Count) shows so far" }
    }
    # Every day has something on, so nothing at all means TVMaze answered with empty
    # schedules. Stop here rather than save a history (and lists) built on that.
    if ($seen -eq 0) { throw 'TVMaze schedules came back empty' }

    # Forget shows that haven't aired within the window, then work in days ago.
    $oldest = $today.AddDays( - ($Days - 1))
    foreach ($id in @($lastAired.Keys)) { if ($lastAired[$id] -lt $oldest) { $lastAired.Remove($id) } }
    $daysAgo = @{}
    foreach ($id in $lastAired.Keys) { $daysAgo[$id] = ($today - $lastAired[$id]).Days }
    Write-Host "trending: $($lastAired.Count) shows aired in the last $Days days"

    $historyLines = New-Object System.Collections.Generic.List[string]
    $historyLines.Add('# Trending history for build-discover.ps1: show id <TAB> latest date it aired (UTC).')
    $historyLines.Add("covered`t$($today.ToString('yyyy-MM-dd'))")
    $historyLines.Add("fullscan`t$($lastFull.ToString('yyyy-MM-dd'))")
    foreach ($id in ($lastAired.Keys | Sort-Object)) { $historyLines.Add("$id`t$($lastAired[$id].ToString('yyyy-MM-dd'))") }

    $airedShows = $lastAired.Keys | Where-Object { $catalog.ContainsKey($_) } | ForEach-Object { $catalog[$_] } |
        Where-Object { $excludedTypes -notcontains $_.type }
    foreach ($w in @(@('week', 7), @('month', 30), @('quarter', 91), @('year', 365))) {
        $trendingPools[$w[0]] = @($airedShows | Where-Object { $daysAgo[$_.id] -lt $w[1] } |
            Sort-Object @{ e = 'weight'; Descending = $true },
                @{ e = { if ($null -eq $_.rating) { -1 } else { $_.rating } }; Descending = $true }, name |
            Select-Object -First $trendingPoolSize | ForEach-Object { $_.id })
    }
}

# ── Default lists (what older app versions show) ──────────────────────────
$top = @($topPool | Select-Object -First 50)
$byYear = [ordered]@{}
foreach ($y in $yearPools.Keys) { $byYear[$y] = @($yearPools[$y] | Select-Object -First 10) }
$trending = [ordered]@{}
foreach ($w in $trendingPools.Keys) { $trending[$w] = @($trendingPools[$w] | Select-Object -First 20) }

# ── Categories: genres common among the top shows, most common first ──────
$catCounts = @{}
foreach ($id in $topPool) { foreach ($cat in $catalog[$id].cats) { $catCounts[$cat] = 1 + [int]$catCounts[$cat] } }
$categories = @($catCounts.Keys | Where-Object { $catCounts[$_] -ge 15 } | Sort-Object { -$catCounts[$_] }, { $_ })
Write-Host "categories: $($categories -join ', ')"

# ── Show info for every pooled show; posters for the default lists ─────────
$pooled = @($topPool) + @($yearPools.Values | ForEach-Object { $_ }) + @($trendingPools.Values | ForEach-Object { $_ }) | Sort-Object -Unique
$shows = [ordered]@{}
foreach ($id in $pooled) {
    $c = $catalog[$id]
    $shows["$id"] = [ordered]@{
        name = $c.name; year = $c.year; network = $c.network; status = $c.status; rating = $c.rating
        cats = @($c.cats); image = $c.image
    }
}

$withPosters = @($top) + @($byYear.Values | ForEach-Object { $_ }) + @($trending.Values | ForEach-Object { $_ }) | Sort-Object -Unique
New-Item -ItemType Directory -Force $posterDir | Out-Null
# Keep posters still in use (they rarely change); drop ones for shows no longer listed.
Get-ChildItem $posterDir -Filter *.jpg | Where-Object { $withPosters -notcontains [int]$_.BaseName } | Remove-Item
$jpeg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$quality = New-Object Drawing.Imaging.EncoderParameters 1
$quality.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), 72L
# Full-size posters build-posters.ps1 kept from earlier runs (id <TAB> TVMaze image
# path), so thumbnails can be made from them instead of asking TVMaze again.
$fullPosters = @{}
$fullIndex = Join-Path $OutDir 'posters\index.tsv'
if (Test-Path $fullIndex) {
    foreach ($line in [IO.File]::ReadLines($fullIndex)) {
        $f = $line.Split("`t")
        if ($f.Count -eq 2) { $fullPosters[[int]$f[0]] = $f[1] }
    }
}
$fromCache = 0; $fromTvMaze = 0
foreach ($id in $withPosters) {
    $dest = Join-Path $posterDir "$id.jpg"
    $image = $catalog[$id].image
    if ((Test-Path $dest) -or -not $image) { continue }
    try {
        $cached = Join-Path $OutDir "posters\$id.jpg"
        if ($fullPosters[$id] -eq $image -and (Test-Path $cached)) {
            $bytes = [IO.File]::ReadAllBytes($cached)
            $fromCache++
        } else {
            $bytes = (Invoke-WebRequest -UseBasicParsing "https://static.tvmaze.com/uploads/images/medium_portrait/$image.jpg").RawContentStream.ToArray()
            $fromTvMaze++
        }
        $src = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $bytes)))
        $thumb = New-Object Drawing.Bitmap 120, 168
        $g = [Drawing.Graphics]::FromImage($thumb)
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, 120, 168)
        $thumb.Save($dest, $jpeg, $quality)
        $g.Dispose(); $thumb.Dispose(); $src.Dispose()
    } catch {
        Write-Host "poster failed for $id ($($catalog[$id].name))"
    }
}

$out = [ordered]@{
    updated       = $today.ToString('yyyy-MM-dd')
    categories    = $categories
    top           = $top
    byYear        = $byYear
    trending      = $trending
    topPool       = $topPool
    yearPools     = $yearPools
    trendingPools = $trendingPools
    shows         = $shows
}
[IO.File]::WriteAllText($jsonPath, ($out | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding $false))
Write-Host "discover thumbnails: $fromCache from cached posters, $fromTvMaze from TVMaze"

# The history is saved only now, after discover.json, so a run that fails part-way
# leaves the old history in place. Temp file + rename, so it's never half-written.
if ($historyLines) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $HistoryPath) | Out-Null
    $temp = "$HistoryPath.tmp"
    [IO.File]::WriteAllLines($temp, [string[]]$historyLines.ToArray(), (New-Object Text.UTF8Encoding $false))
    Move-Item -Force $temp $HistoryPath
    Write-Host "wrote trending history: $($historyLines.Count - 3) shows"
}
$size = (Get-ChildItem $posterDir | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Wrote discover.json: {0} shows ({1:N0} KB), posters {2:N1} MB" -f $shows.Count, ((Get-Item $jsonPath).Length / 1KB), $size)
