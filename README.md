# process-unlock

Shows which process is holding a file or folder open, and lets you kill it.

When Explorer says "File In Use" or "Folder In Use" (on delete, move or rename), a pop-up appears on its own. It lists the processes holding the item, with buttons to kill them. Nothing is killed until you click.

Windows only. No dependencies: PowerShell 5.1 and built-in Windows APIs. MIT licensed.

## Pop-up

- **Header:** the item's name and full path.
- **Table:** one row per locking process: PID, name, why it's holding the item, its window title and its command line.
- **Kill selected:** kills the rows you selected, with no confirmation.
- **Kill all:** asks for confirmation first, listing the processes it will close.
- **How a kill works:** apps with a window are asked to close, as if you'd clicked their X. If one doesn't close within 5 s (for example because it's asking "Save changes?"), it is left running and the pop-up says so. Kill it again to force it. Background processes with no window are ended straight away.
- **Kill all & Try Again:** confirms and kills, then presses Explorer's Try Again for you.
- **Refresh:** scans again. If the item's path couldn't be worked out, open the folder that holds it in Explorer, then click Refresh.
- **Close:** closes the pop-up.
- **Grey rows:** Explorer, svchost and other system processes. They are never killed; close their window on the item instead.
- **Blue rows:** processes that only *mention* the path in their command line, without holding it open. Kill all leaves them out; use Kill selected if you really want them gone.
- **PID check:** a PID is only killed if it still belongs to the same process the scan found (start time is checked).
- **Auto-close:** the pop-up closes itself once Explorer's prompt is resolved or cancelled.

## Install / uninstall

Clone the repo, then run these in PowerShell from its folder. No admin needed.

```powershell
.\install.ps1              # adds Startup shortcut, starts watcher now
.\install.ps1 -Uninstall   # removes shortcut, stops watcher
```

- **Startup shortcut:** `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Process Unlock Watcher.lnk` runs `start-watcher.vbs`, which launches the watcher with no console window.
- **Single instance:** a named mutex means only one watcher ever runs.
- **Log file:** `%LOCALAPPDATA%\process-unlock\watcher.log` (rotates at 1 MB).

## Command line

```powershell
.\process-unlock.ps1 "C:\path\to\item"               # report only
.\process-unlock.ps1 "C:\path\to\item" -Kill         # asks per process
.\process-unlock.ps1 "C:\path\to\item" -Kill -Force  # no prompts
.\process-unlock.ps1 "C:\path\to\item" -Gui          # open the pop-up
```

## How it works

| Piece | What it does |
|---|---|
| `watcher.ps1` | Every 750 ms looks for Explorer's `OperationStatusWindow`. Reads its "interrupted" tiles via UI Automation (`eltItemName`, `eltInterruptDescription`, `eltInterruptRetryBtn`), and launches one pop-up per new "in use" tile. Runs from `%LOCALAPPDATA%\process-unlock` so it never locks your folders itself. |
| `lib/Dialog.ps1` | Turns a tile into a full path. The tile only shows the item name and source folder name, so it searches the open Explorer windows (preferring the one named in "from X") and the desktops. It handles hidden file extensions, and can press Try Again. |
| `lib/Scanner.ps1` | `Get-Lockers` combines three sources. **Restart Manager** finds processes with a file open or a DLL loaded from it. A **system handle scan** finds handles on the folder itself; this is what catches a shell or app whose working directory is inside it. A **command-line match** catches processes started with the path. The tool's own processes are excluded. `Stop-Locker` does the graceful-then-force kill. |
| `lib/Native.cs` | The Win32/NT calls: `rstrtmgr.dll`, `NtQuerySystemInformation(SystemExtendedHandleInformation)`, `DuplicateHandle` + `GetFinalPathNameByHandle`, and `EnumWindows`. |

## Tests

```powershell
powershell -NoProfile -File .\tests\unit.tests.ps1
powershell -NoProfile -STA -File .\tests\e2e.tests.ps1           # needs the watcher running
powershell -NoProfile -STA -File .\tests\e2e.tests.ps1 -Headed   # pauses so you can watch
```

- `unit.tests.ps1` covers:
  - path matching: boundaries, `[ ]` treated as literal characters
  - junctions not being followed
  - tile text parsing and hidden extensions
  - finding working-directory and open-file lockers
  - the PID-reuse guard
  - a handle scan with blocked synchronous pipes present (it must not hang)
- `e2e.tests.ps1` runs the real flow:
  1. Lock a folder.
  2. Delete it through Explorer.
  3. The watcher opens the pop-up.
  4. Kill all & Try Again, then Yes on the confirm.
  5. The locker exits, the folder is deleted, and the pop-up closes itself.

## Limits

- **Not elevated:** the watcher can't see processes running as admin or SYSTEM, such as some antivirus, indexer or sync services. For those, run `process-unlock.ps1` from an admin PowerShell.
- **Explorer itself:** an open window, preview pane or thumbnail on the item is often the locker, and it can't be found this way. The pop-up says so when it finds nothing.
- **Language:** tile detection relies on Explorer's automation IDs, so it doesn't depend on the display language. Two parts are English-only: the "in use" text check (`$InUsePattern` in `lib/Dialog.ps1`) and the "from X" source-folder parsing.
- **Ambiguous names:** if the item's name exists in several open folders and none of them is the source folder, the pop-up won't guess. Open the right folder and click Refresh.
- **Mapped drives and junctions:** the handle scan compares final paths. A target reached through a mapped drive, `subst` or a junction may not match, though Restart Manager still finds open files.
- **Handle scan safety:** it skips handles with pipe/console access masks, and abandons any handle query that stalls for more than 300 ms, so a blocked pipe can't hang it.

## Known cause seen in practice

A Claude Code session started from a terminal whose working directory is inside the folder will lock it, and so will its MCP server child processes. They all inherit that working directory. Exit the session or `cd ..` in that terminal.
