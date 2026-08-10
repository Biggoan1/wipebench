<#
.SYNOPSIS
    Resolve (and optionally download) current Microsoft Surface driver packs.

.DESCRIPTION
    The Surface equivalent of the Panasonic scraper. Two-stage, because neither stage is
    reliable on its own:

      1. MSEndpointMgr publish a curated catalog of Surface packs (model -> direct
         download.microsoft.com MSI, keyed by Surface SystemSKU). It is the fastest path
         and carries a hash.
      2. Microsoft RETIRES superseded MSIs, so catalog URLs go 404 without warning - on a
         live library on 2026-08-10, 7 of ~50 packs were dead, including Surface Pro 9,
         Pro 10, Pro 11 Intel, Laptop 5, Laptop 6 and Pro 8. When that happens this script
         reads the model's own Microsoft Download Center page and takes the current build
         from there.

    No third-party assemblies. Windows PowerShell 5.1 or PowerShell 7.

.NOTES
    THINGS THAT COST TIME TO WORK OUT - do not "simplify" these away:

    * The Download Center page returns HTTP 403 and a ~4KB body to server-ish clients.
      From an ordinary workstation, with an ordinary browser User-Agent, the SAME url
      returns ~126KB of real HTML with the links in it. If you see a tiny identical body
      across several different urls, that is a BLOCK PAGE, not the site's design.

    * NOTHING here can be hash-verified. Checked 2026-08-10: HashMD5 exists as a field on
      the catalog but is null for all 51 entries - Microsoft does not publish one, where
      Dell does. And when the catalog url is dead and we fall back to the vendor page we
      are fetching a DIFFERENT, NEWER file anyway, so even a populated catalog hash would
      not apply. Integrity therefore rests on https to download.microsoft.com. The script
      says which of those two situations you are in rather than a vague "skipped".

    * MSI filenames carry everything needed to choose:
          SurfacePro9_Win11_22631_26.051.6816.0.msi
                      ^OS   ^Windows build  ^pack version
      Pick the highest Windows build first, then the highest pack version. A Pro 9 page
      lists both 22621 and 22631 builds; taking "newest by date" gets it wrong.

    * Surface model strings differ in three places and none of them agree:
          catalog        "Surface Pro 11 Intel"
          WMI Model      "Surface Pro 11th Ed Intel"   (abbreviated "Ed")
          asset system   "Surface Pro for Business 11th Edition with Intel"
      Match on the catalog name here; whatever consumes the packs needs its own mapping.

.EXAMPLE
    .\Get-SurfaceDriverPacks.ps1 -Models 'Surface Pro 9','Surface Laptop 6'
    Resolve only - shows what it would fetch and where each url came from.

.EXAMPLE
    .\Get-SurfaceDriverPacks.ps1 -ModelsJson .\models.json -Destination D:\Drivers\Surface -Download -Expand

.EXAMPLE
    .\Get-SurfaceDriverPacks.ps1 -ListCatalog
    Print every Surface model the catalog knows about, so you can copy exact names.
#>
[CmdletBinding()]
param(
    # Catalog model names, e.g. 'Surface Pro 9'. Use -ListCatalog to see valid values.
    [string[]]$Models,

    # A json file of models. Accepts a flat array, or {"surface":[{"name":"..."}]} so it can
    # share a file with the Panasonic tooling.
    [string]$ModelsJson,

    [ValidateSet('Windows 11','Windows 10')]
    [string]$OsCode = 'Windows 11',

    [string]$Destination = ".\SurfaceDriverPacks",

    # Actually fetch. Without this the script only resolves and reports.
    [switch]$Download,

    # After downloading, expand the MSI to <Destination>\<Model>\ with msiexec /a so DISM
    # can see the .inf files.
    [switch]$Expand,

    [switch]$ListCatalog,

    [string]$CatalogUrl = "https://raw.githubusercontent.com/maurice-daly/DriverAutomationTool/master/Data/OSDCatalogMicrosoftDriverPack.json",

    # Cache the catalog here and reuse it for a day.
    [string]$CatalogCache = "$env:TEMP\MicrosoftDriverPack.json"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

function Write-Step($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

function Get-SurfaceCatalog {
    if ((Test-Path $CatalogCache) -and ((Get-Item $CatalogCache).LastWriteTime -gt (Get-Date).AddDays(-1))) {
        Write-Step "  catalog: using cached $CatalogCache"
    }
    else {
        Write-Step "  catalog: downloading"
        Invoke-WebRequest -Uri $CatalogUrl -UseBasicParsing -TimeoutSec 60 -OutFile $CatalogCache
    }
    Get-Content $CatalogCache -Raw | ConvertFrom-Json
}

function Test-UrlAlive {
    # HEAD is enough to tell a retired pack from a live one and costs nothing.
    param([string]$Url)
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = $UA }
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
    } catch { return $false }
}

