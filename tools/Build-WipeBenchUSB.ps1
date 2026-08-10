<#
.SYNOPSIS
  Build a COMPLETE WipeBench stick from Windows - partitions, the Linux/GRUB side, WinPE,
  and the payload - with no Linux machine involved.

.DESCRIPTION
  Previously the build took two machines: make_WipeBench_USB.ps1 laid down the partitions
  from Windows, then a running WipeBench Linux box rsync'd itself onto the stick
  (build_wipeusb_existing_NEW.sh) and installed GRUB. This finishes the job on Windows by
  restoring the ext4 side from a golden image captured by Capture-WipeBenchImage.ps1:

      partition  ->  raw-restore Linux (ext4+GRUB)  ->  copy WinPE  ->  copy payload

  PARTITIONING IS DELEGATED to make_WipeBench_USB.ps1 (John's, battle-tested: online/
  read-only fixups, USB re-enumeration, and a diskpart clean fallback for firmwares that
  ignore Clear-Disk). Point -Partitioner at it; pass -SelfPartition only if it's missing.

  Layout produced (GPT):
      P1  FAT32  2GB    "WINPE"          boot + WinPE  (+ WIPEBENCH_USB.lock)
      P2  raw    8GB    Debian/ext4      restored byte-for-byte from the golden image
      P3  NTFS   rest   "WIPEBENCHNTFS"  install.wim, Drivers\, STAGING\  (+ WIPEBENCH_USB.lock)

.EXAMPLE
  .\Build-WipeBenchUSB.ps1 -DiskNumber 2 -ImageRoot D:\WipeBenchImages
  .\Build-WipeBenchUSB.ps1 -DiskNumber 2 -ImageRoot D:\WipeBenchImages -SkipPayload -Force

.NOTES
  Run elevated. DESTROYS everything on the target disk. Refuses boot/system disks, and
  refuses any disk that isn't removable/USB unless -AllowInternalDisk is given.
#>
[CmdletBinding()]
param(
    [int]$DiskNumber = -1,
    [Parameter(Mandatory)][string]$ImageRoot,
    [int]$WinPESizeGB = 2,
    [string]$WinPELabel = "WINPE",
    [string]$PayloadLabel = "WIPEBENCHNTFS",
    [string]$Partitioner = "$PSScriptRoot\make_WipeBench_USB.ps1",
    [switch]$SelfPartition,
    [switch]$SkipPayload,
    [switch]$SkipDrivers,
    [switch]$IncludeCustom,                  # personal extras - off by default (see below)
    [string]$CustomFolder = "CustomJohn",
    [switch]$AllowInternalDisk,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Step($n, $m) { Write-Host "`n[$n] $m" -ForegroundColor Cyan }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated PowerShell session."
}

# ---------- manifest ----------
$manifestPath = Join-Path $ImageRoot "wipebench-image.json"
if (-not (Test-Path $manifestPath)) { throw "No wipebench-image.json in $ImageRoot - run Capture-WipeBenchImage.ps1 first." }
$mf = Get-Content $manifestPath -Raw | ConvertFrom-Json
$linuxImg = Join-Path $ImageRoot $mf.linux_image
if (-not (Test-Path $linuxImg)) { throw "Linux image '$($mf.linux_image)' missing from $ImageRoot." }
$linuxBytes = [int64]$mf.linux_part_bytes
Say "Image set: version $($mf.version), captured $($mf.captured_utc) from $($mf.captured_from)" Gray

# ---------- target selection ----------
if ($DiskNumber -lt 0) {
    Say "`n=== Available disks ===" Cyan
    Get-Disk | Sort-Object Number | Select-Object Number, FriendlyName, BusType,
        @{n = "SizeGB"; e = { [math]::Round($_.Size / 1GB, 1) } }, IsBoot, IsSystem | Format-Table -AutoSize
    $ans = Read-Host "Disk number to ERASE and build (q to quit)"
    if ($ans -eq 'q') { return }
    $DiskNumber = [int]$ans
}
$disk = Get-Disk -Number $DiskNumber
if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is the boot/system disk - refusing." }
if ($disk.BusType -ne 'USB' -and -not $AllowInternalDisk) {
    throw "Disk $DiskNumber is $($disk.BusType), not USB. Pass -AllowInternalDisk if you really mean it."
}
$needBytes = ($WinPESizeGB * 1GB) + $linuxBytes + 8GB
if ($disk.Size -lt $needBytes) { throw "Disk is $([math]::Round($disk.Size/1GB,1)) GB; need at least $([math]::Round($needBytes/1GB,1)) GB." }

