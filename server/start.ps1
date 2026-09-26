<#
  SeiunEngine server - start / health check / stop

  Usage (works from any directory; the script locates the repository root itself):
    powershell -NoProfile -File server/start.ps1                     # run in foreground (live logs, Ctrl+C to stop)
    powershell -NoProfile -File server/start.ps1 -Lan                # LAN: bind 0.0.0.0
    powershell -NoProfile -File server/start.ps1 -BindHost 192.168.1.5
    powershell -NoProfile -File server/start.ps1 -HttpPort 3000 -WsPort 3001
    powershell -NoProfile -File server/start.ps1 -NoBuild            # skip the build; run the existing server/bin/server.n
    powershell -NoProfile -File server/start.ps1 -Exe                # run server/bin/server.exe (the launcher shell built by build.ps1)
    powershell -NoProfile -File server/start.ps1 -Background         # run in background (writes pid and logs, returns immediately)
    powershell -NoProfile -File server/start.ps1 -AdminEmail me@x.com  # this email becomes the console admin (/console)
    powershell -NoProfile -File server/start.ps1 -DataDir D:\seidata    # override the runtime data directory (default server/data)
    powershell -NoProfile -File server/start.ps1 -Status
    powershell -NoProfile -File server/start.ps1 -Stop

  Outputs / pid / logs (all under server/):
    server/bin/server.n   server/bin/server.exe (used with -Exe; still requires a local Haxe/neko install)
    server/logs/p5_server.pid  server/logs/p5_server.out.log  server/logs/p5_server.err.log

  For double-click launching use server/start.cmd (it pauses before closing the window).
  LAN: publicAddress is echoed from the HTTP Host header; see server/README.md.
#>
param(
  [string]$BindHost = '',
  [int]$HttpPort = 2567,
  [int]$WsPort = 2568,
  [switch]$Lan,
  [switch]$NoBuild,
  # Run server/bin/server.exe (nekotools boot output) instead of `neko server/bin/server.n`
  [switch]$Exe,
  [switch]$Status,
  [switch]$Stop,
  [switch]$Background,
  # Forwarded to server.n: console admin email / runtime data directory (config.toml, mail.log, accounts.json...)
  [string]$AdminEmail = '',
  [string]$DataDir = ''
)

$ErrorActionPreference = 'Stop'
$root    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binDir  = Join-Path $root 'server\bin'
$logDir  = Join-Path $root 'server\logs'
$pidFile = Join-Path $logDir 'p5_server.pid'
$outLog  = Join-Path $logDir 'p5_server.out.log'
$errLog  = Join-Path $logDir 'p5_server.err.log'
$serverN = Join-Path $binDir 'server.n'
$serverExe = Join-Path $binDir 'server.exe'
$neko    = 'C:\HaxeToolkit\neko\neko.exe'

function Test-PortInUse([int]$port) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $client.Connect('127.0.0.1', $port)
    $client.Close()
    return $true
  } catch {
    try { $client.Close() } catch { }
    return $false
  }
}

function Get-ServerPid {
  if (Test-Path $pidFile) {
    $raw = Get-Content $pidFile -Raw
    if ($raw -ne $null) {
      $v = $raw.Trim()
      if ($v -match '^[0-9]+$') { return [int]$v }
    }
  }
  return 0
}

