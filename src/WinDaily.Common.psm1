# Shared helpers for maintenance-admin.ps1 / maintenance-user.ps1.

Set-StrictMode -Version Latest

$script:Results = [System.Collections.Generic.List[object]]::new()
$script:StepStatus = $null
$script:StepDetail = $null

# Exit codes that mean "nothing to do" rather than failure.
$script:WingetNoOpCodes = @(
    -1978335189  # 0x8A15002B APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE
    -1978335212  # 0x8A150014 APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
)

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-WDLog {
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$Name,
        [int]$RetentionDays = 30
    )
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    Get-ChildItem -Path $LogDir -Filter "$Name-*.log" |
        Where-Object LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $path = Join-Path $LogDir ('{0}-{1:yyyyMMdd-HHmmss}.log' -f $Name, (Get-Date))
    Start-Transcript -Path $path | Out-Null
    $path
}

# Called from inside a step to report WARN (or an informational detail) without failing it.
function Set-StepResult {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL')][string]$Status = 'OK',
        [string]$Detail
    )
    $script:StepStatus = $Status
    $script:StepDetail = $Detail
}

function Invoke-Step {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][scriptblock]$Action,
        # Non-empty => the step is recorded as SKIP with this reason.
        [string]$SkipReason
    )
    if ($SkipReason) {
        Write-Host "--- $Name : skipped ($SkipReason)" -ForegroundColor DarkGray
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'SKIP'; Duration = [timespan]::Zero; Detail = $SkipReason })
        return
    }

    Write-Host ''
    Write-Host "==> $Name" -ForegroundColor Cyan
    $script:StepStatus = 'OK'
    $script:StepDetail = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action | Out-Host
    }
    catch {
        $script:StepStatus = 'FAIL'
        $script:StepDetail = $_.Exception.Message.Trim()
        Write-Host "!!! $Name failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    $sw.Stop()
    $script:Results.Add([pscustomobject]@{ Step = $Name; Status = $script:StepStatus; Duration = $sw.Elapsed; Detail = $script:StepDetail })
}

# Runs a native command, streams its output to the host (and transcript) without progress-bar noise,
# and throws unless the exit code is in SuccessCodes. $LASTEXITCODE is left set for the caller.
# -PassThru also returns the (filtered) output lines.
function Invoke-Native {
    param(
        [Parameter(Mandatory, Position = 0)][string]$FilePath,
        [Parameter(Position = 1)][string[]]$ArgumentList = @(),
        [int[]]$SuccessCodes = @(0),
        # Encoding the tool writes when redirected (sfc.exe writes UTF-16, for example).
        [Text.Encoding]$Encoding = [Text.UTF8Encoding]::new($false),
        [switch]$PassThru
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    Write-Host "> $FilePath $($ArgumentList -join ' ')" -ForegroundColor DarkGray
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = $Encoding
    try {
        & $FilePath @ArgumentList 2>&1 |
            ForEach-Object { "$_".TrimEnd("`0") } |
            # drop spinners, winget progress bars and dism "[====  12.3%  ]" bars
            Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[█▒]' -and $_ -notmatch '^\s*\[[=\s\d.%]*\]\s*$' } |
            ForEach-Object { $lines.Add($_); $_ } |
            Out-Host
    }
    finally {
        [Console]::OutputEncoding = $prevEncoding
    }
    $code = $LASTEXITCODE
    if ($code -notin $SuccessCodes) {
        throw ('{0} {1} exited with code {2} (0x{2:X8})' -f $FilePath, ($ArgumentList -join ' '), $code)
    }
    if ($PassThru) { $lines.ToArray() }
}

# Runs `winget upgrade` for one scope. DryRun lists available upgrades only.
function Invoke-WingetUpgrade {
    param(
        [Parameter(Mandatory)][ValidateSet('machine', 'user')][string]$Scope,
        [switch]$DryRun
    )
    $common = @('--scope', $Scope, '--accept-source-agreements', '--disable-interactivity')
    if ($DryRun) {
        Invoke-Native winget (@('upgrade') + $common) -SuccessCodes (@(0) + $script:WingetNoOpCodes)
        Set-StepResult -Detail 'dry run: listed only'
        return
    }
    Invoke-Native winget (@('upgrade', '--all', '--silent', '--accept-package-agreements') + $common) `
        -SuccessCodes (@(0) + $script:WingetNoOpCodes)

    # `upgrade --all` exits 0 even when winget refuses an upgrade (e.g. "different install technology"),
    # so list again and warn about whatever is still upgradable. Pinned packages are not listed.
    # Table rows follow the dashed separator; summary lines ("1 upgrades available.") start with a number.
    $list = @(Invoke-Native winget (@('upgrade') + $common) -SuccessCodes (@(0) + $script:WingetNoOpCodes) -PassThru)
    $sep = [array]::FindIndex([string[]]$list, [Predicate[string]] { param($l) $l -match '^-{10,}$' })
    if ($sep -ge 0 -and $sep -lt $list.Count - 1) {
        $remaining = @($list[($sep + 1)..($list.Count - 1)] | Where-Object { $_ -notmatch '^\d+\s' })
        if ($remaining) {
            Set-StepResult -Status WARN -Detail "$($remaining.Count) upgrade(s) not applied (see log; 'winget pin add --id <id>' to skip one)"
        }
    }
}

function Get-PendingRebootReason {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons += 'Windows Update'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons += 'Component Based Servicing'
    }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pfro) { $reasons += 'Pending file rename' }
    $reasons
}

function Write-StepSummary {
    Write-Host ''
    Write-Host '==================== Summary ====================' -ForegroundColor Cyan
    $script:Results |
        Format-Table Step, Status, @{ n = 'Duration'; e = { '{0:hh\:mm\:ss}' -f $_.Duration } }, Detail -AutoSize -Wrap |
        Out-Host
}

function Get-StepResult { $script:Results.ToArray() }

Export-ModuleMember -Function Test-IsAdmin, Start-WDLog, Set-StepResult, Invoke-Step, Invoke-Native,
    Invoke-WingetUpgrade, Get-PendingRebootReason, Write-StepSummary, Get-StepResult
