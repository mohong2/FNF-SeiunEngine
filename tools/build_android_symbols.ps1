<#
.SYNOPSIS
    Build the Android release APK together with the symbol bundle that matches
    exactly that APK (crash report -> cpp file:line, no sidecar needed).

.DESCRIPTION
    A single lime build cannot embed the crash linemap: the .bin files do not
    exist yet when that build reads Project.xml. The pipeline is:

      1. haxelib run lime build android -DHXCPP_DEBUG_LINK_AND_STRIP
         hxcpp saves an UNSTRIPPED copy of libApplicationMain.so next to the
         stripped deployment file.
      2. tools\gen_linemap.bat release
         reads the DWARF line table of that copy and writes
         assets\linemap\<abi>.bin (python + pyelftools, installed on demand).
      3. haxelib run lime build android -DCRASH_LINEMAP
         Project.xml:144 embeds those .bin files, so an on-device crash report
         carries "[source/File.cpp:123]" for every game frame.
      4. verify: the .bin embedded in step 3 must still equal the table the
         step-3 .so produces (the asset lives in the APK, not in the .so, so the
         addresses are expected to be identical; this proves it).

    Outputs (all under export\release\android):
      bin\app\build\outputs\apk\release\SeiunEngine-release.apk  the game
      assets\linemap\<abi>.bin                                   also embedded
      symbols\libApplicationMain.so                               unstripped
      symbols\<abi>.bin + symbols\build-info.txt                  the bundle
      symbols-<abi>.zip                                            zip of the above

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\build_android_symbols.ps1
    powershell -ExecutionPolicy Bypass -File tools\build_android_symbols.ps1 -Arch -arm64 -AppVersion 0.2.2-12345
#>

