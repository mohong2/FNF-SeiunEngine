<#
.SYNOPSIS
    Keep a bare "haxelib run lime build android" self-sufficient.

.DESCRIPTION
    Runs from the postbuild hook of every lime build. A single lime build cannot
    embed a table that matches its own .so (Project.xml's asset list is read before
    that .so exists), so instead of a second embedding pass this keeps the DISK
    copy in sync - and NativeCrash.loadLinemap() reads <storage>/linemap/<abi>.bin
    BEFORE the embedded asset, so the running build resolves crashes to file:line
    with no rebuild.

    Steps, all best effort (never fails the build):
      1. skip when the object set that produced the table has not changed, so an
         incremental build that only touched assets costs nothing;
      2. regenerate assets/linemap/<abi>.bin via gen_linemap.py (same selector and
         coverage gate as the release pipeline);
      3. adb push it to the connected device.

    Env:
      SEIUN_LINEMAP_PIPELINE=1   skip (tools/build_android_symbols.ps1 sets it: that
                                 script does the embedding pass itself)
      SEIUN_DEVICE_STORAGE=...   device storage root, default /storage/emulated/0/.SeiunEngine
#>
param([string]$Build = 'release')

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
function Say([string]$m) { Write-Host "[linemap] $m" }

if ($env:SEIUN_LINEMAP_PIPELINE -eq '1') { Say 'skipped (pipeline pass)'; exit 0 }

$abis = @('arm64-v8a', 'armeabi-v7a')
$storage = if ($env:SEIUN_DEVICE_STORAGE) { $env:SEIUN_DEVICE_STORAGE } else { '/storage/emulated/0/.SeiunEngine' }

function Get-ObjSig([string]$abi) {
    switch ($abi) {
        'arm64-v8a'   { $d = "export\$Build\android\obj\obj\androidarm64-64" }
        'armeabi-v7a' { $d = "export\$Build\android\obj\obj\android-v7" }
        default       { return '' }
    }
    if (-not (Test-Path $d)) { return '' }
    $f = Get-ChildItem $d -Filter *.obj -ErrorAction SilentlyContinue
    if (-not $f) { return '' }
    $sum = ($f | Measure-Object Length -Sum).Sum
    $max = ($f | Measure-Object LastWriteTime -Maximum).Maximum.Ticks
    return "$($f.Count)-$sum-$max"
}

# Only ABIs this build actually re-linked need work: the deployment .so is written
# at the very end of a lime build, so a binary from an earlier build is minutes-old
# by comparison. Without this, a -arm64 build would also spend minutes on v7.
$deploy = @{ 'arm64-v8a'   = "export\$Build\android\obj\libApplicationMain-64.so"
             'armeabi-v7a' = "export\$Build\android\obj\libApplicationMain-v7.so" }

$needGen = New-Object System.Collections.Generic.List[string]
foreach ($abi in $abis) {
    $bin = "assets\linemap\$abi.bin"
    $sigFile = "$bin.objsig"
    $sig = Get-ObjSig $abi
    if ($sig -eq '') { continue }
    $linked = Get-Item $deploy[$abi] -ErrorAction SilentlyContinue
    if ($linked -and $linked.LastWriteTime -lt (Get-Date).AddMinutes(-10)) {
        Say "$abi was not re-linked by this build - keeping its existing table"
        continue
    }
    $old = if (Test-Path $sigFile) { (Get-Content $sigFile -Raw).Trim() } else { '' }
    if ($old -eq $sig -and (Test-Path $bin)) {
        Say "$abi table is current (object set unchanged) - skipping generation"
    } else {
        $needGen.Add($abi)
    }
}

if ($needGen.Count -gt 0) {
    foreach ($abi in $needGen) {
        Say "regenerating $abi table from the .so just linked (a few minutes)..."
        & python (Join-Path $PSScriptRoot 'gen_linemap.py') --android $Build --abi $abi
        if ($LASTEXITCODE -ne 0) { Say "$abi generation refused or failed - leaving the previous table alone" }
        else { (Get-ObjSig $abi) | Set-Content -Path "assets\linemap\$abi.bin.objsig" -Encoding ASCII }
    }
}

# ---- push to the connected device (NativeCrash reads this FIRST) ------------
#
# Every adb call goes through cmd /c with its output redirected to a FILE. The
# first adb call spawns the long-lived adb server, which inherits whatever stdio
# it is handed; when that is a pipe, PowerShell waits for EOF that never comes -
# and the lime build waiting on this script hangs forever with it. (Cost me one
# hung build to learn; redirect to a file and the server inherits the file.)
$adb = Get-Command adb -ErrorAction SilentlyContinue
if (-not $adb) { Say 'adb not on PATH - table stays in assets\linemap\ (push it manually)'; exit 0 }

$tmp = Join-Path $env:TEMP 'seiun_adb_out.txt'
function Adb-To([string]$cmdline) {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    & cmd /c "adb $cmdline 1> `"$tmp`" 2>&1"
    if (Test-Path $tmp) { return (Get-Content $tmp -Raw -ErrorAction SilentlyContinue) }
    return ''
}

Adb-To 'start-server' | Out-Null
$devOut = Adb-To 'devices'
if ($devOut -notmatch '(?m)\sdevice\s*$') {
    Say 'no device attached - table stays in assets\linemap\ (push it manually)'
    exit 0
}
Adb-To "shell mkdir -p $storage/linemap" | Out-Null
foreach ($abi in $abis) {
    $bin = "assets\linemap\$abi.bin"
    if (-not (Test-Path $bin)) { continue }
    $out = Adb-To "push $bin $storage/linemap/$abi.bin"
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match 'pushed|error|failed') { Say "$abi -> $line" }
    }
}
Say 'device table refreshed; restart the game so loadLinemap() picks it up'
exit 0
