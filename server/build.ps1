<#
  SeiunEngine server - one-step build

  Usage (works from any directory; the script locates the repository root itself):
    powershell -NoProfile -File server/build.ps1                    # neko (default, unchanged)
    powershell -NoProfile -File server/build.ps1 -Target cpp       # hxcpp -> server/bin/SeiunServer.exe
    powershell -NoProfile -File server/build.ps1 -Target both      # both targets
    powershell -NoProfile -File server/build.ps1 -TypeCheck        # type check only, no output written
    powershell -NoProfile -File server/build.ps1 -NoBoot           # build server.n only, skip server.exe

  Outputs: server/bin/server.n         (neko bytecode; booted into server.exe by nekotools)
           server/bin/server.exe       (neko.exe shell wrapper; still needs the Haxe/neko toolchain)
           server/bin/SeiunServer.exe  (hxcpp native binary; no runtime dependency)

  The hxcpp build is heavyweight (it compiles the C++ runtime on first use). Only one
  hxcpp/lime build should run on a machine at a time.

  Logs / pid are under server/logs/.
#>
param(
  [ValidateSet('neko', 'cpp', 'both')]
  [string]$Target = 'neko',
  [switch]$TypeCheck,
  [switch]$NoBoot
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root

$env:HAXELIB_PATH = Join-Path $root '.haxelib'

# The output directory must exist before haxe runs (haxe does not create it).
$binDir = Join-Path $root 'server\bin'
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Force -Path $binDir | Out-Null }

# nekotools sits next to neko: try PATH, then the neko.exe directory, then the default install path.
function Find-NekoTools {
  $cmd = Get-Command nekotools.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $neko = Get-Command neko.exe -ErrorAction SilentlyContinue
  if ($neko) {
    $candidate = Join-Path (Split-Path $neko.Source) 'nekotools.exe'
    if (Test-Path $candidate) { return $candidate }
  }
  foreach ($candidate in @('C:\HaxeToolkit\neko\nekotools.exe')) {
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

function Invoke-NekoTarget {
  $hxml = 'server/server.hxml'
  if ($TypeCheck) {
    Write-Host "typecheck: haxe $hxml --no-output"
    & haxe $hxml --no-output
  } else {
    Write-Host "build: haxe $hxml"
    & haxe $hxml
  }
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Host "FAILED: haxe exit $code"
    return $code
  }
  if ($TypeCheck) {
    Write-Host 'ok: typecheck passed (no output written)'
    return 0
  }
  $out = Join-Path $root 'server\bin\server.n'
  if (-not (Test-Path $out)) { Write-Host 'warn: haxe reported success but server.n is missing'; return 1 }
  Write-Host ('ok: {0} ({1} bytes)' -f $out, (Get-Item $out).Length)

  if (-not $NoBoot) {
    $tools = Find-NekoTools
    if (-not $tools) {
      Write-Host 'warn: nekotools.exe not found -- skipped server.exe (is the Haxe/neko toolkit on PATH?)'
    } else {
      Write-Host "boot: $tools boot server\bin\server.n"
      & $tools 'boot' 'server\bin\server.n'
      $exe = Join-Path $root 'server\bin\server.exe'
      if (Test-Path $exe) { Write-Host ('ok: {0} ({1} bytes)' -f $exe, (Get-Item $exe).Length) }
      else { Write-Host ('warn: nekotools exited ' + $LASTEXITCODE + ' but server.exe is missing') }
    }
  }
  return 0
}

function Invoke-CppTarget {
  $hxml = 'server/server-cpp.hxml'
  if ($TypeCheck) {
    Write-Host "typecheck: haxe $hxml --no-output"
    & haxe $hxml --no-output
  } else {
    Write-Host "build: haxe $hxml   (hxcpp: the first run compiles the C++ runtime and takes a while)"
    & haxe $hxml
  }
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Host "FAILED: haxe exit $code (is a C++ toolchain installed? see server/README.md)"
    return $code
  }
  if ($TypeCheck) {
    Write-Host 'ok: typecheck passed (no output written)'
    return 0
  }
  $exe = Join-Path $root 'server\bin\SeiunServer.exe'
  if (-not (Test-Path $exe)) { Write-Host 'warn: haxe reported success but server\bin\SeiunServer.exe is missing'; return 1 }
  Write-Host ('ok: {0} ({1} bytes)' -f $exe, (Get-Item $exe).Length)
  return 0
}

$code = 0
if ($Target -eq 'neko' -or $Target -eq 'both') {
  $nekoCode = Invoke-NekoTarget
  if ($nekoCode -ne 0 -and $code -eq 0) { $code = $nekoCode }
}
if ($Target -eq 'cpp' -or $Target -eq 'both') {
  $cppCode = Invoke-CppTarget
  if ($cppCode -ne 0 -and $code -eq 0) { $code = $cppCode }
}
exit $code
