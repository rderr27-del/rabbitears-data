<#
  Builds RabbitEars' show catalog (public/catalog.tsv) from the TVMaze show
  index (https://www.tvmaze.com/api, data licensed CC BY-SA 4.0).

  The catalog holds only what search needs - one line per show:
      id <TAB> name <TAB> premiere year <TAB> network <TAB> status <TAB> weight <TAB> rating <TAB> image
  (rating is TVMaze's average viewer rating out of 10, blank when unrated; image
  is the poster's path on static.tvmaze.com, e.g. "501/1253519", blank when none),
  sorted by TVMaze popularity weight (highest first), so the app can show the
  best matches first without any ranking data of its own. Episode lists are NOT
  bundled; the app downloads a show's episodes once, when you add it.

  The weekly GitHub workflow runs this; to run it by hand (~6 minutes):
      powershell -ExecutionPolicy Bypass -File tools\build-catalog.ps1
#>
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public')
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$out = Join-Path $OutDir 'catalog.tsv'

function Clean([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '[\t\r\n]+', ' ').Trim()
}

$rows = New-Object System.Collections.Generic.List[object]
$page = 0
while ($true) {
    try {
        $resp = Invoke-WebRequest -UseBasicParsing "https://api.tvmaze.com/shows?page=$page"
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) { break }                       # past the last page
        if ($code -eq 429) { Start-Sleep -Seconds 5; continue }  # rate limited: back off and retry
        throw
    }
    $shows = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    foreach ($s in $shows) {
        $network = if ($s.network) { $s.network.name } elseif ($s.webChannel) { $s.webChannel.name } else { '' }
        $year = if ($s.premiered) { $s.premiered.Substring(0, 4) } else { '' }
        $weight = if ($null -ne $s.weight) { [int]$s.weight } else { 0 }
        $rating = if ($s.rating -and $null -ne $s.rating.average) { ([double]$s.rating.average).ToString([Globalization.CultureInfo]::InvariantCulture) } else { '' }
        # ".../medium_portrait/501/1253519.jpg" -> "501/1253519"; the app rebuilds the URL.
        $image = if ($s.image -and $s.image.medium -match 'medium_portrait/(\d+/\d+)\.jpg$') { $Matches[1] } else { '' }
        $rows.Add([pscustomobject]@{
            Line   = "$($s.id)`t$(Clean $s.name)`t$year`t$(Clean $network)`t$(Clean $s.status)`t$weight`t$rating`t$image"
            Weight = $weight
            Id     = [int]$s.id
        })
    }
    Write-Host "page $page -> $($rows.Count) shows"
    $page++
    Start-Sleep -Milliseconds 550   # TVMaze allows ~20 requests / 10 s
}

$lines = $rows | Sort-Object -Property @{ Expression = 'Weight'; Descending = $true }, Id | ForEach-Object { $_.Line }
[System.IO.File]::WriteAllLines($out, [string[]]$lines, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Wrote $($rows.Count) shows to $out"
