#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Daily Windows maintenance tasks that need elevation.

.DESCRIPTION
    Daily:
      - Windows Update (via PSWindowsUpdate; Microsoft Update enabled; drivers, feature upgrades
        and previews excluded by default)
      - winget upgrade --scope machine
      - Microsoft Defender signature update
      - wsl --update (skipped while a WSL distro is running, since updating restarts WSL)
    Weekly (on -WeeklyDay, or when -Weekly is given):
      - Microsoft Defender quick scan
      - Component store health check (DISM ScanHealth -> RestoreHealth + sfc if repairable)
      - Component store cleanup (DISM StartComponentCleanup)
    Always:
      - Pending reboot report (reboots only with -AllowReboot)

.EXAMPLE
    sudo pwsh -NoExit -File .\maintenance-admin.ps1
.EXAMPLE
    pwsh -File .\maintenance-admin.ps1 -DryRun -Weekly
#>
[CmdletBinding()]
param(
    # Run weekly tasks regardless of the day.
    [switch]$Weekly,
    [DayOfWeek]$WeeklyDay = 'Sunday',
    # Only report what would be done; install nothing.
    [switch]$DryRun,
    # Include driver updates from Windows Update.
    [switch]$IncludeDrivers,
    # Run wsl --update even if WSL distros are running (they will be shut down).
    [switch]$ForceWslUpdate,
    # Schedule a reboot (5 minutes, abort with `shutdown /a`) when one is pending and no step failed.
    [switch]$AllowReboot,
    [string]$LogDir = (Join-Path $env:ProgramData 'win_daily\logs')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot 'WinDaily.Common.psm1') -Force

$logPath = Start-WDLog -LogDir $LogDir -Name 'admin'
$runWeekly = $Weekly -or (Get-Date).DayOfWeek -eq $WeeklyDay
$notWeekly = if ($runWeekly) { '' } else { "weekly task (runs on $WeeklyDay or with -Weekly)" }
$defenderOff = try { if ((Get-MpComputerStatus).AntivirusEnabled) { '' } else { 'Defender is not the active AV' } }
               catch { 'Defender status unavailable' }
Write-Host "win_daily admin maintenance  host=$env:COMPUTERNAME  weekly=$runWeekly  dryrun=$DryRun"

# --- Windows Update --------------------------------------------------------------------------
Invoke-Step 'Windows Update' {
    Import-Module PSWindowsUpdate

    # Microsoft Update adds Office, .NET, VC++ runtimes etc. Registering it is a one-time change.
    $microsoftUpdateId = '7971f918-a847-4430-9279-4a52d1efe18d'
    if (-not (Get-WUServiceManager | Where-Object ServiceID -eq $microsoftUpdateId)) {
        Write-Host 'Registering Microsoft Update service'
        Add-WUServiceManager -MicrosoftUpdate -Confirm:$false | Out-Null
    }

    $notCategory = @('Upgrades')
    if (-not $IncludeDrivers) { $notCategory += 'Drivers' }
    $wuArgs = @{ MicrosoftUpdate = $true; NotCategory = $notCategory; NotTitle = 'Preview' }

    if ($DryRun) {
        $updates = @(Get-WindowsUpdate @wuArgs)
        $updates | Format-Table KB, Size, Title -AutoSize | Out-Host
        Set-StepResult -Detail "dry run: $($updates.Count) update(s) available"
        return
    }

    $results = @(Install-WindowsUpdate @wuArgs -AcceptAll -IgnoreReboot -Confirm:$false)
    $results | Format-Table KB, Result, Size, Title -AutoSize | Out-Host
    $failed = @($results | Where-Object Result -eq 'Failed')
    $installed = @($results | Where-Object Result -eq 'Installed')
    if ($failed) {
        Set-StepResult -Status FAIL -Detail ("failed: " + (($failed | ForEach-Object { if ($_.KB) { $_.KB } else { $_.Title } }) -join ', '))
    }
    elseif ($results) {
        Set-StepResult -Detail "$($installed.Count) installed"
    }
    else {
        Set-StepResult -Detail 'no updates'
    }
}

# --- winget (machine scope) ------------------------------------------------------------------
Invoke-Step 'winget upgrade (machine scope)' -SkipReason $(if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { 'winget not found' }) {
    Invoke-WingetUpgrade -Scope machine -DryRun:$DryRun
}

