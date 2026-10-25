# Modified 2026-10-19/20 for Windows GPU UNLOCK; changes documented in CHANGES.md.
param([switch]$PreflightOnly)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$exe = Join-Path $root 'bin\compute-benchmark-3060.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Build the benchmark first' }
$manifest = Get-Content -LiteralPath (Join-Path $root 'build-manifest.json') -Raw | ConvertFrom-Json
foreach ($artifact in $manifest) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $artifact.Path) -Algorithm SHA256).Hash -ne $artifact.SHA256) { throw "Artifact changed: $($artifact.Path)" }
}
$inspect = & $exe --inspect-only
if ($LASTEXITCODE -ne 0) { throw 'Runtime metadata check failed' }
Write-Output $inspect
if ($PreflightOnly) { Write-Output 'Preflight only: no GPU workload run'; exit 0 }
function Assert-GpuIdle {
    $rows = @(& nvidia-smi --query-gpu=name,pci.bus_id,driver_version,utilization.gpu,memory.used,temperature.gpu --format=csv,noheader,nounits | Where-Object { $_ -like "NVIDIA GeForce RTX 3060,*" })
    if ($LASTEXITCODE -ne 0 -or $rows.Count -lt 1) { throw 'Expected the RTX 3060 to be present' }
    $fields = $rows[0] -split ',' | ForEach-Object { $_.Trim() }
    if ($fields[0] -ne 'NVIDIA GeForce RTX 3060' -or $fields[1] -notmatch '^0+:01:00\.0$') { throw 'Unexpected GPU identity' }
    if ([int]$fields[3] -gt 5 -or [int]$fields[4] -gt 2048) { throw 'GPU is busy. Save and finish ComfyUI/other GPU jobs before benchmarking. Nothing was stopped.' }
    if ([int]$fields[5] -gt 65) { throw 'GPU is still hot. Let it cool before a comparable measurement.' }
    return $rows[0]
}
$initialState = Assert-GpuIdle
$resultRoot = Join-Path $root ('results\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
if (Test-Path -LiteralPath $resultRoot) { throw 'Result directory exists' }
New-Item -ItemType Directory -Path $resultRoot | Out-Null
$initialState | Set-Content -LiteralPath (Join-Path $resultRoot 'gpu-before.csv') -Encoding utf8
$measurements = @()
for ($trial = 1; $trial -le 3; $trial++) {
    # The initial check protects existing workloads. Trials themselves may leave transient utilization/heat.
    $json = & $exe 2> (Join-Path $resultRoot "trial-$trial.stderr.txt")
    if ($LASTEXITCODE -ne 0) { throw "Benchmark failed in trial $trial; keep partial evidence in $resultRoot" }
    $parsed = $json | ConvertFrom-Json
    if ($parsed.gpu -ne 'NVIDIA GeForce RTX 3060' -or $parsed.cuda_runtime -ne 12060 -or $parsed.cublas -ne 120600 -or $parsed.benchmarks.Count -ne 3) { throw 'Unexpected benchmark metadata' }
    $json | Set-Content -LiteralPath (Join-Path $resultRoot "trial-$trial.json") -Encoding utf8
    $measurements += $parsed
    & nvidia-smi --query-gpu=timestamp,driver_version,clocks.sm,power.draw,temperature.gpu,clocks_event_reasons.sw_thermal_slowdown --format=csv |
        Set-Content -LiteralPath (Join-Path $resultRoot "trial-$trial-gpu-after.csv") -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'GPU telemetry failed; preserve partial results' }
}
$summary = @()
foreach ($name in @('fp32_pedantic','fp16_tensor_fp32_accumulate','bf16_tensor_fp32_accumulate')) {
    $values = @($measurements | ForEach-Object { $_.benchmarks | Where-Object name -EQ $name | ForEach-Object { [double]$_.gflops / 1000 } } | Sort-Object)
    $summary += [pscustomobject]@{Name=$name;MedianTflops=$values[1];MinTflops=$values[0];MaxTflops=$values[2]}
}
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resultRoot 'summary.json') -Encoding utf8
$summary | Format-Table -AutoSize
Write-Output "Three trials saved to $resultRoot. These are current-state measurements; no pre-unlock baseline or speedup is implied."
