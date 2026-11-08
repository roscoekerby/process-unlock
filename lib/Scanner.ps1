# Shared scan/kill logic for process-unlock. Dot-source this file.

$script:NativeSource = Join-Path $PSScriptRoot 'Native.cs'
$script:ToolRoot = Split-Path $PSScriptRoot -Parent
$script:RmBatchSize = 500
$script:GracefulCloseMs = 5000
$script:ProtectedNames = @(
    'explorer', 'System', 'Idle', 'Registry', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'smss', 'svchost', 'dwm',
    'MsMpEng', 'dllhost', 'sihost', 'taskhostw', 'RuntimeBroker', 'ShellExperienceHost', 'StartMenuExperienceHost',
    'SearchHost', 'SearchIndexer', 'ApplicationFrameHost', 'ctfmon', 'spoolsv', 'fontdrvhost', 'conhost'
)

if (-not ('ProcessUnlock.HandleScan' -as [type])) {
    Add-Type -Path $script:NativeSource
}

function Test-ContainsPath([string]$Text, [string]$Target) {
    <# True if $Text mentions $Target as a whole path (not as a prefix of a longer name). #>
    if (-not $Text) { return $false }
    # A space ends an unquoted path only if the path itself has none; "C:\x\Client Files" must not match "C:\x\Client Files 2".
    $enders = @('\', '"', "'")
    if (-not $Target.Contains(' ')) { $enders += ' ' }
    $from = 0
    while (($i = $Text.IndexOf($Target, $from, [StringComparison]::OrdinalIgnoreCase)) -ge 0) {
        $end = $i + $Target.Length
        if ($end -ge $Text.Length -or $enders -contains [string]$Text[$end]) { return $true }
        $from = $i + 1
    }
    $false
}

function Get-FilesNoReparse([string]$Root) {
    <# All files under $Root without following junctions/symlinks. #>
    $files = New-Object Collections.Generic.List[string]
    $stack = New-Object Collections.Generic.Stack[string]
    $stack.Push($Root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($dir)) { $files.Add($f) }
            foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) {
                if (-not ([IO.File]::GetAttributes($d) -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($d) }
            }
        } catch { }
    }
    $files.ToArray()
}

function Get-SelfProcessIds([hashtable]$ById) {
    $ids = @{}
    $p = $ById[[int]$PID]
    while ($p -and -not $ids.ContainsKey([int]$p.ProcessId)) {
        $ids[[int]$p.ProcessId] = $true
        $p = $ById[[int]$p.ParentProcessId]
    }
    $ids
}

function Get-RmLockers([string[]]$Files, [ref]$Warnings) {
    $found = @{}
    for ($i = 0; $i -lt $Files.Count; $i += $script:RmBatchSize) {
        $batch = $Files[$i..([Math]::Min($i + $script:RmBatchSize, $Files.Count) - 1)]
        try { foreach ($procId in [ProcessUnlock.RmLocker]::Find($batch)) { $found[$procId] = 'has a file open' } }
        catch { $Warnings.Value += "Restart Manager: $($_.Exception.Message)" }
    }
    $found
}

function Get-PathReferencers([string]$Target, [object[]]$CimProcs) {
    # Loaded DLLs are not scanned here: Restart Manager already reports processes with a file in the folder loaded as a module.
    $found = @{}
    foreach ($p in $CimProcs) {
        if (Test-ContainsPath $p.ExecutablePath $Target) { $found[[int]$p.ProcessId] = 'runs from inside it' }
        elseif (Test-ContainsPath $p.CommandLine $Target) { $found[[int]$p.ProcessId] = 'mentions path in command line' }
    }
    $found
}

function Get-Lockers {
    <# Returns one object per process holding $Path (a file or folder) open. #>
    param([Parameter(Mandatory)][string]$Path)

    $target = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    $files = if (Test-Path -LiteralPath $target -PathType Container) { @(Get-FilesNoReparse $target) } else { @($target) }

    $hits = @{}
    $warnings = @()
    $merge = { param($map) foreach ($kv in $map.GetEnumerator()) { if (-not $hits.ContainsKey($kv.Key)) { $hits[$kv.Key] = $kv.Value } } }

    if ($files.Count) { & $merge (Get-RmLockers $files ([ref]$warnings)) }
    try {
        $map = @{}
        foreach ($procId in [ProcessUnlock.HandleScan]::Find($target, $script:NativeSource)) { $map[$procId] = 'has it open' }
        & $merge $map
    } catch { $warnings += "Handle scan: $($_.Exception.Message)" }
    $cim = @(Get-CimInstance Win32_Process)
    & $merge (Get-PathReferencers $target $cim)

    $byId = @{}; foreach ($c in $cim) { $byId[[int]$c.ProcessId] = $c }
    $self = Get-SelfProcessIds $byId
    $rows = foreach ($kv in $hits.GetEnumerator()) {
        if ($self.ContainsKey($kv.Key) -or (Test-ContainsPath $byId[$kv.Key].CommandLine $script:ToolRoot)) { continue }
        $proc = Get-Process -Id $kv.Key -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        $started = try { $proc.StartTime } catch { $null }
        [pscustomobject]@{
            PID         = $proc.Id
            Name        = $proc.ProcessName
            Reason      = $kv.Value
            Window      = $proc.MainWindowTitle
            CommandLine = $byId[$proc.Id].CommandLine
            StartTime   = $started
            Protected   = $script:ProtectedNames -contains $proc.ProcessName
        }
    }
    [pscustomobject]@{ Target = $target; FileCount = $files.Count; Lockers = @($rows | Sort-Object Name, PID); Warnings = $warnings }
}

function Stop-Locker {
    <#
      Asks the process to close via its main window. If it doesn't exit (e.g. it's showing "Save changes?"), leaves it
      running unless -Force. Processes without a window are killed outright. Returns a status line.
      -StartTime guards against the PID having been reused by a different process since the scan.
    #>
    param([Parameter(Mandatory)][int]$ProcessId, [Nullable[datetime]]$StartTime, [switch]$Force)
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return "PID $ProcessId already gone" }
    if ($script:ProtectedNames -contains $p.ProcessName) { return "Skipped $($p.ProcessName) ($ProcessId): protected" }
    if ($StartTime) {
        $now = try { $p.StartTime } catch { $null }
        if ($now -and $now -ne $StartTime) { return "Skipped PID ${ProcessId}: it's a different process now (rescan)" }
    }
    try {
        if (-not $Force -and $p.MainWindowHandle -ne 0) {
            if ($p.CloseMainWindow() -and $p.WaitForExit($script:GracefulCloseMs)) { return "Closed $($p.ProcessName) ($ProcessId)" }
            return "$($p.ProcessName) ($ProcessId) is still open; it may be asking to save. Deal with it, or kill again to force."
        }
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        $null = $p.WaitForExit($script:GracefulCloseMs)
        "Killed $($p.ProcessName) ($ProcessId)"
    } catch { "Failed on $($p.ProcessName) ($ProcessId): $($_.Exception.Message)" }
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
