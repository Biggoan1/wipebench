<#
.SYNOPSIS
    Rewrite ONLY the Linux/ext4 partition of an existing WipeBench stick.

.DESCRIPTION
    The wipe engine (auto_wipe.sh, wipe_mixed.sh, bios_clear.sh) lives inside
    linux-part.img, not in the source tree - so changing it means getting a new image onto
    the stick. Build-WipeBenchUSB.ps1 does that, but only as part of a full rebuild that
    repartitions and re-copies ~260 GB, roughly 17 minutes, to deliver an 8 GB partition.

    This does just that one partition: about 40 seconds, leaving WinPE and the payload
    (drivers, install.wim, the accumulated Evidence\ CSV) untouched.

    It is a RAW WRITE to a physical disk, so the guards matter more than the code:
      * refuses a non-elevated session
      * refuses the boot/system disk
      * refuses any disk that is not already a WipeBench stick (WIPEBENCH_USB.lock)
      * refuses if P2 is smaller than the image
      * clamps every write to the partition size so it can never spill into the payload
      * reads the region back afterwards and compares SHA256 against the source image

.EXAMPLE
    .\Restore-WipeBenchLinux.ps1 -DiskNumber 1
.EXAMPLE
    .\Restore-WipeBenchLinux.ps1 -DiskNumber 1 -ImageRoot D:\WipeBenchImages -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$DiskNumber,
    [string]$ImageRoot = "C:\WipeBenchImages",
    [switch]$SkipVerify,
    # check the partition against the image WITHOUT writing anything
    [switch]$VerifyOnly,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Raw disk writes need an elevated session."
}

$manifestPath = Join-Path $ImageRoot "wipebench-image.json"
if (-not (Test-Path $manifestPath)) { throw "No wipebench-image.json in $ImageRoot." }
$mf = Get-Content $manifestPath -Raw | ConvertFrom-Json
$linuxImg = Join-Path $ImageRoot $mf.linux_image
if (-not (Test-Path $linuxImg)) { throw "Linux image '$($mf.linux_image)' missing from $ImageRoot." }
$linuxBytes = [int64]$mf.linux_part_bytes

$disk = Get-Disk -Number $DiskNumber
if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is the boot/system disk - refusing." }

$parts = @(Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber)
if ($parts.Count -lt 3) { throw "Disk $DiskNumber has $($parts.Count) partitions; a WipeBench stick has 3." }
$lx = $parts[1]
if ($lx.Size -lt $linuxBytes) {
    throw "P2 is $([math]::Round($lx.Size/1GB,2)) GB but the image needs $([math]::Round($linuxBytes/1GB,2)) GB."
}

# The decisive guard: only ever overwrite a disk that is ALREADY a WipeBench stick.
$marker = $false
foreach ($p in @($parts[0], $parts[2])) {
    if ($p.DriveLetter -and (Test-Path ("$($p.DriveLetter):\WIPEBENCH_USB.lock"))) { $marker = $true }
}
if (-not $marker) {
    throw "Disk $DiskNumber has no WIPEBENCH_USB.lock on P1 or P3 - it is not a WipeBench stick. Refusing."
}

Say "`nTARGET  disk $DiskNumber - $($disk.FriendlyName), $($disk.BusType)" Yellow
Say "        P2 offset $($lx.Offset), size $([math]::Round($lx.Size/1GB,2)) GB"
Say "IMAGE   $linuxImg  ($([math]::Round((Get-Item $linuxImg).Length/1GB,2)) GB)"
Say "WinPE and the payload partition are NOT touched." Green
if (-not $Force -and -not $VerifyOnly) {
    if ((Read-Host "Type YES to rewrite the Linux partition") -ne 'YES') { Say "Aborted." Yellow; return }
}

if ($VerifyOnly) { Say "`n-VerifyOnly: not writing, just checking." Cyan }
else {
$sw = [Diagnostics.Stopwatch]::StartNew()
$dst = New-Object IO.FileStream("\\.\PhysicalDrive$DiskNumber", [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
try {
    $null = $dst.Seek([int64]$lx.Offset, [IO.SeekOrigin]::Begin)
    $fileIn = New-Object IO.FileStream($linuxImg, [IO.FileMode]::Open, [IO.FileAccess]::Read)
    $in = if ($mf.compressed) { New-Object IO.Compression.GZipStream($fileIn, [IO.Compression.CompressionMode]::Decompress) } else { $fileIn }
    try {
        $chunk = 8388608
        $buf = New-Object byte[] $chunk
        [int64]$done = 0
        while ($true) {
            $n = $in.Read($buf, 0, $chunk)
            if ($n -le 0) { break }
            if (($done + $n) -gt $linuxBytes) { $n = [int]($linuxBytes - $done) }   # never spill into P3
            if ($n -le 0) { break }
            $dst.Write($buf, 0, $n)
            $done += $n
            if ($done % (1GB) -lt $chunk) { Say ("  {0:N1} GB ..." -f ($done/1GB)) DarkGray }
        }
        $dst.Flush()
        Say ("  wrote {0:N2} GB in {1:N0}s" -f ($done/1GB), $sw.Elapsed.TotalSeconds) Green
    } finally { $in.Dispose(); if ($mf.compressed) { $fileIn.Dispose() } }
} finally { $dst.Dispose() }
}

if ($SkipVerify) { Say "Verification skipped (-SkipVerify)." Yellow; return }

# A raw write that half-fails looks exactly like one that worked. Read it back.
Say "`nVerifying (reading the partition back and hashing it) ..." Cyan
$sha = [Security.Cryptography.SHA256]::Create()
$src = New-Object IO.FileStream("\\.\PhysicalDrive$DiskNumber", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
try {
    $null = $src.Seek([int64]$lx.Offset, [IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] 8388608
    [int64]$read = 0
    while ($read -lt $linuxBytes) {
        $want = [int][math]::Min([int64]8388608, [int64]($linuxBytes - $read))
        $n = $src.Read($buf, 0, $want)
        if ($n -le 0) { break }
        $null = $sha.TransformBlock($buf, 0, $n, $null, 0)
        $read += $n
    }
    $null = $sha.TransformFinalBlock(@(), 0, 0)
} finally { $src.Dispose() }
$onDisk = ($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join ''
$onFile = (Get-FileHash $linuxImg -Algorithm SHA256).Hash.ToLower()
Say "  partition : $onDisk"
Say "  image     : $onFile"
if ($onDisk -eq $onFile) { Say "`nVERIFIED - the Linux partition matches the image byte for byte." Green }
else { Say "`nMISMATCH - the partition does NOT match the image. Do not ship this stick." Red; exit 1 }
