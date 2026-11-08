# Finds Explorer "File/Folder In Use" interruptions and works out which item they are about. Dot-source after Scanner.ps1.
# On Windows 10/11 these appear as tiles inside Explorer's OperationStatusWindow; each tile has its own Try Again button.

$script:StatusWindowClass = 'OperationStatusWindow'
$script:TileIdPrefix = 'eltTile'
$script:ItemNameId = 'eltItemName'
$script:RetryButtonId = 'eltInterruptRetryBtn'
$script:DescriptionId = 'eltInterruptDescription'
$script:InUsePattern = 'open in another program|in use|being used'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

function New-IdCondition([string]$Id) {
    New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::AutomationIdProperty), $Id
}

function Get-InUseTiles {
    <# One object per interrupted "in use" operation across all status windows. #>
    foreach ($hwnd in [ProcessUnlock.Win]::FindByClass($script:StatusWindowClass)) {
        try { $root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd) } catch { continue }
        $groupCond = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ControlTypeProperty), ([Windows.Automation.ControlType]::Group)
        foreach ($tile in $root.FindAll([Windows.Automation.TreeScope]::Descendants, $groupCond)) {
            if (-not $tile.Current.AutomationId.StartsWith($script:TileIdPrefix)) { continue }
            $item = $tile.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-IdCondition $script:ItemNameId))
            $retry = $tile.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-IdCondition $script:RetryButtonId))
            $desc = $tile.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-IdCondition $script:DescriptionId))
            if (-not $item -or -not $retry -or -not $desc) { continue }
            if ($desc.Current.Name -notmatch $script:InUsePattern) { continue }
            [pscustomobject]@{
                Hwnd      = [long]$hwnd
                TileId    = $tile.Current.AutomationId
                ItemName  = $item.Current.Name
                Operation = $tile.Current.Name
                # TileId is left out: it may renumber as other tiles resolve, which would look like a new tile.
                Key       = "$hwnd|$($item.Current.Name)"
            }
        }
    }
}

function Get-SourceFolderName([string]$Operation) {
    # e.g. "Moving 1 item from Projects to Archive - Interrupted ..." or "Recycling 2 items from e2e - Interrupted ..."
    if ($Operation -match ' from (.+?)(?: to .+?)? - ') { return $Matches[1] }
    $null
}

function Get-CandidateFolders {
    <# Open Explorer folders (with their selection), then the desktops. #>
    $views = foreach ($w in (New-Object -ComObject Shell.Application).Windows()) {
        try {
            $folder = $w.Document.Folder.Self.Path
            if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) {
                [pscustomobject]@{ Folder = $folder; Selected = @($w.Document.SelectedItems() | ForEach-Object { $_.Path }) }
            }
        } catch { }
    }
    $desktops = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')) |
        ForEach-Object { [pscustomobject]@{ Folder = $_; Selected = @() } }
    @($views) + $desktops
}

function Find-ItemInFolder([string]$Folder, [string]$Name, [string[]]$Selected) {
    $exact = Join-Path $Folder $Name
    if (Test-Path -LiteralPath $exact) { return $exact }
    # Explorer hides known extensions, so "report" may mean "report.docx".
    $candidates = @(Get-ChildItem -LiteralPath $Folder -Force -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -eq $Name } | ForEach-Object FullName)
    if ($candidates.Count -eq 1) { return $candidates[0] }
    $candidates | Where-Object { $Selected -contains $_ } | Select-Object -First 1
}

function Resolve-TilePath {
    <#
      Full path of the tile's item, or $null if it can't be pinned down. A match in the operation's source folder
      ("from X") wins; otherwise the item must match in exactly one open folder, so a common name like "New folder"
      is never guessed (the popup then asks the user to open the folder and Refresh).
    #>
    param([Parameter(Mandatory)]$Tile)
    if ($Tile.ItemName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $null }
    $source = Get-SourceFolderName $Tile.Operation
    $hits = @{}
    foreach ($f in Get-CandidateFolders) {
        $hit = Find-ItemInFolder $f.Folder $Tile.ItemName $f.Selected
        if ($hit) { $hits[$hit.ToLowerInvariant()] = [pscustomobject]@{ Path = $hit; FromSource = (Split-Path $f.Folder -Leaf) -eq $source } }
    }
    $fromSource = @($hits.Values | Where-Object FromSource)
    if ($fromSource.Count -eq 1) { return $fromSource[0].Path }
    if ($hits.Count -eq 1) { return @($hits.Values)[0].Path }
    $null
}

function Find-Tile([long]$Hwnd, [string]$ItemName) {
    Get-InUseTiles | Where-Object { $_.Hwnd -eq $Hwnd -and $_.ItemName -eq $ItemName } | Select-Object -First 1
}

function Invoke-TileRetry {
    <# Clicks Try Again on the tile for $ItemName in window $Hwnd. Returns $true if clicked. #>
    param([Parameter(Mandatory)][long]$Hwnd, [Parameter(Mandatory)][string]$ItemName)
    if (-not [ProcessUnlock.Win]::Exists($Hwnd)) { return $false }
    $root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
    foreach ($btn in $root.FindAll([Windows.Automation.TreeScope]::Descendants, (New-IdCondition $script:RetryButtonId))) {
        $tile = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($btn)
        $item = $tile.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-IdCondition $script:ItemNameId))
        if ($item -and $item.Current.Name -eq $ItemName) {
            $btn.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            return $true
        }
    }
    $false
}
