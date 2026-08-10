## I know it's called Dell Cleaner... it started with dells and grew up. It's ok!

$Manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer

# ---- CONFIG: where your driver packs live on the USB ----
# Example layout:
#   R:\Drivers\Precision_5570\
#   R:\Drivers\Common\
$Global:DriversRoot = "R:\Drivers"


function Test-ExitCode {
    param([int]$Code, [string]$What)
    if ($Code -ne 0) { throw "$What failed. Exit code: $Code" }
}

# -------------------------
# USB lock file safety check
# Finds whichever disk contains WIPEBENCH_USB.lock and returns its disk number.
# Call before any diskpart/partition operation to ensure we never touch the USB itself.
function Get-USBDiskNumber {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        # Skip drives that aren't ready/accessible (e.g. RAW Linux ext4 partition)
        try {
            if (-not $drive.IsReady) { continue }
        } catch { continue }

        $lockFile = Join-Path $drive.Name "WIPEBENCH_USB.lock"
        if (Test-Path $lockFile) {
            $letter = $drive.Name.TrimEnd('\').TrimEnd(':')
            $part = Get-Partition | Where-Object { $_.DriveLetter -eq $letter } | Select-Object -First 1
            if ($null -ne $part) {
                Write-Host "USB lock file found on drive ${letter}: (Disk $($part.DiskNumber))" -ForegroundColor DarkGray
                return $part.DiskNumber
            }
        }
    }
    Write-Host "WARNING: WIPEBENCH_USB.lock not found on any drive. Cannot verify USB disk number." -ForegroundColor Yellow
    return $null
}

function Assert-SafeToDisk0 {
    $usbDisk = Get-USBDiskNumber
    if ($null -eq $usbDisk) {
        Write-Host "WARNING: USB lock file not found - proceeding without USB disk safety check." -ForegroundColor Yellow
        return  # warn but don't block  lock file may not exist on older USB builds
    }
    if ($usbDisk -eq 0) {
        Write-Host "SAFETY ABORT: USB drive is enumerated as Disk 0. Wiping Disk 0 would destroy the USB!" -ForegroundColor Red
        Write-Host "Remove the USB, check disk enumeration, and try again." -ForegroundColor Red
        Write-Host "Press any key to exit..." -ForegroundColor Yellow; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }
    Write-Host "Safety check passed: USB is Disk $usbDisk, target is Disk 0." -ForegroundColor Green
}

# NOTE: two helpers were removed from the public source - one deriving a Dell Express
# Service Code from the service tag, and a SHA-512 wrapper. Together they reconstructed the
# BIOS admin password from identifiers printed on the outside of the chassis, so publishing
# them would defeat the password entirely. Neither was called by anything else in this file.
# BIOS password handling lives in /opt/wipebench/bios_clear.sh and bios_set.sh on the Linux
# partition, which are not distributed - see README, "BIOS scripts".

# ----------------------------
# Image classification helpers
# ----------------------------
function Test-IsLaptop {
    [CmdletBinding()] param()

    # Primary: enclosure chassis types
    try {
        $enc = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop
        $laptopTypes = 8,9,10,14,30,31,32   # Portable, Laptop, Notebook, SubNotebook, Tablet, Convertible, Detachable
        if ($enc.ChassisTypes -and ($enc.ChassisTypes | Where-Object { $_ -in $laptopTypes })) { return $true }
    } catch { }

    # Fallback: ComputerSystem type
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $typeEx = $null; $type = $null
        if ($cs.PSObject.Properties.Match('PCSystemTypeEx').Count) { $typeEx = [int]$cs.PCSystemTypeEx }
        if ($cs.PSObject.Properties.Match('PCSystemType').Count)   { $type   = [int]$cs.PCSystemType }
        if ($typeEx -eq 2 -or $type -eq 2) { return $true }  # 2 = Mobile
    } catch { }

    return $false
}

