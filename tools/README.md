# tools/

Basic engine tooling. **The online-probe toolbox is not here** -- it lives outside the
repo, next to the engine: `..\FNF-SeiunEngine-online-tools\online_probe\` (not tracked).
Invoke it **from the engine root** (relative paths inside .hxml resolve against the current
directory, not the .hxml's directory):

    haxe ../FNF-SeiunEngine-online-tools/online_probe/probe.hxml
    neko export/online_probe/probe.n --url ws://127.0.0.1:2667

## Crash reports -- one tool: `crash_triage.py`

Cross-platform Python 3 (standard library only; tkinter for the window). **You pick the report and the
.map.** No arguments = window UI, `--tui` = terminal UI, switches = scripting.

    python tools/crash_triage.py              # window UI (Explorer dialogs, mouse)
    python tools/crash_triage.py --tui        # terminal UI
    python tools/crash_triage.py --help       # every switch

**Window UI**: `Browse...` opens the native file picker (Explorer on Windows) for the crash report and
for the .map; click a row in the report list to select it (double-click = triage); buttons for triage /
triage all / summary / snapshot the current .map / archive old reports. The output pane prints
CI-style steps with status colours:

    [ 1/7 ] read report ................. OK     native_crash_20260925_154824.txt  [native]
    [ 5/7 ] compare builds .............. STALE  report 33787392B@1790318226s vs current 33923072B@1790349780s
    [ 6/7 ] resolve fault offset ........ OK     0x3308FB -> FlxSound_obj::update + 0x1FB  (STALE)

**Terminal UI** (`--tui`): numbered menu; it asks for the map with `[Enter]` auto / `p` file dialog /
paste a path.

**Scripted**:

    ... --crash <report.txt> [-m <file.map>]     triage one report
    ... --all                                    triage every report in the crash dir
    ... --summary [--json]                       one line per report + signature counts
    ... --keep-map                               snapshot the current build's .map
    ... --clean [--keep 20] [--prune-maps 5] [--dry-run]
    ... --pick / --no-write / --no-color / --frames 8 / --crash-dir <dir>

A report is only exact against the .map of the build that produced it, so snapshot after every build
(`--keep-map`, or the window button). Symbols taken from another build's map are marked `STALE`.
Exit code 1 means: at least one report came from another build (symbols are hints).

## Other files

| File | Purpose |
|---|---|
| `symbolize-crash.ps1` + `mapresolve.py` | the older two-step map symboliser (PowerShell + Python); `crash_triage.py` supersedes it |
| `gen_linemap.bat` / `gen_linemap.py` | Android: address -> source-line table from an unstripped `.so` (used by `-DCRASH_LINEMAP`) |
