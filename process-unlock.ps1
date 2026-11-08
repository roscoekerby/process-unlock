<#
.SYNOPSIS
  Finds which processes are holding a file or folder open, and optionally closes them.

.EXAMPLE
  .\process-unlock.ps1 "C:\path\Client Files"                # report only
  .\process-unlock.ps1 "C:\path\Client Files" -Kill          # close the lockers (asks per process)
  .\process-unlock.ps1 "C:\path\Client Files" -Kill -Force   # no prompts, force-kill even if an app is asking to save
  .\process-unlock.ps1 "C:\path\Client Files" -Gui           # same pop-up the watcher shows
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [switch]$Kill,
    [switch]$Force,
    [switch]$Gui
)

$ErrorActionPreference = 'Stop'

if ($Gui) {
    # Separate process with a neutral working directory, so neither the pop-up nor this shell's cwd changes.
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $popup = Join-Path $PSScriptRoot 'popup.ps1'
    Start-Process powershell.exe -WorkingDirectory $env:LOCALAPPDATA -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$popup`" -Path:`"$full`""
    return
}

. (Join-Path $PSScriptRoot 'lib\Scanner.ps1')

$result = Get-Lockers -Path $Path
Write-Host "Scanned $($result.FileCount) file(s) under: $($result.Target)" -ForegroundColor Cyan
$result.Warnings | ForEach-Object { Write-Warning $_ }

if (-not $result.Lockers.Count) {
    Write-Host "No process found holding it." -ForegroundColor Green
    if (-not (Test-IsAdmin)) { Write-Host "Not elevated: admin/SYSTEM processes can't be inspected. Re-run in an admin PowerShell to see them." -ForegroundColor Yellow }
    Write-Host "Also check: an Explorer window or preview pane (Alt+P) showing it."
    return
}

$result.Lockers | Format-Table PID, Name, Reason, Window -AutoSize | Out-String -Width 200 | Write-Host
if (-not $Kill) { Write-Host "Report only. Re-run with -Kill to close these." -ForegroundColor Yellow; return }

foreach ($r in $result.Lockers) {
    if ($r.Protected) { Write-Host "Skipping $($r.Name) ($($r.PID)): protected. Close its window instead." -ForegroundColor Yellow; continue }
    if (-not $Force) {
        $ans = Read-Host "Close $($r.Name) (PID $($r.PID))? Unsaved work will be lost. [y/N]"
        if ($ans -notmatch '^(y|yes)$') { continue }
    }
    Write-Host (Stop-Locker -ProcessId $r.PID -StartTime $r.StartTime -Force:$Force)
}