[CmdletBinding()]
param(
    # lime architecture flag for a single-ABI build (CI matrix), e.g. -arm64.
    [string]$Arch = '',
    # Optional lime --app-version value (CI passes <version>-<run id>).
    [string]$AppVersion = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$outDir = 'export\release\android'
$symbolsDir = Join-Path $outDir 'symbols'

function Invoke-Lime {
    param([string[]]$LimeArgs)
    Write-Host ("[symbols] haxelib run lime " + ($LimeArgs -join ' ')) -ForegroundColor Cyan
    & haxelib run lime @LimeArgs
    if ($LASTEXITCODE -ne 0) { throw "lime build failed (exit $LASTEXITCODE)" }
}

# -DCRASH_LINEMAP is passed to BOTH builds on purpose: the asset list (and the
# generated asset manifest) is part of the code, so both builds must see the same
# set of files or the addresses would move. On a fresh checkout the .bin files do
# not exist yet, so a stub is written first and replaced with the real table
# between the two builds.
function Get-LimeArgs {
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add('build'); $a.Add('android')
    if ($Arch) { $a.Add($Arch) }
    $a.Add('-DHXCPP_DEBUG_LINK_AND_STRIP')
    $a.Add('-DCRASH_LINEMAP')
    if ($AppVersion) { $a.Add("--app-version=$AppVersion") }
    return $a.ToArray()
}

function Get-Fingerprint {
    param([string]$Path, [ValidateSet('file', 'whole')][string]$Mode = 'file')
    $value = & python (Join-Path $PSScriptRoot 'fnv1a.py') $Mode $Path
    if ($LASTEXITCODE -ne 0) { throw "fnv1a.py failed for $Path" }
    return $value.Trim()
}

# The unstripped copies hxcpp keeps; the first existing path per ABI wins.
$abiSources = @(
    @{ abi = 'arm64-v8a';   src = @("$outDir\obj\obj\android-64\libApplicationMain.so", "$outDir\obj\libApplicationMain-64.so"); so = 'libApplicationMain-64.so' },
    @{ abi = 'armeabi-v7a'; src = @("$outDir\obj\obj\android-v7\libApplicationMain.so", "$outDir\obj\libApplicationMain-v7.so"); so = 'libApplicationMain-v7.so' }
)

function Find-Unstripped {
    param($Entry)
    foreach ($candidate in $Entry.src) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

# A 16-byte SELM header with zero entries: present as an asset, ignored by the
# C++ lookup (which needs at least 20 bytes), then replaced by the real table.
$stub = [byte[]](0x53, 0x45, 0x4C, 0x4D, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
foreach ($entry in $abiSources) {
    $bin = Join-Path $root "assets\linemap\$($entry.abi).bin"
    if (-not (Test-Path $bin)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $bin) | Out-Null
        [System.IO.File]::WriteAllBytes($bin, $stub)
        Write-Host "[symbols] created stub $bin (replaced by the real table below)"
    }
}

# hxcpp does not track files pulled in through @:cppInclude as dependencies, so
# an edit to source/backend/native_crash.inc alone leaves a stale object behind
# (and therefore a stale crash-report format). Drop that object so it is rebuilt.
Get-ChildItem (Join-Path $outDir 'obj') -Recurse -Filter '*NativeCrash*.obj' -ErrorAction SilentlyContinue |
    Remove-Item -Force

# ---- 1/2: converge on a table that matches the .so it is embedded in -------
#
# The linemap is a build asset with embed="true", so its own size is part of the
# .so layout: embedding a table generated by an earlier build can move code and
# invalidate the addresses it stores. Each round therefore generates the table
# from the current .so, rebuilds with it embedded, and compares the embedded
# table against a fresh one from the new .so. Two friends-and-family rounds are
# enough in practice; one retry is attempted before giving up (CI time bound).
Invoke-Lime (Get-LimeArgs)

$converged = $false
$attempts = 0
$pendingVerify = @()
while (-not $converged -and $attempts -lt 2) {
    $attempts++
    & (Join-Path $PSScriptRoot 'gen_linemap.bat') release
    if ($LASTEXITCODE -ne 0) { throw "gen_linemap.bat failed (exit $LASTEXITCODE)" }

    Invoke-Lime (Get-LimeArgs)

    $converged = $true
    $matched = @()
    foreach ($entry in $abiSources) {
        $bin = Join-Path $root "assets\linemap\$($entry.abi).bin"
        if (-not (Test-Path $bin)) { continue }
        $found = Find-Unstripped $entry
        if ($null -eq $found) { continue }
        $tempBin = Join-Path $env:TEMP ("seiun_lm_" + [Guid]::NewGuid().ToString('N') + '.bin')
        & python (Join-Path $PSScriptRoot 'gen_linemap.py') $found $tempBin | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "gen_linemap.py verification failed for $($entry.abi)" }
        $compare = & python (Join-Path $PSScriptRoot 'linemap_compare.py') $bin $tempBin
        $compareExit = $LASTEXITCODE
        Remove-Item $tempBin -Force -ErrorAction SilentlyContinue
        Write-Host "[symbols] attempt $attempts $($entry.abi): $compare"
        if ($compareExit -ne 0) { $converged = $false } else { $matched += $entry.abi }
    }
    if ($converged) { $pendingVerify = $matched }
    else { Write-Warning "attempt $attempts did not converge; regenerating the linemap and rebuilding" }
}
if (-not $converged) { throw "crash linemap did not converge after $attempts attempts" }

# ---- 3: stage the unstripped .so that matches the shipped APK ---------------
New-Item -ItemType Directory -Force -Path $symbolsDir | Out-Null
$unstripped = @{}
foreach ($entry in $abiSources) {
    $found = Find-Unstripped $entry
    if ($null -eq $found) {
        Write-Warning "no unstripped .so for $($entry.abi) (looked for: $($entry.src -join ', '))"
        continue
    }
    $dest = Join-Path $symbolsDir ("libApplicationMain-" + $entry.abi + '.so')
    Copy-Item $found $dest -Force
    $unstripped[$entry.abi] = $dest
    Write-Host "[symbols] unstripped $($entry.abi): $found"
}

# ---- collect + fingerprint --------------------------------------------------
$apk = Get-ChildItem "$outDir\bin\app\build\outputs\apk\release\*.apk" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($null -eq $apk) { throw "no APK found under $outDir\bin\app\build\outputs\apk\release" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($apk.FullName)
$extractDir = Join-Path $env:TEMP ('seiun_apk_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# SeiunEngine Android symbol bundle")
$lines.Add("#")
$lines.Add("# Match a crash report's Build: line against the entries below. A report")
$lines.Add("# from this build looks like:")
$lines.Add("#   Build: abi=<abi> | so=libApplicationMain.so | size=<n>B@<mtime>s#<hash> | linemap=<abi>:<n>B#<hash>")
$lines.Add("# size and #hash are stable; @mtime is the install time on the reporting")
$lines.Add("# device and WILL differ. Compare size + #hash, then use the unstripped")
$lines.Add("# libApplicationMain.so of the same abi for addr2line if needed.")
$lines.Add("")
$lines.Add("apk: $($apk.Name) $(Get-Fingerprint -Path $apk.FullName -Mode file) (whole $(Get-Fingerprint -Path $apk.FullName -Mode whole))")

$zipEntries = @{}
foreach ($e in $zip.Entries) { $zipEntries[$e.FullName] = $e }

foreach ($entry in $abiSources) {
    $abi = $entry.abi
    $libEntry = "lib/$abi/libApplicationMain.so"
    if (-not $zipEntries.ContainsKey($libEntry)) {
        Write-Warning "$($apk.Name) has no $libEntry"
        continue
    }
    $libOut = Join-Path $extractDir "libApplicationMain-$abi.so"
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($zipEntries[$libEntry], $libOut, $true)
    $lines.Add("$abi lib=$libEntry $(Get-Fingerprint -Path $libOut -Mode file)")

    $linemap = Join-Path $root "assets\linemap\$abi.bin"
    if (Test-Path $linemap) {
        $lines.Add("$abi linemap=" + $abi + ":" + (Get-Fingerprint -Path $linemap -Mode whole))
    } else {
        $lines.Add("$abi linemap=MISSING ($linemap)")
    }
    if ($unstripped.ContainsKey($abi)) {
        $lines.Add("$abi unstripped=$($entry.so) $(Get-Fingerprint -Path $unstripped[$abi] -Mode file)")
    }
}
$zip.Dispose()
Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

$buildInfo = Join-Path $symbolsDir 'build-info.txt'
Set-Content -Path $buildInfo -Value $lines -Encoding UTF8

# ---- zips (local convenience; the release workflow zips the folder itself) --
foreach ($abi in $pendingVerify) {
    $entry = $abiSources | Where-Object { $_.abi -eq $abi } | Select-Object -First 1
    if (-not $entry) { continue }
    $stage = Join-Path $env:TEMP ('seiun_sym_' + $abi)
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item $unstripped[$abi] (Join-Path $stage $entry.so) -Force
    Copy-Item (Join-Path $root "assets\linemap\$abi.bin") (Join-Path $stage "$abi.bin") -Force
    Copy-Item $buildInfo (Join-Path $stage 'build-info.txt') -Force
    $zipPath = Join-Path $outDir "symbols-$abi.zip"
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath
    Write-Host "[symbols] $zipPath"
}

Write-Host ""
Write-Host "[symbols] APK      : $($apk.FullName) ($($apk.Length) bytes)"
Write-Host "[symbols] bundle   : $symbolsDir"
Get-Content $buildInfo | ForEach-Object { Write-Host "  $_" }
