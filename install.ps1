<#
.SYNOPSIS
  Adds the process-unlock watcher to Startup (current user, no admin) and starts it now.
  Use -Uninstall to remove it and stop the running watcher.
#>
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Process Unlock Watcher.lnk'
$Launcher = Join-Path $PSScriptRoot 'start-watcher.vbs'

function Get-Watchers {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*process-unlock\watcher.ps1*' }
}

if ($Uninstall) {
    if (Test-Path $Shortcut) { Remove-Item $Shortcut; "Removed Startup shortcut" }
    Get-Watchers | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; "Stopped watcher PID $($_.ProcessId)" }
    return
}

$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($Shortcut)
$lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$lnk.Arguments = "`"$Launcher`""
$lnk.WorkingDirectory = $env:LOCALAPPDATA
$lnk.Description = 'Shows which process locks a file/folder when Explorer says it is in use'
$lnk.Save()
"Startup shortcut: $Shortcut"

if (-not (Get-Watchers)) { Start-Process wscript.exe -ArgumentList "`"$Launcher`"" -WorkingDirectory $env:LOCALAPPDATA }
Start-Sleep -Seconds 2
$w = @(Get-Watchers)
if ($w.Count) { "Watcher running (PID $($w.ProcessId -join ', '))" } else { throw 'Watcher did not start; see %LOCALAPPDATA%\process-unlock\watcher.log' }
