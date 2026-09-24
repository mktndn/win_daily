#Requires -Version 7.0
<#
.SYNOPSIS
    Daily Windows maintenance tasks that run as the logged-in (non-elevated) user.

.DESCRIPTION
    Daily:
      - scoop update (scoop itself, buckets, all apps)
      - winget upgrade --scope user
      - Disk free space check
    Weekly (on -WeeklyDay, or when -Weekly is given):
      - scoop cleanup (old versions + download cache) and scoop checkup
      - PowerShell module update (CurrentUser scope)
    Always:
      - Pending reboot report

    Must NOT be run elevated: scoop is designed for per-user, non-admin use.

.EXAMPLE
    pwsh -File .\maintenance-user.ps1
.EXAMPLE
    pwsh -File .\maintenance-user.ps1 -DryRun -Weekly
#>
[CmdletBinding()]
param(
    # Run weekly tasks regardless of the day.
    [switch]$Weekly,
    [DayOfWeek]$WeeklyDay = 'Sunday',
    # Only report what would be done; change nothing.
    [switch]$DryRun,
    # Warn when a fixed drive has less free space than this.
    [ValidateRange(1, 99)][int]$MinFreePercent = 15,
    [string]$LogDir = (Join-Path $env:LOCALAPPDATA 'win_daily\logs')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot 'WinDaily.Common.psm1') -Force

if (Test-IsAdmin) {
    Write-Error 'Run this script without elevation (scoop and per-user winget packages belong to the normal user).'
    exit 2
}

$logPath = Start-WDLog -LogDir $LogDir -Name 'user'
$runWeekly = $Weekly -or (Get-Date).DayOfWeek -eq $WeeklyDay
$notWeekly = if ($runWeekly) { '' } else { "weekly task (runs on $WeeklyDay or with -Weekly)" }
$noScoop = if (Get-Command scoop -ErrorAction SilentlyContinue) { '' } else { 'scoop not found' }
Write-Host "win_daily user maintenance  user=$env:USERNAME  weekly=$runWeekly  dryrun=$DryRun"

# scoop is a PowerShell script run in-process, so relax error handling around it and check its exit code.
function Invoke-Scoop {
    $ErrorActionPreference = 'Continue'
    Write-Host "> scoop $args" -ForegroundColor DarkGray
    $global:LASTEXITCODE = 0
    & scoop @args | Out-Host
    if ($LASTEXITCODE) { throw "scoop $args exited with code $LASTEXITCODE" }
}

# --- scoop -----------------------------------------------------------------------------------
Invoke-Step 'scoop update' -SkipReason $noScoop {
    if ($DryRun) {
        Invoke-Scoop status
        Set-StepResult -Detail 'dry run: status only (bucket info may be stale)'
        return
    }
    Invoke-Scoop update
    Invoke-Scoop update '*'
}

# --- winget (user scope) ---------------------------------------------------------------------
Invoke-Step 'winget upgrade (user scope)' -SkipReason $(if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { 'winget not found' }) {
    Invoke-WingetUpgrade -Scope user -DryRun:$DryRun
}

# --- Disk space ------------------------------------------------------------------------------
Invoke-Step 'Disk free space' {
    $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object Size -gt 0
    $disks | Format-Table DeviceID, VolumeName,
        @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } },
        @{ n = 'FreeGB'; e = { [math]::Round($_.FreeSpace / 1GB, 1) } },
        @{ n = 'Free%'; e = { [math]::Round(100 * $_.FreeSpace / $_.Size, 1) } } -AutoSize | Out-Host
    $low = @($disks | Where-Object { 100 * $_.FreeSpace / $_.Size -lt $MinFreePercent })
    if ($low) {
        Set-StepResult -Status WARN -Detail ("low space (<$MinFreePercent%): " + (($low | ForEach-Object DeviceID) -join ', '))
    }
}

# --- Weekly ----------------------------------------------------------------------------------
Invoke-Step 'scoop cleanup / checkup' -SkipReason ($noScoop ? $noScoop : $notWeekly) {
    if (-not $DryRun) { Invoke-Scoop cleanup '*' '--cache' }
    Invoke-Scoop checkup
}

Invoke-Step 'PowerShell modules update (CurrentUser)' -SkipReason $notWeekly {
    $installed = @(Get-InstalledPSResource -Scope CurrentUser -ErrorAction SilentlyContinue |
        Where-Object Type -eq 'Module' | Sort-Object Name -Unique)
    if (-not $installed) { Set-StepResult -Detail 'no CurrentUser modules'; return }
    if ($DryRun) {
        $installed | Format-Table Name, Version, Repository -AutoSize | Out-Host
        Set-StepResult -Detail "dry run: $($installed.Count) module(s) installed"
        return
    }
    $updated = @(Update-PSResource -Name $installed.Name -Scope CurrentUser -TrustRepository -AcceptLicense -PassThru -ErrorAction Continue)
    $updated | Format-Table Name, Version -AutoSize | Out-Host
    Set-StepResult -Detail "$($updated.Count) updated"
}

# --- Reboot ----------------------------------------------------------------------------------
Invoke-Step 'Pending reboot check' {
    $reasons = @(Get-PendingRebootReason)
    if ($reasons) { Set-StepResult -Status WARN -Detail ('reboot pending: ' + ($reasons -join ', ')) }
    else { Set-StepResult -Detail 'none' }
}

Write-StepSummary
$failures = @(Get-StepResult | Where-Object Status -eq 'FAIL').Count
Write-Host "Log: $logPath"
Stop-Transcript | Out-Null
exit ([int]($failures -gt 0))
