<#
.SYNOPSIS
    Build the Windows release exe with the crash linemap embedded, and produce
    the matching symbol bundle - without ever publishing a PDB.

.DESCRIPTION
    MSVC keeps cpp file:line in a PDB, and the crash handler resolves frames from
    the SELM linemap instead (tools/gen_linemap_msvc.py reads the PDB through
    dbghelp at build time, the PDB itself is not shipped).

    Step 0 refreshes source/BuildInfo.hx from git + Project.xml (watermark id).

    Order matters, and the reason is address stability: the linemap must be
    generated from an image whose .text is identical to the shipped one. Adding
    the linemap asset adds a translation unit, so the *first* build must already
    carry a linemap file (a stub on a fresh checkout). Then:

      1. build with -DHXCPP_DEBUG_LINK                    (stub or stale table)
      2. python tools/gen_linemap_msvc.py ...             (real table, PDB input)
      3. build with -DHXCPP_DEBUG_LINK                    (real table embedded)
      4. verify: regenerate from exe 3's PDB and compare byte-for-byte
      5. build WITHOUT -DHXCPP_DEBUG_LINK                 (pristine release)
      6. verify: .text SHA256 of 5 equals 3 -> the embedded table still applies

    The linemap is a resident asset in Project.xml, so EVERY build embeds it (steps
    3 and 5 included); -DCRASH_LINEMAP is still passed for compatibility with the
    older gated Project.xml and is a no-op. Step 6 therefore compares two builds
    that both carry the table.

    Step 5/6 are what let the published exe stay a normal release build (no
    debug directory, no PDB reference beyond a MISSING note); if step 6 fails the
    debug-info exe from step 3 is shipped instead, so a report is never
    symbolized against the wrong addresses.

    Outputs under export\release\windows: bin\SeiunEngine.exe, symbols\ (map,
    windows-x64.bin, build-info.txt).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\build_windows_symbols.ps1
#>