Say "`nTARGET: disk $DiskNumber - $($disk.FriendlyName), $([math]::Round($disk.Size/1GB,1)) GB, $($disk.BusType)" Yellow
Say "Everything on this disk will be destroyed." Red
if (-not $Force) {
    if ((Read-Host "Type ERASE to continue") -ne 'ERASE') { Say "Aborted." Yellow; return }
}

# ---------- 1. partition ----------
Step 1 "Partitioning"
$linuxGB = [int][math]::Round($linuxBytes / 1GB)
if ((Test-Path $Partitioner) -and -not $SelfPartition) {
    Say "  delegating to $(Split-Path $Partitioner -Leaf) (handles offline/read-only disks, USB re-enumeration, diskpart fallback)" Gray
    $ptArgs = @{
        DiskNumber = $DiskNumber
        P1SizeGB   = $WinPESizeGB
        P2SizeGB   = $linuxGB
        P1Label    = $WinPELabel
        P3Label    = $PayloadLabel
        SkipPayload = $true      # we restore Linux + copy WinPE/payload ourselves below
    }
    if ($AllowInternalDisk) { $ptArgs['AllowSystemDisk'] = $true }
    # NOTE: make_WipeBench_USB.ps1 also has a payload-copy phase that pulls boot files /
    # Install.wim / Drivers from a hard-coded C:\Temp\STAGING staging tree. We only want its
    # (well-hardened) partitioning - the WinPE files come from the golden image instead -
    # so a failure AFTER the partitions exist is expected and non-fatal here.
    try {
        & $Partitioner @ptArgs
    } catch {
        Say "  partitioner's payload-copy phase did not run: $($_.Exception.Message)" DarkYellow
        Say "  (expected unless C:\Temp\STAGING is staged - continuing, partitions are what we needed)" DarkGray
    }
} else {
    if (-not $SelfPartition) { Say "  make_WipeBench_USB.ps1 not found next to this script - using the built-in fallback" Yellow }
    Get-Disk -Number $DiskNumber | Get-Partition -ErrorAction SilentlyContinue |
        Remove-Partition -Confirm:$false -ErrorAction SilentlyContinue
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction SilentlyContinue
    Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue
    $p1 = New-Partition -DiskNumber $DiskNumber -Size ($WinPESizeGB * 1GB) -AssignDriveLetter
    Format-Volume -Partition $p1 -FileSystem FAT32 -NewFileSystemLabel $WinPELabel -Force -Confirm:$false | Out-Null
    $null = New-Partition -DiskNumber $DiskNumber -Size $linuxBytes
    $p3 = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $p3 -FileSystem NTFS -NewFileSystemLabel $PayloadLabel -Force -Confirm:$false | Out-Null
}

Update-HostStorageCache; Start-Sleep -Milliseconds 500
$parts = @(Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber)
if ($parts.Count -lt 3) { throw "Expected 3 partitions after partitioning, found $($parts.Count)." }
$pe = $parts[0]; $lx = $parts[1]; $pay = $parts[2]
$peLetter = $pe.DriveLetter
$payLetter = $pay.DriveLetter
if (-not $peLetter -or -not $payLetter) { throw "P1/P3 have no drive letters - check the partitioner output." }
Say "  P1 ${peLetter}: FAT32 ($WinPELabel) | P2 raw $([math]::Round($lx.Size/1GB,1)) GB (Linux) | P3 ${payLetter}: NTFS ($PayloadLabel)" Green
if ($lx.Size -lt $linuxBytes) { throw "P2 is $([math]::Round($lx.Size/1GB,2)) GB but the Linux image needs $([math]::Round($linuxBytes/1GB,2)) GB." }

