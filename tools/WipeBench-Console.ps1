<#
.SYNOPSIS
  WipeBench Console - one window for building sticks and managing the driver repository.

.DESCRIPTION
  A thin GUI over the scripts that already do the work (Capture-WipeBenchImage.ps1,
  Build-WipeBenchUSB.ps1, WipeBenchDrivers.ps1). It deliberately does NOT reimplement any
  of their logic - it runs them as background jobs and streams their output into the log
  pane, so there is exactly one source of truth and the CLI stays usable on its own.

  Tab 1  Build Stick  - pick a disk, capture a golden image, build a stick
  Tab 2  Drivers      - audit the repo, refresh the Dell catalog, search/download packs

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\WipeBench-Console.ps1
  .\WipeBench-Console.ps1 -SelfTest     # build the UI and exit (no window) - for CI/checks

.NOTES
  Run elevated (disk operations). Windows PowerShell 5.1, WinForms, pure ASCII.
#>
[CmdletBinding()]
param(
    [string]$ToolDir = $PSScriptRoot,
    [string]$ImageRoot = "C:\WipeBenchImages",
    [string]$DriversRoot = "C:\WipeBenchImages\payload\Drivers",   # master repo on the build machine
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# Guard the paths BEFORE anything uses them. Join-Path throws
# "Cannot bind argument to parameter 'Path' because it is an empty string" on a blank
# value, which surfaces as an unhandled exception on the first button click.
if ([string]::IsNullOrWhiteSpace($ToolDir)) {
    $ToolDir = if ($PSScriptRoot) { $PSScriptRoot }
               elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent }
               else { (Get-Location).Path }
}
if ([string]::IsNullOrWhiteSpace($ImageRoot))   { $ImageRoot = "C:\WipeBenchImages" }
if ([string]::IsNullOrWhiteSpace($DriversRoot)) { $DriversRoot = "C:\WipeBenchImages\payload\Drivers" }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# This is a GUI: hide the console window powershell.exe put behind it. Everything the
# tools print is streamed into the log pane, so the console is just noise.
if (-not $SelfTest) {
    try {
        Add-Type -Name W -Namespace Con -MemberDefinition '
            [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
            [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);' -ErrorAction SilentlyContinue
        $consoleHandle = [Con.W]::GetConsoleWindow()
        if ($consoleHandle -ne [IntPtr]::Zero) { [void][Con.W]::ShowWindow($consoleHandle, 0) }   # 0 = SW_HIDE
    } catch { }
}
# Routes click-handler errors to our ThreadException handler instead of a .NET crash box.
# Can only be set once per process and only before the first window exists, so a second
# run inside the same PowerShell session throws - harmless, ignore it.
try { [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }

$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# NO ELEVATION PROMPT AT STARTUP (changed 2026-08-10). Most of what this window does -
# the whole Drivers tab: audit, catalog, search, download, update, sync - runs perfectly
# well as a standard user, so demanding admin just to OPEN the console was wrong. Only
# the disk operations need the token, and they now ask for it at the moment they are
# used (see Start-Tool / Invoke-RelaunchElevated below).

function Invoke-RelaunchElevated {
    # Reopen this console with an elevated token, preserving the paths in use. Returns
    # $true when the elevated copy has started, in which case THIS instance should close.
    # Returns $false if the user dismissed the UAC prompt or it failed - we then stay
    # open as a standard user rather than quitting out from under them.
    try {
        $hostExe = (Get-Process -Id $PID).Path
        if (-not $hostExe) { $hostExe = 'powershell.exe' }
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                     '-ToolDir', "`"$ToolDir`"", '-ImageRoot', "`"$ImageRoot`"", '-DriversRoot', "`"$DriversRoot`"")
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $argList -WindowStyle Hidden -ErrorAction Stop
        return $true
    }
    catch {
        # 1223 = ERROR_CANCELLED: the user clicked No on the UAC dialog. That is a normal
        # answer, not a fault, so log it quietly instead of throwing an error box.
        $cancelled = ($_.Exception.NativeErrorCode -eq 1223) -or ($_.Exception.Message -match 'cancell?ed')
        if ($cancelled) {
            Write-Log "Elevation cancelled - staying in standard-user mode." 'Gold'
        }
        else {
            [void][Windows.Forms.MessageBox]::Show(
                "Could not relaunch elevated: $($_.Exception.Message)`n`nRight-click the script and 'Run as administrator'.",
                "Elevation failed", 'OK', 'Error')
        }
        return $false
    }
}

# ---------------------------------------------------------------- shell ----
$form = New-Object Windows.Forms.Form
$form.Text = "WipeBench Console"
$form.Size = New-Object Drawing.Size(940, 720)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font("Segoe UI", 9)

$log = New-Object Windows.Forms.RichTextBox
$log.Dock = 'Fill'
$log.ReadOnly = $true
$log.BackColor = [Drawing.Color]::FromArgb(20, 20, 20)
$log.ForeColor = [Drawing.Color]::Gainsboro
$log.Font = New-Object Drawing.Font("Consolas", 9)
$log.DetectUrls = $false

$script:btnCancel = New-Object Windows.Forms.ToolStripButton
$script:btnCancel.Text = "CANCEL"
$script:btnCancel.Enabled = $false
$script:btnCancel.BackColor = [Drawing.Color]::FromArgb(150, 40, 40)
$script:btnCancel.ForeColor = [Drawing.Color]::White
$script:btnCancel.Alignment = 'Right'
$script:btnCancel.DisplayStyle = 'Text'
$script:btnCancel.Add_Click({ Stop-RunningTool })

$logPanel = New-Object Windows.Forms.Panel
$logPanel.Dock = 'Bottom'
$logPanel.Height = 260
$logPanel.Controls.Add($log)

$status = New-Object Windows.Forms.StatusStrip
$statusLabel = New-Object Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = if ($IsElevated) { "Ready (Administrator)" } else { "Ready - standard user; disk actions will ask for admin" }
$statusLabel.Spring = $true
$statusLabel.TextAlign = 'MiddleLeft'
# long steps (an 8GB image restore, a 147GB payload copy) emit NOTHING for minutes, so
# show a moving bar + elapsed time - otherwise the window looks hung.
$script:progressBar = New-Object Windows.Forms.ToolStripProgressBar
$script:progressBar.Style = 'Marquee'
$script:progressBar.MarqueeAnimationSpeed = 30
$script:progressBar.Visible = $false
$script:progressBar.Width = 160
$script:elapsedLabel = New-Object Windows.Forms.ToolStripStatusLabel
$script:elapsedLabel.Text = ""
$null = $status.Items.AddRange(@($statusLabel, $script:elapsedLabel, $script:progressBar, $script:btnCancel))

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabBuild = New-Object Windows.Forms.TabPage; $tabBuild.Text = "Build Stick"; $tabBuild.Padding = '10,10,10,10'
$tabDrv = New-Object Windows.Forms.TabPage; $tabDrv.Text = "Drivers"; $tabDrv.Padding = '10,10,10,10'
$tabs.TabPages.AddRange(@($tabBuild, $tabDrv))

# same transform DellCleaner.ps1 uses on the WMI model string
function ConvertTo-DriverFolderName([string]$m) {
    if ([string]::IsNullOrWhiteSpace($m)) { return $null }
    ($m.Trim() -replace '[^A-Za-z0-9\-]+', '_')
}

function Write-Log {
    param([string]$Text, [string]$Color = 'Gainsboro')
    if (-not $Text) { return }
    $log.SelectionStart = $log.TextLength
    $log.SelectionColor = [Drawing.Color]::FromName($Color)
    $log.AppendText($Text.TrimEnd() + "`n")
    $log.ScrollToCaret()
}

# ------------------------------------------------- background job plumbing ----
$script:job = $null
$script:jobStart = $null
$script:jobWhat = ""
$script:phase = ""
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 400

# A background job's grandchildren (robocopy, dism, curl, msiexec, expand) are NOT killed
# by Stop-Job - they keep chewing. Walk the tree from this process and take them with it.
function Get-DescendantProcesses([int]$RootPid) {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId, Name)
    $found = @(); $queue = @($RootPid); $seen = @{}
    while ($queue.Count) {
        $p = $queue[0]
        $queue = if ($queue.Count -gt 1) { $queue[1..($queue.Count - 1)] } else { @() }
        foreach ($c in ($all | Where-Object { $_.ParentProcessId -eq $p })) {
            if ($seen.ContainsKey($c.ProcessId)) { continue }
            $seen[$c.ProcessId] = $true
            $found += $c
            $queue += $c.ProcessId
        }
    }
    $found
}

