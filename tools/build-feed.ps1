<#
  Packages the output of build-catalog.ps1 and build-discover.ps1 into the files
  the RabbitEars app downloads, next to them in the same folder:

    catalog.tsv.gz          the search catalog, gzipped (~1.8 MB)
    discover.json           the Discover lists
    discover-posters.zip    the Discover posters (~3 MB)
    manifest.json           what the app checks first: the version (build time, UTC)
                            plus each file's size and SHA-256, so the app can
                            verify downloads and skip files that didn't change

      powershell -ExecutionPolicy Bypass -File tools\build-feed.ps1
#>
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# catalog.tsv -> catalog.tsv.gz
$catalog = Join-Path $OutDir 'catalog.tsv'
$gz = Join-Path $OutDir 'catalog.tsv.gz'
$in = [IO.File]::OpenRead($catalog)
$outStream = [IO.File]::Create($gz)
$gzip = New-Object IO.Compression.GZipStream($outStream, [IO.Compression.CompressionLevel]::Optimal)
$in.CopyTo($gzip)
$gzip.Dispose(); $outStream.Dispose(); $in.Dispose()

# discover/*.jpg -> discover-posters.zip (flat: <id>.jpg)
$zip = Join-Path $OutDir 'discover-posters.zip'
if (Test-Path $zip) { Remove-Item $zip }
[IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $OutDir 'discover'), $zip, [IO.Compression.CompressionLevel]::NoCompression, $false)

function Entry([string]$name) {
    $path = Join-Path $OutDir $name
    [ordered]@{
        path   = $name
        bytes  = (Get-Item $path).Length
        sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

# The version is the build's UTC date and time ("2026-10-30T0412Z"): it sorts as text,
# a later build always counts as newer (even the same day), and it still sorts after
# a bundled copy's plain date from that day.
$manifest = [ordered]@{
    version = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HHmm'Z'")
    files   = [ordered]@{
        catalog  = Entry 'catalog.tsv.gz'
        discover = Entry 'discover.json'
        posters  = Entry 'discover-posters.zip'
    }
}
[IO.File]::WriteAllText((Join-Path $OutDir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))

# A tiny landing page, so the site root isn't a 404.
$index = @"
<!doctype html><meta charset="utf-8"><title>RabbitEars data</title>
<p>Weekly show data for the RabbitEars app, version $($manifest.version).
Built from <a href="https://www.tvmaze.com/">TVMaze</a> data, licensed
<a href="https://creativecommons.org/licenses/by-sa/4.0/">CC BY-SA 4.0</a>.
See <a href="manifest.json">manifest.json</a>.</p>
"@
[IO.File]::WriteAllText((Join-Path $OutDir 'index.html'), $index, (New-Object Text.UTF8Encoding $false))

Write-Host "Feed $($manifest.version):"
$manifest.files.Values | ForEach-Object { Write-Host ("  {0}  {1:N0} KB" -f $_.path, ($_.bytes / 1KB)) }