function Test-IsDesktopWorkstation {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Model)

    if (Test-IsLaptop) { return $false }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $typeEx = $null; $type = $null
    if ($cs.PSObject.Properties.Match('PCSystemTypeEx').Count) { $typeEx = [int]$cs.PCSystemTypeEx }
    if ($cs.PSObject.Properties.Match('PCSystemType').Count)   { $type   = [int]$cs.PCSystemType }

    $workstationFlag = ($typeEx -eq 7 -or $type -eq 7) # 7 = Workstation
    $modelIsWorkstation = ($Model -match '(?i)\bWorkstation\b')
    return ($workstationFlag -or $modelIsWorkstation)
}

function Get-ImageIndex {
    [CmdletBinding()] param([int]$Override)

    if ($PSBoundParameters.ContainsKey('Override')) { return [int]$Override }

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $model = ($cs.Model -as [string])
    if ($null -eq $model) { $model = '' }

    $isLaptop = Test-IsLaptop
    $isPrecision = ($model -match '(?i)\bPrecision\b')
    $isDesktopWS = Test-IsDesktopWorkstation -Model $model

    Write-Host (
        "Classification  Manufacturer: {0}; Model: {1}; IsLaptop: {2}; DesktopWS: {3}" -f $cs.Manufacturer, $model, $isLaptop, $isDesktopWS
    ) -ForegroundColor DarkGray

    if ($isLaptop) { return 5 }
    elseif ($isPrecision -and $isDesktopWS) { return 9 }
    else { return 5 }
}


# -------------------------
# UEFI layout (no DiskPart)
function Initialize-UEFIDisk {
    param([Parameter(Mandatory=$true)][int]$DiskNumber)

    Write-Host "Partitioning disk $DiskNumber..." -ForegroundColor Yellow

    $d = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $d) { throw "Disk $DiskNumber not found." }

    if ($d.IsOffline)  { Set-Disk -Number $DiskNumber -IsOffline:$false }
    if ($d.IsReadOnly) { Set-Disk -Number $DiskNumber -IsReadOnly:$false }

    Clear-Disk      -Number $DiskNumber -RemoveData -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT

    # ESP 100MB FAT32 -> S:
    $esp = New-Partition -DiskNumber $DiskNumber -Size 100MB `
                         -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" -AssignDriveLetter
    Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    Set-DriveLetterSafely -Current $esp.DriveLetter -New 'S'

    # MSR 16MB
    $null = New-Partition -DiskNumber $DiskNumber -Size 16MB `
                          -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}"

    # Primary -> C:
    $pri = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $pri -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-DriveLetterSafely -Current $pri.DriveLetter -New 'C'

    Write-Host "Partitioning complete (ESP=S:, Windows=C:)." -ForegroundColor Green
}

# ===== MODEL-BASED DRIVER DEPLOYMENT FOR DELL =====

