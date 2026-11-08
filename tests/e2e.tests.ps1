<#
  Real-user E2E: lock a folder, trigger a real Explorer delete, and drive the pop-up the watcher opens.
  Run: powershell -NoProfile -File tests\e2e.tests.ps1 [-Headed]   (exit code = number of failures)
  The watcher must be running (install.ps1). -Headed pauses between steps so you can watch.
#>
param([switch]$Headed)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\Scanner.ps1')
. (Join-Path $root 'lib\Dialog.ps1')
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class E2E { delegate bool P(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, P cb, IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumWindows(P cb, IntPtr l);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
 static string Text(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
 public static Dictionary<long,string> Children(long parent) { var r = new Dictionary<long,string>();
  EnumChildWindows(new IntPtr(parent), (h,l)=>{ r[h.ToInt64()] = Text(h); return true; }, IntPtr.Zero); return r; }
 public static List<long> TopLevel(int pid) { var r = new List<long>();
  EnumWindows((h,l)=>{ uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) r.Add(h.ToInt64()); return true; }, IntPtr.Zero); return r; }
 public static string Title(long h) { return Text(new IntPtr(h)); } }
'@

$script:fail = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "PASS $Name" -ForegroundColor Green } else { Write-Host "FAIL $Name" -ForegroundColor Red; $script:fail++ }
}
function Pause-Headed([string]$Step) { if ($Headed) { Write-Host "-- $Step (watch the screen)" -ForegroundColor Cyan; Start-Sleep 3 } }
function Wait-Until([scriptblock]$Cond, [int]$Seconds = 20) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) { $v = & $Cond; if ($v) { return $v }; Start-Sleep -Milliseconds 300 }
    $null
}
function Click-Child([long]$Parent, [string]$Like) {
    $c = [E2E]::Children($Parent).GetEnumerator() | Where-Object { $_.Value -like $Like } | Select-Object -First 1
    if (-not $c) { return $false }
    [void][E2E]::PostMessage([IntPtr]$c.Key, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)  # BM_CLICK
    $true
}
function Get-PopupProcess([string]$ItemName) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*popup.ps1*$ItemName*" } | Select-Object -First 1
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("pu-e2e-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $work | Out-Null
Set-Location $env:LOCALAPPDATA
$item = 'PU E2E Folder'
$target = Join-Path $work $item
New-Item -ItemType Directory $target | Out-Null
'hello' | Out-File (Join-Path $target 'note.txt')
$locker = $null; $deleter = $null
try {
    Check 'watcher running' ([bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*process-unlock\watcher.ps1*' }))

    $locker = Start-Process powershell -PassThru -WindowStyle Hidden -WorkingDirectory $target -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 300'
    Start-Process explorer.exe $work
    $shell = New-Object -ComObject Shell.Application
    $win = Wait-Until { @($shell.Windows()) | Where-Object { try { $_.Document.Folder.Self.Path -eq $work } catch { $false } } | Select-Object -First 1 }
    Check 'explorer window opened' ([bool]$win)
    Pause-Headed 'Explorer open; deleting the locked folder'

    # Delete from inside Explorer's own view so the in-use prompt is Explorer's.
    $cmd = "`$s = New-Object -ComObject Shell.Application; `$w = @(`$s.Windows()) | Where-Object { try { `$_.Document.Folder.Self.Path -eq '$work' } catch { `$false } } | Select-Object -First 1; `$w.Document.Folder.ParseName('$item').InvokeVerb('delete'); Start-Sleep 60"
    $deleter = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $cmd

    $tile = Wait-Until { Get-InUseTiles | Where-Object ItemName -eq $item }
    Check 'explorer shows in-use prompt' ([bool]$tile)
    $popup = Wait-Until { Get-PopupProcess $item }
    Check 'watcher opened pop-up' ([bool]$popup)
    $hwnd = Wait-Until { (Get-Process -Id $popup.ProcessId).MainWindowHandle | Where-Object { $_ -ne 0 } }
    $listed = Wait-Until { [E2E]::Children([long]$hwnd).Values | Where-Object { $_ -like '*process(es) found*' } }
    Check 'pop-up finished scanning' ([bool]$listed)
    Check 'pop-up shows the right path' ([E2E]::Children([long]$hwnd).Values -contains $target)
    Pause-Headed 'Pop-up listed the locker; clicking Kill all & Try Again'

    Check 'clicked Kill all & Try Again' (Click-Child $hwnd 'Kill all*Try*')
    $confirm = Wait-Until { [E2E]::TopLevel($popup.ProcessId) | Where-Object { $_ -ne [long]$hwnd -and [E2E]::Title($_) -eq 'Process Unlock' } } 10
    Check 'confirm dialog shown' ([bool]$confirm)
    $text = ([E2E]::Children([long]@($confirm)[0]).Values) -join ' '
    Check 'confirm lists the locker' ($text -like "*PID $($locker.Id)*")
    Pause-Headed 'Confirming'
    [void](Click-Child @($confirm)[0] '&Yes')

    Check 'locker closed' ($locker.WaitForExit(15000))
    Check 'folder deleted by Explorer retry' ([bool](Wait-Until { -not (Test-Path -LiteralPath $target) } 20))
    Check 'pop-up closed itself' ([bool](Wait-Until { -not (Get-Process -Id $popup.ProcessId -ErrorAction SilentlyContinue) } 20))
}
finally {
    foreach ($p in @($locker, $deleter)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    foreach ($w in @((New-Object -ComObject Shell.Application).Windows())) { try { if ($w.Document.Folder.Self.Path -eq $work) { $w.Quit() } } catch { } }
    Start-Sleep 1
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "`n$script:fail failure(s)"
exit $script:fail
