<#
.SYNOPSIS
  Driver library manager for the WipeBench stick - audit, add, normalize and report on
  the model driver packs that WinPE injects during reimage.

.DESCRIPTION
  DellCleaner.ps1 picks drivers by turning the live WMI model string into a folder name:

        (Get-CimInstance Win32_ComputerSystem).Model  -replace '[^A-Za-z0-9\-]+','_'
        e.g.  "Precision 5570"  ->  R:\Drivers\Precision_5570

  So a pack only ever gets used if its folder name matches that transform exactly (case
  aside) AND actually contains .inf files. This tool makes that verifiable instead of
  hopeful:

    Audit     every folder: does it look like a real model? does it hold .inf files?
              is it Win11-shaped? how big? any junk (installers, .zip, docs)?
    Check     a specific model string (or THIS machine) -> which folder would be used?
    Add       import a driver pack (folder / .cab / .zip / extracted Dell pack) and file
              it under the correctly-normalized name.
    Normalize rename folders that don't match the transform, and flatten Dell's
              nested pack layout so DISM /Recurse actually finds the .inf files.
    Report     a coverage table you can hand to someone.

.EXAMPLE
  .\WipeBenchDrivers.ps1 -Action Audit   -DriversRoot F:\Drivers
  .\WipeBenchDrivers.ps1 -Action Check   -DriversRoot F:\Drivers -Model "Latitude 5440"
  .\WipeBenchDrivers.ps1 -Action Check   -DriversRoot F:\Drivers -ThisMachine
  .\WipeBenchDrivers.ps1 -Action Add     -DriversRoot F:\Drivers -Model "OptiPlex 7020" -Source C:\Packs\7020.cab
  .\WipeBenchDrivers.ps1 -Action Normalize -DriversRoot F:\Drivers -WhatIfOnly
  .\WipeBenchDrivers.ps1 -Action Report  -DriversRoot F:\Drivers -Csv C:\temp\drivers.csv
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Check', 'Add', 'Normalize', 'Report', 'Catalog', 'Search', 'Download', 'Update', 'Alias', 'Index', 'PEDriver', 'SyncStick')]
    [string]$Action = 'Audit',
    # MASTER repository lives on the BUILD MACHINE, not on a stick: with ~30 sticks to
    # maintain you download each pack once here, and every build copies it out. Point
    # -DriversRoot at a stick only when servicing that stick directly.
    [string]$DriversRoot = "C:\WipeBenchImages\payload\Drivers",
    [string]$Model,
    [switch]$ThisMachine,
    [string]$Source,
    [string]$Csv,
    [switch]$WhatIfOnly,
    [string]$OsFolder = "Win11",
    [string]$Sku,
    [string]$FolderName,
    [string[]]$Models,
    [string]$OsCode = "Windows11",
    [switch]$KeepCache,
    [switch]$DellOnly,
    [string]$WimPath,
    [int]$ImageIndex = 1,
    [switch]$List,
    [switch]$NoBackup,
    # Remove the Defender exclusion again once the download finishes. Off by default:
    # "make sure it exists" can never destroy anything, whereas removing it blind on a
    # box that hides exclusions can wipe out one somebody set deliberately.
    [switch]$TempExclusion,
    # Skip the ASR rule-specific exclusion (see Add-AsrDriverExclusion for why it exists).
    [switch]$NoAsrExclusion,
    # Re-download a pack even when the repository already holds the catalog's current
    # version. Without this, Download now skips packs that are already up to date.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

# ---- Defender ----------------------------------------------------------------
# Defender scans every .sys/.inf as it lands, which turns a driver-pack extraction
# into a crawl (and occasionally quarantines a legitimate vendor binary). Exclude the
# repository for the duration of a download, then put things back exactly as found:
# if the path was ALREADY excluded we leave it alone, so a permanent exclusion someone
# set up by hand survives.
$script:TempDefenderExclusion = $null

# Separate from the antivirus exclusion below: Attack Surface Reduction is a different
# engine and a plain ExclusionPath does not reliably cover it. Dell chipset packs contain
# RtsPer.sys (Realtek card reader), which is on Microsoft's vulnerable-driver list, and
# the packs extract themselves with their own bundled miniunz.exe - so the ASR rule
# "Block abuse of exploited vulnerable signed drivers" blocks that write. Observed on
# GAME1: the extractor retried and every file DID land intact, so this is mostly noise -
# but a blocked write mid-extraction is a nondeterministic way to end up with a silently
# incomplete driver pack, so head it off.
#
# Deliberately RULE-SPECIFIC: only this one rule is relaxed, and only for the driver
# repo. Every other ASR rule stays fully armed on that path. -NoAsrExclusion skips it.
$AsrVulnerableDriverRule = "56a863a9-875e-4185-98a7-b882c64b5ce5"