function Add-DellModelDrivers {
    param(
        [string]$OfflineWindows = "C:\",
        [string]$DriversRoot = $Global:DriversRoot
    )

    Write-Host ""
    Write-Host "=== Adding model-specific drivers to offline Windows ===" -ForegroundColor Cyan
    Write-Host "Offline Windows: $OfflineWindows"
    Write-Host "Drivers root   : $DriversRoot"
    Write-Host ""

    if (-not (Test-Path $DriversRoot)) {
        Write-Host "Drivers root '$DriversRoot' not found. Skipping driver injection." -ForegroundColor Yellow
        return
    }

    # CustomJohn is an OPT-IN folder that only lands on personal sticks (Build-WipeBenchUSB.ps1
    # -IncludeCustom). If it carries its own Drivers tree, treat it as an ADDITIONAL source -
    # searched AFTER the master, so it fills gaps without ever shadowing a team pack. This is
    # how personal-only hardware (e.g. a whitebox board that no fleet machine uses) gets its
    # drivers without occupying ~3GB on all 30 production sticks.
    $script:SearchRoots = @($DriversRoot)
    $customDrivers = Join-Path (Split-Path $DriversRoot -Parent) 'CustomJohn\Drivers'
    if (Test-Path $customDrivers) {
        $script:SearchRoots += $customDrivers
        Write-Host "CustomJohn drivers present - also searching $customDrivers" -ForegroundColor DarkCyan
    }

    # Detect model
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $rawModel = ($cs.Model).Trim()
    } catch {
        Write-Host "Failed to get model via CIM: $_" -ForegroundColor Red
        return
    }

    if (-not $rawModel) {
        Write-Host "Model string is empty; cannot map to driver folder." -ForegroundColor Red
        return
    }

    Write-Host "Detected model: '$rawModel'"

    # ---- Resolve the driver pack: SystemSKU first, model name second -------------
    # The machine's SystemSKU is exact. Model strings are not: Dell folds "Plus" variants
    # under the plain name, Surface Pro 7+ normalises its "+" away, Surface packs split by
    # CPU (AMD/Intel, ARM/Intel), and the 2025 rebrand renamed Latitude/Precision to
    # Dell Pro. Any of those silently yields NO drivers when matching by name alone.
    # sku-index.json is written by WipeBenchDrivers.ps1 -Action Index. The original
    # name-based lookup is kept underneath as the fallback, so worst case is today's
    # behaviour.
    $modelDriverPath = $null
    $resolvedBy = $null

    $sku = $null
    try {
        $sku = $cs.SystemSKUNumber
        if (-not $sku) { $sku = (Get-CimInstance -ClassName Win32_ComputerSystemProduct).SKUNumber }
        if ($sku) { $sku = ($sku -replace '[^A-Za-z0-9]', '').ToUpper() }
    } catch { }
    if ($sku) { Write-Host "System SKU     : $sku" } else { Write-Host "System SKU     : (not reported)" -ForegroundColor DarkGray }

    $sawAnyIndex = $false
    foreach ($root in $script:SearchRoots) {
        if ($modelDriverPath) { break }
        $skuIndexPath = Join-Path $root "sku-index.json"
        if (-not ($sku -and (Test-Path $skuIndexPath))) { continue }
        $sawAnyIndex = $true
        try {
            $skuIndex = Get-Content $skuIndexPath -Raw | ConvertFrom-Json
            $hit = $skuIndex.skus.PSObject.Properties | Where-Object { $_.Name -eq $sku } | Select-Object -First 1
            if ($hit) {
                $candidate = Join-Path $root $hit.Value.folder
                if (Test-Path $candidate) {
                    $modelDriverPath = $candidate
                    $resolvedBy = "SKU $sku -> $($hit.Value.folder) [$($hit.Value.source)]"
                    Write-Host "SKU index hit  : $resolvedBy" -ForegroundColor Green
                }
                else {
                    Write-Host "SKU index names '$($hit.Value.folder)' but that folder is missing under $root." -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "SKU $sku is not in $skuIndexPath - falling back to model name." -ForegroundColor DarkGray
            }
        }
        catch { Write-Host "sku-index.json unreadable ($_) - falling back to model name." -ForegroundColor Yellow }
    }
    if ($sku -and -not $sawAnyIndex) {
        Write-Host "No sku-index.json under any driver root - falling back to model name." -ForegroundColor DarkGray
    }

    # Fallback: normalize model name to folder name, e.g. "Precision 5570" -> "Precision_5570"
    $safeModel = $rawModel -replace '[^A-Za-z0-9\-]+', '_'
    if (-not $modelDriverPath) {
        Write-Host "Normalized model folder: '$safeModel'"
        foreach ($root in $script:SearchRoots) {
            $byName = Join-Path $root $safeModel
            if (Test-Path $byName) { $modelDriverPath = $byName; $resolvedBy = "model name -> $safeModel"; break }
        }
    }

    # Last resort: whitebox / DIY machines. Consumer boards leave the model string as a
    # placeholder ("System Product Name", "To Be Filled By O.E.M.") and report a useless
    # SKU, so the motherboard is the only real identifier. Never used for OEM machines,
    # which resolve above.
    if (-not $modelDriverPath) {
        $placeholders = @('System Product Name', 'To Be Filled By O.E.M.', 'Default string', 'To be filled by O.E.M.', '')
        try { $board = (Get-CimInstance -ClassName Win32_BaseBoard).Product } catch { $board = $null }
        if ($board) {
            $safeBoard = $board.Trim() -replace '[^A-Za-z0-9\-]+', '_'
            $byBoard = $null
            foreach ($root in $script:SearchRoots) {
                $c = Join-Path $root $safeBoard
                if (Test-Path $c) { $byBoard = $c; break }
            }
            if ($byBoard) {
                $modelDriverPath = $byBoard
                $resolvedBy = "baseboard -> $safeBoard"
                Write-Host "Whitebox fallback: model '$rawModel' matched nothing; using motherboard '$board'." -ForegroundColor Green
            }
            elseif ($placeholders -contains $rawModel) {
                Write-Host "Model string is a placeholder and no pack named '$safeBoard' exists for this board." -ForegroundColor Yellow
            }
        }
    }

    if (-not $modelDriverPath) {
        Write-Host "No driver pack for this machine (SKU '$sku', model folder '$safeModel')." -ForegroundColor Yellow
        foreach ($root in $script:SearchRoots) {
            Write-Host "Available driver folders under ${root}:" -ForegroundColor Yellow
            Get-ChildItem -Directory $root -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        }
        Write-Host "Skipping model-specific driver injection."
    }
    else {
        Write-Host "Using model driver path: $modelDriverPath  ($resolvedBy)"
        $imageRoot = $OfflineWindows.TrimEnd('\')
        $args = "/Image:`"$imageRoot`" /Add-Driver /Driver:`"$modelDriverPath`" /Recurse /ForceUnsigned"
        Write-Host "Running DISM for model drivers..." -ForegroundColor Cyan
        $proc = Start-Process -FilePath dism.exe -ArgumentList $args -Wait -NoNewWindow -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-Host "Model driver injection completed successfully." -ForegroundColor Green
        }
        else {
            Write-Host "DISM failed for model drivers with exit code $($proc.ExitCode)." -ForegroundColor Red
        }
    }

    # Optional "Common" driver pack
    $commonPath = Join-Path $DriversRoot "Common"
    if (Test-Path $commonPath) {
        Write-Host ""
        Write-Host "Applying 'Common' driver pack from '$commonPath'..." -ForegroundColor Cyan
        $imageRoot = $OfflineWindows.TrimEnd('\')
        $args = "/Image:`"$imageRoot`" /Add-Driver /Driver:`"$commonPath`" /Recurse /ForceUnsigned"
        $proc = Start-Process -FilePath dism.exe -ArgumentList $args -Wait -NoNewWindow -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-Host "Common driver injection completed successfully." -ForegroundColor Green
        }
        else {
            Write-Host "DISM failed for Common drivers with exit code $($proc.ExitCode)." -ForegroundColor Red
        }
    }
    else {
        Write-Host "No 'Common' driver folder found; skipping common drivers." -ForegroundColor DarkGray
    }

    Write-Host "=== Driver deployment stage complete ===" -ForegroundColor Cyan
}

