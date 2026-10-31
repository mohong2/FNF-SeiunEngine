[CmdletBinding()]
param([switch]$Portable)

$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $dir

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw '找不到 .NET Framework 4.x 的 csc.exe（Windows 10/11 默认自带）。' }

$refs = @(
    '/r:System.dll',
    '/r:System.Core.dll',
    '/r:System.Windows.Forms.dll',
    '/r:System.Drawing.dll',
    '/r:System.Web.Extensions.dll',
    '/r:System.Web.dll'
)

$cscArgs = @(
    '/nologo',
    '/target:winexe',
    '/platform:anycpu',
    '/codepage:65001',
    '/win32icon:app.ico',
    '/win32manifest:app.manifest',
    '/resource:chartpack.mjs,chartpack.mjs',
    '/out:chartpack-ui.exe'
) + $refs + @('ChartPackUI.cs', 'Lang.cs')

Write-Host '编译 chartpack-ui.exe ...'
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc 编译失败（exit $LASTEXITCODE）" }
$exe = Join-Path $dir 'chartpack-ui.exe'
Write-Host ('完成: ' + $exe + '  (' + [math]::Round((Get-Item $exe).Length / 1KB, 1) + ' KiB)')

if (-not $Portable) { return }

Write-Host '收集便携版（exe + node.exe + chartpack.mjs）...'
$node = $null
$cmd = Get-Command node.exe -ErrorAction SilentlyContinue
if ($cmd -ne $null) { $node = $cmd.Source }
if ($node -eq $null) {
    $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
        (Join-Path $pf86 'nodejs\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
    )) {
        if ($p -and (Test-Path $p)) { $node = $p; break }
    }
}
if ($node -eq $null) { throw '找不到 node.exe；请安装 Node.js 18+ 或把 node.exe 放到 PATH 后再执行 -Portable。' }

$dist = Join-Path $dir 'dist'
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist | Out-Null
Copy-Item $exe (Join-Path $dist 'chartpack-ui.exe')
Copy-Item (Join-Path $dir 'chartpack.mjs') (Join-Path $dist 'chartpack.mjs')
Copy-Item $node (Join-Path $dist 'node.exe')
$license = Join-Path (Split-Path $node) 'LICENSE'
if (Test-Path $license) { Copy-Item $license (Join-Path $dist 'LICENSE-node.txt') }

$readme = @'
Seiun ChartPack GUI — 便携版
============================

双击 chartpack-ui.exe 即可使用，已内置 node.exe，不需要安装 Node.js。

功能：
  * 输入类型下拉框：单个 JSON / 文件夹 / ZIP 压缩包
  * 直接对 ZIP 内部打包，不解压到磁盘
  * 右上角语言：跟随系统 / 简体中文 / English，立即切换
  * 实时显示每个文件的原始大小、输出大小、压缩比、用时、速度、音符数
  * 支持并发、tick/float 自动模式、覆盖已有 pack
  * 找不到 Node.js 时会提示安装或选择 node.exe

内置的 node.exe 来自 Node.js（MIT License，https://nodejs.org/）。

注意：
  * “打包后删除源 JSON”只会删除文件夹模式下的源文件，默认不勾选。
  * 覆盖已有 .chartpack 需要勾选“覆盖已有 pack”。
  * 分段谱面请把 <song>.parts.json 一起放到 data/<song>/。
'@
Set-Content -Path (Join-Path $dist '使用说明.txt') -Value $readme -Encoding UTF8

$zip = Join-Path $dir 'chartpack-ui-portable.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $zip -CompressionLevel Optimal
Write-Host ('便携版: ' + $zip + '  (' + [math]::Round((Get-Item $zip).Length / 1MB, 1) + ' MiB)')