function Get-PacksFromVendorPage {
    # Read a Download Center page and return every MSI on it, parsed.
    param([string]$PageUrl)
    try {
        $r = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = $UA }
    } catch {
        Write-Step "    vendor page unreachable: $($_.Exception.Message)" Yellow
        return @()
    }
    if ($r.RawContent.Length -lt 20000) {
        Write-Step "    vendor page returned only $($r.RawContent.Length) bytes - almost certainly a block page, not the real page." Yellow
    }
    $out = @()
    foreach ($m in [regex]::Matches($r.RawContent, 'https://download\.microsoft\.com/[^"''<> \\]+\.msi')) {
        $url  = $m.Value
        $file = Split-Path $url -Leaf
        if ($file -notmatch '_Win(\d+)_(\d+)_(.+)\.msi$') { continue }
        $out += [pscustomobject]@{
            Url = $url; File = $file
            Os = "Windows $($matches[1])"; Build = [int]$matches[2]; Version = $matches[3]
        }
    }
    $out | Sort-Object Url -Unique
}

function Resolve-SurfacePack {
    param([object]$Entry)      # a catalog row
    $res = [pscustomobject]@{
        Model = $Entry.Model; Os = $Entry.OperatingSystem
        Version = $Entry.ReleaseDate; Url = $Entry.Url; File = (Split-Path $Entry.Url -Leaf)
        Source = 'catalog'; Md5 = $Entry.HashMD5; UpdatePage = $Entry.UpdatePage; Alternatives = @()
    }
    if (Test-UrlAlive $Entry.Url) { return $res }

    Write-Step "    catalog url is dead - reading $($Entry.UpdatePage)" Yellow
    $cands = @(Get-PacksFromVendorPage -PageUrl $Entry.UpdatePage)
    $want  = @($cands | Where-Object { $_.Os -eq $OsCode })
    if (-not $want.Count) {
        Write-Step "    no $OsCode pack on the vendor page either" Red
        return $null
    }
    # newest servicing baseline first, then newest pack version
    $pick = $want | Sort-Object @{E={$_.Build};D=$true}, @{E={$_.Version};D=$true} | Select-Object -First 1
    $res.Url = $pick.Url; $res.File = $pick.File; $res.Version = $pick.Version
    $res.Source = 'vendor-page'
    $res.Md5 = $null          # the catalog hash belongs to the RETIRED file - not this one
    $res.Alternatives = @($want | Where-Object { $_.File -ne $pick.File } | Select-Object -Expand File)
    return $res
}

