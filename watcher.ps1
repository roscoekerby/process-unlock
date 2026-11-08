<#
.SYNOPSIS
  Background watcher: when Explorer reports a file or folder "in use", opens popup.ps1 for it.
  Started at logon by start-watcher.vbs (see install.ps1). Single instance.
#>
$ErrorActionPreference = 'Stop'

$PollMs = 750
$ForgetAfterMs = 5000
$MutexName = 'Local\ProcessUnlockWatcher'
$DataDir = Join-Path $env:LOCALAPPDATA 'process-unlock'
$LogFile = Join-Path $DataDir 'watcher.log'
$MaxLogBytes = 1MB
$Popup = Join-Path $PSScriptRoot 'popup.ps1'

New-Item -ItemType Directory -Force $DataDir | Out-Null
# Never sit inside a user folder; that would lock it ourselves.
Set-Location -LiteralPath $DataDir

function Write-Log([string]$Message) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $MaxLogBytes) { Move-Item $LogFile "$LogFile.old" -Force }
        Add-Content -LiteralPath $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message) -Encoding UTF8
    } catch { }  # A locked log must never kill the watcher.
}

$created = $false
$mutex = New-Object Threading.Mutex($true, $MutexName, [ref]$created)
if (-not $created) { exit 0 }

. (Join-Path $PSScriptRoot 'lib\Scanner.ps1')
. (Join-Path $PSScriptRoot 'lib\Dialog.ps1')

function Start-Popup($Tile, [int]$Stack) {
    $path = Resolve-TilePath $Tile
    Write-Log "In use: '$($Tile.ItemName)' ($($Tile.Operation)) -> $(if ($path) { $path } else { 'unresolved' })"
    # Colon form so a name starting with '-' isn't read as a parameter.
    $argLine = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$Popup`" -Hwnd:$($Tile.Hwnd) -ItemName:`"$($Tile.ItemName)`" -Stack:$Stack"
    if ($path) { $argLine += " -Path:`"$path`"" }
    Start-Process powershell.exe -ArgumentList $argLine -WorkingDirectory $DataDir -WindowStyle Hidden
}

Write-Log "Watcher started (PID $PID)"
$seen = @{}
try {
    while ($true) {
        try {
            $now = Get-Date
            foreach ($t in @(Get-InUseTiles)) {
                $isNew = -not $seen.ContainsKey($t.Key)
                $seen[$t.Key] = $now  # mark first, so a failed launch isn't retried every poll
                if ($isNew) {
                    try { Start-Popup $t ($seen.Count - 1) } catch { Write-Log "Popup launch failed for '$($t.ItemName)': $($_.Exception.Message)" }
                }
            }
            # Forget a tile only after it has been gone a while; UI Automation reads occasionally come back empty.
            foreach ($k in @($seen.Keys)) { if (($now - $seen[$k]).TotalMilliseconds -gt $ForgetAfterMs) { $seen.Remove($k) } }
        } catch { Write-Log "Error: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds $PollMs
    }
} finally {
    Write-Log 'Watcher stopped'
    $mutex.ReleaseMutex()
}