function Stop-RunningTool {
    if (-not $script:job -or $script:job.State -ne 'Running') { return }
    $what = $statusLabel.Text -replace '^Running: ', ''
    $answer = [Windows.Forms.MessageBox]::Show(
        "Cancel '$what'?`n`nAnything already written stays written - a cancelled BUILD leaves the stick incomplete and it will need building again. A cancelled download or driver import is safe.",
        "Cancel running task", 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    Write-Log "`n*** cancelling ***" 'Gold'
    $timer.Stop()
    $kids = @(Get-DescendantProcesses -RootPid $PID |
        Where-Object { $_.Name -match '^(robocopy|dism|dismhost|curl|msiexec|expand|nvme)' })
    foreach ($k in $kids) {
        Write-Log ("  killing {0} (pid {1})" -f $k.Name, $k.ProcessId) 'Gold'
        Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Stop-Job $script:job -ErrorAction SilentlyContinue
    Receive-Job $script:job -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "$_" }
    Remove-Job $script:job -Force -ErrorAction SilentlyContinue
    $script:job = $null
    $script:onDone = $null
    Write-Log "*** cancelled ***" 'Tomato'
    if ($kids | Where-Object { $_.Name -match 'dism' }) {
        Write-Log "A DISM operation was interrupted - if you were servicing a WIM, run" 'Gold'
        Write-Log "  Dismount-WindowsImage -Path <mount> -Discard   (or Clear-WindowsCorruptMountPoint)" 'Gold'
    }
    Set-Busy $false
}

function Set-Busy([bool]$busy, [string]$what = "") {
    $statusLabel.Text = if ($busy) { "Running: $what" } elseif ($IsElevated) { "Ready (Administrator)" } else { "Ready - standard user; disk actions will ask for admin" }
    if ($script:progressBar) { $script:progressBar.Visible = $busy }
    if (-not $busy -and $script:elapsedLabel) { $script:elapsedLabel.Text = "" }
    foreach ($b in $script:actionButtons) { $b.Enabled = -not $busy }
    if ($script:btnCancel) { $script:btnCancel.Enabled = $busy }
}

# actions that genuinely need the elevated token
$script:NeedsAdmin = @('Build-WipeBenchUSB.ps1', 'Capture-WipeBenchImage.ps1')

function Start-Tool {
    # NOTE: do NOT name parameters $Args or $Script - both are automatic variables and
    # PowerShell 7 will try to bind the remaining-args array into them and hard-fail.
    param([string]$ToolName, [hashtable]$ToolArgs, [string]$What)
    if ($script:job -and $script:job.State -eq 'Running') {
        [void][Windows.Forms.MessageBox]::Show("Something is already running - wait for it to finish.", "Busy")
        return
    }
    if ([string]::IsNullOrWhiteSpace($ToolDir)) { Write-Log "Tool directory is not set - reopen the console from its folder." 'Tomato'; return }
    $path = Join-Path $ToolDir $ToolName
    if (-not (Test-Path $path)) { Write-Log "Missing tool: $path" 'Tomato'; return }
    $peDriver = ($ToolArgs.ContainsKey('Action') -and $ToolArgs['Action'] -eq 'PEDriver')
    if (-not $IsElevated -and (($script:NeedsAdmin -contains $ToolName) -or $peDriver)) {
        # Ask for the token HERE, at the point of use, rather than at startup. Answering
        # Yes reopens the console elevated; the disk must be reselected afterwards, which
        # is deliberate - a destructive action should not be inherited across a relaunch.
        $answer = [Windows.Forms.MessageBox]::Show(
            "'$What' needs Administrator rights.`n`nReopen WipeBench Console as Administrator now?`n`nThe window will reopen elevated - reselect the disk and click again.",
            "Administrator required", 'YesNo', 'Warning')
        if ($answer -eq 'Yes' -and (Invoke-RelaunchElevated)) {
            Write-Log "Reopening elevated..." 'DeepSkyBlue'
            $form.Close()
            return
        }
        Write-Log "SKIPPED: '$What' needs elevation. Everything on the Drivers tab still works without it." 'Gold'
        return
    }
    Write-Log ("`n=== $What ===") 'DeepSkyBlue'
    Write-Log ("    $ToolName " + (($ToolArgs.GetEnumerator() | ForEach-Object {
        if ($_.Value -is [switch] -or $_.Value -is [bool]) { "-$($_.Key)" } else { "-$($_.Key) '$($_.Value)'" } }) -join ' ')) 'Gray'
    $script:job = Start-Job -ScriptBlock {
        param($p, $a)
        $ErrorActionPreference = 'Continue'
        # *>&1 merges EVERY stream (error, warning, verbose, debug and - crucially -
        # information, which is where Write-Host goes). With plain 2>&1 all the coloured
        # progress lines stayed in the parent console and never reached the log pane.
        # Out-String -Stream then renders formatting records as real text rather than
        # type names (FormatStartData / MSFT_Volume / FileInfo).
        & $p @a *>&1 | Out-String -Stream -Width 160
    } -ArgumentList $path, $ToolArgs
    $script:jobStart = Get-Date
    $script:jobWhat = $What
    $script:phase = ""
    try { $script:progressBar.Style = 'Marquee'; $script:progressBar.Value = 0 } catch { }
    Set-Busy $true $What
    $timer.Start()
}

$timer.Add_Tick({
    if (-not $script:job) { $timer.Stop(); return }
    if ($script:jobStart) {
        $el = (Get-Date) - $script:jobStart
        $script:elapsedLabel.Text = "{0:mm\:ss} elapsed" -f $el
        $statusLabel.Text = "Running: $($script:jobWhat)$(if ($script:phase) { "  -  $($script:phase)" })"
    }
    Receive-Job $script:job -ErrorAction SilentlyContinue | ForEach-Object {
        $line = "$_"
        # "[12/22] Latitude 5450" - a counted item: show position AND drive a real bar
        if ($line -match '\[(\d+)/(\d+)\]\s*(.+?)\s*=*$') {
            $script:phase = "$($matches[1]) of $($matches[2]): $($matches[3])"
            try {
                $script:progressBar.Style = 'Continuous'
                $script:progressBar.Maximum = [int]$matches[2]
                $script:progressBar.Value = [Math]::Min([int]$matches[1], [int]$matches[2])
            } catch { }
        }
        # "[2] Restoring Linux/ext4 partition" style headings - surface the current one in
        # the status bar so a silent 2-minute step still says what it is
        elseif ($line -match '^\s*\[(\d+)\]\s*(.+)$') { $script:phase = "step $($matches[1]): $($matches[2])" }
        $c = 'Gainsboro'
        if ($line -match 'ERROR|FAIL|Exception|NOT SANITIZED|refus|cannot|MISMATCH') { $c = 'Tomato' }
        elseif ($line -match 'WARN|OUTDATED|skipped|NO MATCH|EMPTY') { $c = 'Gold' }
        elseif ($line -match 'COMPLETE|OK$|imported|current|hash OK|Green') { $c = 'LightGreen' }
        Write-Log $line $c
    }
    if ($script:job.State -ne 'Running') {
        $timer.Stop()
        Receive-Job $script:job -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "$_" }
        $took = if ($script:jobStart) { " in {0:mm\:ss}" -f ((Get-Date) - $script:jobStart) } else { "" }
        Write-Log "--- finished ($($script:job.State))$took ---" 'DeepSkyBlue'
        Remove-Job $script:job -Force -ErrorAction SilentlyContinue
        $script:job = $null
        Set-Busy $false
        if ($script:onDone) { & $script:onDone; $script:onDone = $null }
    }
})

