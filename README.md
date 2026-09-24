# win_daily
maintenance of windows env

Daily maintenance scripts for the Windows 11 host. Two scripts, because scoop must not run
elevated while Windows Update / machine-wide installs must.

| Script | Run as | Daily | Weekly (`-WeeklyDay`, default Sunday, or `-Weekly`) |
|---|---|---|---|
| `src/maintenance-admin.ps1` | elevated | Windows Update, `winget upgrade --scope machine`, Defender signatures, `wsl --update` | Defender quick scan, DISM health check (+ RestoreHealth/sfc if repairable), DISM component cleanup |
| `src/maintenance-user.ps1` | normal user (refuses elevation) | scoop update, `winget upgrade --scope user`, disk free space | scoop cleanup/checkup, PowerShell module update (CurrentUser) |

Both report a pending reboot, print a summary table and exit `1` if any step failed.

## Requirements
- PowerShell 7 (`pwsh`)
- [PSWindowsUpdate](https://www.powershellgallery.com/packages/PSWindowsUpdate) for the admin script:
  `Install-PSResource PSWindowsUpdate -Scope AllUsers` (elevated)

## Usage
Run from a Windows path, not `\\wsl.localhost\...` (execution policy treats UNC paths as remote).
Deploy from WSL with `./deploy.sh` (copies `src/` to `%LOCALAPPDATA%\win_daily`, or to the path given
as the first argument). Don't copy via Explorer from `\\wsl.localhost`: those copies get a
`Zone.Identifier` (Internet zone) mark and `RemoteSigned` refuses them ("is not digitally signed").
If that happened, fix it with `Get-ChildItem <dir> | Unblock-File`.

Then, in `%LOCALAPPDATA%\win_daily`:

```powershell
pwsh -File .\maintenance-user.ps1
sudo pwsh -NoExit -File .\maintenance-admin.ps1   # or: Start-Process pwsh -Verb RunAs -ArgumentList '-NoExit', '-File', '...'
```

If `sudo` is in "force new window" mode (the default), the elevated window closes when the script
ends; `-NoExit` keeps it open. Otherwise check the log file.

Common options: `-DryRun` (list only, change nothing), `-Weekly` (force weekly tasks).
Admin only: `-IncludeDrivers`, `-ForceWslUpdate`, `-AllowReboot` (reboot in 5 min if pending; `shutdown /a` aborts).

Logs: admin → `%ProgramData%\win_daily\logs`, user → `%LOCALAPPDATA%\win_daily\logs` (30 days kept).

## Scheduled tasks
`register-tasks.ps1` (deployed alongside the scripts) creates `\win_daily\admin` (highest privileges,
no UAC prompt) and `\win_daily\user`, both running as you while logged on, daily at 12:00 / 12:30.
Missed runs (PC off or asleep) start as soon as possible afterwards.

```powershell
sudo pwsh -File .\register-tasks.ps1                                  # defaults
sudo pwsh -File .\register-tasks.ps1 -AdminTime 09:00 -UserTime 09:30 -AdminArguments '-AllowReboot'
sudo pwsh -File .\register-tasks.ps1 -Unregister
Start-ScheduledTask -TaskPath '\win_daily\' -TaskName admin           # run now
Get-ScheduledTask -TaskPath '\win_daily\' | Get-ScheduledTaskInfo     # last result (0 = no step failed)
```

The tasks run the scripts from the directory `register-tasks.ps1` was run from; re-running
`./deploy.sh` updates them in place, no re-registration needed. Results are only in the logs.

## Notes
- Windows Update: Microsoft Update is registered on first run (Office/.NET/VC++ updates).
  Feature upgrades, `Preview` updates and drivers are excluded; never reboots unless `-AllowReboot`.
- `wsl --update` restarts WSL, so it is skipped (WARN) while a distro is running.
  Running the admin script from inside WSL therefore usually skips it; use `-ForceWslUpdate` from Windows.
- winget: machine-scope packages are upgraded by the admin script, user-scope by the user script.
  `winget upgrade --all` exits 0 even when it refuses an upgrade, so the scripts list upgrades again
  afterwards and WARN about anything left. For packages that update themselves or can't be upgraded by
  winget (e.g. Edge: "different install technology"), pin them once: `winget pin add --id Microsoft.Edge`.
- winget skips packages whose installed version is unknown (see `winget upgrade --include-unknown`).