function Resolve-RetiredVendorPack {
    # Vendors retire superseded packs, so a catalog URL can 404 while the product's own
    # download page still lists a CURRENT build. That page is real HTML with direct
    # download.microsoft.com links, so read it rather than making the operator do it by hand.
    # (A 2026-08-07 note claimed this was impossible because the page was "a 4KB JS shell" -
    # that was a 403 bot-block seen from a server, not what a normal client gets. A real
    # client gets ~126KB of HTML with the links in it.)
    param([string]$UpdatePage, [string]$OsCode)
    if (-not $UpdatePage) { return $null }
    try {
        $resp = Invoke-WebRequest -Uri $UpdatePage -UseBasicParsing -TimeoutSec 45 `
                -Headers @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }
    }
    catch { Say "  could not read the vendor page: $($_.Exception.Message)" Yellow; return $null }
    $links = [regex]::Matches($resp.Content, 'https://download\.microsoft\.com/[^"''<> \\]+\.msi') |
             ForEach-Object { $_.Value } | Sort-Object -Unique
    if (-not $links) { Say "  vendor page had no .msi links" Yellow; return $null }
    $want = if ("$OsCode" -match '11') { 'Win11' } elseif ("$OsCode" -match '10') { 'Win10' } else { $null }
    $cands = @()
    foreach ($l in $links) {
        $f = Split-Path $l -Leaf
        # e.g. SurfacePro9_Win11_22631_26.051.6816.0.msi
        if ($f -notmatch '_Win(\d+)_(\d+)_(.+)\.msi$') { continue }
        $cands += [pscustomobject]@{ Url = $l; File = $f; Os = "Win$($matches[1])"; Build = [int]$matches[2]; Ver = $matches[3] }
    }
    if ($want) { $cands = @($cands | Where-Object { $_.Os -eq $want }) }
    if (-not $cands.Count) { Say "  vendor page had no $want pack" Yellow; return $null }
    # newest Windows servicing baseline first, then newest pack version. Version segments are
    # fixed-width here so a string sort is fine; if that ever changes, parse it properly.
    $pick = $cands | Sort-Object @{ Expression = { $_.Build }; Descending = $true },
                                 @{ Expression = { $_.Ver };   Descending = $true } | Select-Object -First 1
    Say ("  vendor page lists {0} {1} pack(s); taking {2}" -f $cands.Count, $want, $pick.File) Green
    foreach ($c in $cands) { if ($c.File -ne $pick.File) { Say "    also on the page: $($c.File)" DarkGray } }
    return $pick
}

function Add-AsrDriverExclusion {
    param([string]$Path)
    if ($NoAsrExclusion -or -not $Path) { return }
    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) { return }
    try {
        Add-MpPreference -AttackSurfaceReductionRules_RuleSpecificExclusions_Id $AsrVulnerableDriverRule `
                         -AttackSurfaceReductionRules_RuleSpecificExclusions ("{0}\*" -f $Path.TrimEnd('\')) -ErrorAction Stop
        Say "  Defender: ASR exclusion in place for the vulnerable-signed-driver rule" DarkGray
    } catch {
        # CORRECTED 2026-08-10. This used to say the block was "noisy rather than
        # destructive" - that was WRONG, and the controlled test on 2026-08-07 proved it:
        # a blocked write leaves the file on disk at FULL SIZE with a normal ACL but
        # UNREADABLE (access denied), and nothing fails at extraction time. You discover
        # it when DISM tries to read the .sys during injection. A missing exclusion is a
        # SILENT-CORRUPTION risk, not cosmetic noise - so say so plainly.
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $elevated) {
            Say "  Defender: NOT ELEVATED - could not set the ASR rule exclusion." Yellow
            Say "  Why it matters: if the rule fires, a pack can import LOOKING complete while" Yellow
            Say "  RtsPer.sys is present-but-unreadable, and DISM only fails later at injection." Yellow
            Say "  If this machine has no permanent exclusion yet, rerun Download as Administrator." Yellow
        }
        else {
            Say "  Defender: could not set the ASR rule exclusion ($($_.Exception.Message)) - continuing" Yellow
            Say "  Expect 'vulnerable signed drivers' alerts for RtsPer.sys during extraction," Yellow
            Say "  and verify the pack afterwards - blocked writes are unreadable, not absent." Yellow
        }
    }
}

function Add-DefenderExclusion {
    param([string]$Path)
    if (-not $Path) { return $null }
    if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { return $null }
    $norm = $Path.TrimEnd('\\')

    # Group policy HideExclusionsFromLocalAdmins=1 (set on some lab boxes) makes
    # Get-MpPreference return the literal string
    #   "N/A: Administrators are not allowed to view exclusions"
    # instead of the list, and the backing registry key is ACL'd shut. On those
    # machines we CANNOT tell whether an exclusion already exists - which is exactly
    # why removal is opt-in.
    $readable = $true
    try { $current = @((Get-MpPreference -ErrorAction Stop).ExclusionPath) }
    catch { Say "  Defender: cannot read exclusions - continuing without one" DarkGray; return $null }
    if (@($current | Where-Object { $_ -match '^N/A:' -or $_ -match 'not allowed to view' }).Count -gt 0) {
        $readable = $false
    }

    if ($readable -and @($current | Where-Object { $_ -and $_.TrimEnd('\\') -ieq $norm }).Count -gt 0) {
        Say "  Defender: $norm already excluded" DarkGray
        return $null   # never remove one we did not create
    }

    try {
        Add-MpPreference -ExclusionPath $norm -ErrorAction Stop
    } catch {
        # Not fatal - needs admin, and a slow scan still finishes.
        Say "  Defender: could not add an exclusion ($($_.Exception.Message)) - continuing" Yellow
        return $null
    }

    Add-AsrDriverExclusion $norm

    if (-not $TempExclusion) {
        # The exclusion also speeds up SyncStick and DISM injection, which chew the
        # same files long after the download is over, so keeping it is the default.
        Say "  Defender: exclusion in place for $norm (kept - pass -TempExclusion to drop it after)" DarkGray
        return $null
    }
    Say "  Defender: temporary exclusion added for $norm" DarkGray
    if (-not $readable) {
        Say "  Defender: this box hides exclusions from admins (policy), so I cannot tell" Yellow
        Say "  whether one already existed - it WILL be removed when this finishes." Yellow
    }
    return $norm
}

function Remove-DefenderExclusion {
    param([string]$Path)
    if (-not $Path) { return }
    try {
        Remove-MpPreference -ExclusionPath $Path -ErrorAction Stop
        Say "  Defender: temporary exclusion removed" DarkGray
    } catch {
        Say "  Defender: FAILED to remove the temporary exclusion for $Path" Red
        Say "  Remove it by hand: Remove-MpPreference -ExclusionPath '$Path'" Red
    }
}

# The one transform that matters - mirrored from DellCleaner.ps1
# How deep an .inf may sit before it is worth remarking on. MEASURED across the live
# library 2026-08-10: Surface packs bottom out at 4, Dell's own layout runs 8-14
# (Win11\x64\<component>\<vendor>\<sub>\...). The old threshold of 4 therefore flagged
# every single pack, which is the same as flagging none - a warning that always fires
# trains you to ignore audit output. 16 sits clear of the deepest real pack while still
# catching the pathology that actually matters: a pack containing a SECOND nested copy of
# itself, which is what made optiplex_5000 13.71GB of the same 197 INFs twice.
$DeepInfThreshold = 16

function ConvertTo-DriverFolderName([string]$modelString) {
    if ([string]::IsNullOrWhiteSpace($modelString)) { return $null }
    return ($modelString.Trim() -replace '[^A-Za-z0-9\-]+', '_')
}

# ---- Dell driver-pack catalog (the DriverAutomationTool mechanism, minus ConfigMgr) ----
# Dell publishes every driver pack in one manifest:
#   https://downloads.dell.com/catalog/DriverPackCatalog.cab  -> DriverPackCatalog.xml
# Each DriverPackage carries: path (relative to downloads.dell.com), dellVersion,
# releaseDate, hashMD5, size, the supported OS codes, and - the useful part -
# SupportedSystems/Brand/Model with BOTH a display name and a systemID (the 4-char
# SystemSKU). Matching on SKU is exact, where model strings are a guessing game.
$CatalogUrl = "https://downloads.dell.com/catalog/DriverPackCatalog.cab"
# Microsoft publishes NO machine-readable Surface catalog, so we consume the curated one
# MSEndpointMgr maintains for the Driver Automation Tool (model -> direct download.microsoft
# .com MSI, keyed by Surface SystemSKU). Credit: github.com/maurice-daly/DriverAutomationTool
$SurfaceCatalogUrl = "https://raw.githubusercontent.com/maurice-daly/DriverAutomationTool/master/Data/OSDCatalogMicrosoftDriverPack.json"
$StateDir   = Join-Path $DriversRoot ".wipebench"
# Batch mode runs each model as a CHILD invocation of this same script, so the child needs
# a way to tell the parent "I skipped that one, it was already current". A marker file is
# used rather than capturing the child's output, because capturing would buffer a multi-GB
# download and make the log look frozen until each model finished.
$SkipMarker = Join-Path $StateDir ".last-download-skipped"
$CatalogXml = Join-Path $StateDir "DriverPackCatalog.xml"
$SurfaceJson = Join-Path $StateDir "MicrosoftDriverPack.json"
$CacheDir   = Join-Path $StateDir "cache"

function Get-Catalog {
    param([switch]$Force)
    $stale = $Force -or -not (Test-Path $CatalogXml) -or
             ((Get-Item $CatalogXml).LastWriteTime -lt (Get-Date).AddDays(-14))
    if ($stale) {
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        $cab = Join-Path $StateDir "DriverPackCatalog.cab"
        & curl.exe -s -L --fail -o $cab $CatalogUrl
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path $CatalogXml) { Say "  catalog download failed - using the cached copy" Yellow }
            else { throw "Could not download the Dell catalog (curl exit $LASTEXITCODE). Offline?" }
        } else {
            Remove-Item $CatalogXml -Force -ErrorAction SilentlyContinue
            & expand.exe $cab $CatalogXml | Out-Null
            Remove-Item $cab -Force -ErrorAction SilentlyContinue
        }
    }
    [xml]$x = Get-Content $CatalogXml
    $pkgs = foreach ($p in $x.DriverPackManifest.DriverPackage) {
        $models = @($p.SupportedSystems.Brand.Model)
        [pscustomobject]@{
            Models    = @($models | ForEach-Object { $_.name })
            ModelList = (($models | ForEach-Object { $_.name }) -join ' / ')
            Skus      = (($models | ForEach-Object { $_.systemID }) -join ',')
            Version   = $p.dellVersion
            Released  = ($p.dateTime -split 'T')[0]
            Format    = $p.format
            Md5       = $p.hashMD5
            Size      = [int64]$p.size
            OsCodes   = (@($p.SupportedOperatingSystems.OperatingSystem | ForEach-Object { $_.osCode }) | Select-Object -Unique) -join ','
            Url       = "https://downloads.dell.com/" + $p.path
            Vendor    = 'Dell'
            UpdatePage = $null
        }
    }
    $all = @($pkgs)
    if (-not $DellOnly) { $all += @(Get-SurfaceCatalog) }
    [pscustomobject]@{ Version = $x.DriverPackManifest.version; Packages = $all }
}

function Get-SurfaceCatalog {
    param([switch]$Force)
    $stale = $Force -or -not (Test-Path $SurfaceJson) -or
             ((Get-Item $SurfaceJson).LastWriteTime -lt (Get-Date).AddDays(-14))
    if ($stale) {
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        & curl.exe -s -L --fail -o $SurfaceJson $SurfaceCatalogUrl
        if ($LASTEXITCODE -ne 0 -and -not (Test-Path $SurfaceJson)) {
            Say "  Surface catalog unavailable (offline?) - Dell only" Yellow
            return @()
        }
    }
    try { $raw = Get-Content $SurfaceJson -Raw | ConvertFrom-Json } catch { return @() }
    foreach ($e in $raw) {
        # ReleaseDate is yy.MM.dd in this catalog - normalise to yyyy-MM-dd so sorting and
        # the Update comparison behave the same as they do for Dell.
        $rel = "$($e.ReleaseDate)"
        if ($rel -match '^(\d{2})\.(\d{2})\.(\d{2})$') { $rel = "20$($matches[1])-$($matches[2])-$($matches[3])" }
        [pscustomobject]@{
            Models    = @($e.Model)
            ModelList = "$($e.Model)"
            Skus      = (@($e.SystemId) -join ',')
            Version   = $rel                                   # MS ships no version, date is it
            Released  = $rel
            Md5       = $e.HashMD5
            Size      = 0                                      # not published
            OsCodes   = ("$($e.OperatingSystem)" -replace '\s', '')   # "Windows 11" -> Windows11
            Url       = $e.Url
            Format    = 'msi'
            Vendor    = 'Microsoft'
            UpdatePage = $e.UpdatePage   # official microsoft.com/download page for this model
        }
    }
}