# ================================================================ BUILD tab ==
$diskGrid = New-Object Windows.Forms.DataGridView
$diskGrid.Location = '10,30'; $diskGrid.Size = New-Object Drawing.Size(880, 150)
$diskGrid.ReadOnly = $true; $diskGrid.AllowUserToAddRows = $false; $diskGrid.RowHeadersVisible = $false
$diskGrid.SelectionMode = 'FullRowSelect'; $diskGrid.MultiSelect = $false
$diskGrid.AutoSizeColumnsMode = 'Fill'; $diskGrid.BackgroundColor = [Drawing.Color]::White

$lblDisks = New-Object Windows.Forms.Label
$lblDisks.Text = "Target disk (USB only - boot/system disks are refused):"
$lblDisks.Location = '10,8'; $lblDisks.AutoSize = $true

function Update-Disks {
    $diskGrid.DataSource = $null
    $rows = New-Object Collections.ArrayList
    $hidden = @()
    foreach ($d in (Get-Disk | Sort-Object Number)) {
        # The boot/system disk is never a valid target - don't even offer it. The build
        # script refuses it too, but the safest control is the one you can't click.
        if ($d.IsBoot -or $d.IsSystem) {
            $hidden += "disk $($d.Number) ($($d.FriendlyName))"
            continue
        }
        $null = $rows.Add([pscustomobject]@{
            Disk    = $d.Number
            Model   = $d.FriendlyName
            SizeGB  = [math]::Round($d.Size / 1GB, 1)
            Bus     = $d.BusType
            Fits    = if ($d.Size -ge 200GB) { "" } else { "small - use Skip drivers" }
            Layout  = ((Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
                        ForEach-Object { if ($_.DriveLetter) { "$($_.DriveLetter):" } else { "raw" } }) -join ' ')
        })
    }
    $diskGrid.DataSource = [Collections.ArrayList]$rows
    $lblDisks.Text = "Target disk" + $(if ($hidden.Count) {
            "  (system disk hidden: " + ($hidden -join ', ') + ")"
        } else { " (USB only - boot/system disks are refused)" })
    if (-not $rows.Count) { Write-Log "No eligible disks - plug in a USB stick and hit Refresh disks." 'Gold' }
}

function Get-SelectedDisk {
    if ($diskGrid.SelectedRows.Count -lt 1) { return $null }
    $r = $diskGrid.SelectedRows[0]
    $n = [int]$r.Cells['Disk'].Value
    $d = Get-Disk -Number $n -ErrorAction SilentlyContinue
    [pscustomobject]@{ Number = $n; Model = $r.Cells['Model'].Value
                       Protected = [bool]($d -and ($d.IsBoot -or $d.IsSystem)) }
}

