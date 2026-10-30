<#
  Builds RabbitEars' Discover tab data from TVMaze (https://www.tvmaze.com/api,
  CC BY-SA 4.0). Run it after build-catalog.ps1, whose catalog.tsv it reads from
  the same output folder:

      powershell -ExecutionPolicy Bypass -File tools\build-discover.ps1

  Writes (to public/ unless -OutDir says otherwise):
    discover.json        the lists (show ids + display info)
    discover/<id>.jpg    a small poster for every listed show

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

  Takes ~20 minutes (TVMaze allows ~20 requests per 10 s). To re-rank only the top
  and by-year lists, keeping the trending lists (and their date) from the current
  discover.json, add -ReuseTrending (~10 minutes).
#>
param(
    [int]$Days = 365,          # schedule history to scan for trending
    [int]$FirstYear = 1950,
    [switch]$ReuseTrending,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$assets = $OutDir
$posterDir = Join-Path $assets 'discover'
$excludedTypes = @('News', 'Talk Show', 'Sports', 'Award Show')

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

function Network-Of($show) {
    if ($show.network) { return $show.network.name }
    if ($show.webChannel) { return $show.webChannel.name }
    return ''
}

# ── Catalog (id, name, year, network, status, weight, rating) ─────────────
$catalog = @{}
foreach ($line in [IO.File]::ReadAllLines((Join-Path $assets 'catalog.tsv'), [Text.Encoding]::UTF8)) {
    $f = $line -split "`t"
    $catalog[[int]$f[0]] = [pscustomobject]@{
        id = [int]$f[0]; name = $f[1]; year = $f[2]; network = $f[3]; status = $f[4]
        weight = [int]$f[5]; rating = if ($f.Count -gt 6 -and $f[6]) { [double]$f[6] } else { $null }
    }
}
Write-Host "catalog: $($catalog.Count) shows"

# Full details (type, poster URL) for every show a list might use, fetched once each.
$details = @{}
function Detail([int]$id) {
    if (-not $details.ContainsKey($id)) { $details[$id] = Get-Json "https://api.tvmaze.com/shows/$id" }
    return $details[$id]
}
function Is-Listable([int]$id) {
    $d = Detail $id
    return $d -and ($excludedTypes -notcontains $d.type)
}

function Rank-ByRating($candidates, [int]$take) {
    $picked = @()
    foreach ($c in ($candidates | Sort-Object @{ e = 'rating'; Descending = $true }, @{ e = 'weight'; Descending = $true }, name)) {
        if ($picked.Count -ge $take) { break }
        if (Is-Listable $c.id) { $picked += $c.id }
    }
    return , $picked
}

# ── Top 50 of all time ────────────────────────────────────────────────────
$rated = $catalog.Values | Where-Object { $null -ne $_.rating }
$top = Rank-ByRating ($rated | Where-Object { $_.weight -ge 97 }) 50
Write-Host "top: $($top.Count)"

# ── Top 10 by premiere year ───────────────────────────────────────────────
$thisYear = (Get-Date).Year
$byYear = [ordered]@{}
for ($y = $thisYear; $y -ge $FirstYear; $y--) {
    # Brand-new shows can carry a high rating from few votes, so the two most recent
    # years need the same popularity bar as the all-time list.
    $cutoff = if ($y -ge $thisYear - 1) { 97 } else { 90 }
    $ids = Rank-ByRating ($rated | Where-Object { $_.year -eq "$y" -and $_.weight -ge $cutoff }) 10
    if ($ids.Count -gt 0) { $byYear["$y"] = $ids }
    Write-Host "year $y : $($ids.Count)"
}

# ── Trending: scan the schedules ──────────────────────────────────────────
# For each show, the most recent day (as days ago) it released an episode.
$lastAired = @{}
$today = (Get-Date).Date
$jsonPath = Join-Path $assets 'discover.json'
$previous = if ($ReuseTrending) { [IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } else { $null }
if ($previous) { $Days = 0; Write-Host "reusing trending lists from $($previous.updated)" }
for ($d = 0; $d -lt $Days; $d++) {
    $date = $today.AddDays(-$d).ToString('yyyy-MM-dd')
    $entries = @()
    $us = Get-Json "https://api.tvmaze.com/schedule?country=US&date=$date"
    if ($us) { $entries += $us | ForEach-Object { $_.show } }
    $web = Get-Json "https://api.tvmaze.com/schedule/web?date=$date"
    if ($web) { $entries += $web | ForEach-Object { $_._embedded.show } }
    foreach ($s in $entries) {
        if (-not $s) { continue }
        $id = [int]$s.id
        if (-not $details.ContainsKey($id)) { $details[$id] = $s }   # schedule embeds full show info
        if (-not $lastAired.ContainsKey($id) -or $lastAired[$id] -gt $d) { $lastAired[$id] = $d }
    }
    if ($d % 10 -eq 0) { Write-Host "schedule $date : $($lastAired.Count) shows so far" }
}

function Trending([int]$window) {
    $candidates = $lastAired.Keys | Where-Object { $lastAired[$_] -lt $window -and $catalog.ContainsKey($_) } |
        ForEach-Object { $catalog[$_] } |
        Where-Object { $excludedTypes -notcontains $details[$_.id].type }
    $sorted = $candidates | Sort-Object @{ e = 'weight'; Descending = $true },
        @{ e = { if ($null -eq $_.rating) { -1 } else { $_.rating } }; Descending = $true }, name
    return , @($sorted | Select-Object -First 20 | ForEach-Object { $_.id })
}
if ($previous) {
    $trending = [ordered]@{}
    foreach ($w in 'week', 'month', 'quarter', 'year') { $trending[$w] = @($previous.trending.$w) }
    $today = [datetime]::ParseExact($previous.updated, 'yyyy-MM-dd', $null)   # trending is still as of then
} else {
    $trending = [ordered]@{
        week    = Trending 7
        month   = Trending 30
        quarter = Trending 91
        year    = Trending 365
    }
}

# ── Show info + posters for everything listed ─────────────────────────────
$listed = @($top) + @($byYear.Values | ForEach-Object { $_ }) + @($trending.Values | ForEach-Object { $_ }) | Sort-Object -Unique
New-Item -ItemType Directory -Force $posterDir | Out-Null
# Keep posters still in use (they rarely change); drop ones for shows no longer listed.
Get-ChildItem $posterDir -Filter *.jpg | Where-Object { $listed -notcontains [int]$_.BaseName } | Remove-Item
$shows = [ordered]@{}
$jpeg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$quality = New-Object Drawing.Imaging.EncoderParameters 1
$quality.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), 72L
foreach ($id in $listed) {
    $c = $catalog[$id]
    $shows["$id"] = [ordered]@{
        name = $c.name; year = $c.year; network = $c.network; status = $c.status; rating = $c.rating
    }
    if (Test-Path (Join-Path $posterDir "$id.jpg")) { continue }
    $d = Detail $id
    $url = if ($d -and $d.image) { $d.image.medium } else { $null }
    if (-not $url) { continue }
    try {
        $bytes = (Invoke-WebRequest -UseBasicParsing $url).RawContentStream.ToArray()
        $src = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $bytes)))
        $thumb = New-Object Drawing.Bitmap 120, 168
        $g = [Drawing.Graphics]::FromImage($thumb)
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, 120, 168)
        $thumb.Save((Join-Path $posterDir "$id.jpg"), $jpeg, $quality)
        $g.Dispose(); $thumb.Dispose(); $src.Dispose()
    } catch {
        Write-Host "poster failed for $id ($($c.name))"
    }
}

$out = [ordered]@{
    updated  = $today.ToString('yyyy-MM-dd')
    top      = $top
    byYear   = $byYear
    trending = $trending
    shows    = $shows
}
[IO.File]::WriteAllText($jsonPath, ($out | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding $false))
$size = (Get-ChildItem $posterDir | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Wrote discover.json: {0} shows, posters {1:N1} MB" -f $shows.Count, $size)