if ($Status) {
  $c = $null
  try { $c = (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$HttpPort/api/onlinecount" -TimeoutSec 3).Content } catch { }
  "pid=$(Get-ServerPid) http=$HttpPort ws=$WsPort onlinecount=$c"
  exit 0
}

if ($Stop) {
  $p = Get-ServerPid
  $stopped = $false
  if ($p -gt 0 -and (Get-Process -Id $p -ErrorAction SilentlyContinue)) {
    Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
    $stopped = $true
  }
  # Fallback: also stop this server's process when the pid file is gone or the directory changed.
  # Only match instances on the same port as this run, otherwise an instance on another port would be killed too.
  Get-CimInstance Win32_Process -Filter "Name='neko.exe' or Name='server.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      if ($_.CommandLine -notlike '*server\bin\server*') { return $false }
      if ($_.CommandLine -like ('*--http-port ' + $HttpPort + '*')) { return $true }
      # An instance without --http-port uses the default 2567; only match it when this run also uses 2567.
      return ($HttpPort -eq 2567 -and $_.CommandLine -notlike '*--http-port*')
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $stopped = $true }
  Remove-Item -Path $pidFile -ErrorAction SilentlyContinue
  if ($stopped) { "stopped pid=$p" } else { 'no running server' }
  exit 0
}

$existing = Get-ServerPid
if ($existing -gt 0 -and (Get-Process -Id $existing -ErrorAction SilentlyContinue)) {
  "already running pid=$existing"
  exit 0
}

foreach ($d in @($binDir, $logDir)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

if (-not $NoBuild) {
  Set-Location $root
  $env:HAXELIB_PATH = Join-Path $root '.haxelib'
  Write-Host 'build: haxe server/server.hxml'
  & haxe 'server/server.hxml'
  if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host "build FAILED (haxe exit $LASTEXITCODE) -- server NOT started." -ForegroundColor Red
    exit 1
  }
}

$target = if ($Exe) { $serverExe } else { $serverN }
if (-not (Test-Path $target)) {
  $hint = if ($Exe) { 'run server/build.ps1 (it boots server.exe) first' } else { 'run server/build.ps1 first' }
  Write-Host "missing $target -- $hint" -ForegroundColor Red
  exit 1
}

# Check the ports first: report clearly when the server is already running or the port is taken,
# instead of letting neko raise a hard-to-read bind error and clobber the live log files.
foreach ($p in @($HttpPort, $WsPort)) {
  if (Test-PortInUse $p) {
    Write-Host "port $p is already in use on 127.0.0.1 -- the server may already be running (-Status / -Stop), or another program owns it." -ForegroundColor Red
    exit 1
  }
}

$bindAddr = $BindHost
if ($bindAddr -eq '') { $bindAddr = if ($Lan) { '0.0.0.0' } else { '127.0.0.1' } }

$flags = @('--host', $bindAddr, '--http-port', "$HttpPort", '--ws-port', "$WsPort")
if ($AdminEmail -ne '') { $flags += @('--admin-email', $AdminEmail) }
if ($DataDir -ne '') { $flags += @('--data-dir', $DataDir) }

# server.exe already embeds the bytecode, so it takes no .n path argument; neko requires the .n path first.
if ($Exe) { $runner = $serverExe; $argList = $flags }
else { $runner = $neko; $argList = @($serverN) + $flags }

if ($Background) {
  $proc = Start-Process -FilePath $runner -ArgumentList $argList -WorkingDirectory $root -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden
  Set-Content -Path $pidFile -Value $proc.Id
  Start-Sleep -Seconds 2
  if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
    Write-Host "server exited immediately (pid=$($proc.Id)) -- see $errLog" -ForegroundColor Red
    if (Test-Path $errLog) { Get-Content $errLog | Write-Host }
    exit 1
  }
  "started (background) pid=$($proc.Id)  bind=$bindAddr  http://127.0.0.1:$HttpPort  ws://127.0.0.1:$WsPort"
  "console: http://127.0.0.1:$HttpPort/console   (web console)"
  "logs: $outLog / $errLog"
  exit 0
}

# ------------------------------------------------------------------
# Foreground run: stream stdout + stderr to the console and write a log copy.
# Normal logs, errors and startup failures such as a taken port stay visible.
# ------------------------------------------------------------------
Write-Host "server : $runner"
Write-Host "bind   : $bindAddr   http://127.0.0.1:$HttpPort   ws://127.0.0.1:$WsPort"
Write-Host "console: http://127.0.0.1:$HttpPort/console   (web console)"
Write-Host "logs   : $outLog"
Write-Host 'Ctrl+C to stop.'
Write-Host ''

# neko's trace() writes to stderr, which PowerShell wraps as error records;
# relax ErrorActionPreference temporarily so server errors are shown without aborting the script
# (otherwise a startup failure such as a taken port would abort before the exit code is printed).
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $runner $argList 2>&1 | Tee-Object -FilePath $outLog
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap

Write-Host ''
if ($code -eq 0) {
  Write-Host 'server exited (code 0)' -ForegroundColor Yellow
} else {
  Write-Host "server exited with code $code" -ForegroundColor Red
}
exit $code