$txtImage = New-Object Windows.Forms.TextBox
$txtImage.Location = '120,196'; $txtImage.Width = 620; $txtImage.Text = $ImageRoot
$lblImage = New-Object Windows.Forms.Label
$lblImage.Text = "Image set:"; $lblImage.Location = '10,199'; $lblImage.AutoSize = $true

$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = "Browse..."; $btnBrowse.Location = '750,194'; $btnBrowse.Width = 90
$btnBrowse.Add_Click({
    $fb = New-Object Windows.Forms.FolderBrowserDialog
    if ($fb.ShowDialog() -eq 'OK') { $txtImage.Text = $fb.SelectedPath; Update-ImageInfo }
})

$lblImageInfo = New-Object Windows.Forms.Label
$lblImageInfo.Location = '120,224'; $lblImageInfo.Size = New-Object Drawing.Size(720, 34)
$lblImageInfo.ForeColor = [Drawing.Color]::DimGray

function Update-ImageInfo {
    if ([string]::IsNullOrWhiteSpace($txtImage.Text)) { $lblImageInfo.Text = "Set an image-set folder (Browse...)."; return }
    $mfp = Join-Path $txtImage.Text "wipebench-image.json"
    if (-not (Test-Path $mfp)) { $lblImageInfo.Text = "No image set here yet - use 'Capture image' to make one."; return }
    try {
        $mf = Get-Content $mfp -Raw | ConvertFrom-Json
        $hasPay = if ($mf.payload_dir) { "with payload" } else { "NO payload (stick will boot but cannot reimage)" }
        $lblImageInfo.Text = "version $($mf.version) - captured $($mf.captured_utc) from $($mf.captured_from)`r`n$hasPay"
    } catch { $lblImageInfo.Text = "manifest unreadable: $_" }
}

$chkSkipPayload = New-Object Windows.Forms.CheckBox
$chkSkipPayload.Text = "Skip payload entirely"; $chkSkipPayload.Location = '120,266'; $chkSkipPayload.AutoSize = $true
$chkSkipDrivers = New-Object Windows.Forms.CheckBox
$chkSkipDrivers.Text = "Skip drivers (copy install.wim only - fast test build)"; $chkSkipDrivers.Location = '300,266'; $chkSkipDrivers.AutoSize = $true
$chkIncludeCustom = New-Object Windows.Forms.CheckBox
$chkIncludeCustom.Text = "Include CustomJohn (my personal stick)"; $chkIncludeCustom.Location = '300,292'; $chkIncludeCustom.AutoSize = $true

$chkIncludePayload = New-Object Windows.Forms.CheckBox
$chkIncludePayload.Text = "Capture payload too (~150 GB, slow)"; $chkIncludePayload.Location = '120,292'; $chkIncludePayload.AutoSize = $true

$btnRefreshDisks = New-Object Windows.Forms.Button
$btnRefreshDisks.Text = "Refresh disks"; $btnRefreshDisks.Location = '10,326'; $btnRefreshDisks.Width = 110
$btnRefreshDisks.Add_Click({ Update-Disks })

$btnCapture = New-Object Windows.Forms.Button
$btnCapture.Text = "Capture image from selected disk"; $btnCapture.Location = '130,326'; $btnCapture.Width = 250
$btnCapture.Add_Click({
    $d = Get-SelectedDisk
    if (-not $d) { [void][Windows.Forms.MessageBox]::Show("Pick the REFERENCE stick to capture from.", "No disk selected"); return }
    $a = @{ DiskNumber = $d.Number; OutputRoot = $txtImage.Text; NoCompress = [switch]::Present }
    if ($chkIncludePayload.Checked) { $a['IncludePayload'] = [switch]::Present }
    $script:onDone = { Update-ImageInfo }
    Start-Tool -ToolName "Capture-WipeBenchImage.ps1" -ToolArgs $a -What "Capture from disk $($d.Number) ($($d.Model))"
})

