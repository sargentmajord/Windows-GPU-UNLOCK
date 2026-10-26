# Before/after benchmark and verdict (plan requirement 13, 18, 19). On by default; the user may decline, with a strong warning.
# The benchmark runs on the chosen card only, found by its PCI bus address. Results stay local. Needs State.ps1, Ui.ps1, Tools.ps1,
# Capture.ps1 (Get-WorkRoot, Get-RepoRoot, Invoke-SysPowerShellFile).

$script:BenchmarkBytes = 488838722          # sum of NVIDIA's four CUDA 12.6.0 redistributables (checked with setup.ps1 -ListOnly)
# HINT ONLY. FP16 tensor speed divided by FP32 speed: about 3.2 locked and 5.9 unlocked on the reference RTX 3060, but a different card can sit lower
# (an unlocked RTX 3090 is about 4.0, so this limit would not notice it). It is used to warn about an unfair baseline, never to decide anything.
# The authoritative check is the capture's selector state: profile_gen.py refuses a card that is already unlocked, and the boot programs
# refuse to run unless the card is in its untouched startup state.
$script:LockedRatioLimit = 4.5

function Get-BenchmarkRoot { Join-Path (Get-WorkRoot) 'benchmark' }
function Invoke-SysBenchmarkProcess([string]$CommandText) {
 $ErrorActionPreference = 'Continue'
 $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $CommandText 2>&1
 [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($o | Out-String) }
}

function Show-BenchmarkOffer {
 Write-Plain ''
 Write-Plain 'Benchmark: a before-and-after measurement of your card.'
 Write-Plain ('  It runs a matrix-multiply test three times (about a minute of full load on the card you chose) before the unlock and again after it,'
 )
 Write-Plain '  then shows a plain comparison and a verdict. It needs NVIDIA''s CUDA compiler and libraries:'
 Write-Plain ('  download about {0:N0} MB from developer.download.nvidia.com, each file checked against NVIDIA''s published hash, kept in the installer''s' -f ($script:BenchmarkBytes / 1000000))
 Write-Plain '  own folder, nothing installed system-wide. Results are saved on your PC only; nothing is uploaded.'
 Write-Plain ''
 Write-Plain '  We highly recommend you do not skip this. The benchmark is the only way to find out whether the unlock is worth the effort of installing it on your PC.'
}

# Returns $true (run it) or $false (skipped). The choice is stored by the caller.
function Ask-Benchmark {
 Show-BenchmarkOffer
 if (Ask-YesNo ('Download about {0:N0} MB and run the benchmark?' -f ($script:BenchmarkBytes / 1000000))) { return $true }
 Write-Plain 'The benchmark is skipped. The final report will say "improvement not measured" and give no verdict. You can still run it at the end.'
 $false
}

function Test-BenchmarkBuilt { (Test-Path -LiteralPath (Join-Path (Get-BenchmarkRoot) 'bin\compute-benchmark.exe')) -and (Test-Path -LiteralPath (Join-Path (Get-BenchmarkRoot) 'build-manifest.json')) }

# Downloads NVIDIA's CUDA components into the work folder and builds the benchmark. Both steps are the repo's own scripts.
function Initialize-Benchmark($State, $Tools, [switch]$DryRun) {
 $root = Get-BenchmarkRoot
 if ($DryRun) { Write-Plain "DRYRUN: download and check the CUDA components, then build the benchmark in $root"; return }
 if (Test-BenchmarkBuilt) { return }
 [void](New-Item -ItemType Directory -Path $root -Force)
 $be = Get-BuildEnvironment $Tools $null
 $repoBench = Join-Path (Get-RepoRoot) 'benchmark'
 [void](Invoke-JournaledChange -Phase 'benchmark' -Action 'download and build the benchmark' -Target $root -Undo 'files stay in the installer folder; Roll back asks whether to delete them' -Do {
  if (-not (Test-Path -LiteralPath (Join-Path $root 'packages\libcublas'))) {
   $r = Invoke-SysBenchmarkProcess (New-ScriptCall (Join-Path $repoBench 'setup.ps1') ([ordered]@{ Root = $root }))
   if ($r.Code -ne 0) { throw ('Downloading the CUDA components failed: ' + $r.Output) }
  }
  Invoke-WithBuildEnvironment $be { $script:__b = Invoke-SysBenchmarkProcess (New-ScriptCall (Join-Path $repoBench 'build.ps1') ([ordered]@{ Root = $root; VcVars = $be.VcVars })) }
  if ($script:__b.Code -ne 0) { throw ('Building the benchmark failed: ' + $script:__b.Output) }
 })
}