# Restore the captured FAT32 volume serial. GRUB's WinPE chainload entry locates that
# partition by fs-UUID (derived from these 4 BPB bytes at 0x43); a fresh format would
# hand out a new one and silently break the WinPE menu entry.
if ($mf.winpe_vol_serial) {
    try {
        $bytes = [byte[]]( (0..3) | ForEach-Object { [Convert]::ToByte($mf.winpe_vol_serial.Substring($_ * 2, 2), 16) } )
        # Raw device I/O is sector-granular: read each sector, patch 0x43..0x46, write it back.
        $vol = New-Object IO.FileStream("\\.\${peLetter}:", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        try {
            foreach ($sectorNo in 0, 6) {   # boot sector + FAT32 backup boot sector
                $buf = New-Object byte[] 512
                $null = $vol.Seek($sectorNo * 512, [IO.SeekOrigin]::Begin)
                $null = $vol.Read($buf, 0, 512)
                if ($buf[0] -eq 0 -and $buf[510] -ne 0x55) { continue }   # not a boot sector, leave it alone
                [Array]::Copy($bytes, 0, $buf, 0x43, 4)
                $null = $vol.Seek($sectorNo * 512, [IO.SeekOrigin]::Begin)
                $vol.Write($buf, 0, 512)
            }
            $vol.Flush()
        } finally { $vol.Dispose() }
        Say "  restored WinPE volume serial $($mf.winpe_vol_serial) (keeps GRUB's chainload UUID valid)" Green
    } catch { Say "  WARN: could not restore the WinPE volume serial: $_" Yellow }
}

# ---------- 2. restore the Linux partition ----------
Step 2 "Restoring Linux/ext4 partition (the part Windows normally can't make)"
$lxOffset = [int64]$lx.Offset
$dst = New-Object IO.FileStream("\\.\PhysicalDrive$DiskNumber", [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
try {
    $null = $dst.Seek([int64]$lxOffset, [IO.SeekOrigin]::Begin)
    $fileIn = New-Object IO.FileStream($linuxImg, [IO.FileMode]::Open, [IO.FileAccess]::Read)
    $in = if ($mf.compressed) { New-Object IO.Compression.GZipStream($fileIn, [IO.Compression.CompressionMode]::Decompress) } else { $fileIn }
    try {
        $chunk = 8388608
        $buf = New-Object byte[] $chunk
        [int64]$done = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $n = $in.Read($buf, 0, $chunk)
            if ($n -le 0) { break }
            if (($done + $n) -gt $linuxBytes) { $n = [int]($linuxBytes - $done) }  # never spill into P3
            if ($n -le 0) { break }
            $dst.Write($buf, 0, $n)
            $done += $n
            if ($done % (512MB) -lt $chunk) {
                Write-Progress -Activity "Restoring Linux partition" -Status "$([math]::Round($done/1GB,1)) GB" -PercentComplete (100 * $done / $linuxBytes)
            }
        }
        $dst.Flush()
        Write-Progress -Activity "Restoring Linux partition" -Completed
        Say ("  wrote $([math]::Round($done/1GB,2)) GB in {0:N0}s" -f $sw.Elapsed.TotalSeconds) Green
    } finally { $in.Dispose(); if ($mf.compressed) { $fileIn.Dispose() } }
} finally { $dst.Dispose() }

# ---------- stick manifest ----------
# The marker file used to be a single line of text, which meant a stick in the field could
# not be told apart from one built eighteen months earlier without auditing it. With ~30
# sticks in circulation and a roughly six-monthly driver refresh, that is precisely how a
# machine quietly gets stale drivers. Same filename and location as before - SyncStick only
# tests for the file's EXISTENCE, it never parses it - so nothing downstream changes.
function Write-StickManifest {
    param([string]$Root, [string]$Partition)
    $lock = $Root.TrimEnd('\') + '\WIPEBENCH_USB.lock'
    try {
        $drv = $Root.TrimEnd('\') + '\Drivers'
        $packs = $null; $bytes = $null; $skus = $null; $cat = $null
        if (Test-Path $drv) {
            $packs = @(Get-ChildItem $drv -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -notlike ".*" }).Count
            $bytes = (Get-ChildItem $drv -Recurse -File -ErrorAction SilentlyContinue |
                      Measure-Object -Sum Length).Sum
            $si = $drv + '\sku-index.json'
            if (Test-Path $si) {
                $j = Get-Content $si -Raw | ConvertFrom-Json
                $skus = @($j.skus.PSObject.Properties).Count
                $cat  = $j.catalog_version
            }
        }
        $toolTime = $null
        try {
            $newest = Get-ChildItem $PSScriptRoot -Filter *.ps1 -ErrorAction Stop |
                      Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($newest) { $toolTime = $newest.LastWriteTimeUtc.ToString('s') + 'Z' }
        } catch { }
        ([ordered]@{
            product         = 'WipeBench USB - do not wipe this disk.'
            partition       = $Partition
            built_utc       = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
            built_by        = "$env:USERNAME@$env:COMPUTERNAME"
            image_version   = $mf.version
            image_captured  = $mf.captured_utc
            tools_newest    = $toolTime
            driver_packs    = $packs
            driver_bytes    = $bytes
            sku_entries     = $skus
            catalog_version = $cat
            skip_drivers    = [bool]$SkipDrivers
            skip_payload    = [bool]$SkipPayload
            custom_included = [bool]$IncludeCustom
        } | ConvertTo-Json -Depth 4) | Set-Content $lock -Encoding ASCII
    }
    catch {
        # a manifest problem must never fail a build - fall back to the original marker
        'WipeBench USB - do not wipe this disk.' | Set-Content $lock -Encoding ASCII
    }
}

# ---------- 3. WinPE ----------
Step 3 "Copying WinPE / boot files"
$peDir = Join-Path $ImageRoot $mf.winpe_dir
if ($mf.winpe_dir -and (Test-Path $peDir)) {
    robocopy $peDir "${peLetter}:\" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    Say "  $((Get-ChildItem "${peLetter}:\" -Recurse -File | Measure-Object).Count) files copied" Green
} else { Say "  no winpe\ in the image set - skipped" Yellow }
Write-StickManifest -Root "${peLetter}:\" -Partition "winpe"

# ---------- 4. payload ----------
Step 4 "Copying payload (install.wim, Drivers, STAGING)"
$payDir = Join-Path $ImageRoot $mf.payload_dir
if (-not $SkipPayload -and $mf.payload_dir -and (Test-Path $payDir)) {
    # -SkipDrivers: everything except the 140GB Drivers tree. The stick still boots and
    # reimages (install.wim is there); the machine just gets no model-specific drivers,
    # which is what you want for a quick test build.
    $xd = @()
    if ($SkipDrivers) { $xd += @("/XD", (Join-Path $payDir "Drivers")); Say "  -SkipDrivers: leaving the Drivers tree behind" Yellow }
    # The personal folder (unattend.xml, Install-Apps.ps1, provisioning bits) belongs on
    # its owner's sticks, not on the 30 production ones. Opt IN with -IncludeCustom.
    $customPath = Join-Path $payDir $CustomFolder
    if (Test-Path $customPath) {
        if ($IncludeCustom) { Say "  -IncludeCustom: $CustomFolder\ will be copied (personal stick)" Gray }
        else { $xd += @("/XD", $customPath); Say "  $CustomFolder\ excluded (pass -IncludeCustom for your own stick)" Gray }
    }
    robocopy $payDir "${payLetter}:\" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP @xd | Out-Null
    $copied = [math]::Round((Get-ChildItem "${payLetter}:\" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum / 1GB, 1)
    Say "  $copied GB copied$(if ($SkipDrivers) { ' (no drivers)' })" Green
    if ($SkipDrivers) { Say "  add them later: .\WipeBenchDrivers.ps1 -Action Sync -DriversRoot ${payLetter}:\Drivers" Gray }
} elseif ($SkipPayload) {
    Say "  -SkipPayload: copy install.wim + Drivers\ to ${payLetter}:\ yourself" Yellow
} else {
    Say "  no payload\ in the image set - capture with -IncludePayload, or copy it yourself" Yellow
}
Write-StickManifest -Root "${payLetter}:\" -Partition "payload"
Say "  stamped WIPEBENCH_USB.lock with a build manifest (date, packs, catalog, tool age)" Gray

# ---------- 5. verify ----------
Step 5 "Verification"
$final = Get-Partition -DiskNumber $DiskNumber | Select-Object PartitionNumber, DriveLetter,
    @{n = "SizeGB"; e = { [math]::Round($_.Size / 1GB, 1) } }
$final | Format-Table -AutoSize
$ok = $true
if (-not (Test-Path "${peLetter}:\bootmgr.efi") -and -not (Test-Path "${peLetter}:\EFI")) { Say "  WARN: no bootmgr.efi/EFI on the WinPE partition" Yellow; $ok = $false }
if ($lx.Size -lt $linuxBytes) { Say "  WARN: Linux partition smaller than image" Yellow; $ok = $false }
Say ""
Say ("Build {0}: disk $DiskNumber is a WipeBench stick." -f $(if ($ok) { "COMPLETE" } else { "finished WITH WARNINGS" })) $(if ($ok) { "Green" } else { "Yellow" })
Say "Boot a target machine from it to run the wipe; GRUB's 'wipe only' entry skips the reimage." Gray