$btnBuild = New-Object Windows.Forms.Button
$btnBuild.Text = "BUILD STICK on selected disk"; $btnBuild.Location = '390,326'; $btnBuild.Width = 240
$btnBuild.BackColor = [Drawing.Color]::FromArgb(200, 30, 30); $btnBuild.ForeColor = [Drawing.Color]::White
$btnBuild.Add_Click({
    $d = Get-SelectedDisk
    if (-not $d) { [void][Windows.Forms.MessageBox]::Show("Select the disk to build onto.", "No disk selected"); return }
    if ($d.Protected) { [void][Windows.Forms.MessageBox]::Show("That is the boot/system disk. Not happening.", "Refused"); return }
    $answer = [Windows.Forms.MessageBox]::Show(
        "ERASE disk $($d.Number) - $($d.Model)?`n`nEverything on it will be destroyed.",
        "Confirm build", 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    $a = @{ DiskNumber = $d.Number; ImageRoot = $txtImage.Text; Force = [switch]::Present }
    if ($chkSkipPayload.Checked) { $a['SkipPayload'] = [switch]::Present }
    if ($chkSkipDrivers.Checked) { $a['SkipDrivers'] = [switch]::Present }
    if ($chkIncludeCustom.Checked) { $a['IncludeCustom'] = [switch]::Present }
    $script:onDone = { Update-Disks }
    Start-Tool -ToolName "Build-WipeBenchUSB.ps1" -ToolArgs $a -What "Build stick on disk $($d.Number)"
})

$tabBuild.Controls.AddRange(@($lblDisks, $diskGrid, $lblImage, $txtImage, $btnBrowse, $lblImageInfo,
        $chkSkipPayload, $chkSkipDrivers, $chkIncludeCustom, $chkIncludePayload, $btnRefreshDisks, $btnCapture, $btnBuild))

# ============================================================== DRIVERS tab ==
$lblDrv = New-Object Windows.Forms.Label
$lblDrv.Text = "Driver repository:"; $lblDrv.Location = '10,12'; $lblDrv.AutoSize = $true
$txtDrv = New-Object Windows.Forms.TextBox
$txtDrv.Location = '120,9'; $txtDrv.Width = 620; $txtDrv.Text = $DriversRoot
$btnDrvBrowse = New-Object Windows.Forms.Button
$btnDrvBrowse.Text = "Browse..."; $btnDrvBrowse.Location = '750,7'; $btnDrvBrowse.Width = 90
$btnDrvBrowse.Add_Click({
    $fb = New-Object Windows.Forms.FolderBrowserDialog
    if ($fb.ShowDialog() -eq 'OK') { $txtDrv.Text = $fb.SelectedPath }
})

$btnAudit = New-Object Windows.Forms.Button
$btnAudit.Text = "Audit repository"; $btnAudit.Location = '10,46'; $btnAudit.Width = 140
$btnAudit.Add_Click({ Start-Tool -ToolName "WipeBenchDrivers.ps1" -ToolArgs @{ Action = 'Audit'; DriversRoot = $txtDrv.Text } -What "Audit driver repository" })

$btnCatalog = New-Object Windows.Forms.Button
$btnCatalog.Text = "Refresh Dell catalog"; $btnCatalog.Location = '160,46'; $btnCatalog.Width = 150
$btnCatalog.Add_Click({ Start-Tool -ToolName "WipeBenchDrivers.ps1" -ToolArgs @{ Action = 'Catalog'; DriversRoot = $txtDrv.Text } -What "Refresh Dell catalog" })

$btnUpdate = New-Object Windows.Forms.Button
$btnUpdate.Text = "Check for updates"; $btnUpdate.Location = '320,46'; $btnUpdate.Width = 150
$btnUpdate.Add_Click({ Start-Tool -ToolName "WipeBenchDrivers.ps1" -ToolArgs @{ Action = 'Update'; DriversRoot = $txtDrv.Text } -What "Compare repository against catalog" })

$btnSyncStick = New-Object Windows.Forms.Button
$btnSyncStick.Text = "Update drivers on attached stick"; $btnSyncStick.Location = '680,46'; $btnSyncStick.Width = 210
$btnSyncStick.BackColor = [Drawing.Color]::FromArgb(0, 90, 140); $btnSyncStick.ForeColor = [Drawing.Color]::White
$btnSyncStick.Add_Click({
    # dry run first so the user sees which stick(s) were found and whether they fit
    Start-Tool -ToolName "WipeBenchDrivers.ps1" -ToolArgs @{ Action = 'SyncStick'; DriversRoot = $txtDrv.Text; WhatIfOnly = [switch]::Present } -What "Find attached WipeBench sticks"
    $script:onDone = {
        $go = [Windows.Forms.MessageBox]::Show(
            "Mirror the master driver repository onto the stick(s) listed in the log?`n`nThis makes the stick match the master exactly - packs on the stick that are no longer in the master are removed.",
            "Update stick drivers", 'YesNo', 'Question')
        if ($go -eq 'Yes') {
            Start-Tool -ToolName "WipeBenchDrivers.ps1" -ToolArgs @{ Action = 'SyncStick'; DriversRoot = $txtDrv.Text } -What "Mirror drivers onto attached stick(s)"
        }
    }
})

$btnThisPc = New-Object Windows.Forms.Button
$btnThisPc.Text = "What does THIS PC need?"; $btnThisPc.Location = '480,46'; $btnThisPc.Width = 190
$btnThisPc.Add_Click({
    Start-Tool -ToolName "WipeBenchDrivers.ps1" -ToolArgs @{ Action = 'Check'; DriversRoot = $txtDrv.Text; ThisMachine = [switch]::Present } -What "Check this machine against the repository"
})

$lblSearch = New-Object Windows.Forms.Label
# NOTE: keep the comment on its OWN line. It used to trail the .Text assignment and
# swallowed the two statements after it, so this label never got a Location and rendered
# at 0,0 - on top of the tab strip. A '#' comments out the REST OF THE LINE, semicolons
# included.
# (SKU is exact - use it when catalog and WMI names disagree.)
$lblSearch.Text = "Model or SKU:"
$lblSearch.Location = '10,92'
$lblSearch.AutoSize = $true
$txtSearch = New-Object Windows.Forms.TextBox
$txtSearch.Location = '120,89'; $txtSearch.Width = 300
$cmbOs = New-Object Windows.Forms.ComboBox
$cmbOs.Location = '430,89'; $cmbOs.Width = 120; $cmbOs.DropDownStyle = 'DropDownList'
$null = $cmbOs.Items.AddRange(@('Windows11', 'Windows10', '(any)'))
$cmbOs.SelectedIndex = 0

function Get-SearchArgs([string]$action) {
    if ([string]::IsNullOrWhiteSpace($txtDrv.Text)) { $txtDrv.Text = $DriversRoot }
    $a = @{ Action = $action; DriversRoot = $txtDrv.Text }
    $q = $txtSearch.Text.Trim()
    if ($q -match '^[0-9A-Fa-f]{4}$') { $a['Sku'] = $q } elseif ($q) { $a['Model'] = $q }
    if ($cmbOs.SelectedItem -ne '(any)') { $a['OsCode'] = $cmbOs.SelectedItem }
    if ($action -eq 'Download' -and $chkTempExcl.Checked) { $a['TempExclusion'] = [switch]::Present }
    if ($action -eq 'Download' -and $chkForce.Checked) { $a['Force'] = [switch]::Present }
    $a
}

$btnSearch = New-Object Windows.Forms.Button
$btnSearch.Text = "Search catalogs"; $btnSearch.Location = '560,87'; $btnSearch.Width = 130
$btnSearch.Add_Click({
    if (-not $txtSearch.Text.Trim()) { [void][Windows.Forms.MessageBox]::Show("Type a model name or a 4-character SKU.", "Nothing to search"); return }
    Start-Tool -ToolName "WipeBenchDrivers.ps1" -ToolArgs (Get-SearchArgs 'Search') -What "Search Dell catalog"
})

$btnDownload = New-Object Windows.Forms.Button
$btnDownload.Text = "Download typed model/SKU"; $btnDownload.Location = '700,87'; $btnDownload.Width = 180
$btnDownload.BackColor = [Drawing.Color]::FromArgb(0, 110, 60); $btnDownload.ForeColor = [Drawing.Color]::White
$btnDownload.Add_Click({
    if (-not $txtSearch.Text.Trim()) { [void][Windows.Forms.MessageBox]::Show("Type a model name or a 4-character SKU first.", "Nothing to download"); return }
    Start-Tool -ToolName "WipeBenchDrivers.ps1" -ToolArgs (Get-SearchArgs 'Download') -What "Download driver pack"
})

# ---- catalog model selector: filter, multi-select, batch download ----
$lblPick = New-Object Windows.Forms.Label
$lblPick.Text = "Catalog models (multi-select, Ctrl/Shift):"; $lblPick.Location = '10,126'; $lblPick.AutoSize = $true

$lstModels = New-Object Windows.Forms.ListBox
$lstModels.Location = '10,148'; $lstModels.Size = New-Object Drawing.Size(560, 150)
$lstModels.SelectionMode = 'MultiExtended'
$lstModels.Add_SelectedIndexChanged({
    if ($script:btnDownloadSel) {
        $n = $lstModels.SelectedItems.Count
        $script:btnDownloadSel.Text = if ($n) { "Download $n selected (~$(Format-GB (Get-SelectionBytes)))" } else { "Download checked models" }
    }
})

$lblOwned = New-Object Windows.Forms.Label
$lblOwned.Location = '580,204'; $lblOwned.Size = New-Object Drawing.Size(300, 96)
$lblOwned.ForeColor = [Drawing.Color]::DimGray

$script:catalogModels = @()
# model -> published pack size (bytes). Dell's catalog carries it; the Microsoft catalog
# does not publish a size, so Surface models contribute 0 and the estimate is a floor.
$script:modelSize = @{}
# Observed on the PB14250 import: a 1.78 GB download extracted to 7.27 GB on disk. Packs
# are compressed installers, so DISK need is several times the transfer. Estimate with 4x
# rather than pretending the download size is the requirement.
$script:ExtractFactor = 4

function Get-SelectionBytes {
    $b = 0
    foreach ($m in @($lstModels.SelectedItems)) { if ($script:modelSize.ContainsKey($m)) { $b += $script:modelSize[$m] } }
    return $b
}
function Format-GB([double]$bytes) { return ("{0:N1} GB" -f ($bytes / 1GB)) }
function Get-RepoFreeBytes {
    try { return ([IO.DriveInfo]::new((Split-Path $txtDrv.Text -Qualifier) + "\")).AvailableFreeSpace }
    catch { return 0 }
}
# What the repository already holds, keyed by normalized folder name, plus whatever model
# name each pack's manifest recorded (a pack imported as "OptiPlex 7020 SFF" should still
# light up even if the folder was renamed).
function Get-OwnedIndex {
    $idx = @{}
    # Same reason the CLI skips them: an alias junction is not a pack, and listing it here
    # would auto-select a second entry for hardware you already own exactly one pack for.
    foreach ($d in (Get-ChildItem $txtDrv.Text -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike ".*" -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })) {
        $idx[$d.Name.ToLower()] = $d.Name
        $mf = Join-Path $d.FullName ".wipebench.json"
        if (Test-Path $mf) {
            try {
                $j = Get-Content $mf -Raw | ConvertFrom-Json
                if ($j.model) { $idx[(ConvertTo-DriverFolderName $j.model).ToLower()] = $d.Name }
            } catch { }
        }
    }
    $idx
}

function Load-CatalogModels {
    $lstModels.Items.Clear()
    if ([string]::IsNullOrWhiteSpace($txtDrv.Text)) { $lblOwned.Text = "Set a driver repository folder (Browse...)."; return }
    $xml = Join-Path (Join-Path $txtDrv.Text ".wipebench") "DriverPackCatalog.xml" 
    if (-not (Test-Path $xml)) { $lblOwned.Text = "No catalog cached yet.`r`nClick 'Refresh Dell catalog' first."; return }
    try {
        [xml]$c = Get-Content $xml
        $os = if ($cmbOs.SelectedItem -eq '(any)') { $null } else { [string]$cmbOs.SelectedItem }
        $names = New-Object Collections.Generic.HashSet[string]
        foreach ($p in $c.DriverPackManifest.DriverPackage) {
            if ($os) {
                $codes = @($p.SupportedOperatingSystems.OperatingSystem | ForEach-Object { $_.osCode })
                if ($codes -notcontains $os) { continue }
            }
            $psize = 0; [void][int64]::TryParse("$($p.size)", [ref]$psize)
            foreach ($m in @($p.SupportedSystems.Brand.Model)) {
                $null = $names.Add($m.name)
                # one model can appear in several packages; keep the largest as the estimate
                if (-not $script:modelSize.ContainsKey($m.name) -or $script:modelSize[$m.name] -lt $psize) {
                    $script:modelSize[$m.name] = $psize
                }
            }
        }
        # Surface models live in the Microsoft catalog (a separate JSON), not Dell's XML -
        # merge them in so the selector shows the whole repository-relevant world.
        $msJson = Join-Path (Join-Path $txtDrv.Text ".wipebench") "MicrosoftDriverPack.json"
        if (Test-Path $msJson) {
            try {
                foreach ($e in (Get-Content $msJson -Raw | ConvertFrom-Json)) {
                    if ($os -and ("$($e.OperatingSystem)" -replace '\s', '') -ne $os) { continue }
                    $null = $names.Add($e.Model)
                }
            } catch { }
        }
        $script:catalogModels = @($names) | Sort-Object
        $owned = Get-OwnedIndex
        $f = $txtSearch.Text.Trim()
        $show = @($script:catalogModels)
        if ($f) { $show = @($show | Where-Object { $_ -like "*$f*" }) }
        if ($chkOwnedOnly.Checked) { $show = @($show | Where-Object { $owned.ContainsKey((ConvertTo-DriverFolderName $_).ToLower()) }) }
        foreach ($n in $show) { $null = $lstModels.Items.Add($n) }

        # auto-select everything the repository already has -> "refresh what I own" is one click
        $matched = New-Object Collections.Generic.HashSet[string]
        for ($i = 0; $i -lt $lstModels.Items.Count; $i++) {
            $key = (ConvertTo-DriverFolderName $lstModels.Items[$i]).ToLower()
            if ($owned.ContainsKey($key)) { $lstModels.SetSelected($i, $true); $null = $matched.Add($owned[$key]) }
        }
        $unmatched = @($owned.Values | Sort-Object -Unique | Where-Object { -not $matched.Contains($_) })
        $lblOwned.Text = "$($lstModels.Items.Count) model(s) listed$(if($f){" matching '$f'"}).`r`n`r`n" +
            "Auto-selected $($matched.Count) already in your repository.`r`n`r`n" +
            $(if ($unmatched.Count) {
                # the label is only ~96px tall now, so keep it to a teaser and put the whole
                # list in the log pane, which scrolls
                "NOT in the catalog by that name ($($unmatched.Count)):`r`n  " +
                (($unmatched | Select-Object -First 2) -join "`r`n  ") +
                $(if ($unmatched.Count -gt 2) { "`r`n  ...full list in the log" })
            } else { "Every pack you own matched a catalog model." })
        if ($unmatched.Count) {
            Write-Log "$($unmatched.Count) pack(s) match no catalog model by name - they resolve by SKU or need -ThisMachine on the real hardware:" 'Gold'
            foreach ($u in $unmatched) { Write-Log "    $u" 'Gray' }
        }
    } catch { $lblOwned.Text = "catalog unreadable: $_" }
}
$chkOwnedOnly = New-Object Windows.Forms.CheckBox
$chkOwnedOnly.Text = "Only models I already have"; $chkOwnedOnly.Location = '250,126'; $chkOwnedOnly.AutoSize = $true
$chkOwnedOnly.Add_CheckedChanged({ Load-CatalogModels })

# "everything we could still fetch" - the complement of the owned auto-selection. Filter
# aware on purpose: with the box empty this is EVERY missing model (277 / ~520 GB download
# / ~2 TB extracted as of 2026-08-10, which does not fit), so type a filter first and let
# the size readout on the download button tell you what you are committing to.
$btnSelMissing = New-Object Windows.Forms.Button
$btnSelMissing.Text = "Missing"; $btnSelMissing.Location = '700,148'; $btnSelMissing.Width = 74
$btnSelMissing.Add_Click({
    $owned = Get-OwnedIndex
    $lstModels.ClearSelected()
    $n = 0
    for ($i = 0; $i -lt $lstModels.Items.Count; $i++) {
        $key = (ConvertTo-DriverFolderName $lstModels.Items[$i]).ToLower()
        if (-not $owned.ContainsKey($key)) { $lstModels.SetSelected($i, $true); $n++ }
    }
    $bytes = Get-SelectionBytes
    Write-Log "Selected $n model(s) not in the repository - about $(Format-GB $bytes) to download, roughly $(Format-GB ($bytes * $script:ExtractFactor)) once extracted." 'DeepSkyBlue'
    if (-not $n) { Write-Log "  (nothing missing in the current list)" 'Gray' }
})

# Select from a plain list of model names - one per line, '#' comments and blanks ignored.
# This is how a real work-list gets into the app: export the models your estimate actually
# contains, point at the file, download exactly those. Hand-picking 21 models out of 292 in
# a listbox is how you end up with the wrong 21.
$btnSelFile = New-Object Windows.Forms.Button
$btnSelFile.Text = "From file"; $btnSelFile.Location = '778,148'; $btnSelFile.Width = 74
$btnSelFile.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = "Model lists (*.txt)|*.txt|All files (*.*)|*.*"
    $dlg.InitialDirectory = $ToolDir
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $wanted = @(Get-Content $dlg.FileName | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and -not $_.StartsWith('#') })
    if (-not $wanted.Count) { Write-Log "No model names in $($dlg.FileName)." 'Tomato'; return }
    # match on the normalized folder name so catalog/marketing/WMI spelling differences
    # ("Surface Pro 7+" vs "Surface_Pro_7_") do not silently drop entries
    $want = @{}
    foreach ($w in $wanted) { $want[(ConvertTo-DriverFolderName $w).ToLower()] = $w }
    $lstModels.ClearSelected()
    $hit = New-Object Collections.Generic.HashSet[string]
    for ($i = 0; $i -lt $lstModels.Items.Count; $i++) {
        $key = (ConvertTo-DriverFolderName $lstModels.Items[$i]).ToLower()
        if ($want.ContainsKey($key)) { $lstModels.SetSelected($i, $true); $null = $hit.Add($key) }
    }
    $missed = @($want.Keys | Where-Object { -not $hit.Contains($_) } | ForEach-Object { $want[$_] })
    $bytes = Get-SelectionBytes
    Write-Log "From $(Split-Path $dlg.FileName -Leaf): selected $($hit.Count) of $($wanted.Count) - about $(Format-GB $bytes) to download, ~$(Format-GB ($bytes * $script:ExtractFactor)) extracted." 'DeepSkyBlue'
    if ($missed.Count) {
        # Not in the visible list is not the same as not in the catalog - a filter or the OS
        # dropdown may simply be hiding it. Say which, rather than implying it does not exist.
        Write-Log "  not in the CURRENT list ($($missed.Count)) - clear the filter / set OS to (any) and retry: $($missed -join ', ')" 'Gold'
    }
})

