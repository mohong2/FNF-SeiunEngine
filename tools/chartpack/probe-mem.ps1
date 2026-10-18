param([string]$Spec, [string]$Out)
$env:SEIUN_CHART_PROBE = $Spec
$env:SEIUN_CHART_PROBE_OUT = $Out
$exe = 'O:\\FNF-PsychEngine-0.6.3\\FNF-PsychEngine-0.6.3\\FNF-SeiunEngine\export\release\windows\bin\SeiunEngine.exe'
$p = Start-Process -FilePath $exe -PassThru -WorkingDirectory (Split-Path $exe)
$max = 0
while (-not $p.HasExited) {
  try { $p.Refresh(); if ($p.WorkingSet64 -gt $max) { $max = $p.WorkingSet64 } } catch {}
  Start-Sleep -Milliseconds 400
}
"MAX_MB=" + [math]::Round($max / 1MB, 1)
if (Test-Path $Out) { Get-Content $Out }