# One measurement run (three trials) on the chosen card. Returns the summary, or throws with the script's own message
# (for example "the card is busy", naming the programs using it).
function Invoke-BenchmarkRun($State, [string]$Label, [switch]$DryRun) {
 if ($DryRun) { Write-Plain "DRYRUN: run the '$Label' benchmark on bus $($State.Cards.Target.Bus)"; return $null }
 $root = Get-BenchmarkRoot
 $call = New-ScriptCall (Join-Path (Get-RepoRoot) 'benchmark\run-benchmark.ps1') ([ordered]@{ Bus = $State.Cards.Target.Bus; Root = $root; Label = $Label })
 $r = Invoke-SysBenchmarkProcess $call
 $m = [regex]::Match($r.Output, '(?m)^RESULT_DIR=(.+)$')
 if ($r.Code -ne 0 -or -not $m.Success) {
  $msg = @($r.Output -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\s+(\+|At |CategoryInfo|FullyQualified)' } | Select-Object -First 3) -join ' '
  throw ('Benchmark did not run: ' + $msg)
 }
 $s = Get-Content -LiteralPath (Join-Path $m.Groups[1].Value.Trim() 'summary.json') -Raw | ConvertFrom-Json
 ConvertTo-BenchmarkRecord $s
}

function ConvertTo-BenchmarkRecord($Summary) {
 $get = { param($n) ($Summary.Benchmarks | Where-Object Name -eq $n).MedianTflops }
 [ordered]@{ Label = $Summary.Label; Gpu = $Summary.Gpu; Bus = $Summary.Bus; Driver = $Summary.DriverVersion
  Fp32 = [double](& $get 'fp32_pedantic'); Fp16 = [double](& $get 'fp16_tensor_fp32_accumulate'); Bf16 = [double](& $get 'bf16_tensor_fp32_accumulate')
  MaxPowerWatts = [double]$Summary.MaxPowerWatts; MaxTempC = [double]$Summary.MaxTempC; MaxSmClockMhz = [double]$Summary.MaxSmClockMhz; Measured = (Get-Date).ToString('o') }
}

# FP16 tensor speed divided by FP32 speed. Locked cards sit near 3; an unlocked card near 6 (reference card).
function Get-TensorRatio($Record) { if ($Record.Fp32 -gt 0) { $Record.Fp16 / $Record.Fp32 } else { 0 } }
function Test-LooksUnlocked($Record) { (Get-TensorRatio $Record) -ge $script:LockedRatioLimit }

# Plain-words verdict from the median of three trials. Cut-offs are this installer's rule of thumb, not an upstream figure.
function Get-Verdict($Before, $After) {
 $g16 = if ($Before.Fp16 -gt 0) { ($After.Fp16 / $Before.Fp16 - 1) * 100 } else { 0 }
 $gbf = if ($Before.Bf16 -gt 0) { ($After.Bf16 / $Before.Bf16 - 1) * 100 } else { 0 }
 $g32 = if ($Before.Fp32 -gt 0) { ($After.Fp32 / $Before.Fp32 - 1) * 100 } else { 0 }
 # compare what is shown: one decimal (12.0 vs 10.0 is exactly +20.0%, not 19.999...)
 $g16 = [math]::Round($g16, 1); $gbf = [math]::Round($gbf, 1); $g32 = [math]::Round($g32, 1)
 $best = [math]::Max($g16, $gbf)
 $level = if ($best -ge 20) { 'clear' } elseif ($best -ge 5) { 'small' } else { 'none' }
 $control = [math]::Abs($g32) -gt 5
 $text = switch ($level) {
  'clear' { 'clear improvement' }
  'small' { 'small improvement' }
  default { 'no meaningful improvement: consider rolling back' }
 }
 [pscustomobject]@{ Level = $level; Text = $text; Fp16Percent = $g16; Bf16Percent = $gbf; Fp32Percent = $g32; ControlOff = $control
  OneMissing = (($g16 -ge 20) -xor ($gbf -ge 20)) }
}

function Show-Verdict($Before, $After, $Verdict) {
 Write-Plain ''
 Write-Plain ('Benchmark result for {0} (bus {1}), median of three trials, TFLOPS:' -f $After.Gpu, $After.Bus)
 Write-Plain ('  {0,-26} {1,8} {2,8} {3,9}' -f '', 'before', 'after', 'change')
 foreach ($row in @(@('FP16 tensor math', 'Fp16', $Verdict.Fp16Percent), @('BF16 tensor math', 'Bf16', $Verdict.Bf16Percent), @('FP32 (control, should not change)', 'Fp32', $Verdict.Fp32Percent))) {
  Write-Plain ('  {0,-26} {1,8:N2} {2,8:N2} {3,8:+0.0;-0.0}%' -f $row[0], $Before[$row[1]], $After[$row[1]], $row[2])
 }
 Write-Plain ('  Driver {0}; before: {1:N0} W, {2:N0} C; after: {3:N0} W, {4:N0} C at the highest point.' -f $After.Driver, $Before.MaxPowerWatts, $Before.MaxTempC, $After.MaxPowerWatts, $After.MaxTempC)
 Write-Plain ''
 Write-Plain ('Verdict: {0}.' -f $Verdict.Text)
 if ($Verdict.ControlOff) { Write-Plain 'The FP32 control changed by more than 5%, so the two measurements were not made under the same conditions (heat, power limit or other load). Treat the comparison with care and measure again.' }
 if ($Verdict.OneMissing) { Write-Plain 'Only one of FP16 and BF16 improved clearly. Some cards (for example an OEM RTX 3080 Ti, upstream issue #28) finish the unlock but gain nothing in one precision.' }
 Write-Plain 'Only matrix-heavy GPU work gets faster (for example AI model prefill, training and image generation). Games, FP32 work and memory-bound work such as single-token LLM decode do not.'
 Write-Plain ('The unlocked card drew up to about {0:N0} W and reached {1:N0} C in this test; power draw and heat go up.' -f $After.MaxPowerWatts, $After.MaxTempC)
}

# Public-safe report: card names and numbers only (no user name, serials or paths).
function Save-BenchmarkReport($Before, $After, $Verdict, [string]$Folder) {
 [void](New-Item -ItemType Directory -Path $Folder -Force)
 $file = Join-Path $Folder ('benchmark-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
 $lines = @('Windows GPU UNLOCK benchmark report', ('Date: {0:s}' -f (Get-Date)), ('Card: {0} (bus {1}), driver {2}' -f $After.Gpu, $After.Bus, $After.Driver), '',
  'Median of three trials, TFLOPS (before / after / change):',
  ('  FP16 tensor: {0:N2} / {1:N2} / {2:+0.0;-0.0}%' -f $Before.Fp16, $After.Fp16, $Verdict.Fp16Percent),
  ('  BF16 tensor: {0:N2} / {1:N2} / {2:+0.0;-0.0}%' -f $Before.Bf16, $After.Bf16, $Verdict.Bf16Percent),
  ('  FP32 control: {0:N2} / {1:N2} / {2:+0.0;-0.0}%' -f $Before.Fp32, $After.Fp32, $Verdict.Fp32Percent),
  ('Highest power / temperature: before {0:N0} W, {1:N0} C; after {2:N0} W, {3:N0} C' -f $Before.MaxPowerWatts, $Before.MaxTempC, $After.MaxPowerWatts, $After.MaxTempC),
  ('Verdict: ' + $Verdict.Text))
 $lines | Set-Content -LiteralPath $file -Encoding utf8
 $file
}