$btnSelNone = New-Object Windows.Forms.Button
$btnSelNone.Text = "Clear selection"; $btnSelNone.Location = '700,176'; $btnSelNone.Width = 150
$btnSelNone.Add_Click({ $lstModels.ClearSelected() })

$btnLoadModels = New-Object Windows.Forms.Button
$btnLoadModels.Text = "Load / filter list"; $btnLoadModels.Location = '700,120'; $btnLoadModels.Width = 150
$btnLoadModels.Add_Click({ Load-CatalogModels })

# Defender scans each .sys/.inf as it is extracted, which drags a multi-GB pack out
# for ages. The tool makes sure the repo is excluded and LEAVES it that way (the same
# exclusion also speeds up stick syncs and DISM injection). Tick this to drop the
# exclusion again when the download finishes.
$chkTempExcl = New-Object Windows.Forms.CheckBox
$chkTempExcl.Text = "Remove Defender exclusion when done"; $chkTempExcl.Location = '10,332'; $chkTempExcl.AutoSize = $true

# Download now SKIPS a pack whose recorded version already matches the catalog, so
# "select everything I own and refresh" costs nothing when it is all current. Tick this
# only to force the bytes down again (corrupt extraction, replaced pack, paranoia).
$chkForce = New-Object Windows.Forms.CheckBox
$chkForce.Text = "Re-download even if already current"; $chkForce.Location = '280,332'; $chkForce.AutoSize = $true

