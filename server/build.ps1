<#
  SeiunEngine server - one-step build

  Usage (works from any directory; the script locates the repository root itself):
    powershell -NoProfile -File server/build.ps1
    powershell -NoProfile -File server/build.ps1 -TypeCheck    # type check only, no output written
    powershell -NoProfile -File server/build.ps1 -NoBoot       # build server.n only, skip server.exe

  Outputs: server/bin/server.n
        server/bin/server.exe   <- nekotools boot wraps the .n into the neko.exe shell; double-click to start;
                                  still requires the Haxe/neko toolchain (see server/README.md)

  Logs / pid are under server/logs/.
#>
param([switch]$TypeCheck, [switch]$NoBoot)

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

$hxml = 'server/server.hxml'
if ($TypeCheck) {
  Write-Host "typecheck: haxe $hxml --no-output"
  & haxe $hxml --no-output
} else {
  Write-Host "build: haxe $hxml"
  & haxe $hxml
}
$code = $LASTEXITCODE

if ($code -eq 0) {
  if ($TypeCheck) {
    Write-Host 'ok: typecheck passed (no output written)'
  } else {
    $out = Join-Path $root 'server\bin\server.n'
    if (-not (Test-Path $out)) { Write-Host 'warn: haxe reported success but server.n is missing'; exit 1 }
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
  }
} else {
  Write-Host "FAILED: haxe exit $code"
}
exit $code
