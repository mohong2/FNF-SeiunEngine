#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Symbolicate SeiunEngine native crash reports for an official (release) build.

.DESCRIPTION
  Official builds keep HXCPP_DEBUG_LINK off, so the exe has no CodeView (RSDS)
  record and dbghelp cannot pair it with a PDB. The crash report's inline frames
  are therefore export-table guesses and must be ignored - but the report's
  "Fault offset" is exact, and the linker .map file maps it back to a real
  function.

  This script reads crash/native_crash_*.txt, takes the version, module stamp and
  fault offsets, and resolves them against the matching ApplicationMain.map.

.PARAMETER Map
  Symbol map produced next to the built exe, e.g.
  export/release/windows/obj/ApplicationMain.map
  Falls back to ./ApplicationMain.map next to this script's repo root.

.PARAMETER CrashDir
  Directory holding native_crash_*.txt. Defaults to
  export/release/windows/bin/crash.

.PARAMETER Offset
  Resolve these hex offsets instead of scanning the crash directory.

.EXAMPLE
  pwsh tools/symbolize-crash.ps1
.EXAMPLE
  pwsh tools/symbolize-crash.ps1 -Offset 0x1340289,0x133429A
#>
[CmdletBinding()]
param(
    [string]$Map,
    [string]$CrashDir,
    # [object[]] rather than [string[]]: binding "0x1340289,0x2" to [string[]]
    # first parses the values as numbers, turning them into decimals.
    [object[]]$Offset
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $Map) {
    $candidates = @(
        (Join-Path $repoRoot 'export/release/windows/obj/ApplicationMain.map'),
        (Join-Path $repoRoot 'ApplicationMain.map')
    )
    $Map = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Map -or -not (Test-Path $Map)) {
    throw "No .map file found. Build with -DHXCPP_MAP_FILE (Project.xml already sets it) or pass -Map <path>."
}
if (-not $CrashDir) { $CrashDir = Join-Path $repoRoot 'export/release/windows/bin/crash' }

# The resolver itself lives in Python (tools/mapresolve.py) to keep the parsing
# in one place and reusable from CI.
$resolver = Join-Path $PSScriptRoot 'mapresolve.py'
if (-not (Test-Path $resolver)) { throw "Missing $resolver" }

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
if (-not $py) { throw 'Python 3 is required to run tools/mapresolve.py' }

Write-Host "map      : $Map"
if ($Offset) {
    # PowerShell's binder may hand us either separate items or one comma-joined
    # string (and may already have converted the hex to decimal). Normalise both
    # shapes, then re-render as hex strings for Python.
    $hexArgs = @()
    foreach ($item in $Offset) {
        foreach ($piece in ([string]$item -split ',')) {
            $piece = $piece.Trim()
            if ($piece) { $hexArgs += ('0x{0:X}' -f [int64]$piece) }
        }
    }
    Write-Host "offsets  : $($hexArgs -join ', ')"
    & $py.Source $resolver $Map @hexArgs
} else {
    if (-not (Test-Path $CrashDir)) { throw "No crash directory at $CrashDir" }
    Write-Host "crash dir: $CrashDir"
    Write-Host ''
    # Echo the build identity of every report first: a report is only resolvable
    # against the .map of the SAME build, so a mismatched stamp invalidates it.
    Get-ChildItem $CrashDir -Filter 'native_crash_*.txt' | Sort-Object Name | ForEach-Object {
        Write-Host "===== $($_.Name) ====="
        Select-String -Path $_.FullName -Pattern '^App:|^Main module stamp:|^Fault offset:|^Faulting module:' |
            ForEach-Object { Write-Host ("  " + $_.Line.Trim()) }
    }
    Write-Host ''
    & $py.Source $resolver $Map --crash-dir $CrashDir
}