$script:btnDownloadSel = New-Object Windows.Forms.Button
$btnDownloadSel = $script:btnDownloadSel
$btnDownloadSel.Text = "Download checked models"; $btnDownloadSel.Location = '10,304'; $btnDownloadSel.Width = 230
$btnDownloadSel.BackColor = [Drawing.Color]::FromArgb(0, 110, 60); $btnDownloadSel.ForeColor = [Drawing.Color]::White
$btnDownloadSel.Add_Click({
    $sel = @($lstModels.SelectedItems)
    if (-not $sel.Count) { [void][Windows.Forms.MessageBox]::Show("Select one or more models from the list.", "Nothing selected"); return }
    $bytes = Get-SelectionBytes
    $needed = $bytes * $script:ExtractFactor
    $free = Get-RepoFreeBytes
    # Hard stop rather than a warning: running the disk dry mid-extraction leaves a
    # half-imported pack behind, and a truncated pack looks fine until DISM reads it.
    if ($free -gt 0 -and $needed -gt $free) {
        [void][Windows.Forms.MessageBox]::Show(
            "That selection will not fit.`n`n$($sel.Count) pack(s)`ndownload  ~$(Format-GB $bytes)`non disk   ~$(Format-GB $needed) (packs extract to about $($script:ExtractFactor)x)`nfree      $(Format-GB $free)`n`nNarrow the list with the filter box, or free up space.",
            "Not enough space", 'OK', 'Warning')
        Write-Log "BLOCKED: $($sel.Count) pack(s) need ~$(Format-GB $needed) extracted, only $(Format-GB $free) free." 'Tomato'
        return
    }
    $answer = [Windows.Forms.MessageBox]::Show(
        "Download $($sel.Count) driver pack(s)?`n`ndownload  ~$(Format-GB $bytes)`non disk   ~$(Format-GB $needed) after extraction`nfree      $(Format-GB $free)`n`n" +
        (($sel | Select-Object -First 12) -join "`n") + $(if ($sel.Count -gt 12) { "`n..." }),
        "Confirm download", 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $a = @{ Action = 'Download'; DriversRoot = $txtDrv.Text; Models = $sel }
    if ($cmbOs.SelectedItem -ne '(any)') { $a['OsCode'] = $cmbOs.SelectedItem }
    if ($chkTempExcl.Checked) { $a['TempExclusion'] = [switch]::Present }
    if ($chkForce.Checked) { $a['Force'] = [switch]::Present }
    Start-Tool -ToolName "WipeBenchDrivers.ps1" -ToolArgs $a -What "Download $($sel.Count) driver pack(s)"
})

$noteDrv = New-Object Windows.Forms.Label
$noteDrv.Location = '250,306'; $noteDrv.Size = New-Object Drawing.Size(620, 46)
$noteDrv.ForeColor = [Drawing.Color]::DimGray
$noteDrv.Text = @"
Both download buttons do the same work - they differ only in where the list comes from. The TOP one takes whatever is typed in the Model/SKU box (use it for a SKU, or a name the list does not show). The one under the list takes everything highlighted there, for batch refreshes.
Packs are filed under the folder name WinPE derives from the machine's WMI model string. Dell's catalog name is often different (it calls "Dell Pro Max 16 Premium MA16250" just "MA16250"), which is why SKU matching exists.
"@

$tabDrv.Controls.AddRange(@($chkTempExcl, $chkForce, $lblDrv, $txtDrv, $btnDrvBrowse, $btnAudit, $btnCatalog, $btnUpdate, $btnThisPc,
        $btnSyncStick, $lblSearch, $txtSearch, $cmbOs, $btnSearch, $btnDownload,
        $lblPick, $lstModels, $lblOwned, $btnLoadModels, $btnDownloadSel, $chkOwnedOnly, $btnSelMissing, $btnSelFile, $btnSelNone, $noteDrv))

# --------------------------------------------------------------- assemble ----
$script:actionButtons = @($btnCapture, $btnBuild, $btnAudit, $btnCatalog, $btnUpdate, $btnThisPc, $btnSearch, $btnDownload, $btnDownloadSel, $btnSyncStick, $btnSelMissing, $btnSelFile)
$form.Controls.AddRange(@($tabs, $logPanel, $status))
$tabs.BringToFront()

[Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-Log ("UNHANDLED: " + $e.Exception.Message) 'Tomato'
    Write-Log "  (caught - the window is still usable)" 'Gold'
})