# ===== DELL PATH =====

function Handle-Dell {

    [CmdletBinding()]
    param(
        [string]$DriversRoot = "R:\Drivers",         # e.g., R:\Drivers\Precision_5570\ and \Common
        [string]$InstallWim  = "R:\Sources\install.wim",
        [int]   $ImageIndexOverride                  # optional: force an index (skips auto-detect)
    )
    Write-Host "Doing Dell Things!"

    $ImageIndex = Get-ImageIndex
    $partitions = Get-CimInstance -Query "SELECT * FROM Win32_DiskPartition WHERE DiskIndex = 0"

    #
    # CASE 1: DISK 0 HAS PARTITIONS  WIPE PATH
    #
    if ($partitions) {
        Write-Host "Disk 0 has partitions. Pleaes reboot in to Linux and wipe the disk." -ForegroundColor DarkRed

# NOTE: a block that derived the Dell BIOS admin password from machine-visible
        # identifiers used to sit here, commented out. It has been REMOVED from the public
        # source: the inputs are printed on the outside of the chassis, so publishing the
        # derivation would let anyone with physical access compute the password.
        # BIOS password handling lives in /opt/wipebench/bios_clear.sh and bios_set.sh on
        # the Linux partition, which are not distributed - see README "BIOS scripts".
                exit 0
    }

    #
    # CASE 2: DISK 0 HAS NO PARTITIONS  INSTALL WIN11 + DRIVERS + SECURE BOOT
    #
    Write-Host "Disk 0 has no partitions. Auto-installing Windows 11."

    Write-Host "Disk Party!" -ForegroundColor Yellow
    Assert-SafeToDisk0
    #diskpart /s W:\Disk.txt
    Initialize-UEFIDisk -DiskNumber '0'
    Write-Host "Disk has been partied!" -ForegroundColor Yellow
    Write-Host "Applying Windows 11 image..." -ForegroundColor Yellow
    # Apply WIM
    if (-not (Test-Path $InstallWim)) {
        throw "Install WIM not found at '$InstallWim'."
    }
    Write-Host ("Applying Windows image (Index {0})..." -f $ImageIndex) -ForegroundColor Yellow
    $applyArgs = "/Apply-Image /ImageFile:`"$InstallWim`" /Index:$ImageIndex /ApplyDir:C:\"
    $p = Start-Process -FilePath dism.exe -ArgumentList $applyArgs -Wait -NoNewWindow -PassThru
    Test-ExitCode -Code $p.ExitCode -What "Applying image"
    Write-Host "Windows image applied." -ForegroundColor Green
    
    #Start-Process dism -ArgumentList "/Apply-Image /ImageFile:R:\Sources\install.wim /Index:1 /ApplyDir:C:\" -Wait -NoNewWindow

    # Inject model-based drivers into the offline C:\ image
    Write-Host "Injecting model-specific drivers into offline Windows..." -ForegroundColor Yellow
    Add-DellModelDrivers -OfflineWindows "C:\" -DriversRoot $Global:DriversRoot

    # Boot files
    Write-Host "Configuring UEFI boot..." -ForegroundColor Yellow
    bcdboot C:\Windows /s S: /f UEFI

    # Stage optional custom provisioning if D:\CustomJohn is present.
    Invoke-CustomJohnStaging -TargetDrive 'C'

    # Enable Secure Boot only in the blank-disk/install path
    Write-Host "Enabling Secure Boot..." -ForegroundColor Yellow
    Start-Process x:\cctk\x86_64\cctk.exe `
        -ArgumentList "--secureboot=enable" `
        -Wait -NoNewWindow
    Write-Host "Secure Boot enabled." -ForegroundColor Yellow

    # Disable AutoOn
    Write-Host "Disable AutoOn..." -ForegroundColor Yellow
    Start-Process x:\cctk\x86_64\cctk.exe `
        -ArgumentList "--autoon=disabled" `
        -Wait -NoNewWindow
    Write-Host "AutoOn Disabled." -ForegroundColor Yellow

    Write-Host "Windows 11 load complete! Safe to remove the USB." -ForegroundColor Yellow
    Write-Host "Press any key to continue..." -ForegroundColor Yellow; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Stop-Computer
}

# ===== MICROSOFT / SURFACE PATH (unchanged from your original) =====

function Handle-Microsoft {
    Write-Host "Doing Microsoft Things!"
    if (Test-Path "X:\Windows\SurfaceEnterpriseManagement\SEMM Resources\*.pkg") {
        Start-Process X:\Windows\SurfaceEnterpriseManagement\SEMM.bat -Wait
    }
    else {
        Start-Process "X:\Windows\SurfaceDataEraser\devcon.exe" -ArgumentList "Remove =Net > init.log" -Wait -NoNewWindow
    }

    Import-Module "X:\Windows\SurfaceDataEraser\SurfaceDriversInstallation.psm1" -ErrorAction SilentlyContinue
    if (Get-Module -Name "SurfaceDriversInstallation") {
        Write-Host "Please wait while we set up the environment..." -NoNewline
        $succeed = Install-SurfaceDrivers
        if ($succeed) {
            Write-Host "Done"
            Go
        }
        else {
            Write-Host ""
            Write-Host "This image is not compatible with this device. Please use a different image option available in Surface Data Eraser application and try again."
            Write-Host ""
        }
    }
}

function Go {
    $partitions = Get-CimInstance -Query "SELECT * FROM Win32_DiskPartition WHERE DiskIndex = 0"
    if ($partitions) {
        Write-Host "Disk 0 has the following partitions:"
        $partitions | Format-Table -Property PartitionNumber, DriveLetter, Size
        Set-Location "X:\Windows\SurfaceDataEraser\"
        .\SurfaceDataEraser.ps1 -Force
        GoMore
    }
}

function GoMore {
    if (Test-Path -Path C:\) {
        Write-Host "Disk 0 has no partitions."
            Write-Host "PC will load Windows 11 - Do NOT remove the thumbdrive" -ForegroundColor Yellow
            Write-Host "Disk Party!" -ForegroundColor Yellow
            Assert-SafeToDisk0
            if ($Manufacturer -like "Microsoft*") { diskpart /s w:\Disk.txt }
            else {Initialize-UEFIDisk -DiskNumber '0'} 
            #diskpart /s w:\Disk.txt
            Write-Host "Disk has been partied!" -ForegroundColor Yellow
            Write-Host "Installing Windows 11" -ForegroundColor Yellow
            Start-Process dism -ArgumentList "/Apply-Image /ImageFile:R:\Sources\install.wim /Index:1 /ApplyDir:C:\" -Wait -NoNewWindow
            if ($Manufacturer -like "Microsoft*") { Add-DellModelDrivers -DriversRoot R:\Drivers}
            else { Add-DellModelDrivers -OfflineWindows -DriversRoot R:\Drivers }
            Write-Host "Configuring boot things." -ForegroundColor Yellow
            bcdboot C:\Windows /s S: /f UEFI
            # Stage optional custom provisioning if D:\CustomJohn is present.
            Invoke-CustomJohnStaging -TargetDrive 'C'

            Write-Host "Windows load complete! It's safe to remove the thumb drive." -ForegroundColor Yellow
            Write-Host "I'm all done! Powering off!" -ForegroundColor Yellow
            Start-Sleep -Seconds 10
            Stop-Computer
    }
}

# ===== PANASONIC PATH =====

function Handle-Pana {
    [CmdletBinding()]
    param(
        [string]$DriversRoot = "R:\Drivers",
        [string]$InstallWim  = "R:\Sources\install.wim",
        [int]   $ImageIndexOverride
    )
    Write-Host "Doing Panasonic Things!" -ForegroundColor Cyan

    $ImageIndex = Get-ImageIndex
    $partitions = Get-CimInstance -Query "SELECT * FROM Win32_DiskPartition WHERE DiskIndex = 0"

    #
    # CASE 1: DISK 0 HAS PARTITIONS  needs wipe first
    #
    if ($partitions) {
        Write-Host "Disk 0 has partitions. Please reboot into Linux and wipe the disk." -ForegroundColor DarkRed
        exit 0
    }

    #
    # CASE 2: DISK 0 HAS NO PARTITIONS  INSTALL WIN11 + DRIVERS
    #
    Write-Host "Disk 0 has no partitions. Auto-installing Windows 11." -ForegroundColor Yellow

    Write-Host "Disk Party!" -ForegroundColor Yellow
    Assert-SafeToDisk0
    diskpart /s W:\Disk.txt
    Write-Host "Disk has been partied!" -ForegroundColor Yellow

    # Apply WIM
    if (-not (Test-Path $InstallWim)) {
        throw "Install WIM not found at '$InstallWim'."
    }
    Write-Host ("Applying Windows image (Index {0})..." -f $ImageIndex) -ForegroundColor Yellow
    $applyArgs = "/Apply-Image /ImageFile:`"$InstallWim`" /Index:$ImageIndex /ApplyDir:C:\"
    $p = Start-Process -FilePath dism.exe -ArgumentList $applyArgs -Wait -NoNewWindow -PassThru
    Test-ExitCode -Code $p.ExitCode -What "Applying image"
    Write-Host "Windows image applied." -ForegroundColor Green

    # Inject model-specific drivers (e.g. R:\Drivers\Panasonic_FZ-G1\)
    Write-Host "Injecting model-specific drivers into offline Windows..." -ForegroundColor Yellow
    Add-DellModelDrivers -OfflineWindows "C:\" -DriversRoot $Global:DriversRoot

    # Boot files
    Write-Host "Configuring UEFI boot..." -ForegroundColor Yellow
    bcdboot C:\Windows /s S: /f UEFI

    # Stage optional custom provisioning if D:\CustomJohn is present.
    Invoke-CustomJohnStaging -TargetDrive 'C'

    # Note: No CCTK on Panasonic  Secure Boot and AutoOn not managed here
    Write-Host "Panasonic: skipping CCTK steps (not supported)." -ForegroundColor DarkGray

    Write-Host "Windows 11 load complete! Safe to remove the USB." -ForegroundColor Green
    Write-Host "Press any key to continue..." -ForegroundColor Yellow; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Stop-Computer
}

