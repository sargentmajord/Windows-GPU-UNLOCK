# Runs the matrix-multiply benchmark (three trials) on ONE card chosen by its PCI bus address. Every other card is left alone.
# Before it starts it checks that the card is idle and cool (otherwise the numbers are not comparable) and says which programs
# are using it. Writes summary.json (medians, power, temperature, driver) next to the raw trial files.
#   -Bus  '01:00.0'   bus:device.function as nvidia-smi shows it (domain 0000 is assumed)
#   -Root             folder that holds bin\ and where results\ go (default: this folder)
#   -Label            short name for the result folder, for example 'before' or 'after'
param([Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$')][string]$Bus, [string]$Root = $PSScriptRoot, [string]$Label = 'run', [switch]$PreflightOnly)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $Root 'bin\compute-benchmark.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Build the benchmark first' }
$manifest = Get-Content -LiteralPath (Join-Path $Root 'build-manifest.json') -Raw | ConvertFrom-Json
foreach ($artifact in $manifest) {
    if ((Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash -ne $artifact.SHA256) { throw "Artifact changed: $($artifact.Path)" }
}
$inspect = & $exe --inspect-only
if ($LASTEXITCODE -ne 0) { throw 'Runtime metadata check failed' }
Write-Output $inspect
if ($PreflightOnly) { Write-Output 'Preflight only: no GPU workload run'; exit 0 }
$busLower = $Bus.ToLowerInvariant()
function Get-GpuRow {
    $rows = @(& nvidia-smi --query-gpu=name,pci.bus_id,driver_version,utilization.gpu,memory.used,temperature.gpu --format=csv,noheader,nounits)
    if ($LASTEXITCODE -ne 0) { throw 'nvidia-smi failed' }
    foreach ($r in $rows) { $f = @($r -split ',' | ForEach-Object { $_.Trim() }); if ($f[1].ToLowerInvariant() -match ('^0+:' + [regex]::Escape($busLower) + '$')) { return $f } }
    throw "No NVIDIA card at bus $Bus"
}
function Assert-GpuIdle {
    $f = Get-GpuRow
    $busy = ([int]$f[3] -gt 5 -or [int]$f[4] -gt 2048)
    if ($busy) {
        $apps = @(& nvidia-smi --query-compute-apps=gpu_bus_id,process_name --format=csv,noheader 2>$null | Where-Object { $_.ToLowerInvariant() -match ('0+:' + [regex]::Escape($busLower)) } | ForEach-Object { [IO.Path]::GetFileName(($_ -split ',', 2)[1].Trim()) })
        $who = if ($apps.Count) { ' Using it now: ' + ($apps -join ', ') + '.' } else { '' }
        throw ("The card at $Bus is busy (GPU $($f[3])%, memory $($f[4]) MiB).$who Save and close those programs and run this again. Nothing was stopped.")
    }
    if ([int]$f[5] -gt 65) { throw "The card at $Bus is still hot ($($f[5]) C). Let it cool before a comparable measurement." }
    return $f
}
$initial = Assert-GpuIdle
$resultRoot = Join-Path $Root ('results\' + $Label + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $resultRoot | Out-Null
($initial -join ',') | Set-Content -LiteralPath (Join-Path $resultRoot 'gpu-before.csv') -Encoding utf8
$measurements = @(); $power = @(); $temp = @(); $clock = @()
$pci = '0000:' + $Bus
for ($trial = 1; $trial -le 3; $trial++) {
    $json = & $exe --pci $pci 2> (Join-Path $resultRoot "trial-$trial.stderr.txt")
    if ($LASTEXITCODE -ne 0) { throw "Benchmark failed in trial $trial; partial evidence is in $resultRoot" }
    $parsed = $json | ConvertFrom-Json
    if ($parsed.pci -ne $pci.ToLowerInvariant() -or $parsed.cuda_runtime -ne 12060 -or $parsed.cublas -ne 120600 -or $parsed.benchmarks.Count -ne 3) { throw 'Unexpected benchmark metadata' }
    $json | Set-Content -LiteralPath (Join-Path $resultRoot "trial-$trial.json") -Encoding utf8
    $measurements += $parsed
    $tele = @(& nvidia-smi --query-gpu=pci.bus_id,clocks.sm,power.draw,temperature.gpu --format=csv,noheader,nounits | Where-Object { $_.ToLowerInvariant() -match ('0+:' + [regex]::Escape($busLower) + ',') })
    if ($LASTEXITCODE -ne 0 -or $tele.Count -ne 1) { throw 'GPU telemetry failed; preserve partial results' }
    $tf = @($tele[0] -split ',' | ForEach-Object { $_.Trim() })
    $clock += [double]$tf[1]; $power += [double]$tf[2]; $temp += [double]$tf[3]
    $tele[0] | Set-Content -LiteralPath (Join-Path $resultRoot "trial-$trial-gpu-after.csv") -Encoding utf8
}
$benchmarks = @()
foreach ($name in @('fp32_pedantic', 'fp16_tensor_fp32_accumulate', 'bf16_tensor_fp32_accumulate')) {
    $values = @($measurements | ForEach-Object { $_.benchmarks | Where-Object name -EQ $name | ForEach-Object { [double]$_.gflops / 1000 } } | Sort-Object)
    $benchmarks += [pscustomobject]@{Name=$name;MedianTflops=$values[1];MinTflops=$values[0];MaxTflops=$values[2]}
}
$summary = [pscustomobject]@{
    Label = $Label; Bus = $Bus; Gpu = $measurements[0].gpu; DriverVersion = $initial[2]
    Benchmarks = $benchmarks
    MaxPowerWatts = ($power | Measure-Object -Maximum).Maximum; MaxTempC = ($temp | Measure-Object -Maximum).Maximum; MaxSmClockMhz = ($clock | Measure-Object -Maximum).Maximum
    StartTempC = [int]$initial[5]; Trials = 3
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $resultRoot 'summary.json') -Encoding utf8
$benchmarks | Format-Table -AutoSize | Out-String | Write-Output
Write-Output "RESULT_DIR=$resultRoot"
