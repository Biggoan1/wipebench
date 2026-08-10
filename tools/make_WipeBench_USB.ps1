<#
.SYNOPSIS
  Builds a WipeBench USB: P1=WINPE(FAT32,2GB,W:), P2=Linux placeholder (8GB, unformatted), P3=NTFS(rest,T:).
  Single-confirm by disk selection; no second confirmation.

.USAGE
  # Interactive (lists disks and prompts):
  .\make_WipeBench_USB.ps1

  # Non-interactive (specify a disk directly):
  .\make_WipeBench_USB.ps1 -DiskNumber 2

.PARAMETERS
  -DiskNumber           Optional. If provided, skips the selection prompt.
  -P1SizeGB             Size of Partition 1 (default 2).
  -P2SizeGB             Size of Partition 2 (default 8).
  -P1Label              Label for Partition 1 (default "WINPE").
  -P3Label              Label for Partition 3 (default "WIPEBENCHNTFS").
  -P1Letter             Drive letter for P1 (default "W").
  -P3Letter             Drive letter for P3 (default "T").
  -StageP2Fat32         If set, P2 will be FAT32 formatted and assigned a letter (default: leave unformatted for Linux).
  -P2Letter             Drive letter for P2 if -StageP2Fat32 (default "L").
  -AllowSystemDisk      If set, allows operating on boot/system disks (NOT recommended).

.NOTES
  Run in an elevated PowerShell session. This is DESTRUCTIVE for the selected disk.
#>

[CmdletBinding()]
param(
    [int]$DiskNumber = -1,
    [int]$P1SizeGB = 2,
    [int]$P2SizeGB = 8,
    [string]$P1Label = "WINPE",
    [string]$P3Label = "WIPEBENCHNTFS",
    [ValidatePattern('^[A-Z]$')] [string]$P1Letter = "W",
    [ValidatePattern('^[A-Z]$')] [string]$P3Letter = "T",
    [switch]$StageP2Fat32,
    [ValidatePattern('^[A-Z]$')] [string]$P2Letter = "L",
    [switch]$AllowSystemDisk,
    [string]$StagingRoot,
    [switch]$SkipPayload      # caller supplies the payload itself (Build-WipeBenchUSB.ps1)
)

$ErrorActionPreference = 'Stop'

function Show-Disks {
    Write-Host "=== Available Disks ===" -ForegroundColor Cyan
    Get-Disk |
        Sort-Object Number |
        Select-Object Number, FriendlyName, BusType, PartitionStyle, Size, IsBoot, IsSystem, IsOffline, IsReadOnly |
        Format-Table -AutoSize
}

function Select-DiskInteractive {
    [int]$sel = -1
    while ($sel -lt 0) {
        $inputVal = Read-Host "Enter the DISK NUMBER to ERASE and initialize as GPT (or 'q' to quit)"
        if ($inputVal -eq 'q') { Write-Host "Aborted."; return -1 }

        $parsed = 0
        if (-not [int]::TryParse($inputVal, [ref]$parsed)) {
            Write-Warning "Please enter a valid integer disk number."
            continue
        }

        try {
            $d = Get-Disk -Number $parsed -ErrorAction Stop
        } catch {
            Write-Warning "Disk $parsed not found. Please try again."
            continue
        }

        if (-not $script:AllowSystemDisk) {
            if ($d.IsBoot -or $d.IsSystem) {
                Write-Error "Refusing to operate on a boot/system disk (Disk $parsed). Pick a different disk, or rerun with -AllowSystemDisk."
                continue
            }
        }

        $sel = $parsed
    }
    return $sel
}

function Ensure-DiskWritable {
    param([int]$Number)
    $d = Get-Disk -Number $Number -ErrorAction Stop
    if ($d.IsOffline) {
        Write-Host "Bringing disk ${Number} online..."
        Set-Disk -Number $Number -IsOffline:$false
        $d = Get-Disk -Number $Number
    }
    if ($d.IsReadOnly) {
        Write-Host "Clearing read-only on disk ${Number}..."
        Set-Disk -Number $Number -IsReadOnly:$false
        $d = Get-Disk -Number $Number
    }
    return $d
}