# --- Defender --------------------------------------------------------------------------------
Invoke-Step 'Defender signature update' -SkipReason $defenderOff {
    $before = (Get-MpComputerStatus).AntivirusSignatureVersion
    if ($DryRun) {
        Set-StepResult -Detail "dry run: current $before"
        return
    }
    Update-MpSignature
    $after = (Get-MpComputerStatus).AntivirusSignatureVersion
    Set-StepResult -Detail $(if ($before -eq $after) { "up to date ($after)" } else { "$before -> $after" })
}

# --- WSL -------------------------------------------------------------------------------------
Invoke-Step 'WSL update' -SkipReason $(if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { 'wsl.exe not found' }) {
    $env:WSL_UTF8 = '1'
    Invoke-Native wsl.exe '--version'
    if ($DryRun) {
        Set-StepResult -Detail 'dry run'
        return
    }
    $running = @(wsl.exe --list --running --quiet | Where-Object { $_.Trim() })
    if ($running -and -not $ForceWslUpdate) {
        Set-StepResult -Status WARN -Detail "skipped: running distro(s) $($running -join ', '); use -ForceWslUpdate"
        return
    }
    Invoke-Native wsl.exe '--update'
}

# --- Weekly ----------------------------------------------------------------------------------
Invoke-Step 'Defender quick scan' -SkipReason ($defenderOff ? $defenderOff : $notWeekly) {
    if ($DryRun) { Set-StepResult -Detail 'dry run'; return }
    Start-MpScan -ScanType QuickScan
    $threats = @(Get-MpThreatDetection | Where-Object InitialDetectionTime -gt (Get-Date).AddDays(-1))
    if ($threats) { Set-StepResult -Status WARN -Detail "$($threats.Count) detection(s) in last 24h" }
}

Invoke-Step 'Component store health (DISM/SFC)' -SkipReason $notWeekly {
    # dism.exe with /English rather than Repair-WindowsImage, whose cmdlets fail under the
    # Store build of pwsh 7 with "Class not registered".
    $dism = '/Online', '/Cleanup-Image', '/English'
    $scan = (Invoke-Native dism.exe ($dism + '/ScanHealth') -PassThru) -join "`n"
    if ($scan -match 'No component store corruption detected') {
        Set-StepResult -Detail 'healthy'
    }
    elseif ($scan -match 'component store is repairable') {
        if ($DryRun) { Set-StepResult -Status WARN -Detail 'repairable (dry run: not repaired)'; return }
        Invoke-Native dism.exe ($dism + '/RestoreHealth') -SuccessCodes 0, 3010
        Invoke-Native sfc.exe '/scannow' -Encoding ([Text.Encoding]::Unicode)
        Set-StepResult -Status WARN -Detail 'was repairable: RestoreHealth + sfc ran'
    }
    else {
        throw 'component store is not repairable or ScanHealth result unrecognized (see log)'
    }
}

Invoke-Step 'Component store cleanup (DISM)' -SkipReason $notWeekly {
    if ($DryRun) {
        Invoke-Native dism.exe '/Online', '/Cleanup-Image', '/AnalyzeComponentStore', '/English'
        Set-StepResult -Detail 'dry run: analyzed only'
        return
    }
    Invoke-Native dism.exe '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/English' -SuccessCodes 0, 3010
}

# --- Reboot ----------------------------------------------------------------------------------
$rebootReasons = @(Get-PendingRebootReason)
Invoke-Step 'Pending reboot check' {
    if (-not $rebootReasons) { Set-StepResult -Detail 'none'; return }
    Set-StepResult -Status WARN -Detail ('reboot pending: ' + ($rebootReasons -join ', '))
}

Write-StepSummary
$failures = @(Get-StepResult | Where-Object Status -eq 'FAIL').Count

if ($rebootReasons -and $AllowReboot -and -not $DryRun) {
    if ($failures) {
        Write-Host 'Reboot pending but not scheduled because a step failed.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Rebooting in 5 minutes. Abort with: shutdown /a' -ForegroundColor Yellow
        shutdown.exe /r /t 300 /c 'win_daily: reboot after maintenance (abort with shutdown /a)'
    }
}

Write-Host "Log: $logPath"
Stop-Transcript | Out-Null
exit ([int]($failures -gt 0))