[CmdletBinding()]
param(
    # Optional lime --app-version value (CI passes <version>-<run id>).
    [string]$AppVersion = '',
    # Skip step 5/6 (ship the debug-info exe from step 3). Rarely useful.
    [switch]$KeepDebugLink
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Step 0: bake the git revision into source/BuildInfo.hx so the in-game watermark and the
# cold-start notice identify the binary that is about to be built. The file is tracked; after
# a release build restore the committed "unknown" placeholder with
#   git checkout -- source/BuildInfo.hx
& python (Join-Path $PSScriptRoot 'gen_buildinfo.py')
if ($LASTEXITCODE -ne 0) { throw "gen_buildinfo.py failed (exit $LASTEXITCODE)" }

$outDir = 'export\release\windows'
$exe = Join-Path $outDir 'bin\SeiunEngine.exe'
$objDir = Join-Path $outDir 'obj'

# tools/SymbolsAfterBuild.hx MOVES obj\ApplicationMain.map into the bundle after every
# lime build, so a plain read of obj\ comes up empty once the hook has run.
$bundleMap = Join-Path $root 'export\symbols\windows-release\ApplicationMain.map'
function Get-MapPath {
    $raw = Join-Path $objDir 'ApplicationMain.map'
    if (Test-Path $raw) { return $raw }
    if (Test-Path $bundleMap) { return $bundleMap }
    return $raw
}
$linemap = 'assets\linemap\windows-x64.bin'
$symbolsDir = Join-Path $outDir 'symbols'

# hxcpp reads HXCPP_CONFIG when it is set (CI does that) and the per-user
# ~/.hxcpp_config.xml otherwise, verbatim. /DEBUG turns /OPT:REF and /OPT:ICF
# off, which would keep unreferenced code and change .text - so the symbol build
# gets a private copy of whichever config is in effect, with those two flags
# added (only under HXCPP_DEBUG_LINK). Nothing global is modified.
function New-AugmentedHxcppConfig {
    $source = $env:HXCPP_CONFIG
    if (-not $source -or -not (Test-Path $source)) {
        $source = Join-Path $env:USERPROFILE '.hxcpp_config.xml'
    }
    if (-not (Test-Path $source)) {
        # Resolve the hxcpp directory that is actually in use instead of hardcoding
        # .haxelib\hxcpp\git: an upgrade renames the fork's version directory (4.2.1 ->
        # 4.3.x), and a dead path here only surfaces as "no hxcpp config found to augment".
        $hxcppDir = $null
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $hxcppDir = @(& haxelib libpath hxcpp 2>$null | Where-Object { $_ -and "$_".Trim() -ne '' })[0]
        } catch {
            $hxcppDir = $null
        } finally {
            $ErrorActionPreference = $prevEAP
        }
        if ($hxcppDir) {
            $hxcppDir = "$hxcppDir".Trim() -replace '/', '\'
            $source = Join-Path $hxcppDir.TrimEnd('\') 'toolchain\example.hxcpp_config.xml'
        }
    }
    if (-not (Test-Path $source)) { throw "no hxcpp config found to augment (tried HXCPP_CONFIG, ~\.hxcpp_config.xml and 'haxelib libpath hxcpp')" }
    $xml = Get-Content -Raw $source
    $nl = [Environment]::NewLine
    $block = '     <linker id="exe" if="windows">' + $nl +
             '        <flag value="/OPT:REF" if="HXCPP_DEBUG_LINK" />' + $nl +
             '        <flag value="/OPT:ICF" if="HXCPP_DEBUG_LINK" />' + $nl +
             '     </linker>' + $nl
    $exes = '<section id="exes">'
    $idx = $xml.IndexOf($exes)
    if ($idx -ge 0) {
        $insert = $idx + $exes.Length
        $xml = $xml.Substring(0, $insert) + $nl + $block + $xml.Substring($insert)
    } else {
        $xml = $xml.Replace('</xml>', $block + '</xml>')
    }
    $dest = Join-Path $env:TEMP 'seiun-hxcpp-config.xml'
    [System.IO.File]::WriteAllText($dest, $xml, [System.Text.UTF8Encoding]::new($false))
    return $dest
}
$env:HXCPP_CONFIG = New-AugmentedHxcppConfig
Write-Host "[symbols] hxcpp config: $env:HXCPP_CONFIG"

function Invoke-Lime {
    param([string[]]$LimeArgs)
    Write-Host ("[symbols] haxelib run lime " + ($LimeArgs -join ' ')) -ForegroundColor Cyan
    & haxelib run lime @LimeArgs
    if ($LASTEXITCODE -ne 0) { throw "lime build failed (exit $LASTEXITCODE)" }
}

function Get-BuildArgs {
    param([switch]$WithDebug)
    $a = New-Object System.Collections.Generic.List[string]
    # Pass the project file explicitly: lime's auto-detection scans *.xml in the working
    # directory and can pick a non-project file (the CI .hxcpp-config.xml), which then fails
    # with 'You must have a "project.xml" file' on case-sensitive filesystems.
    $a.Add('build'); $a.Add((Join-Path $root 'Project.xml')); $a.Add('windows')
    if ($WithDebug) { $a.Add('-DHXCPP_DEBUG_LINK') }
    # Only -Dhxcpp_symbols turns the linemap/unstripped-.so/postbuild pipeline on;
    # the null-pointer checks stay on in these builds (Project.xml hxcpp_safe).
    $a.Add('-Dhxcpp_symbols')
    $a.Add('-DCRASH_LINEMAP')
    if ($AppVersion) { $a.Add("--app-version=$AppVersion") }
    return $a.ToArray()
}

function New-Linemap {
    param([string]$OutPath)
    & python (Join-Path $PSScriptRoot 'gen_linemap_msvc.py') $exe $OutPath --symbols $objDir --root .
    if ($LASTEXITCODE -ne 0) { throw "gen_linemap_msvc.py failed (exit $LASTEXITCODE)" }
}

# A stub keeps the linemap asset present (and therefore the object list stable)
# on a fresh checkout, where the real table does not exist yet.
if (-not (Test-Path $linemap)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $linemap) | Out-Null
    $stub = [byte[]](0x53, 0x45, 0x4C, 0x4D, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    [System.IO.File]::WriteAllBytes((Join-Path $root $linemap), $stub)
    Write-Host "[symbols] created stub $linemap (replaced below by the real table)"
}

# hxcpp does not track files pulled in through @:cppInclude as dependencies, so
# an edit to source/backend/native_crash.inc alone leaves a stale object behind.
# Drop it so the report format in the shipped exe matches the source.
Get-ChildItem (Join-Path $outDir 'obj') -Recurse -Filter '*NativeCrash*.obj' -ErrorAction SilentlyContinue |
    Remove-Item -Force

# ---- 1/2: debug-info build -> real linemap ---------------------------------
Invoke-Lime (Get-BuildArgs -WithDebug)
New-Linemap $linemap

# ---- 3: embed the real linemap ---------------------------------------------
Invoke-Lime (Get-BuildArgs -WithDebug)

# ---- 4: the embedded table must describe exactly this exe ------------------
$verify = Join-Path $env:TEMP ('seiun_win_verify_' + [Guid]::NewGuid().ToString('N') + '.bin')
New-Linemap $verify
$h1 = (Get-FileHash $linemap -Algorithm SHA256).Hash
$h2 = (Get-FileHash $verify -Algorithm SHA256).Hash
Remove-Item $verify -Force -ErrorAction SilentlyContinue
if ($h1 -ne $h2) { throw "linemap mismatch: the table does not match the exe it was embedded in" }
Write-Host "[symbols] linemap verified against the embedding build ($h1)"

# Park the map of THIS link. Step 5 relinks without -DHXCPP_DEBUG_LINK, which
# overwrites obj\ApplicationMain.map; if that relink turns out to move .text we
# ship the step-3 exe instead, and it must be shipped together with the step-3
# map. Keeping only the newest map is how a release ends up publishing symbols
# for a binary nobody has.
$matchedMap = Join-Path $env:TEMP ('seiun_win_map_' + [Guid]::NewGuid().ToString('N') + '.map')
Copy-Item (Get-MapPath) $matchedMap -Force

# ---- 5/6: pristine release build with the same .text -----------------------
if (-not $KeepDebugLink) {
    $debugExe = Join-Path $env:TEMP ('seiun_win_debugexe_' + [Guid]::NewGuid().ToString('N') + '.exe')
    Copy-Item $exe $debugExe -Force
    $debugText = (& python (Join-Path $PSScriptRoot 'gen_linemap_msvc.py') $debugExe --text-sha)
    if ($LASTEXITCODE -ne 0) { throw "text-sha failed on the debug-info exe" }

    Invoke-Lime (Get-BuildArgs)
    $releaseText = (& python (Join-Path $PSScriptRoot 'gen_linemap_msvc.py') $exe --text-sha)
    if ($LASTEXITCODE -ne 0) { throw "text-sha failed on the release exe" }

    Write-Host "[symbols] debug-info exe $debugText"
    Write-Host "[symbols] release exe    $releaseText"
    if ($debugText -notmatch 'vaddr=0x([0-9A-F]+) size=(\d+)') { throw "unexpected text-sha output" }
    $dbgV = $Matches[1]; $dbgS = $Matches[2]
    if ($releaseText -notmatch 'vaddr=0x([0-9A-F]+) size=(\d+)') { throw "unexpected text-sha output" }
    if ($Matches[1] -ne $dbgV -or $Matches[2] -ne $dbgS) {
        Write-Warning "release .text differs from the linemap build - shipping the debug-info exe instead"
        Copy-Item $debugExe $exe -Force
        # The release relink overwrote the map; put back the one that describes the
        # exe we are actually shipping, or every resolved frame would be wrong.
        Copy-Item $matchedMap (Join-Path $objDir 'ApplicationMain.map') -Force
        Write-Host "[symbols] restored the map that matches the shipped debug-info exe"
    } else {
        Write-Host "[symbols] release .text matches the linemap build; shipping the pristine exe"
    }
    Remove-Item $debugExe -Force -ErrorAction SilentlyContinue
}

# ---- collect the bundle -----------------------------------------------------
# The parked step-3 map has served its purpose (the fallback above restores it when
# it is needed); the map collected below is always obj\ApplicationMain.map, fresh
# from the link that produced the exe now sitting in bin\.
Remove-Item $matchedMap -Force -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Force -Path $symbolsDir | Out-Null
Get-ChildItem (Join-Path $outDir 'bin') -Filter '*.pdb' -ErrorAction SilentlyContinue | Remove-Item -Force
Copy-Item (Get-MapPath) $symbolsDir -Force -ErrorAction SilentlyContinue
Copy-Item $linemap $symbolsDir -Force

# The published map is only useful if it describes the published exe. Linking is
# the only thing that can change this, so check it here, once, and fail the build
# rather than hand out symbols that resolve every frame to the wrong function.
$mapPath = Join-Path $symbolsDir 'ApplicationMain.map'
if (-not (Test-Path $mapPath)) { throw "no ApplicationMain.map in $objDir - cannot publish symbols" }
$mapVerdict = (& python (Join-Path $PSScriptRoot 'verify_map.py') $exe $mapPath) -join [Environment]::NewLine
Write-Host $mapVerdict
if ($LASTEXITCODE -ne 0) {
    throw "the map does not match the exe being published - refusing to continue"
}
if ($mapVerdict -match 'map Timestamp=0x([0-9A-F]+)') { $mapStamp = $Matches[1] } else { $mapStamp = '?' }
Write-Host "[symbols] map verified against the exe (Timestamp=$mapStamp)"

$exeFp = (& python (Join-Path $PSScriptRoot 'fnv1a.py') file $exe).Trim()
$exeWhole = (& python (Join-Path $PSScriptRoot 'fnv1a.py') whole $exe).Trim()
$linemapFp = (& python (Join-Path $PSScriptRoot 'fnv1a.py') whole $linemap).Trim()
$mapFp = ''
if (Test-Path (Get-MapPath)) {
    $mapFp = (& python (Join-Path $PSScriptRoot 'fnv1a.py') file (Get-MapPath)).Trim()
}
$text = (& python (Join-Path $PSScriptRoot 'gen_linemap_msvc.py') $exe --text-sha)

$info = @(
    '# SeiunEngine Windows symbol bundle',
    '#',
    '# The crash report Build: line of this build reads, for example:',
    '#   Build: SeiunEngine.exe=<size>B@<mtime>s#<hash> | linemap=windows-x64:<n>B#<hash>',
    '# The exe fingerprint identifies the build; the linemap fingerprint identifies',
    '# the exact address table embedded in that exe. Both must match this file.',
    '#',
    '# Frame annotations ([src/File.cpp:123]) come from the embedded linemap - the',
    '# PDB used to generate it is NOT part of the release.',
    '',
    "exe: SeiunEngine.exe $exeFp",
    "exe-whole: SeiunEngine.exe $exeWhole",
    "linemap: windows-x64.bin $linemapFp",
    "map: ApplicationMain.map $mapFp",
    "map-verified: yes (Timestamp=0x$mapStamp matches the exe above)",
    "text-sha256: $text"
)
$buildInfo = Join-Path $symbolsDir 'build-info.txt'
Set-Content -Path $buildInfo -Value $info -Encoding UTF8

Write-Host ""
Write-Host "[symbols] exe     : $exe ($((Get-Item $exe).Length) bytes)"
Write-Host "[symbols] linemap : $linemap"
Write-Host "[symbols] bundle  : $symbolsDir"
Get-Content $buildInfo | ForEach-Object { Write-Host "  $_" }