function Find-Packages {
    param($Catalog, [string]$Model, [string]$Sku, [string]$OsCode)
    # OS filter FIRST: otherwise an exact model hit on a Windows10-only pack "succeeds",
    # then gets filtered away, and we never try the looser match that would have found
    # the Windows 11 variant (e.g. "OptiPlex 7020" vs "OptiPlex 7020 Tower").
    $r = $Catalog.Packages
    if ($OsCode) { $r = @($r | Where-Object { $_.OsCodes -match [regex]::Escape($OsCode) }) }
    if ($Sku) {
        # $Sku may be a single SKU or the comma-joined list we stored in .wipebench.json
        $want = @($Sku -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        return @($r | Where-Object { $mine = ($_.Skus -split ','); @($mine | Where-Object { $want -contains $_ }).Count -gt 0 })
    }
    if (-not $Model) { return @($r) }
    $needle = ($Model -replace '[^A-Za-z0-9]', '').ToLower()
    $exact = @($r | Where-Object { @($_.Models | Where-Object { ($_ -replace '[^A-Za-z0-9]', '').ToLower() -eq $needle }).Count -gt 0 })
    if ($exact) { return $exact }
    @($r | Where-Object { @($_.Models | Where-Object { ($_ -replace '[^A-Za-z0-9]', '').ToLower() -like "*$needle*" }).Count -gt 0 })
}

# Dells report a SystemSKU; it is the reliable identifier. Model strings vary by BIOS.
function Get-MachineId {
    $cs = Get-CimInstance Win32_ComputerSystem
    $sku = $cs.SystemSKUNumber
    if (-not $sku) { $sku = (Get-CimInstance Win32_ComputerSystemProduct).SKUNumber }
    if ($sku) { $sku = ($sku -replace '[^A-Za-z0-9]', '') }
    [pscustomobject]@{ Manufacturer = $cs.Manufacturer; Model = $cs.Model.Trim(); Sku = $sku }
}

# Every INF carries "DriverVer=mm/dd/yyyy,version". The newest one in a pack dates the
# pack itself, which is how we can age a pack that predates this tool (no .wipebench.json)
# WITHOUT downloading anything. Sampled, because a pack can hold hundreds of INFs.
function Get-PackDriverDate([string]$packPath, [int]$Sample = 60) {
    $infs = @(Get-ChildItem $packPath -Recurse -Filter *.inf -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First $Sample)
    $newest = $null
    foreach ($i in $infs) {
        try {
            # do NOT force ASCII: plenty of INFs are UTF-16, and forcing it makes the
            # match silently fail so a single bogus file can define the pack's date
            $line = Select-String -Path $i.FullName -Pattern 'DriverVer\s*=' -List -ErrorAction SilentlyContinue
            if (-not $line) { continue }
            $m = [regex]::Match($line.Line, '(\d{1,2}/\d{1,2}/\d{4})')
            if (-not $m.Success) { continue }
            $d = [datetime]::ParseExact($m.Groups[1].Value, 'M/d/yyyy', $null)
            # placeholder dates exist in the wild (saw a 1968) - ignore anything absurd
            if ($d.Year -lt 2000 -or $d -gt (Get-Date).AddYears(1)) { continue }
            if (-not $newest -or $d -gt $newest) { $newest = $d }
        } catch { }
    }
    $newest
}

function Get-PackInfo([IO.DirectoryInfo]$dir) {
    $infs = @(Get-ChildItem $dir.FullName -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
    $files = @(Get-ChildItem $dir.FullName -Recurse -File -ErrorAction SilentlyContinue)
    $junk = @($files | Where-Object { $_.Extension -in '.zip', '.cab', '.exe', '.msi', '.pdf', '.txt', '.html' })
    $osDirs = @(Get-ChildItem $dir.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    [pscustomobject]@{
        Folder      = $dir.Name
        Normalized  = ConvertTo-DriverFolderName $dir.Name
        IsNormal    = ($dir.Name -eq (ConvertTo-DriverFolderName $dir.Name))
        InfCount    = $infs.Count
        FileCount   = $files.Count
        SizeMB      = [math]::Round((($files | Measure-Object -Sum Length).Sum) / 1MB, 1)
        OsFolders   = ($osDirs -join ',')
        JunkFiles   = $junk.Count
        # +1 on the Substring: without it the relative path keeps its leading '\', Split()
        # returns an empty first element and every depth came out one too high.
        DeepestInf  = if ($infs) { ($infs | ForEach-Object { ($_.FullName.Substring($dir.FullName.Length + 1).Split('\').Count - 1) } | Measure-Object -Maximum).Maximum } else { 0 }
        Usable      = ($infs.Count -gt 0)
        Path        = $dir.FullName
    }
}

if (-not (Test-Path $DriversRoot)) { throw "Drivers root '$DriversRoot' not found. Is the stick plugged in?" }
# Skip REPARSE POINTS. -Action Alias creates directory junctions so one pack can answer to
# two names, and a junction is an alias, not a pack: counting it would inflate the audit,
# double-count its size, and - worst - Index would read the SAME .wipebench.json through it
# and map the same SKUs to two folders, which trips the duplicate-SKU conflict check.
# DISM still follows the junction at reimage time, which is the whole point of it.
$packs = @(Get-ChildItem $DriversRoot -Directory |
           Where-Object { $_.Name -notlike ".*" -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
           ForEach-Object { Get-PackInfo $_ })

try {
switch ($Action) {

    'Audit' {
        Say "`nWipeBench driver library - $DriversRoot" Cyan
        Say ("{0} model folders, {1:N1} GB total`n" -f $packs.Count, (($packs | Measure-Object -Sum SizeMB).Sum / 1024)) Gray
        $packs | Sort-Object Folder | Format-Table `
            @{n = 'Model folder'; e = { $_.Folder } },
            @{n = 'INFs'; e = { $_.InfCount } },
            @{n = 'Size MB'; e = { $_.SizeMB } },
            @{n = 'OS dirs'; e = { $_.OsFolders } },
            @{n = 'Junk'; e = { if ($_.JunkFiles) { $_.JunkFiles } else { '' } } },
            @{n = 'Name OK'; e = { if ($_.IsNormal) { 'yes' } else { 'NO' } } },
            @{n = 'Usable'; e = { if ($_.Usable) { 'yes' } else { 'EMPTY' } } } -AutoSize

        $bad = @($packs | Where-Object { -not $_.Usable })
        $odd = @($packs | Where-Object { -not $_.IsNormal })
        $deep = @($packs | Where-Object { $_.DeepestInf -gt $DeepInfThreshold })
        if ($bad) { Say "$($bad.Count) folder(s) contain NO .inf files - nothing would be injected: $($bad.Folder -join ', ')" Red }
        if ($odd) { Say "$($odd.Count) folder name(s) don't match the model transform: $($odd.Folder -join ', ')  (run -Action Normalize)" Yellow }
        if ($deep) { Say "$($deep.Count) pack(s) nest .inf files deeper than $DeepInfThreshold levels - usually means a duplicated inner tree, worth checking: $($deep.Folder -join ', ')" Yellow }

        # ---- alias junctions ----------------------------------------------------------
        # -Action Alias points a second folder name at an existing pack with a directory
        # junction, and junctions are deliberately excluded from $packs (see the enumeration
        # above) so they cannot double-count. That means NOTHING else looks at them, and they
        # have no referential integrity: delete a pack and any alias aimed at it is silently
        # orphaned. Worse, a dangling junction still returns Test-Path = TRUE, so the reimage
        # path resolves it as a valid pack and DISM injects nothing without an obvious error.
        # (Observed 2026-08-10: pruning Precision_3660_Tower orphaned the Precision_3660 alias.)
        # Audit is the only place positioned to catch this, so check it here.
        $dangling = @()   # declared out here: the healthy-library test below reads it even
                          # when there are no aliases at all, and an undefined variable only
                          # happens to work because StrictMode is off.
        $aliases = @(Get-ChildItem $DriversRoot -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -notlike ".*" -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
        if ($aliases.Count) {
            Say "`nAlias junctions ($($aliases.Count)):" Cyan
            foreach ($a in $aliases) {
                $tgt = @($a.Target) -join ','
                $n = @(Get-ChildItem $a.FullName -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
                if ($n -gt 0) {
                    Say ("  {0,-32} -> {1,-30} {2} INFs" -f $a.Name, (Split-Path $tgt -Leaf), $n) Gray
                } else {
                    $dangling += $a
                    Say ("  {0,-32} -> {1,-30} DANGLING" -f $a.Name, (Split-Path $tgt -Leaf)) Red
                }
            }
            if ($dangling.Count) {
                Say "$($dangling.Count) alias(es) point at a pack that no longer exists." Red
                Say "  Test-Path still returns TRUE for these, so WinPE would resolve one as a valid" Red
                Say "  pack and inject NOTHING. Remove them, or restore the pack they point at:" Red
                foreach ($a in $dangling) { Say ("    cmd /c rmdir `"{0}`"" -f $a.FullName) Yellow }
            }
        }

        if (-not $bad -and -not $odd -and -not $dangling) { Say "`nLibrary looks healthy." Green }
    }

    'Check' {
        if ($ThisMachine) {
            $cs = Get-CimInstance Win32_ComputerSystem
            $Model = $cs.Model
            Say "This machine: $($cs.Manufacturer) / $Model" Cyan
        }
        if (-not $Model) { throw "Give me -Model '<WMI model string>' or -ThisMachine." }
        $want = ConvertTo-DriverFolderName $Model
        Say "`nModel string : '$Model'" Gray
        Say "Folder needed: '$want'" Gray
        $hit = $packs | Where-Object { $_.Folder -eq $want }               # exact
        if (-not $hit) { $hit = $packs | Where-Object { $_.Folder -ieq $want } }  # case-insensitive (NTFS matches this way)
        if ($hit) {
            if ($hit.Usable) {
                Say "MATCH: $($hit.Path) - $($hit.InfCount) INFs, $($hit.SizeMB) MB" Green
                if ($hit.Folder -ne $want) { Say "  (matched only by case - Windows is fine with it, but -Action Normalize would tidy it)" Yellow }
            } else { Say "MATCH but EMPTY: $($hit.Path) has no .inf files - reimage would install no drivers." Red }
        } else {
            Say "NO MATCH - reimage would skip model-specific drivers for this machine." Red
            $near = $packs | Where-Object { $_.Folder -replace '_', '' -match ($want -replace '_', '').Substring(0, [Math]::Min(6, ($want -replace '_', '').Length)) }
            if ($near) { Say "Closest folders: $($near.Folder -join ', ')" Yellow }
            Say "Add one with:  -Action Add -Model `"$Model`" -Source <folder|.cab|.zip>" Gray
        }
    }

    'Add' {
        if (-not $Model) { throw "-Model is required (use the exact WMI model string, e.g. 'Latitude 5450')." }
        if (-not $Source -or -not (Test-Path $Source)) { throw "-Source must point at a driver folder, .cab or .zip." }
        $folder = ConvertTo-DriverFolderName $Model
        $dest = Join-Path $DriversRoot $folder
        $osDest = Join-Path $dest $OsFolder
        Say "Model '$Model' -> $osDest" Cyan
        if ($WhatIfOnly) { Say "(WhatIf) would import $Source" Yellow; break }
        New-Item -ItemType Directory -Force -Path $osDest | Out-Null

        $item = Get-Item $Source
        switch ($item.Extension.ToLower()) {
            '.cab' {
                Say "Expanding CAB ..." Gray
                & expand.exe -F:* "$Source" "$osDest" | Out-Null
            }
            '.zip' {
                Say "Expanding ZIP ..." Gray
                Expand-Archive -Path $Source -DestinationPath $osDest -Force
            }
            default {
                if (-not $item.PSIsContainer) { throw "Unsupported source type '$($item.Extension)'. Use a folder, .cab or .zip." }
                Say "Copying folder ..." Gray
                robocopy $item.FullName $osDest /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            }
        }
        $info = Get-PackInfo (Get-Item $dest)
        if ($info.Usable) { Say "Imported: $($info.InfCount) INFs, $($info.SizeMB) MB" Green }
        else { Say "WARNING: no .inf files landed - check the source layout." Red }
    }

    'Normalize' {
        $todo = @($packs | Where-Object { -not $_.IsNormal })
        if (-not $todo) { Say "Every folder already matches the model transform." Green; break }
        foreach ($p in $todo) {
            $target = Join-Path $DriversRoot $p.Normalized
            if (Test-Path $target) { Say "SKIP $($p.Folder) -> $($p.Normalized) (target exists - merge by hand)" Yellow; continue }
            if ($WhatIfOnly) { Say "(WhatIf) $($p.Folder) -> $($p.Normalized)" Yellow }
            else { Rename-Item $p.Path $p.Normalized; Say "$($p.Folder) -> $($p.Normalized)" Green }
        }
        # flag Dell packs whose INFs hide under an extra wrapper directory
        foreach ($p in $packs | Where-Object { $_.Usable -and $_.DeepestInf -gt $DeepInfThreshold }) {
            Say "NOTE: $($p.Folder) nests INFs $($p.DeepestInf) levels deep - consider flattening for faster DISM." Gray
        }
    }

    'Report' {
        $rows = $packs | Sort-Object Folder | Select-Object Folder, InfCount, FileCount, SizeMB, OsFolders, JunkFiles,
            @{n = 'NameMatchesTransform'; e = { $_.IsNormal } }, @{n = 'Usable'; e = { $_.Usable } }, Path
        ($rows | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host
        Write-Host ''
        $total = ($packs | Measure-Object -Sum SizeMB).Sum
        Say ("`n{0} packs | {1:N1} GB | {2} usable | {3} empty | {4} misnamed" -f $packs.Count, ($total / 1024),
            @($packs | Where-Object Usable).Count, @($packs | Where-Object { -not $_.Usable }).Count,
            @($packs | Where-Object { -not $_.IsNormal }).Count) Cyan
        if ($Csv) { $rows | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8; Say "CSV: $Csv" Green }
    }
    'Catalog' {
        Say "`nRefreshing the Dell driver-pack catalog ..." Cyan
        $cat = Get-Catalog -Force
        $dellN = @($cat.Packages | Where-Object { $_.Vendor -eq 'Dell' }).Count
        $msN = @($cat.Packages | Where-Object { $_.Vendor -eq 'Microsoft' }).Count
        Say ("  Dell    : version {0} - {1} packages" -f $cat.Version, $dellN) Green
        Say ("  Surface : {0} packages (MSEndpointMgr curated catalog)" -f $msN) Green
        $win11 = @($cat.Packages | Where-Object { $_.OsCodes -match 'Windows11' })
        Say ("  {0} of them ship Windows 11 drivers" -f $win11.Count) Gray
        Say "  cached at $CatalogXml" Gray
        Say "`nNext: -Action Search -Model 'Latitude 5450'   (or -Sku 0645)" Gray
    }

    'Search' {
        $cat = Get-Catalog
        if (-not $Model -and -not $Sku -and -not $ThisMachine) { throw "Give me -Model, -Sku, or -ThisMachine." }
        if ($ThisMachine) { $id = Get-MachineId; $Model = $id.Model; $Sku = $id.Sku; Say "This machine: $($id.Manufacturer) / $Model  [SKU $Sku]" Cyan }
        $hits = Find-Packages -Catalog $cat -Model $Model -Sku $Sku -OsCode $OsCode
        if (-not $hits) { Say "No catalog match for $(if($Sku){"SKU $Sku"}else{"'$Model'"})." Red; break }
        Say ""
        $hits | ForEach-Object {
            Say ("{0}  v{1}  {2}  {3}[{4}]" -f $_.ModelList, $_.Version, $_.OsCodes,
                $(if ($_.Size -gt 0) { "$([math]::Round($_.Size/1GB,2)) GB  " } else { "" }), $_.Vendor) White
            Say ("    SKU {0}   released {1}" -f $_.Skus, $_.Released) Gray
            Say ("    {0}" -f $_.Url) DarkGray
            if ($_.UpdatePage) { Say ("    official page: {0}" -f $_.UpdatePage) DarkGray }
        }
        Say "`nDownload with: -Action Download -Model '<model>'  (add -OsCode Windows11 to narrow)" Gray
    }

    'Download' {
        # Batch mode: -Models "a","b","c" downloads each in turn, reusing this same code
        # path so behaviour is identical to a single download.
        if ($Models -and $Models.Count -gt 0) {
            if (-not $WhatIfOnly) { $script:TempDefenderExclusion = Add-DefenderExclusion $DriversRoot }
            $done = 0; $skipped = 0; $failed = @(); $n = 0
            $total = $Models.Count
            foreach ($m in $Models) {
                $n++
                # "[n/total]" is parsed by the GUI to drive a real progress bar, and reads
                # fine on its own in a console.
                Say ("`n========== [{0}/{1}] {2} ==========" -f $n, $total, $m) Cyan
                $p = @{ Action = 'Download'; DriversRoot = $DriversRoot; Model = $m; OsCode = $OsCode; OsFolder = $OsFolder }
                if ($KeepCache) { $p['KeepCache'] = $true }
                if ($WhatIfOnly) { $p['WhatIfOnly'] = $true }
                if ($Force) { $p['Force'] = $true }
                Remove-Item $SkipMarker -Force -ErrorAction SilentlyContinue
                try {
                    & $PSCommandPath @p
                    if (Test-Path $SkipMarker) { $skipped++ } else { $done++ }
                }
                catch { $failed += "$m - $($_.Exception.Message)"; Say "  FAILED: $($_.Exception.Message)" Red }
                finally { Remove-Item $SkipMarker -Force -ErrorAction SilentlyContinue }
            }
            Say ("`n{0} imported, {1} already current, {2} failed (of {3})" -f `
                $done, $skipped, $failed.Count, $Models.Count) $(if ($failed) { 'Yellow' } else { 'Green' })
            foreach ($f in $failed) { Say "  $f" Red }
            break
        }
        Remove-Item $SkipMarker -Force -ErrorAction SilentlyContinue
        $cat = Get-Catalog
        if ($ThisMachine) { $id = Get-MachineId; $Model = $id.Model; $Sku = $id.Sku; Say "This machine: $Model [SKU $Sku]" Cyan }
        if (-not $Model -and -not $Sku) { throw "Give me -Model, -Sku, or -ThisMachine." }
        $hits = @(Find-Packages -Catalog $cat -Model $Model -Sku $Sku -OsCode $OsCode)
        if (-not $hits) { throw "No catalog match for $(if($Sku){"SKU $Sku"}else{"'$Model'"})." }
        if ($hits.Count -gt 1) {
            Say "$($hits.Count) matches - taking the newest; use -Sku to pick exactly:" Yellow
            $hits | ForEach-Object { Say ("    {0}  v{1}  SKU {2}" -f $_.ModelList, $_.Version, $_.Skus) Gray }
        }
        $candidates = @($hits | Sort-Object Released -Descending)
        $pkg = $candidates[0]
        # The folder name MUST equal what DellCleaner.ps1 derives from the machine's WMI
        # model string, or the pack is never injected. Dell's catalog name is NOT always
        # that string (catalog says "OptiPlex 7020 SFF"; a machine may report
        # "OptiPlex SFF Plus 7020"), so be explicit about where the name came from.
        if ($FolderName) {
            $folder = ConvertTo-DriverFolderName $FolderName
            $folderModel = $FolderName
            $nameSource = "explicit (-FolderName)"
        } elseif ($ThisMachine) {
            $folderModel = $Model            # set from Win32_ComputerSystem above
            $folder = ConvertTo-DriverFolderName $folderModel
            $nameSource = "this machine's WMI model"
        } elseif ($Model) {
            $folderModel = $Model
            $folder = ConvertTo-DriverFolderName $folderModel
            $nameSource = "the -Model you supplied"
        } else {
            $folderModel = ($pkg.Models | Select-Object -First 1)
            $folder = ConvertTo-DriverFolderName $folderModel
            $nameSource = "Dell's CATALOG name"
        }
        $dest = Join-Path $DriversRoot $folder
        $osDest = Join-Path $dest $OsFolder
        # What the CATALOG claims right now. Kept separate from $pkg.Version because a
        # vendor-page fallback replaces the latter with the build actually fetched.
        $catalogVersion = $pkg.Version
        Say ("`n{0}  v{1}  {2}{3}" -f $pkg.ModelList, $pkg.Version,
            $(if ($pkg.Size -gt 0) { "$([math]::Round($pkg.Size/1GB,2)) GB  " } else { "" }),
            $(if ($pkg.Vendor) { "[$($pkg.Vendor)]" } else { "" })) Cyan
        Say "  -> $osDest" Gray
        Say "  folder name from: $nameSource" Gray
        if ($nameSource -eq "Dell's CATALOG name") {
            Say "  WARNING: WinPE matches packs by the machine's WMI model string, which is" Yellow
            Say "  often NOT what Dell calls the model. If this machine reports something else," Yellow
            Say "  re-run on the machine with -ThisMachine, or pass -FolderName '<wmi model>'," Yellow
            Say "  or add an alias afterwards: -Action Alias -FolderName $folder -Model '<wmi model>'" Yellow
        }
        # Already holding the catalog's current build? Then re-fetching is pure waste. This
        # matters because the model list AUTO-SELECTS everything already in the repository
        # ("refresh what I own" in one click) - without this check that click re-downloaded
        # every owned pack in full, current or not.
        # A pack with NO manifest predates the tool: provenance unknown, so always refresh.
        # A missing OS subfolder means the pack is not actually usable, so refresh too.
        $manifestPath = Join-Path $dest ".wipebench.json"
        if (-not $Force -and (Test-Path $manifestPath) -and (Test-Path $osDest)) {
            try {
                $have = Get-Content $manifestPath -Raw | ConvertFrom-Json
                # Second test: a pack fetched from the vendor page is NEWER than the stale
                # catalog entry, so its version can never equal the catalog's. Compare what the
                # catalog said AT IMPORT TIME instead - if the catalog has not moved there is
                # nothing new to get, and without this every refresh would re-scrape.
                $catalogUnchanged = $have.catalog_version -and "$($have.catalog_version)" -eq "$($pkg.Version)"
                if (($have.dell_version -and "$($have.dell_version)" -eq "$($pkg.Version)") -or $catalogUnchanged) {
                    Say ("  already at v{0}{1} - skipping (use -Force to re-download)" -f `
                        $have.dell_version,
                        $(if ($have.imported_utc) { ", imported $($have.imported_utc)" } else { "" })) Green
                    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
                    Set-Content -Path $SkipMarker -Value "1" -Encoding ASCII
                    break
                }
                elseif ($have.dell_version) {
                    Say ("  have v{0}, catalog has v{1} - updating" -f $have.dell_version, $pkg.Version) Yellow
                }
            }
            catch { Say "  existing .wipebench.json is unreadable - re-downloading" Yellow }
        }

        if ($WhatIfOnly) { Say "(WhatIf) would download $($pkg.Url)" Yellow; break }

        $script:TempDefenderExclusion = Add-DefenderExclusion $DriversRoot
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        $cab = Join-Path $CacheDir (Split-Path $pkg.Url -Leaf)
        if ((Test-Path $cab) -and $pkg.Size -gt 0 -and ((Get-Item $cab).Length -eq $pkg.Size)) { Say "  using cached $(Split-Path $cab -Leaf)" Gray }
        else {
            # Vendors retire superseded packs, so a catalog URL can be a dead 404 while a
            # SIBLING match is still live. Microsoft does this constantly: "Surface Pro 7"
            # matches both Pro 7 (live) and Pro 7+ (retired), and picking the newest by
            # release date lands on the dead one. Walk the candidates rather than giving up.
            $downloaded = $false
            $lastCode = 0
            for ($ci = 0; $ci -lt $candidates.Count; $ci++) {
                $try = $candidates[$ci]
                if ($ci -gt 0) {
                    Say ("  that one is gone - trying {0} v{1} instead" -f $try.ModelList, $try.Version) Yellow
                    $cab = Join-Path $CacheDir (Split-Path $try.Url -Leaf)
                    if ((Test-Path $cab) -and $try.Size -gt 0 -and ((Get-Item $cab).Length -eq $try.Size)) {
                        $pkg = $try; $downloaded = $true; break
                    }
                }
                Say $(if ($try.Size -gt 0) { "  downloading {0:N2} GB ..." -f ($try.Size / 1GB) } else { "  downloading ..." }) Gray
                # curl writes its progress meter to stderr; with EAP=Stop PowerShell treats
                # that as a terminating error, so relax it just for the call.
                $prevEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { & curl.exe -L --fail --retry 2 --progress-bar -o $cab $try.Url 2>&1 | Out-Null }
                finally { $ErrorActionPreference = $prevEAP }
                $lastCode = $LASTEXITCODE
                if ($lastCode -eq 0 -and (Test-Path $cab)) { $pkg = $try; $downloaded = $true; break }
                Remove-Item $cab -Force -ErrorAction SilentlyContinue
            }
            # Catalog URL is dead but the vendor still publishes a build: go and get that one.
            if (-not $downloaded -and $lastCode -eq 22 -and $pkg.UpdatePage) {
                Say "  catalog URL is dead - checking the vendor's download page ..." Yellow
                $alt = Resolve-RetiredVendorPack -UpdatePage $pkg.UpdatePage -OsCode $OsCode
                if ($alt) {
                    $cab = Join-Path $CacheDir $alt.File
                    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                    try { & curl.exe -L --fail --retry 2 --progress-bar -o $cab $alt.Url 2>&1 | Out-Null }
                    finally { $ErrorActionPreference = $prevEAP }
                    if ($LASTEXITCODE -eq 0 -and (Test-Path $cab)) {
                        $downloaded = $true
                        # The catalog's hash and version describe the RETIRED file, so both are
                        # wrong for this one. Drop the hash (nothing to check against) and record
                        # the build actually fetched, or the manifest would claim a version we
                        # do not have.
                        $pkg.Url = $alt.Url
                        $pkg.Version = $alt.Ver
                        $pkg.Md5 = $null
                        Say "  got $($alt.File) from the vendor page" Green
                        Say "  no published hash for a scraped pack - MD5 verification skipped" Yellow
                    }
                    else {
                        Remove-Item $cab -Force -ErrorAction SilentlyContinue
                        Say "  the vendor page link failed too (curl $LASTEXITCODE)" Red
                    }
                }
            }
            if (-not $downloaded) {
                # curl 22 with --fail means HTTP >= 400; for these catalogs that is almost
                # always "the vendor replaced this build and deleted the old MSI".
                $msg = "download failed (curl exit $lastCode)"
                if ($lastCode -eq 22) {
                    $msg = "the vendor has retired this pack (HTTP 404) - the catalog entry is stale"
                    Say ("  {0}" -f $msg) Red
                    if ($pkg.UpdatePage) {
                        Say ("  Grab the current pack by hand from: {0}" -f $pkg.UpdatePage) Yellow
                        Say ("  then import it with:  -Action Add -Source <downloaded file> -FolderName '{0}'" -f $folder) Yellow
                    }
                }
                throw $msg
            }
        }
        if ($pkg.Md5) {
            Say "  verifying MD5 ..." Gray
            $got = (Get-FileHash $cab -Algorithm MD5).Hash
            if ($got -ne $pkg.Md5.ToUpper()) { throw "MD5 mismatch! expected $($pkg.Md5) got $got - refusing to import." }
            Say "  hash OK" Green
        }
        # A pack with no .wipebench.json predates this tool: unknown provenance, and older
        # imports left stray sibling trees (optiplex_5000 held BOTH Win11\ and
        # OptiPlex-5000\ - the same 197 INFs twice, 13.7GB). Replace the whole folder
        # rather than merging into it. Only after the download is verified, so a failed
        # fetch never destroys what is already there.
        if ((Test-Path $dest) -and -not (Test-Path (Join-Path $dest ".wipebench.json"))) {
            $oldGB = [math]::Round((Get-ChildItem $dest -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum / 1GB, 2)
            Say "  untracked pack already here ($oldGB GB, no .wipebench.json) - replacing it wholesale" Yellow
            Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
        Say "  extracting (this takes a few minutes) ..." Gray
        # Extract to a scratch dir first. Dell packs unpack as <Model>\<OS>\x64\<category>,
        # so extracting straight into <folder>\Win11 produced silly nesting like
        # optiplex_5000\Win11\OptiPlex-5000\Win11\x64\... - functional (DISM /Recurse
        # still finds the INFs) but wasteful and confusing. Lift the real driver tree up.
        $tmp = Join-Path $CacheDir ("x_" + [IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            if ($pkg.Format -eq 'msi' -or $cab -like '*.msi') {
                # Surface driver MSIs unpack via an administrative install
                $proc = Start-Process msiexec.exe -ArgumentList "/a", "`"$cab`"", "/qn", "TARGETDIR=`"$tmp`"" -Wait -PassThru
                if ($proc.ExitCode -ne 0) { Say "  msiexec exit code $($proc.ExitCode)" Yellow }
            } elseif ($pkg.Format -eq 'exe' -or $cab -like '*.exe') {
                # Dell driver-pack self-extractors: /s silent, /e=<dir> extract-only
                $proc = Start-Process -FilePath $cab -ArgumentList "/s", "/e=`"$tmp`"" -Wait -PassThru -NoNewWindow
                if ($proc.ExitCode -ne 0) { Say "  extractor exit code $($proc.ExitCode) - check the result" Yellow }
            } else {
                & expand.exe -F:* $cab $tmp | Out-Null
            }
            # An administrative install drops a copy of the .msi in TARGETDIR as well;
            # that is 678 MB of dead weight inside the pack, so bin it before flattening.
            Get-ChildItem $tmp -Filter *.msi -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

            # Flattening rule: NEVER discard content. Dell packs have exactly one x64
            # directory and its parent is the OS root, so lifting it is safe. Surface MSIs
            # have an x64 under EVERY component (SurfaceUpdate\fingerprint\x64, ...), and
            # blindly lifting the first one kept the fingerprint driver and threw away the
            # other 3.6 GB. So only lift when there is a single x64 AND its parent still
            # holds effectively the whole pack.
            $totalBytes = (Get-ChildItem $tmp -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum
            $srcRoot = $tmp
            $archDirs = @(Get-ChildItem $tmp -Recurse -Directory -Filter "x64" -ErrorAction SilentlyContinue)
            if ($archDirs.Count -eq 1) {
                $cand = $archDirs[0].Parent.FullName
                $candBytes = (Get-ChildItem $cand -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum
                if ($totalBytes -gt 0 -and $candBytes -ge ($totalBytes * 0.9)) { $srcRoot = $cand }
                else {
                    Say ("  not flattening: that x64 tree holds only {0:N0}% of the pack" -f (100 * $candBytes / [Math]::Max($totalBytes, 1))) Yellow
                }
            } elseif ($archDirs.Count -gt 1) {
                Say ("  {0} arch folders (multi-component pack) - keeping the tree intact" -f $archDirs.Count) Gray
            }
            # walk down single-child directories so a pure wrapper folder still collapses
            while ($true) {
                $kids = @(Get-ChildItem $srcRoot -Force -ErrorAction SilentlyContinue)
                if ($kids.Count -eq 1 -and $kids[0].PSIsContainer) { $srcRoot = $kids[0].FullName } else { break }
            }
            if (Test-Path $osDest) {
                Say "  replacing existing $OsFolder\ content" Gray
                Remove-Item $osDest -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Force -Path $osDest | Out-Null
            Get-ChildItem $srcRoot -Force | Move-Item -Destination $osDest -Force
            if ($srcRoot -ne $tmp) { Say "  flattened: kept $(Split-Path $srcRoot -Leaf)\* -> $OsFolder\*" Gray }
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        $infs = @(Get-ChildItem $osDest -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
        if (-not $infs) { Say "  WARNING: no .inf files after extraction - check the pack layout" Red }
        else { Say "  imported: $($infs.Count) INFs" Green }
        # record provenance so -Action Update can tell what is stale
        [ordered]@{
            model = $folderModel; folder = $folder; skus = $pkg.Skus; name_source = $nameSource
            dell_version = $pkg.Version; catalog_version = $catalogVersion; released = $pkg.Released
            os_codes = $pkg.OsCodes; source_url = $pkg.Url; md5 = $pkg.Md5
            imported_utc = (Get-Date).ToUniversalTime().ToString("s") + "Z"
        } | ConvertTo-Json | Set-Content (Join-Path $dest ".wipebench.json") -Encoding ASCII
        if (-not $KeepCache) { Remove-Item $cab -Force -ErrorAction SilentlyContinue }
    }

    'Update' {
        $cat = Get-Catalog
        Say "`nComparing the repository against catalog $($cat.Version) ...`n" Cyan
        $rows = foreach ($p in $packs) {
            $mfPath = Join-Path $p.Path ".wipebench.json"
            $known = if (Test-Path $mfPath) { Get-Content $mfPath -Raw | ConvertFrom-Json } else { $null }
            $modelGuess = if ($known) { $known.model } else { $p.Folder -replace '_', ' ' }
            $hit = Find-Packages -Catalog $cat -Model $modelGuess -Sku $(if ($known) { $known.skus }) -OsCode $OsCode |
                Sort-Object Released -Descending | Select-Object -First 1
            # no manifest? date the pack from its INFs and compare to the catalog release
            $packDate = $null
            $status = if (-not $hit) { "not in catalog" }
                      elseif ($known) { if ($known.dell_version -eq $hit.Version) { "current" } else { "OUTDATED" } }
                      else { $null }
            if (-not $status) {
                $packDate = Get-PackDriverDate $p.Path
                $rel = $null
                try { $rel = [datetime]::Parse($hit.Released) } catch { }
                if ($packDate -and $rel) {
                    # a month's grace: pack drivers are always a little older than the
                    # pack's own release date, so only flag a real gap
                    $status = if ($packDate -lt $rel.AddDays(-30)) { "probably OUTDATED" } else { "probably current" }
                }
                else { $status = "unknown (no manifest)" }
            }
            [pscustomobject]@{
                Folder    = $p.Folder
                Have      = if ($known) { $known.dell_version } elseif ($packDate) { "~" + $packDate.ToString("yyyy-MM") } else { "?" }
                Latest    = if ($hit) { $hit.Version } else { "-" }
                Status    = $status
                Released  = if ($hit) { $hit.Released } else { "" }
            }
        }
        ($rows | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host
        Write-Host ''
        $old = @($rows | Where-Object { $_.Status -like '*OUTDATED*' })
        $unk = @($rows | Where-Object Status -like 'unknown*')
        if ($old) { Say "$($old.Count) pack(s) outdated: $($old.Folder -join ', ')" Yellow
                    Say "  refresh one with: -Action Download -Model '<model>'" Gray }
        if ($unk) { Say "$($unk.Count) pack(s) have no manifest and no datable INFs - re-download to start tracking." Gray }
        Say "Rows marked 'probably' are dated from their INFs (no manifest yet); re-downloading one records its exact version." Gray
        if (-not $old -and -not $unk) { Say "Everything tracked is current." Green }
    }

    'Alias' {
        # Point a second folder name at an existing pack, so one download serves both the
        # name Dell uses and the name a machine actually reports. Uses a directory
        # junction (no second copy of 2GB of drivers); DISM /Recurse follows junctions.
        if (-not $FolderName) { throw "-FolderName <existing pack folder> is required." }
        if (-not $Model -and -not $ThisMachine) { throw "Give me -Model '<WMI model string>' (or -ThisMachine) for the new alias." }
        if ($ThisMachine) { $Model = (Get-MachineId).Model }
        $src = Join-Path $DriversRoot (ConvertTo-DriverFolderName $FolderName)
        if (-not (Test-Path $src)) { throw "No such pack: $src" }
        $aliasName = ConvertTo-DriverFolderName $Model
        $dst = Join-Path $DriversRoot $aliasName
        if ($aliasName -ieq (Split-Path $src -Leaf)) { Say "That alias is the same name as the pack - nothing to do." Yellow; break }
        if (Test-Path $dst) { throw "'$aliasName' already exists - remove it first if you mean to replace it." }
        Say "alias '$aliasName' -> $(Split-Path $src -Leaf)" Cyan
        if ($WhatIfOnly) { Say "(WhatIf) would create the junction" Yellow; break }
        & cmd.exe /c mklink /J "`"$dst`"" "`"$src`"" | Out-Null
        if (Test-Path $dst) {
            Say "created - a machine reporting '$Model' will now find these drivers." Green
        } else { Say "junction creation failed (needs an elevated session on NTFS)." Red }
    }

    'Index' {
        # SKU -> folder index. WinPE's apply step can resolve the machine's SystemSKU
        # exactly, instead of guessing from the WMI model string (which breaks on Plus
        # variants, "+" characters, CPU splits and Dell's rebrand). Folders stay
        # human-readable; this is purely the machine-readable lookup beside them.
        # Re-runnable: catalog/manifest entries are rebuilt, manual ones are preserved.
        $indexPath = Join-Path $DriversRoot "sku-index.json"
        $manual = @{}
        $prevCount = 0
        if (Test-Path $indexPath) {
            try {
                $prev = Get-Content $indexPath -Raw | ConvertFrom-Json
                foreach ($p in @($prev.skus.PSObject.Properties)) {
                    $prevCount++
                    if ($p.Value.source -eq 'manual') { $manual[$p.Name] = $p.Value }
                }
            } catch { Say "  existing index unreadable - rebuilding from scratch" Yellow }
        }

        # -- hand-add a mapping: -Action Index -Sku 0C6F -FolderName optiplex_sff_plus_7020
        if ($Sku -and $FolderName) {
            $f = ConvertTo-DriverFolderName $FolderName
            if (-not (Test-Path (Join-Path $DriversRoot $f))) { throw "No such pack folder: $f" }
            foreach ($one in ($Sku -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                $manual[$one.ToUpper()] = [pscustomobject]@{ folder = $f; model = $FolderName; source = 'manual' }
                Say "  manual: $($one.ToUpper()) -> $f" Green
            }
        }
        if ($ThisMachine) {
            $id = Get-MachineId
            if (-not $id.Sku) { Say "  this machine reports no SystemSKU - nothing to add" Yellow }
            elseif (-not $FolderName) { Say "  this machine: $($id.Model) [SKU $($id.Sku)] - re-run with -FolderName '<pack folder>' to map it" Yellow }
            else {
                $f = ConvertTo-DriverFolderName $FolderName
                $manual[$id.Sku.ToUpper()] = [pscustomobject]@{ folder = $f; model = $id.Model; source = 'manual' }
                Say "  manual: $($id.Sku.ToUpper()) ($($id.Model)) -> $f" Green
            }
        }

        # -- rebuild the derived entries
        $cat = $null
        try { $cat = Get-Catalog } catch { Say "  catalogs unavailable - manifest data only" Yellow }
        $byName = @{}
        if ($cat) {
            foreach ($p in $cat.Packages) {
                foreach ($m in $p.Models) {
                    if ([string]::IsNullOrWhiteSpace($m)) { continue }   # catalogs contain the odd empty model
                    $k = (ConvertTo-DriverFolderName $m).ToLower()
                    if (-not $byName.ContainsKey($k)) { $byName[$k] = @{ skus = @(); model = $m } }
                    $byName[$k].skus += @($p.Skus -split ',' | Where-Object { $_ })
                }
            }
        }

        $index = [ordered]@{}
        $conflicts = @()
        $unmapped = @()
        $ambiguous = @()
        foreach ($pack in ($packs | Sort-Object Folder)) {
            $skus = @()
            $model = $pack.Folder -replace '_', ' '
            $src = $null
            $mfp = Join-Path $pack.Path ".wipebench.json"
            if (Test-Path $mfp) {              # authoritative: recorded at download time
                try {
                    $j = Get-Content $mfp -Raw | ConvertFrom-Json
                    if ($j.skus) { $skus = @($j.skus -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }); $src = 'manifest' }
                    if ($j.model) { $model = $j.model }
                } catch { }
            }
            if (-not $skus.Count) {            # bootstrap: match the folder name to a catalog model
                # Normalise BOTH sides with the same transform. The catalog keys are built
                # with ConvertTo-DriverFolderName, so comparing a RAW folder name against
                # them silently missed anything containing a character the transform
                # rewrites - "Surface_Pro_7+" never matched key "surface_pro_7_" ('+' -> '_').
                $k = (ConvertTo-DriverFolderName $pack.Folder).ToLower()
                if ($byName.ContainsKey($k)) { $skus = @($byName[$k].skus); $model = $byName[$k].model; $src = 'catalog' }
                else {
                    # No exact hit. Vendors sometimes split one folder-worth of hardware into
                    # named VARIANTS - "Surface Laptop 7 ARM" / "... Intel", "Surface Laptop 4
                    # AMD" / "... Intel". Those are different silicon needing DIFFERENT packs,
                    # so map only when the variant is unambiguous. Guessing would hand an ARM
                    # machine an Intel driver pack, which is worse than leaving it unmapped.
                    $variants = @($byName.Keys | Where-Object { $_ -like "${k}_*" })
                    if ($variants.Count -eq 1) {
                        $skus = @($byName[$variants[0]].skus); $model = $byName[$variants[0]].model; $src = 'catalog'
                    }
                    elseif ($variants.Count -gt 1) {
                        $ambiguous += ("{0} -> {1}" -f $pack.Folder,
                            (($variants | ForEach-Object { $byName[$_].model }) -join ' | '))
                    }
                }
            }
            if (-not $skus.Count) { continue }
            foreach ($sk in ($skus | Sort-Object -Unique)) {
                $u = $sk.ToUpper()
                if ($manual.ContainsKey($u)) { continue }        # manual wins
                if ($index.Contains($u) -and $index[$u].folder -ne $pack.Folder) {
                    $conflicts += "$u -> $($index[$u].folder) AND $($pack.Folder)"
                    continue
                }
                $index[$u] = [pscustomobject]@{ folder = $pack.Folder; model = $model; source = $src }
            }
        }
        foreach ($k in ($manual.Keys | Sort-Object)) { $index[$k] = $manual[$k] }
        # work out what is still unmapped AFTER manual entries land, or hand-mapped packs
        # keep showing up in the "no SKUs yet" list
        $mappedFolders = @($index.Values | Select-Object -ExpandProperty folder -Unique)
        $unmapped = @($packs | Where-Object { $mappedFolders -notcontains $_.Folder } | Select-Object -ExpandProperty Folder)
        # ...and drop ambiguity warnings for folders a manual entry has already settled,
        # for the same reason: once it is mapped, telling the operator to go pick a variant
        # is just noise that reads like an unfinished job.
        $ambiguous = @($ambiguous | Where-Object { $mappedFolders -notcontains ($_ -split ' -> ')[0] })

        $out = [ordered]@{
            generated_utc   = (Get-Date).ToUniversalTime().ToString("s") + "Z"
            catalog_version = if ($cat) { $cat.Version } else { $null }
            note            = "SystemSKU -> driver pack folder. Built by WipeBenchDrivers.ps1 -Action Index. Re-runnable; entries with source=manual are preserved."
            skus            = $index
        }
        if ($WhatIfOnly) { Say "(WhatIf) would write $($index.Count) entries to $indexPath" Yellow; break }
        $out | ConvertTo-Json -Depth 5 | Set-Content $indexPath -Encoding ASCII

        Say ""
        Say "wrote $indexPath" Green
        Say ("  {0} SKU entries (was {1})   from: {2} manifest, {3} catalog, {4} manual" -f $index.Count, $prevCount,
            @($index.Values | Where-Object { $_.source -eq 'manifest' }).Count,
            @($index.Values | Where-Object { $_.source -eq 'catalog' }).Count,
            @($index.Values | Where-Object { $_.source -eq 'manual' }).Count) Gray
        Say ("  covering {0} of {1} packs" -f (@($index.Values | Select-Object -ExpandProperty folder -Unique)).Count, $packs.Count) Gray
        if ($conflicts) { Say "  CONFLICTS (same SKU, two packs) - resolve with -Sku X -FolderName Y:" Red; $conflicts | Sort-Object -Unique | ForEach-Object { Say "    $_" Red } }
        if ($ambiguous) {
            Say "  AMBIGUOUS (several catalog variants match one folder - pick the right one," Yellow
            Say "  they are different hardware and NOT interchangeable):" Yellow
            $ambiguous | Sort-Object -Unique | ForEach-Object { Say "    $_" Yellow }
        }
        if ($unmapped) {
            Say "  no SKUs yet ($($unmapped.Count)): $($unmapped -join ', ')" Yellow
            Say "    -> run on the machine:  -Action Index -ThisMachine -FolderName '<pack folder>'" Gray
            Say "    -> or by hand:          -Action Index -Sku 0C6F,0C70 -FolderName '<pack folder>'" Gray
        }
    }

    'PEDriver' {
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "Servicing boot.wim needs an elevated session (DISM mount). Reopen PowerShell as Administrator."
        }
        # Inject drivers INTO boot.wim (WinPE itself) - the fix for "WinPE can't see the
        # NVMe/RAID controller" or "no network in PE". Different from the model packs,
        # which go into the offline Windows image at reimage time.
        #   -Source <folder of INFs>   what to add          (required unless -List)
        #   -WimPath <boot.wim>        defaults to the stick's D:\sources\boot.wim
        #   -List                      just show what PE already has
        #   -NoBackup                  skip the .bak copy (boot.wim is ~1.2GB)
        if (-not $WimPath) {
            foreach ($guess in @("D:\sources\boot.wim", "W:\sources\boot.wim", (Join-Path $DriversRoot "..\sources\boot.wim"))) {
                if (Test-Path $guess) { $WimPath = (Resolve-Path $guess).Path; break }
            }
        }
        if (-not $WimPath -or -not (Test-Path $WimPath)) { throw "boot.wim not found - pass -WimPath <path to boot.wim>." }
        Say "`nboot.wim : $WimPath ($([math]::Round((Get-Item $WimPath).Length/1MB)) MB)" Cyan

        $mount = Join-Path $env:TEMP ("wbpe_" + [IO.Path]::GetRandomFileName().Substring(0, 8))
        # a stale mount from a crashed run blocks everything - clear it first
        $stale = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.ImagePath -eq $WimPath })
        foreach ($m in $stale) {
            Say "  clearing stale mount at $($m.Path)" Yellow
            Dismount-WindowsImage -Path $m.Path -Discard -ErrorAction SilentlyContinue | Out-Null
        }
        if ($stale) { Clear-WindowsCorruptMountPoint -ErrorAction SilentlyContinue | Out-Null }

        if (-not $List) {
            if (-not $Source -or -not (Test-Path $Source)) { throw "-Source <folder containing .inf files> is required." }
            $infs = @(Get-ChildItem $Source -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
            if (-not $infs.Count) { throw "No .inf files under '$Source'." }
            Say "drivers  : $($infs.Count) INF(s) from $Source" Cyan
            if (-not $NoBackup) {
                $bak = "$WimPath.bak-pedrivers-" + (Get-Date -Format "yyyyMMddHHmm")
                Say "  backing up to $(Split-Path $bak -Leaf) ..." Gray
                Copy-Item $WimPath $bak -Force
            }
        }
        if ($WhatIfOnly) { Say "(WhatIf) would mount, $(if($List){'list'}else{'inject'}), and $(if($List){'discard'}else{'commit'})" Yellow; break }

        New-Item -ItemType Directory -Force -Path $mount | Out-Null
        $committed = $false
        try {
            Say "  mounting (this takes a minute) ..." Gray
            Mount-WindowsImage -ImagePath $WimPath -Index $ImageIndex -Path $mount -ErrorAction Stop | Out-Null

            if ($List) {
                $have = @(Get-WindowsDriver -Path $mount -ErrorAction SilentlyContinue)
                Say "`n  $($have.Count) driver(s) in this WinPE ($(@($have | Where-Object { $_.ClassName -eq 'Net' }).Count) Net, $(@($have | Where-Object { $_.ClassName -eq 'SCSIAdapter' -or $_.ClassName -eq 'HDC' }).Count) storage):" Cyan
                # NOTE: DISM renames injected INFs to oemNN.inf - OriginalFileName is the
                # name you actually recognise, so show both.
                $have | Sort-Object ClassName, ProviderName |
                    Select-Object @{n = 'Class'; e = { $_.ClassName } }, ProviderName, Version,
                        @{n = 'OriginalINF'; e = { if ($_.OriginalFileName) { Split-Path $_.OriginalFileName -Leaf } else { $_.Driver } } },
                        @{n = 'AsStored'; e = { $_.Driver } } |
                    Format-Table -AutoSize | Out-String -Width 130 | Write-Host
            }
            else {
                Say "  injecting ..." Gray
                $before = @(Get-WindowsDriver -Path $mount -ErrorAction SilentlyContinue).Count
                # capture what DISM says it added - do NOT swallow it, a silent no-op here
                # is indistinguishable from success and that is exactly how you ship a
                # boot.wim that still cannot see the NIC.
                $added = @(Add-WindowsDriver -Path $mount -Driver $Source -Recurse -ForceUnsigned -ErrorAction Stop)
                $after = @(Get-WindowsDriver -Path $mount -ErrorAction SilentlyContinue).Count
                # count can stay flat when you re-inject a driver PE already has - that is
                # a replace, not a failure. Trust what DISM reports it added.
                Say "  DISM added $($added.Count) driver(s); image total $before -> $after$(if ($before -eq $after -and $added.Count) { ' (replaced an existing version)' })" $(if ($added.Count) { 'Green' } else { 'Red' })
                foreach ($a in $added) { Say ("    + {0}" -f (Split-Path $a.Driver -Leaf)) Gray }
                if (-not $added.Count) {
                    Say "  nothing was added - not committing. Check the INF targets amd64/x86 and" Red
                    Say "  that it is a real driver package (some ASUS/OEM folders are installers only)." Red
                }
                else { $committed = $true }
            }
        }
        catch {
            Say "  FAILED: $($_.Exception.Message)" Red
            Say "  discarding the mount - boot.wim is untouched" Yellow
        }
        finally {
            if (Test-Path $mount) {
                Say "  $(if ($committed) { 'committing' } else { 'discarding' }) and unmounting ..." Gray
                if ($committed) {
                    # never silence this: if the save fails the injection is lost and the
                    # tool would otherwise still report success
                    try { Dismount-WindowsImage -Path $mount -Save -ErrorAction Stop | Out-Null }
                    catch {
                        $committed = $false
                        Say "  COMMIT FAILED: $($_.Exception.Message)" Red
                        Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                else { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null }
                Remove-Item $mount -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($committed) {
            Say "`nboot.wim updated." Green
            Say "Remember the OTHER copy: the live stick is D:\sources\boot.wim and the golden" Gray
            Say "image is C:\WipeBenchImages\winpe\sources\boot.wim - update both or a rebuilt" Gray
            Say "stick will silently lose these PE drivers." Gray
        }
    }

    'SyncStick' {
        # Refresh the driver library on attached WipeBench stick(s) from the master repo,
        # without rebuilding the stick. Finds them by the WIPEBENCH_USB.lock marker on an
        # NTFS payload partition, so it can never target a random USB drive.
        $master = $DriversRoot
        if (-not (Test-Path $master)) { throw "Master repository '$master' not found." }
        $masterBytes = (Get-ChildItem $master -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum
        Say ("`nMaster repository: {0}  ({1:N1} GB, {2} packs)" -f $master, ($masterBytes / 1GB),
            @(Get-ChildItem $master -Directory | Where-Object { $_.Name -notlike ".*" }).Count) Cyan

        $targets = @()
        foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
            $root = "$($v.DriveLetter):\"
            # NB: build these with string concat, not Join-Path. The stick's ext4 partition
            # gets a drive letter with no readable filesystem, and Join-Path validates the
            # drive - it throws DriveNotFound before Test-Path ever runs.
            if ($v.FileSystem -ne 'NTFS') { continue }        # the payload partition, not the FAT32 boot one
            if (-not (Test-Path ($root + 'WIPEBENCH_USB.lock') -ErrorAction SilentlyContinue)) { continue }
            $dest = $root + 'Drivers'
            if ($master -like "$root*") { Say "  skipping $root - that IS the master repository" Yellow; continue }
            $have = (Get-ChildItem $dest -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum
            # Read the build manifest the builder now stamps into the marker. Older sticks
            # carry the one-line text version, so treat a parse failure as "unknown", not
            # an error - "unknown" is itself the useful signal that it predates this.
            $built = 'unknown'; $age = $null
            try {
                $m = Get-Content ($root + 'WIPEBENCH_USB.lock') -Raw | ConvertFrom-Json
                if ($m.built_utc) {
                    $built = $m.built_utc
                    $age = [math]::Round(((Get-Date).ToUniversalTime() - [datetime]$m.built_utc).TotalDays)
                }
            } catch { }
            $targets += [pscustomobject]@{
                Root = $root; Dest = $dest; Label = $v.FileSystemLabel
                FreeGB = [math]::Round($v.SizeRemaining / 1GB, 1)
                HaveGB = [math]::Round($have / 1GB, 1)
                RoomGB = [math]::Round((($v.SizeRemaining + $have) / 1GB), 1)
                Built = $built
                AgeDays = $age
            }
        }
        if (-not $targets) {
            Say "`nNo WipeBench stick found. Plug one in - it is identified by WIPEBENCH_USB.lock" Yellow
            Say "on its NTFS payload partition." Gray
            break
        }
        Say "`nAttached WipeBench stick(s):" Cyan
        foreach ($t in $targets) {
            $fits = ($t.RoomGB * 1GB) -ge $masterBytes
            Say ("  {0}  [{1}]  currently {2} GB of drivers, {3} GB usable  {4}" -f $t.Root, $t.Label, $t.HaveGB, $t.RoomGB,
                $(if ($fits) { "" } else { "<- TOO SMALL for the full library" })) $(if ($fits) { 'Green' } else { 'Red' })
        }
        if ($WhatIfOnly) { Say "`n(WhatIf) would mirror the master onto the stick(s) above." Yellow; break }

        foreach ($t in $targets) {
            if ((($t.RoomGB * 1GB) -lt $masterBytes)) {
                Say "`n$($t.Root) skipped - needs $([math]::Round($masterBytes/1GB,1)) GB, has $($t.RoomGB) GB." Red
                continue
            }
            Say "`nMirroring -> $($t.Dest)" Cyan
            Say "  /MIR removes packs on the stick that are no longer in the master (that is the point)." Gray
            New-Item -ItemType Directory -Force -Path $t.Dest | Out-Null
            $sw = [Diagnostics.Stopwatch]::StartNew()
            & robocopy.exe $master $t.Dest /MIR /R:1 /W:1 /MT:16 /NFL /NDL /NJH /NJS /NP | Out-Null
            $rc = $LASTEXITCODE
            # robocopy: 0-7 are success-ish, 8+ are real failures
            if ($rc -ge 8) { Say "  robocopy reported errors (exit $rc)" Red }
            else { Say ("  done in {0:N0}s (robocopy {1})" -f $sw.Elapsed.TotalSeconds, $rc) Green }
            $now = (Get-ChildItem $t.Dest -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum
            Say ("  stick now holds {0:N1} GB, {1} packs" -f ($now / 1GB),
                @(Get-ChildItem $t.Dest -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike ".*" }).Count) Gray
            $idx = Join-Path $master "sku-index.json"
            if (Test-Path $idx) { Say "  sku-index.json carried across (WinPE resolves SKU -> folder with it)" Gray }
            else { Say "  NOTE: no sku-index.json in the master - run -Action Index first" Yellow }
        }
    }
}
}
finally {
    # Runs on success, on throw, and on Ctrl-C alike.
    if ($script:TempDefenderExclusion) {
        Remove-DefenderExclusion $script:TempDefenderExclusion
        $script:TempDefenderExclusion = $null
    }
}