function Clear-And-InitGpt {
    param([int]$Number)

    Write-Host "Clearing disk ${Number} (RemoveData + RemoveOEM)..." -ForegroundColor Yellow
    Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false

    # Refresh storage cache
    Update-HostStorageCache
    Start-Sleep -Milliseconds 400

    Write-Host "Initializing disk ${Number} as GPT..." -ForegroundColor Yellow # <---------- 60% of the time this works everytime! The linux build double checks this. 
    try {
        Initialize-Disk -Number $Number -PartitionStyle GPT -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -match 'already been initialized') {
            Write-Host "Disk ${Number} already initialized; continuing." -ForegroundColor DarkYellow
        } else {
            throw
        }
    }

    # If anything survived, remove it
    Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue |
        Remove-Partition -Confirm:$false -ErrorAction SilentlyContinue

    # Force re-enumeration (helps some USB controllers)
    try {
        Set-Disk -Number $Number -IsOffline $true -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
        Set-Disk -Number $Number -IsOffline $false -ErrorAction SilentlyContinue
    } catch {}

    Update-HostStorageCache
    Start-Sleep -Milliseconds 400

    # Sanity: check free space
    $diskState = Get-Disk -Number $Number
    $free = $diskState.LargestFreeExtent
    if (-not $free -or $free -lt 100MB) {
        Write-Host "No usable free extent after clear/init. Trying a DiskPart clean fallback..." -ForegroundColor DarkYellow

        # Fallback: force a diskpart clean (some firmwares respond better)
        $dp = @"
select disk $Number
clean
convert gpt
exit
"@
        $tmp = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tmp -Value $dp -Encoding ASCII
        try {
            Start-Process -FilePath diskpart.exe -ArgumentList "/s `"$tmp`"" -Wait -NoNewWindow
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }

        Update-HostStorageCache
        Start-Sleep -Milliseconds 500

        # Re-check free space
        $diskState = Get-Disk -Number $Number
        $free = $diskState.LargestFreeExtent
        if (-not $free -or $free -lt 100MB) {
            throw "Disk $Number still shows insufficient free space after DiskPart fallback. PartitionStyle=$($diskState.PartitionStyle)"
        }
    }
}

function Build-WipeBenchLayout {
    param(
        [int]$Number,
        [int]$P1SizeGB, [int]$P2SizeGB,
        [string]$P1Label, [string]$P3Label,
        [string]$P1Letter, [string]$P3Letter,
        [switch]$StageP2Fat32, [string]$P2Letter
    )

    $gb = 1GB

    # ---- Partition 1: WINPE FAT32 (P1SizeGB) -> P1Letter ----
    Write-Host ("Creating Partition 1 (FAT32 {0}GB) -> {1}:  {2}" -f $P1SizeGB, $P1Letter, $P1Label)
    $p1 = New-Partition -DiskNumber $Number -Size ([int64]$P1SizeGB * $gb) -AssignDriveLetter
    # Force the letter after creation (more reliable than specifying during creation)
    Set-Partition -DiskNumber $Number -PartitionNumber $p1.PartitionNumber -NewDriveLetter $P1Letter
    Format-Volume -DriveLetter $P1Letter -FileSystem FAT32 -NewFileSystemLabel $P1Label -Confirm:$false | Out-Null

    # ---- Partition 2: Linux placeholder (P2SizeGB) ----
    Write-Host ("Creating Partition 2 (Linux placeholder {0}GB) - leaving unformatted" -f $P2SizeGB)
    $p2 = New-Partition -DiskNumber $Number -Size ([int64]$P2SizeGB * $gb)

    if ($StageP2Fat32) {
        Write-Host ("Staging P2 as FAT32 -> {0}:  WIPEBNCHTUX" -f $P2Letter)
        Set-Partition -DiskNumber $Number -PartitionNumber $p2.PartitionNumber -NewDriveLetter $P2Letter
        Format-Volume -DriveLetter $P2Letter -FileSystem FAT32 -NewFileSystemLabel 'WIPEBNCHTUX' -Confirm:$false | Out-Null
    }

    # ---- Partition 3: NTFS remainder -> P3Letter ----
    Write-Host ("Creating Partition 3 (NTFS remainder) -> {0}:  {1}" -f $P3Letter, $P3Label)
    $p3 = New-Partition -DiskNumber $Number -UseMaximumSize -AssignDriveLetter
    Set-Partition -DiskNumber $Number -PartitionNumber $p3.PartitionNumber -NewDriveLetter $P3Letter
    Format-Volume -DriveLetter $P3Letter -FileSystem NTFS -NewFileSystemLabel $P3Label -Confirm:$false | Out-Null
}

try {
    # 1) Selection (no second confirmation)
    if ($DiskNumber -lt 0) {
        Show-Disks
        $sel = Select-DiskInteractive
        if ($sel -lt 0) { return }
        $DiskNumber = $sel
    } else {
        # Validate provided disk and block system/boot unless allowed
        $d0 = Get-Disk -Number $DiskNumber -ErrorAction Stop
        if (-not $AllowSystemDisk -and ($d0.IsBoot -or $d0.IsSystem)) {
            throw "Refusing to operate on a boot/system disk (Disk $DiskNumber). Re-run with -AllowSystemDisk if you are absolutely sure."
        }
    }

    $disk = Get-Disk -Number $DiskNumber
    Write-Host ("`nProceeding to ERASE Disk {0}:" -f $DiskNumber) -ForegroundColor Yellow
    $disk |
      Select-Object Number, FriendlyName, BusType, PartitionStyle, Size, IsBoot, IsSystem, IsOffline, IsReadOnly |
      Format-Table -AutoSize

    # 2) Ensure writable & online
    $disk = Ensure-DiskWritable -Number $DiskNumber

    # 3) Destructive clear + GPT init
    Clear-And-InitGpt -Number $DiskNumber

    # 4) Build the three partitions
    Build-WipeBenchLayout -Number $DiskNumber `
        -P1SizeGB $P1SizeGB -P2SizeGB $P2SizeGB `
        -P1Label $P1Label -P3Label $P3Label `
        -P1Letter $P1Letter -P3Letter $P3Letter `
        -StageP2Fat32:$StageP2Fat32 -P2Letter $P2Letter

    Write-Host ("`nDone. Created {0}: {1} and {2}: {3}. P2 ready for Linux." -f $P1Letter, $P1Label, $P3Letter, $P3Label) -ForegroundColor Green
}
catch {
    Write-Error $_
    exit 1
}

# Define letters (if you're using parameters, keep using $P1Letter/$P3Letter)
$P1Letter = $P1Letter # e.g., "W"
$P3Letter = $P3Letter # e.g., "T"

# Resolve roots
$P1Root    = ("{0}:\" -f $P1Letter)      # W:\
$P3Root    = ("{0}:\" -f $P3Letter)      # T:\
$P3Sources = Join-Path $P3Root 'sources' # T:\sources
$P3Drivers = Join-Path $P3Root 'Drivers' # T:\Drivers

# Verify destinations exist (P1 and P3 should be created by your partition step)
if (-not (Test-Path $P1Root)) { throw "Destination $P1Root does not exist. Was P1 created and assigned letter $P1Letter?" }
if (-not (Test-Path $P3Root)) { throw "Destination $P3Root does not exist. Was P3 created and assigned letter $P3Letter?" }

# Create sources folder structure on P3
if (-not (Test-Path $P3Sources)) { New-Item -ItemType Directory -Path $P3Sources -Force | Out-Null }
if (-not (Test-Path $P3Drivers)) { New-Item -ItemType Directory -Path $P3Drivers -Force | Out-Null }

# ---- locate the staging tree instead of hard-coding C:\Temp\STAGING -------------------
# Looks for a folder that actually contains the payload (a Boots\ tree and/or an
# install.wim), checking: -StagingRoot if given, then next to this script, then any
# subdirectory of it, then the script's parent, then the old C:\Temp\STAGING default.
function Find-StagingRoot {
    param([string]$Explicit)

    function Test-Staging([string]$p) {
        if (-not $p -or -not (Test-Path $p)) { return $false }
        if (Test-Path (Join-Path $p 'Boots')) { return $true }
        if (Get-ChildItem $p -Filter 'install.wim' -File -ErrorAction SilentlyContinue) { return $true }
        if (Get-ChildItem (Join-Path $p 'sources') -Filter 'install.wim' -File -ErrorAction SilentlyContinue) { return $true }
        return $false
    }

    $roots = @()
    if ($Explicit) { $roots += $Explicit }
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $roots += @(
        (Join-Path $here 'STAGING'),
        $here,
        (Join-Path (Split-Path $here -Parent) 'STAGING'),
        (Split-Path $here -Parent)
    )
    # any subdirectory of the script folder that looks like a staging tree
    $roots += @(Get-ChildItem $here -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $roots += 'C:\Temp\STAGING'   # the original hard-coded location, kept last

    foreach ($r in $roots) {
        if (Test-Staging $r) { return (Resolve-Path $r).Path }
    }
    return $null
}

$stage = if ($SkipPayload) { $null } else { Find-StagingRoot -Explicit $StagingRoot }
if ($stage) { Write-Host "Staging root: $stage" -ForegroundColor Cyan }
elseif ($SkipPayload) {
    Write-Host "Payload copy skipped - the caller is supplying it." -ForegroundColor DarkGray
}
else {
    Write-Host "No staging tree found (looked for a folder containing Boots\ or install.wim)." -ForegroundColor DarkYellow
    Write-Host "Partitions are created; payload copy will be skipped. Pass -StagingRoot <path> to supply one." -ForegroundColor DarkYellow
}

$BootsSrc      = if ($stage) { Join-Path $stage 'Boots' } else { $null }
$DriversSrc    = if ($stage) { Join-Path $stage 'Drivers' } else { $null }
$InstallWimSrc = $null
if ($stage) {
    foreach ($cand in @((Join-Path $stage 'Install.wim'), (Join-Path $stage 'sources\install.wim'))) {
        if (Test-Path $cand) { $InstallWimSrc = (Resolve-Path $cand).Path; break }
    }
}

# Build absolute destination exclusions for 'System Volume Information'
$P1_SVI = "$P1Root" + "System Volume Information"
$P3_SVI = "$P3Root" + "System Volume Information"

if ($BootsSrc -and (Test-Path $BootsSrc)) {
    Write-Host "Copying Boot Files to $P1Root"
    robocopy $BootsSrc $P1Root *.* `
      /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NP /MT:16 /XJ /NFL /ETA /XA:SH /XD "$P1_SVI"
} elseif (-not $SkipPayload) {
    Write-Host "No Boots\ tree in the staging root - skipping boot file copy." -ForegroundColor DarkYellow
}

if ($InstallWimSrc) {
    Write-Host "Copying Install.wim to $P3Sources  (from $InstallWimSrc)"
    # For single file with robocopy: source folder + leaf file
    $srcFolder = Split-Path $InstallWimSrc -Parent
    $srcFile   = Split-Path $InstallWimSrc -Leaf
    robocopy $srcFolder $P3Sources $srcFile `
      /R:2 /W:1 /NP /MT:16 /XJ /NDL /XA:SH /XD "$P3_SVI"
} elseif (-not $SkipPayload) {
    Write-Host "No install.wim in the staging root - skipping." -ForegroundColor DarkYellow
}


if (-not $SkipPayload) { Write-Host "Copying Driver Files to $P3Drivers" }
if ($DriversSrc -and (Test-Path $DriversSrc)) {
    robocopy $DriversSrc $P3Drivers *.* `
      /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NP /MT:16 /XJ /NFL /ETA /XA:SH /XD "$P3_SVI"
} elseif (-not $SkipPayload) {
    Write-Host "Drivers source not found at $DriversSrc - skipping." -ForegroundColor DarkYellow
}

New-Item  $P1Root\WIPEBENCH_USB.lock -ItemType File -Force | Out-Null
New-Item  $P3Root\WIPEBENCH_USB.lock -ItemType File -Force | Out-Null


Write-Host "USB created successfully."

<#
    robocopy C:\Temp\STAGINGdrivers T:\Drivers *.* `
      /E /COPY:DAT /DCOPY:DAT /R:4 /W:1 /NP /MT:16 /XJ /NFL /ETA  

#>