# ===== OPTIONAL: custom provisioning staging (CustomJohn) =====
# If D:\CustomJohn exists, run its Stage-Provisioning.ps1 to copy the
# unattend.xml + Install-Apps.ps1 onto the freshly applied Windows image.
# If the folder is absent, this is silently skipped.
function Invoke-CustomJohnStaging {
    param([string]$TargetDrive = 'C')

    $customDir = 'R:\CustomJohn'
    $stager    = Join-Path $customDir 'Stage-Provisioning.ps1'

    if (-not (Test-Path $customDir)) {
        Write-Host "CustomJohn folder not found ($customDir) - skipping custom staging." -ForegroundColor DarkGray
        return
    }
    if (-not (Test-Path $stager)) {
        Write-Host "CustomJohn present but Stage-Provisioning.ps1 missing - skipping custom staging." -ForegroundColor Yellow
        return
    }

    Write-Host "CustomJohn folder found - staging provisioning files onto ${TargetDrive}:..." -ForegroundColor Cyan
    # Run as a child process so the stager exit calls do not terminate this script.
    $stageArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$stager`" -TargetDrive $TargetDrive -SourceDir `"$customDir`""
    $proc = Start-Process -FilePath powershell.exe -ArgumentList $stageArgs -Wait -NoNewWindow -PassThru
    if ($proc.ExitCode -eq 0) {
        Write-Host "Custom provisioning staged." -ForegroundColor Green
    } else {
        Write-Host "Custom staging reported exit code $($proc.ExitCode)." -ForegroundColor Yellow
    }
}

# ===== MAIN =====

if ($Manufacturer -like "Dell*") {
    Handle-Dell
}
elseif ($Manufacturer -like "Microsoft*") {
    Handle-Microsoft
}
elseif ($Manufacturer -like "Panasonic*") {
    Handle-Pana
}
else {
    Write-Host "Unrecognized manufacturer: '$Manufacturer'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "No automated Windows deployment handler for this device." -ForegroundColor Yellow
    Write-Host "If this is a Getac or other wipe-only device, the drive has already" -ForegroundColor Yellow
    Write-Host "been wiped by the Linux stage. This device does not receive a Windows load." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Press any key to power off..." -ForegroundColor Yellow; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Stop-Computer
}
