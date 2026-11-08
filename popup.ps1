<#
.SYNOPSIS
  Pop-up listing the processes locking a file or folder, with Kill buttons.
  Launched by watcher.ps1 (with -Hwnd/-ItemName so it can press Explorer's Try Again), or by process-unlock.ps1 -Gui.
#>
param(
    [string]$Path,
    [long]$Hwnd = 0,
    [string]$ItemName,
    [int]$Stack = 0
)

$ErrorActionPreference = 'Stop'
# Never sit inside the folder being unlocked.
Set-Location -LiteralPath $env:LOCALAPPDATA
. (Join-Path $PSScriptRoot 'lib\Scanner.ps1')
. (Join-Path $PSScriptRoot 'lib\Dialog.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$TileCheckMs = 1500
$RetrySettleMs = 1500
$MissesBeforeClose = 3
$Width = 820
$Height = 380
$StackOffset = 36
$linked = $Hwnd -ne 0 -and $ItemName

$form = New-Object Windows.Forms.Form -Property @{
    Text = 'Process Unlock'; Width = $Width; Height = $Height; TopMost = $true
    StartPosition = 'Manual'; Font = New-Object Drawing.Font('Segoe UI', 9)
    MinimumSize = New-Object Drawing.Size(560, 260)
}

$header = New-Object Windows.Forms.Label -Property @{
    Dock = 'Top'; Height = 34; Padding = '10,8,10,0'; AutoEllipsis = $true
    Font = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)
}
$pathLabel = New-Object Windows.Forms.Label -Property @{ Dock = 'Top'; Height = 22; Padding = '10,0,10,0'; AutoEllipsis = $true; ForeColor = [Drawing.Color]::DimGray }
$status = New-Object Windows.Forms.Label -Property @{ Dock = 'Top'; Height = 26; Padding = '10,2,10,0'; AutoEllipsis = $true }

$grid = New-Object Windows.Forms.DataGridView -Property @{
    Dock = 'Fill'; ReadOnly = $true; AllowUserToAddRows = $false; AllowUserToDeleteRows = $false
    SelectionMode = 'FullRowSelect'; MultiSelect = $true; RowHeadersVisible = $false
    AutoSizeColumnsMode = 'Fill'; BackgroundColor = [Drawing.SystemColors]::Window
}
foreach ($col in @(@('PID', 8), @('Name', 14), @('Reason', 20), @('Window', 22), @('Command line', 36))) {
    $i = $grid.Columns.Add($col[0], $col[0]); $grid.Columns[$i].FillWeight = $col[1]
}

$buttons = New-Object Windows.Forms.FlowLayoutPanel -Property @{ Dock = 'Bottom'; Height = 44; Padding = '6,6,6,6'; FlowDirection = 'RightToLeft' }
function New-Button([string]$Text) {
    $b = New-Object Windows.Forms.Button -Property @{ Text = $Text; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Height = 30; Padding = '8,4,8,4'; Font = $form.Font }
    $buttons.Controls.Add($b); $b
}
$btnClose = New-Button 'Close'
$btnRefresh = New-Button 'Refresh'
$btnRetry = if ($linked) { New-Button 'Kill all && Try Again' }
$btnKillAll = New-Button 'Kill all'
$btnKill = New-Button 'Kill selected'

$form.Controls.AddRange(@($grid, $status, $pathLabel, $header, $buttons))

function Set-Status([string]$Text, [string]$Color = 'Black') {
    $status.Text = $Text; $status.ForeColor = [Drawing.Color]::$Color; $form.Refresh()
}

function Test-HoldsIt($Locker) { $Locker.Reason -ne 'mentions path in command line' }

function Set-KillEnabled([bool]$On) {
    foreach ($b in @($btnKill, $btnKillAll, $btnRetry)) { if ($b) { $b.Enabled = $On } }
}

function Update-Grid {
    $grid.Rows.Clear()
    Set-KillEnabled $false
    if ($linked -and -not ($script:Path -and (Test-Path -LiteralPath $script:Path))) {
        $tile = Find-Tile $Hwnd $ItemName
        if ($tile) { $script:Path = Resolve-TilePath $tile }
    }
    if (-not $script:Path -or -not (Test-Path -LiteralPath $script:Path)) {
        $header.Text = if ($ItemName) { "`"$ItemName`" is in use" } else { 'No path given' }
        $pathLabel.Text = "Couldn't locate it on disk (it may have moved)."
        Set-Status 'Open the folder that holds it in Explorer, or run process-unlock.ps1 with the full path.' 'DarkRed'
        return
    }
    $header.Text = "`"$(Split-Path $script:Path -Leaf)`" is in use"
    $pathLabel.Text = $script:Path
    Set-Status 'Scanning...' 'DimGray'
    $form.Cursor = 'WaitCursor'
    try { $result = Get-Lockers -Path $script:Path } finally { $form.Cursor = 'Default' }
    foreach ($r in $result.Lockers) {
        $i = $grid.Rows.Add($r.PID, $r.Name, $r.Reason, $r.Window, $r.CommandLine)
        $grid.Rows[$i].Tag = $r
        if ($r.Protected) { $grid.Rows[$i].DefaultCellStyle.ForeColor = [Drawing.Color]::Gray }
        elseif (-not (Test-HoldsIt $r)) { $grid.Rows[$i].DefaultCellStyle.ForeColor = [Drawing.Color]::SteelBlue }
    }
    $grid.ClearSelection()
    $n = $result.Lockers.Count
    Set-KillEnabled ($n -gt 0)
    if ($n) {
        $notes = @()
        if ($result.Lockers | Where-Object Protected) { $notes += "Grey = system process, can't be killed here." }
        if ($result.Lockers | Where-Object { -not $_.Protected -and -not (Test-HoldsIt $_) }) { $notes += 'Blue = only mentions the path; not in Kill all, use Kill selected.' }
        Set-Status ("$n process(es) found. " + ($notes -join ' ')) 'DarkOrange'
    }
    else {
        $extra = if (Test-IsAdmin) { '' } else { ' Not elevated, so admin/SYSTEM processes are hidden.' }
        Set-Status "No process found. Check Explorer windows or the preview pane (Alt+P).$extra" 'DarkGreen'
        if ($btnRetry) { $btnRetry.Enabled = $true }
    }
    if ($result.Warnings) { $status.Text += '  [' + ($result.Warnings -join '; ') + ']' }
}

function Get-KillAllRows {
    @($grid.Rows | Where-Object { $_.Tag -and -not $_.Tag.Protected -and (Test-HoldsIt $_.Tag) })
}

function Confirm-Kill($Rows) {
    if (-not $Rows.Count) { Set-Status 'Nothing to kill (only system or path-mentioning processes). Use Kill selected for those.' 'DarkRed'; return $false }
    $names = ($Rows | ForEach-Object { "$($_.Tag.Name) (PID $($_.Tag.PID))" }) -join "`n"
    $msg = "Close these processes? Unsaved work in them may be lost.`n`n$names"
    [Windows.Forms.MessageBox]::Show($form, $msg, 'Process Unlock', 'YesNo', 'Warning') -eq 'Yes'
}

function Stop-Rows($Rows, [switch]$NoRescan) {
    $msgs = @(foreach ($row in $Rows) {
        $r = $row.Tag
        if (-not $r -or $r.Protected) { continue }
        # First click asks the app to close; a second click on a process that didn't close forces it.
        $force = $script:Asked.ContainsKey($r.PID)
        $script:Asked[$r.PID] = $true
        Stop-Locker -ProcessId $r.PID -StartTime $r.StartTime -Force:$force
    })
    if (-not $NoRescan) { Update-Grid }
    if ($msgs.Count) { Set-Status ($msgs -join '; ') 'DarkGreen' }
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action } catch { $form.Cursor = 'Default'; Set-KillEnabled $true; Set-Status "Error: $($_.Exception.Message)" 'DarkRed' }
}

$script:Asked = @{}
$btnKill.Add_Click({ Invoke-Safely {
    if (-not $grid.SelectedRows.Count) { Set-Status 'Select one or more rows first.' 'DarkRed'; return }
    Stop-Rows @($grid.SelectedRows)
} })
$btnKillAll.Add_Click({ Invoke-Safely {
    $rows = Get-KillAllRows
    if (Confirm-Kill $rows) { Stop-Rows $rows }
} })
$btnRefresh.Add_Click({ Invoke-Safely { Update-Grid } })
$btnClose.Add_Click({ $form.Close() })
if ($btnRetry) {
    $btnRetry.Add_Click({ Invoke-Safely {
        $rows = Get-KillAllRows
        if ($rows.Count -and -not (Confirm-Kill $rows)) { return }
        Stop-Rows $rows -NoRescan
        if (Invoke-TileRetry -Hwnd $Hwnd -ItemName $ItemName) { Set-Status 'Pressed Try Again in Explorer.' 'DarkGreen'; Start-Sleep -Milliseconds $RetrySettleMs }
        else { Set-Status "Couldn't find Explorer's Try Again button; press it yourself." 'DarkRed' }
    } })
}

if ($linked) {
    # Close automatically once Explorer's interruption is resolved or cancelled. UIA reads can briefly come back empty,
    # so require several misses in a row.
    $script:Misses = 0
    $timer = New-Object Windows.Forms.Timer -Property @{ Interval = $TileCheckMs }
    $timer.Add_Tick({
        try { $script:Misses = if (Find-Tile $Hwnd $ItemName) { 0 } else { $script:Misses + 1 } } catch { $script:Misses++ }
        if ($script:Misses -ge $MissesBeforeClose) { $timer.Stop(); $form.Close() }
    })
    $timer.Start()
}

function Set-StartPosition {
    $screen = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $rect = if ($Hwnd) { [ProcessUnlock.Win]::Rect($Hwnd) }
    $x = $screen.Right - $Width - 20; $y = $screen.Bottom - $Height - 20
    if ($rect) {
        $x = if ($rect[2] + $Width -le $screen.Right) { $rect[2] + 8 } else { [Math]::Max($screen.Left, $rect[0] - $Width - 8) }
        $y = [Math]::Min([Math]::Max($screen.Top, $rect[1]), $screen.Bottom - $Height)
    }
    $x = [Math]::Max($screen.Left, $x - $Stack * $StackOffset)
    $y = [Math]::Max($screen.Top, $y - $Stack * $StackOffset)
    $form.Location = New-Object Drawing.Point($x, $y)
}

Set-StartPosition
$form.Add_Shown({ $form.Activate(); Invoke-Safely { Update-Grid } })
[void]$form.ShowDialog()
