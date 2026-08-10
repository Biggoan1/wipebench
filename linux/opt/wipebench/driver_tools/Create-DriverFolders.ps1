#!/usr/bin/env pwsh
# Create-DriverFolders.ps1 - Auto-create driver folder structure for WipeBench
# Works with PowerShell 5.1+ and PowerShell 7+

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="Source path containing driver files")]
    [ValidateScript({Test-Path $_})]
    [string]$DriversPath,
    
    [Parameter(Mandatory=$false, Position=1, HelpMessage="Output path for organized drivers")]
    [string]$OutputPath = ".\drivers",
    
    [Parameter(Mandatory=$false)]
    [string]$Manufacturer,
    
    [Parameter(Mandatory=$false)]
    [string]$Model
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = "1.0"

function Write-Banner {
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "              WipeBench Driver Folder Creator v$ScriptVersion" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ""
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "  ℹ $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

function Get-SystemInfo {
    $wmi = Get-CimInstance -ClassName Win32_ComputerSystem
    
    $mfg = $wmi.Manufacturer
    $mdl = $wmi.Model
    
    # Normalize manufacturer
    switch -Wildcard ($mfg) {
        "*Dell*" { $mfg = "Dell" }
        "*HP*" { $mfg = "HP" }
        "*Hewlett*" { $mfg = "HP" }
        "*Lenovo*" { $mfg = "Lenovo" }
        "*Microsoft*" { $mfg = "Microsoft" }
        "*Panasonic*" { 
            $mfg = "Panasonic"
            # Clean up Panasonic model names
            $mdl = $mdl -replace '-\d+$', '' -replace '[^a-zA-Z0-9]', ''
        }
    }
    
    # Remove special characters from model
    $mdl = $mdl -replace '[^a-zA-Z0-9]', ''
    
    return @{
        Manufacturer = $mfg
        Model = $mdl
    }
}

# Main script
try {
    Write-Banner
    
    # Verify source path
    if (-not (Test-Path $DriversPath)) {
        Write-Fail "Source path does not exist: $DriversPath"
        exit 1
    }
    
    # Check for .inf files
    $infFiles = Get-ChildItem -Path $DriversPath -Filter "*.inf" -Recurse -File
    
    if ($infFiles.Count -eq 0) {
        Write-Fail "No .inf files found in source directory!"
        Write-Info "Make sure the source path contains driver files."
        exit 1
    }
    
    Write-Success "Found $($infFiles.Count) .inf files in source directory"
    
    # Detect or prompt for system info
    Write-Info "Detecting system information..."
    
    if (-not $Manufacturer -or -not $Model) {
        $sysInfo = Get-SystemInfo
        
        if (-not $Manufacturer) {
            if ($sysInfo.Manufacturer -and $sysInfo.Manufacturer -ne "To Be Filled By O.E.M.") {
                $Manufacturer = $sysInfo.Manufacturer
            } else {
                $Manufacturer = Read-Host "Enter manufacturer name (Dell, HP, Lenovo, etc.)"
            }
        }
        
        if (-not $Model) {
            if ($sysInfo.Model -and $sysInfo.Model -ne "To Be Filled By O.E.M.") {
                $Model = $sysInfo.Model
            } else {
                $Model = Read-Host "Enter model name"
            }
        }
    }
    
    # Clean up names
    $Manufacturer = $Manufacturer.Trim()
    $Model = $Model -replace '[^a-zA-Z0-9]', ''
    
    # Show configuration
    Write-Host ""
    Write-Info "Detected Configuration:"
    Write-Host "  Manufacturer: $Manufacturer" -ForegroundColor White
    Write-Host "  Model: $Model" -ForegroundColor White
    Write-Host "  Source: $DriversPath" -ForegroundColor White
    Write-Host "  Output: $OutputPath\$Manufacturer\$Model" -ForegroundColor White
    Write-Host ""
    
    # Confirm
    $confirm = Read-Host "Continue with this configuration? (Y/n)"
    if ($confirm -and $confirm -notmatch '^[Yy]') {
        Write-Info "Cancelled by user"
        exit 0
    }
    
    # Create target directory
    $targetDir = Join-Path $OutputPath "$Manufacturer\$Model"
    Write-Info "Creating directory structure..."
    
    $null = New-Item -ItemType Directory -Path $targetDir -Force
    Write-Success "Created: $targetDir"
    
    # Copy drivers with progress
    Write-Info "Copying driver files..."
    Write-Host ""
    
    $sourceFiles = Get-ChildItem -Path $DriversPath -Recurse -File
    $totalFiles = $sourceFiles.Count
    $current = 0
    
    foreach ($file in $sourceFiles) {
        $current++
        $percentComplete = [math]::Round(($current / $totalFiles) * 100)
        
        Write-Progress -Activity "Copying drivers" -Status "$current of $totalFiles files" -PercentComplete $percentComplete
        
        $relativePath = $file.FullName.Substring($DriversPath.Length).TrimStart('\', '/')
        $targetFile = Join-Path $targetDir $relativePath
        $targetFileDir = Split-Path $targetFile -Parent
        
        if (-not (Test-Path $targetFileDir)) {
            $null = New-Item -ItemType Directory -Path $targetFileDir -Force
        }
        
        Copy-Item -Path $file.FullName -Destination $targetFile -Force
    }
    
    Write-Progress -Activity "Copying drivers" -Completed
    
    Write-Success "Drivers copied successfully"
    
    # Count results
    $totalFilesCopied = (Get-ChildItem -Path $targetDir -Recurse -File).Count
    $infFilesCopied = (Get-ChildItem -Path $targetDir -Recurse -Filter "*.inf" -File).Count
    
    Write-Host ""
    Write-Success "Driver folder creation complete!"
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Location: $targetDir" -ForegroundColor White
    Write-Host "  Total files: $totalFilesCopied" -ForegroundColor White
    Write-Host "  Driver files (.inf): $infFilesCopied" -ForegroundColor White
    Write-Host ""
    
    # Create metadata file
    $metadata = @"
WipeBench Driver Package
========================

Manufacturer: $Manufacturer
Model: $Model
Created: $(Get-Date)
Source: $DriversPath
Total Files: $totalFilesCopied
Driver Files: $infFilesCopied

This driver package will be automatically detected and injected by WipeBench
during Windows installation on matching hardware.
"@
    
    $metadata | Out-File -FilePath (Join-Path $targetDir "DRIVER_INFO.txt") -Encoding UTF8
    Write-Success "Created metadata file: DRIVER_INFO.txt"
    
    # Next steps
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Cyan
    
    if ($OutputPath -match '[A-Z]:\\' -and (Get-PSDrive | Where-Object {$_.Root -eq ($OutputPath.Substring(0,3))}).DisplayRoot) {
        Write-Host "  1. Eject USB safely from Windows" -ForegroundColor White
        Write-Host "  2. USB is ready for WipeBench!" -ForegroundColor White
    } else {
        Write-Host "  1. Copy to USB: robocopy `"$OutputPath`" `"E:\drivers`" /E" -ForegroundColor White
        Write-Host "  2. Eject USB safely" -ForegroundColor White
    }
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Fail "ERROR: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}