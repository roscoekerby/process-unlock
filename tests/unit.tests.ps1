# Run: powershell -NoProfile -File tests\unit.tests.ps1   (exit code = number of failures)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\Scanner.ps1')
. (Join-Path $root 'lib\Dialog.ps1')

$script:fail = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "PASS $Name" -ForegroundColor Green } else { Write-Host "FAIL $Name" -ForegroundColor Red; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("pu-unit-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
Set-Location $env:LOCALAPPDATA
try {
    # Test-ContainsPath: whole-path matching, no wildcards
    Check 'path boundary: exact end' (Test-ContainsPath 'x "C:\a\Client Files"' 'C:\a\Client Files')
    Check 'path boundary: child path' (Test-ContainsPath 'C:\a\Client Files\f.txt' 'C:\a\Client Files')
    Check 'path boundary: rejects longer sibling' (-not (Test-ContainsPath 'C:\a\Client Files 2\f.txt' 'C:\a\Client Files'))
    Check 'path boundary: sibling then real' (Test-ContainsPath 'C:\a\Client Files 2 "C:\a\Client Files"' 'C:\a\Client Files')
    Check 'unquoted no-space path then arg' (Test-ContainsPath 'code C:\proj --new-window' 'C:\proj')
    Check 'brackets are literal' (Test-ContainsPath 'C:\p\Photos [2023]\x' 'C:\p\Photos [2023]')
    Check 'brackets no false hit' (-not (Test-ContainsPath 'C:\p\Photos 2\x' 'C:\p\Photos [2]'))
    Check 'case-insensitive' (Test-ContainsPath 'c:\A\b' 'C:\a\B')
    Check 'null text' (-not (Test-ContainsPath $null 'C:\a'))

    # Get-FilesNoReparse: does not follow junctions
    $inside = Join-Path $tmp 'inside'; $outside = Join-Path $tmp 'outside'
    New-Item -ItemType Directory $inside, $outside | Out-Null
    'a' | Out-File (Join-Path $inside 'a.txt'); 'b' | Out-File (Join-Path $outside 'b.txt')
    cmd /c mklink /J "$inside\jn" "$outside" | Out-Null
    $files = Get-FilesNoReparse $inside
    Check 'enumerates real files' ($files -contains (Join-Path $inside 'a.txt'))
    Check 'skips junction contents' (-not ($files | Where-Object { $_ -like '*b.txt' }))

    # Get-SourceFolderName
    Check 'source from move' ((Get-SourceFolderName 'Moving 1 item from Projects to Archive - Interrupted - 0% complete') -eq 'Projects')
    Check 'source from recycle' ((Get-SourceFolderName 'Recycling 2 items from e2e - Interrupted - 0 items recycled') -eq 'e2e')

    # Find-ItemInFolder: hidden extension
    'x' | Out-File (Join-Path $outside 'report.docx')
    Check 'hidden extension resolves' ((Find-ItemInFolder $outside 'report' @()) -eq (Join-Path $outside 'report.docx'))

    # Lockers: cwd lock found, file lock found, wrong-start-time kill refused
    $cwdLock = Start-Process powershell -PassThru -WindowStyle Hidden -WorkingDirectory $inside -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60'
    $fileLock = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', "`$s=[IO.File]::Open('$inside\a.txt','Open','Read','None'); Start-Sleep 60"
    Start-Sleep 3
    $r = Get-Lockers -Path $inside
    $ids = @($r.Lockers | ForEach-Object PID)
    Check 'finds cwd locker' ($ids -contains $cwdLock.Id)
    Check 'finds file locker' ($ids -contains $fileLock.Id)
    Check 'excludes self' (-not ($ids -contains $PID))
    $msg = Stop-Locker -ProcessId $cwdLock.Id -StartTime ([datetime]'2000-01-01')
    Check 'PID-reuse guard refuses' ($msg -like '*different process*' -and -not $cwdLock.HasExited)
    $row = $r.Lockers | Where-Object PID -eq $cwdLock.Id
    $null = Stop-Locker -ProcessId $cwdLock.Id -StartTime $row.StartTime
    Check 'kill with matching start time' ($cwdLock.WaitForExit(5000))
    Stop-Process -Id $fileLock.Id -Force

    # Handle scan must not hang on a blocked synchronous pipe
    $pipeName = 'pu-hang-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $server = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', "`$p = New-Object IO.Pipes.NamedPipeServerStream('$pipeName'); `$p.WaitForConnection(); `$b = New-Object byte[] 1; `$p.Read(`$b, 0, 1)"
    $client = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', "`$c = New-Object IO.Pipes.NamedPipeClientStream('.', '$pipeName'); `$c.Connect(5000); `$b = New-Object byte[] 1; `$c.Read(`$b, 0, 1)"
    Start-Sleep 3
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = [ProcessUnlock.HandleScan]::Find($inside, (Join-Path $root 'lib\Native.cs'))
    Check "handle scan finishes with blocked pipes present ($($sw.ElapsedMilliseconds) ms)" ($sw.ElapsedMilliseconds -lt 15000)
    Stop-Process -Id $server.Id, $client.Id -Force -ErrorAction SilentlyContinue
}
finally {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$tmp*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 1
    cmd /c rmdir "$tmp\inside\jn" 2>$null
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "`n$script:fail failure(s)"
exit $script:fail
