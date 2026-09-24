#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers (or removes) the daily Task Scheduler entries for the maintenance scripts.

.DESCRIPTION
    Creates two tasks under \win_daily\, both running as the current user and only while logged on:
      admin : maintenance-admin.ps1, "Run with highest privileges" (no UAC prompt)
      user  : maintenance-user.ps1, normal privileges
    Both start daily at the given time; if the PC was off or asleep then, they run as soon as
    possible afterwards. Weekly tasks are decided by the scripts themselves (-WeeklyDay).
    Scripts are run from this script's directory, so deploy first and run this from there.

.EXAMPLE
    sudo pwsh -File .\register-tasks.ps1
.EXAMPLE
    sudo pwsh -File .\register-tasks.ps1 -AdminTime 09:00 -UserTime 09:30
.EXAMPLE
    sudo pwsh -File .\register-tasks.ps1 -Unregister
#>
[CmdletBinding()]
param(
    [datetime]$AdminTime = '12:00',
    [datetime]$UserTime = '12:30',
    # Extra arguments passed to each script, e.g. '-AllowReboot'.
    [string]$AdminArguments = '',
    [string]$UserArguments = '',
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
$taskPath = '\win_daily\'
$userId = "$env:USERDOMAIN\$env:USERNAME"

if ($Unregister) {
    Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    Write-Host "Removed tasks under $taskPath"
    return
}

# Prefer the app execution alias: the Store build's real path contains its version and changes on update.
$pwsh = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
if (-not (Test-Path $pwsh)) { $pwsh = (Get-Command pwsh.exe).Source }

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew

$tasks = @(
    @{ Name = 'admin'; Script = 'maintenance-admin.ps1'; Time = $AdminTime; RunLevel = 'Highest'; Arguments = $AdminArguments }
    @{ Name = 'user'; Script = 'maintenance-user.ps1'; Time = $UserTime; RunLevel = 'Limited'; Arguments = $UserArguments }
)

foreach ($t in $tasks) {
    $script = Join-Path $PSScriptRoot $t.Script
    if (-not (Test-Path $script)) { throw "not found: $script" }
    $action = New-ScheduledTaskAction -Execute $pwsh -WorkingDirectory $PSScriptRoot `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$script`" $($t.Arguments)".TrimEnd()
    $trigger = New-ScheduledTaskTrigger -Daily -At $t.Time
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel $t.RunLevel
    Register-ScheduledTask -TaskPath $taskPath -TaskName $t.Name -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description "win_daily: $($t.Script)" -Force | Out-Null
    Write-Host ("Registered {0}{1}: daily {2:HH:mm} ({3}) -> {4}" -f $taskPath, $t.Name, $t.Time, $t.RunLevel, $script)
}

Write-Host "Run now:  Start-ScheduledTask -TaskPath '$taskPath' -TaskName admin"
Write-Host "Status:   Get-ScheduledTask -TaskPath '$taskPath' | Get-ScheduledTaskInfo"
