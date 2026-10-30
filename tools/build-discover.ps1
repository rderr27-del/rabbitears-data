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

  Takes ~10 minutes (TVMaze allows ~20 requests per 10 s). To re-rank only the top
  and by-year lists, keeping the trending pools (and their date) from the current
  discover.json, add -ReuseTrending (~1 minute).
#>
param(
    [int]$Days = 365,          # schedule history to scan for trending
    [int]$FirstYear = 1950,
    [switch]$ReuseTrending,
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
$today = (Get-Date).ToUniversalTime().Date   # UTC, like the GitHub runner, so dates agree wherever this runs
$previous = if ($ReuseTrending) { [IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } else { $null }
$trendingPools = [ordered]@{}
if ($previous -and $previous.trendingPools) {
    foreach ($w in 'week', 'month', 'quarter', 'year') { $trendingPools[$w] = @($previous.trendingPools.$w) }
    $today = [datetime]::ParseExact($previous.updated, 'yyyy-MM-dd', $null)   # trending is still as of then
    Write-Host "reusing trending pools from $($previous.updated)"
} else {
    # For each show, the most recent day (as days ago) it released an episode.
    $lastAired = @{}
    for ($d = 0; $d -lt $Days; $d++) {
        $date = $today.AddDays(-$d).ToString('yyyy-MM-dd')
        $ids = @()
        $us = Get-Json "https://api.tvmaze.com/schedule?country=US&date=$date"
        if ($us) { $ids += $us | ForEach-Object { $_.show.id } }
        $web = Get-Json "https://api.tvmaze.com/schedule/web?date=$date"
        if ($web) { $ids += $web | ForEach-Object { $_._embedded.show.id } }
        foreach ($id in $ids) {
            if ($null -eq $id) { continue }
            $id = [int]$id
            if (-not $lastAired.ContainsKey($id) -or $lastAired[$id] -gt $d) { $lastAired[$id] = $d }
        }
        if ($d % 30 -eq 0) { Write-Host "schedule $date : $($lastAired.Count) shows so far" }
    }
    $airedShows = $lastAired.Keys | Where-Object { $catalog.ContainsKey($_) } | ForEach-Object { $catalog[$_] } |
        Where-Object { $excludedTypes -notcontains $_.type }
    foreach ($w in @(@('week', 7), @('month', 30), @('quarter', 91), @('year', 365))) {
        $trendingPools[$w[0]] = @($airedShows | Where-Object { $lastAired[$_.id] -lt $w[1] } |
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
foreach ($id in $withPosters) {
    $dest = Join-Path $posterDir "$id.jpg"
    $image = $catalog[$id].image
    if ((Test-Path $dest) -or -not $image) { continue }
    try {
        $bytes = (Invoke-WebRequest -UseBasicParsing "https://static.tvmaze.com/uploads/images/medium_portrait/$image.jpg").RawContentStream.ToArray()
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
$size = (Get-ChildItem $posterDir | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Wrote discover.json: {0} shows ({1:N0} KB), posters {2:N1} MB" -f $shows.Count, ((Get-Item $jsonPath).Length / 1KB), $size)