$form.Add_Shown({
    Write-Log "WipeBench Console" 'DeepSkyBlue'
    Write-Log "Tools: $ToolDir" 'Gray'
    if (-not $IsElevated) { Write-Log "Standard user - the Drivers tab works fully; disk actions will ask for admin when used." 'Gold' }
    try { Update-Disks } catch { Write-Log "Could not enumerate disks: $_" 'Tomato' }
    Update-ImageInfo
    try { Load-CatalogModels } catch { }
})

if ($SelfTest) {
    Update-ImageInfo
    # Exercise the job-launch path too. Building the form alone missed a real bug once:
    # a parameter named $Args (an automatic variable) blew up on first button click under
    # PowerShell 7. Pointing at a nonexistent tool makes Start-Tool bind its parameters,
    # log "Missing tool", and return before spawning anything.
    try {
        Start-Tool -ToolName "__selftest_missing__.ps1" -ToolArgs @{ Action = 'Audit'; DriversRoot = $DriversRoot } -What "self test"
        $bindOk = $true
    } catch { $bindOk = $false; "SelfTest FAILED binding Start-Tool: $($_.Exception.Message)" }
    $cancelOk = ($null -ne $script:btnCancel) -and -not $script:btnCancel.Enabled
    "SelfTest {0} - form '{1}', {2} tabs, {3} actions wired, Start-Tool binding {4}, cancel button $(if ($cancelOk) { 'present (disabled while idle)' } else { 'MISSING' })" -f `
        $(if ($bindOk) { "OK" } else { "FAILED" }), $form.Text, $tabs.TabPages.Count,
        $script:actionButtons.Count, $(if ($bindOk) { "OK" } else { "BROKEN" })
    $form.Dispose()
    return
}

[void]$form.ShowDialog()
