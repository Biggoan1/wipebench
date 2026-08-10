<#
.SYNOPSIS
  Capture a reference WipeBench stick into a reusable "golden image" set so a whole new
  stick can be built later from Windows alone (no Linux box required).

.DESCRIPTION
  Reads the raw Linux (ext4) partition - the one Windows can't otherwise reproduce -
  straight off the physical disk and stores it as a gzip-compressed image, then copies
  the WinPE boot partition as files and (optionally) the big NTFS payload. Writes a
  wipebench-image.json manifest describing the set.

  Pair with Build-WipeBenchUSB.ps1, which restores what this captures.

.EXAMPLE
  .\Capture-WipeBenchImage.ps1 -DiskNumber 1 -OutputRoot D:\WipeBenchImages
  .\Capture-WipeBenchImage.ps1 -DiskNumber 1 -OutputRoot D:\WipeBenchImages -IncludePayload

.NOTES
  Run elevated. Read-only with respect to the source stick.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$DiskNumber,
    [Parameter(Mandatory)][string]$OutputRoot,
    [int]$LinuxPartitionNumber = 2,
    [int]$WinPEPartitionNumber = 1,
    [int]$PayloadPartitionNumber = 3,
    [switch]$IncludePayload,
    [switch]$NoCompress,
    [string]$Version = (Get-Date -Format "yyyy-MM-dd")
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated PowerShell session."
}

$disk = Get-Disk -Number $DiskNumber
Say "Source disk $DiskNumber : $($disk.FriendlyName) ($([math]::Round($disk.Size/1GB,1)) GB, $($disk.BusType))" Cyan
if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is a boot/system disk - refusing." }

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

# ---------- 1. Linux partition -> raw (optionally gzip) image ----------
$lp = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $LinuxPartitionNumber
$imgName = if ($NoCompress) { "linux-part.img" } else { "linux-part.img.gz" }
$imgPath = Join-Path $OutputRoot $imgName
Say "Capturing Linux partition ($([math]::Round($lp.Size/1GB,1)) GB) -> $imgName ..." Cyan

$src = New-Object IO.FileStream("\\.\PhysicalDrive$DiskNumber", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
try {
    $null = $src.Seek([int64]$lp.Offset, [IO.SeekOrigin]::Begin)
    $raw = New-Object IO.FileStream($imgPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    $out = if ($NoCompress) { $raw } else { New-Object IO.Compression.GZipStream($raw, [IO.Compression.CompressionLevel]::Optimal) }
    try {
        $chunk = 8388608
        $buf = New-Object byte[] $chunk
        [int64]$left = $lp.Size
        [int64]$done = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($left -gt 0) {
            $want = [int][Math]::Min([int64]$chunk, $left)
            $n = $src.Read($buf, 0, $want)
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)
            $left -= $n; $done += $n
            if ($done % (512MB) -lt $chunk) {
                Write-Progress -Activity "Capturing Linux partition" -Status "$([math]::Round($done/1GB,1)) GB" -PercentComplete (100 * $done / $lp.Size)
            }
        }
        Write-Progress -Activity "Capturing Linux partition" -Completed
        Say ("  done in {0:N0}s" -f $sw.Elapsed.TotalSeconds) Green
    } finally { $out.Dispose(); if (-not $NoCompress) { $raw.Dispose() } }
} finally { $src.Dispose() }

$sha = (Get-FileHash $imgPath -Algorithm SHA256).Hash

# ---------- 2. WinPE partition -> files (+ FAT32 volume serial) ----------
# GRUB's WinPE chainload entry finds that partition by fs-UUID, which on FAT32 comes from
# the 4-byte volume serial in the BPB (offset 0x43). Capture it so the rebuilt stick can
# reuse the same ID and the chainload keeps working.
$pePart = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $WinPEPartitionNumber
$peSerial = $null
try {
    # Raw device I/O must be sector-aligned: read the whole boot sector, then pick out 0x43.
    $s = New-Object IO.FileStream("\\.\PhysicalDrive$DiskNumber", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $null = $s.Seek([int64]$pePart.Offset, [IO.SeekOrigin]::Begin)
        $sector = New-Object byte[] 512
        $null = $s.Read($sector, 0, 512)
        $peSerial = (0x43..0x46 | ForEach-Object { $sector[$_].ToString("x2") }) -join ''
        Say "WinPE FAT32 volume serial: $peSerial" Gray
    } finally { $s.Dispose() }
} catch { Say "Could not read the WinPE volume serial: $_" Yellow }

$peSrc = $pePart.DriveLetter
$peDir = Join-Path $OutputRoot "winpe"
if ($peSrc) {
    Say "Capturing WinPE partition ${peSrc}: -> winpe\ ..." Cyan
    New-Item -ItemType Directory -Force -Path $peDir | Out-Null
    robocopy "${peSrc}:\" $peDir /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    Say "  $((Get-ChildItem $peDir -Recurse -File | Measure-Object).Count) files" Green
} else { Say "WinPE partition has no drive letter - skipped." Yellow }

# ---------- 3. Payload (optional; it's big) ----------
$payDir = Join-Path $OutputRoot "payload"
if ($IncludePayload) {
    $paySrc = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PayloadPartitionNumber).DriveLetter
    if ($paySrc) {
        Say "Capturing payload partition ${paySrc}: -> payload\ (this is the big one) ..." Cyan
        New-Item -ItemType Directory -Force -Path $payDir | Out-Null
        robocopy "${paySrc}:\" $payDir /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        Say "  $([math]::Round((Get-ChildItem $payDir -Recurse -File | Measure-Object -Sum Length).Sum/1GB,1)) GB" Green
    }
}

# ---------- 4. Manifest ----------
$manifest = [ordered]@{
    version           = $Version
    captured_utc      = (Get-Date).ToUniversalTime().ToString("s") + "Z"
    captured_from     = "$($disk.FriendlyName) (disk $DiskNumber)"
    linux_image       = $imgName
    linux_image_bytes = (Get-Item $imgPath).Length
    linux_part_bytes  = [int64]$lp.Size
    linux_sha256      = $sha
    compressed        = (-not $NoCompress.IsPresent)
    winpe_dir         = if (Test-Path $peDir) { "winpe" } else { $null }
    winpe_vol_serial  = $peSerial   # 4 bytes at BPB 0x43 - restored so GRUB's UUID search still matches
    payload_dir       = if (Test-Path $payDir) { "payload" } else { $null }
    partitions        = @(
        @{ n = 1; label = "WINPE"; fs = "FAT32"; size_gb = 2 },
        @{ n = 2; label = "linux"; fs = "ext4(raw image)"; size_gb = [math]::Round($lp.Size / 1GB, 0) },
        @{ n = 3; label = "WIPEBENCHNTFS"; fs = "NTFS"; size_gb = "rest" }
    )
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputRoot "wipebench-image.json") -Encoding UTF8

Say ""
Say "Golden image set written to $OutputRoot" Green
Say "  $imgName  ($([math]::Round((Get-Item $imgPath).Length/1GB,2)) GB)  sha256=$($sha.Substring(0,16))..." Gray
Say "Build a new stick with:  .\Build-WipeBenchUSB.ps1 -DiskNumber <n> -ImageRoot $OutputRoot" Cyan