function Save-SurfacePack {
    param([object]$Pack)
    $dir = Join-Path $Destination ($Pack.Model -replace '[^A-Za-z0-9\-]+','_')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $msi = Join-Path $dir $Pack.File
    if (Test-Path $msi) { Write-Step "    already downloaded: $($Pack.File)" ; }
    else {
        Write-Step "    downloading $($Pack.File)"
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -L --fail --retry 2 -s -o $msi $Pack.Url
            if ($LASTEXITCODE -ne 0) { Write-Step "    download FAILED (curl $LASTEXITCODE)" Red; return $null }
        }
        else {
            Invoke-WebRequest -Uri $Pack.Url -OutFile $msi -UseBasicParsing -Headers @{ 'User-Agent' = $UA }
        }
    }
    if ($Pack.Md5) {
        $got = (Get-FileHash $msi -Algorithm MD5).Hash
        if ($got -ne $Pack.Md5.ToUpper()) { Write-Step "    MD5 MISMATCH - not trusting this file" Red; return $null }
        Write-Step "    MD5 ok"
    }
    elseif ($Pack.Source -eq 'vendor-page') {
        Write-Step "    vendor-page pack: the catalog's hash describes the RETIRED file, so it cannot be used here" Yellow
    }
    else {
        # Not a defect on our side - checked 2026-08-10, HashMD5 is present as a field but
        # null for all 51 catalog entries. Microsoft simply does not publish one, unlike Dell.
        Write-Step "    the Microsoft catalog publishes no hashes (HashMD5 is null for every entry) - nothing to verify against" Yellow
    }

    if ($Expand) {
        $ex = Join-Path $dir 'expanded'
        New-Item -ItemType Directory -Force -Path $ex | Out-Null
        Write-Step "    expanding (msiexec /a)"
        $p = Start-Process msiexec.exe -ArgumentList @('/a', "`"$msi`"", '/qn', "TARGETDIR=`"$ex`"") -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Step "    msiexec returned $($p.ExitCode)" Red }
        # /a drops a copy of the .msi into TARGETDIR - dead weight, sometimes 600MB+
        Get-ChildItem $ex -Filter *.msi -File -ErrorAction SilentlyContinue | Remove-Item -Force
        $infs = @(Get-ChildItem $ex -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
        Write-Step "    expanded: $infs INFs" $(if ($infs) { 'Green' } else { 'Red' })
    }
    $msi
}

# ------------------------------------------------------------------ main ----
Write-Step "`nSurface driver packs - target OS: $OsCode" Cyan
$catalog = Get-SurfaceCatalog

if ($ListCatalog) {
    $catalog | Where-Object { $_.OperatingSystem -eq $OsCode } |
        Select-Object Model, OperatingSystem, ReleaseDate |
        Sort-Object Model | Format-Table -AutoSize
    return
}

if ($ModelsJson) {
    $j = Get-Content $ModelsJson -Raw | ConvertFrom-Json
    if ($j.surface)   { $Models = @($j.surface   | ForEach-Object { if ($_.name) { $_.name } else { $_ } }) }
    elseif ($j.models){ $Models = @($j.models    | ForEach-Object { if ($_.name) { $_.name } else { $_ } }) }
    else              { $Models = @($j           | ForEach-Object { if ($_.name) { $_.name } else { $_ } }) }
}
if (-not $Models) { throw "Give me -Models, or -ModelsJson. Use -ListCatalog to see valid names." }

$results = @()
foreach ($name in $Models) {
    Write-Step "`n== $name ==" Cyan
    $entries = @($catalog | Where-Object { $_.Model -eq $name -and $_.OperatingSystem -eq $OsCode })
    if (-not $entries.Count) {
        # Suggest, do not guess. Match BOTH directions: the asset-system name is usually the
        # verbose one ("Surface Pro 10 for Business") and the catalog name the short one
        # ("Surface Pro 10"), so checking only "catalog contains query" finds nothing - which
        # is the single most likely way someone mistypes this.
        # Score on shared TOKENS, not substrings. The three naming worlds reorder and
        # abbreviate differently - "Surface Pro for Business 11th Edition with Intel" (asset)
        # vs "Surface Pro 11 Intel" (catalog) share every meaningful word but neither string
        # contains the other. Normalising 11th/1st/2nd -> the bare number is what makes the
        # ordinal forms line up.
        $strip = { param($t) ($t.ToLower() -split '[^a-z0-9+]+') | Where-Object { $_ } |
                              ForEach-Object { $_ -replace '^(\d+)(st|nd|rd|th)$','$1' } }
        $qt = @(& $strip $name)
        $near = @(
            foreach ($cm in @($catalog | Select-Object -Expand Model -Unique)) {
                $ct = @(& $strip $cm)
                if (-not $ct.Count) { continue }
                $hit = @($ct | Where-Object { $qt -contains $_ }).Count
                if ($hit) { [pscustomobject]@{ Model = $cm; Score = $hit / $ct.Count } }
            }
        ) | Sort-Object Score -Descending | Select-Object -First 3 -ExpandProperty Model
        Write-Step "  not in the catalog for $OsCode." Red
        if ($near) { Write-Step "  did you mean: $($near -join ', ')" Yellow }
        continue
    }
    $pack = Resolve-SurfacePack -Entry $entries[0]
    if (-not $pack) { continue }
    Write-Step ("  {0}  [{1}]" -f $pack.File, $pack.Source) $(if ($pack.Source -eq 'catalog') { 'Green' } else { 'Yellow' })
    if ($pack.Alternatives) { $pack.Alternatives | ForEach-Object { Write-Step "    also on the page: $_" DarkGray } }
    if ($Download) { $pack | Add-Member NoteProperty LocalPath (Save-SurfacePack -Pack $pack) -Force }
    $results += $pack
}

Write-Step "`n---- summary ----" Cyan
$results | Select-Object Model, Version, Source, File | Format-Table -AutoSize
$vp = @($results | Where-Object { $_.Source -eq 'vendor-page' }).Count
if ($vp) { Write-Step "$vp pack(s) came from the vendor page because the catalog url was retired - those have no verifiable hash." Yellow }
if (-not $Download) { Write-Step "Resolve only. Re-run with -Download (and -Expand for DISM-ready folders)." Gray }
