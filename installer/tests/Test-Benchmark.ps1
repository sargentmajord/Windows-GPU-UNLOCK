# Benchmark offer, preparation, verdict and report, plus the REAL benchmark\run-benchmark.ps1 run against fake nvidia-smi and
# benchmark programs (small C# executables built here), so the script's parsing and idle/heat checks are exercised without any GPU.
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$repo = Split-Path -Parent $base

# ---------------- verdict ----------------
function Rec($Fp32, $Fp16, $Bf16, $W = 100, $C = 60) { [ordered]@{ Gpu = 'NVIDIA GeForce RTX 3060'; Bus = '01:00.0'; Driver = '617.42'; Fp32 = $Fp32; Fp16 = $Fp16; Bf16 = $Bf16; MaxPowerWatts = $W; MaxTempC = $C } }
$before = Rec 8.20 26.51 26.40
$v = Get-Verdict $before (Rec 8.18 48.13 50.34 149 68)
Expect 'the reference result is a clear improvement' $v.Level 'clear'
ExpectTrue 'FP16 +81.6%' ([math]::Abs($v.Fp16Percent - 81.55) -lt 0.1)
ExpectTrue 'BF16 +90.7%' ([math]::Abs($v.Bf16Percent - 90.68) -lt 0.1)
ExpectTrue 'the FP32 control is fine' (-not $v.ControlOff)
Expect 'exactly +20% is clear' (Get-Verdict (Rec 8 10 10) (Rec 8 12 10)).Level 'clear'
Expect 'just under +20% is small' (Get-Verdict (Rec 8 10 10) (Rec 8 11.99 10)).Level 'small'
Expect 'exactly +5% is small' (Get-Verdict (Rec 8 10 10) (Rec 8 10.5 10)).Level 'small'
Expect 'just under +5% is none' (Get-Verdict (Rec 8 10 10) (Rec 8 10.49 10.49)).Level 'none'
Expect 'no change is none' (Get-Verdict $before $before).Level 'none'
ExpectTrue 'none says to consider rolling back' ((Get-Verdict $before $before).Text -like '*consider rolling back*')
Expect 'the better of FP16 and BF16 decides' (Get-Verdict (Rec 8 10 10) (Rec 8 10 13)).Level 'clear'
ExpectTrue 'one precision missing is flagged' (Get-Verdict (Rec 8 10 10) (Rec 8 13 10)).OneMissing
ExpectTrue 'both improving is not flagged' (-not (Get-Verdict (Rec 8 10 10) (Rec 8 13 13)).OneMissing)
ExpectTrue 'FP32 moving by more than 5% flags different conditions' (Get-Verdict (Rec 8 10 10) (Rec 9 13 13)).ControlOff
ExpectTrue 'a zero baseline does not divide by zero' ((Get-Verdict (Rec 0 0 0) (Rec 8 10 10)).Level -eq 'none')
ExpectTrue 'locked card looks locked' (-not (Test-LooksUnlocked $before))
ExpectTrue 'unlocked card looks unlocked' (Test-LooksUnlocked (Rec 8.18 48.13 50.34))
Expect 'tensor ratio' ([math]::Round((Get-TensorRatio $before), 2)) 3.23

Set-Answers @()
Show-Verdict $before (Rec 8.18 48.13 50.34 149 68) $v
$text = OutText
ExpectTrue 'verdict screen shows the table and the verdict' (($text -like '*FP16 tensor math*26.51*48.13*+81.6%*') -and ($text -like '*Verdict: clear improvement.*'))
ExpectTrue 'it says what gets faster and what does not' (($text -like '*matrix-heavy*') -and ($text -like '*Games, FP32 work and memory-bound*'))
ExpectTrue 'it states power and heat' ($text -like '*149 W*68 C*')
Set-Answers @(); Show-Verdict $before (Rec 9.5 13 13) (Get-Verdict $before (Rec 9.5 13 13))
ExpectTrue 'a moved control is explained' ((OutText) -like '*not made under the same conditions*')
Set-Answers @(); Show-Verdict $before (Rec 8.2 40 26.4) (Get-Verdict $before (Rec 8.2 40 26.4))
ExpectTrue 'a one-precision gain mentions issue 28' ((OutText) -like '*issue #28*')

$t = New-TestRoot
try {
 $f = Save-BenchmarkReport $before (Rec 8.18 48.13 50.34 149 68) $v (Join-Path $t 'reports')
 $r = Get-Content $f -Raw
 ExpectTrue 'report has the numbers and the verdict' (($r -like '*26.51 / 48.13*') -and ($r -like '*Verdict: clear improvement*'))
 ExpectTrue 'report holds no user name' ($r -notlike "*$env:USERNAME*")

 # ---------------- the offer ----------------
 Set-Answers @('Y'); ExpectTrue 'Y runs the benchmark' (Ask-Benchmark)
 $o = OutText
 ExpectTrue 'the offer states size and source' (($o -like '*489 MB*') -and ($o -like '*developer.download.nvidia.com*') -and ($o -like '*published hash*'))
 ExpectTrue 'the offer has the strong recommendation, word for word' ($o -like '*We highly recommend you do not skip this. The benchmark is the only way to find out whether the unlock is worth the effort of installing it on your PC.*')
 ExpectTrue 'the offer says results stay local' ($o -like '*nothing is uploaded*')
 Set-Answers @('N'); ExpectTrue 'N skips' (-not (Ask-Benchmark))
 ExpectTrue 'skipping says improvement is not measured' ((OutText) -like '*improvement not measured*')

 # ---------------- preparation (mocked processes) ----------------
 Set-RepoRoot $repo
 Set-InstallerRoot (Join-Path $t 'inst')
 $tools = @(
  [pscustomobject]@{ Id = 'llvm'; Info = [pscustomobject]@{ Path = 'C:\LLVM\bin\clang.exe'; Dir = 'C:\LLVM\bin'; Lld = 'x' } },
  [pscustomobject]@{ Id = 'python'; Info = [pscustomobject]@{ Path = 'C:\Py\python.exe' } },
  [pscustomobject]@{ Id = 'msvc'; Info = [pscustomobject]@{ VcVars = 'C:\VS\vcvars64.bat'; VswhereDir = 'C:\VSI' } })
 $script:Procs = New-Object System.Collections.ArrayList; $script:ProcCode = 0
 function Invoke-SysBenchmarkProcess([string]$CommandText) {
  [void]$script:Procs.Add($CommandText)
  if ($CommandText -like '*setup.ps1*') { [void](New-Item -ItemType Directory -Path (Join-Path (Get-BenchmarkRoot) 'packages\libcublas') -Force) }
  if ($CommandText -like '*build.ps1*' -and $script:ProcCode -eq 0) { [void](New-Item -ItemType Directory -Path (Join-Path (Get-BenchmarkRoot) 'bin') -Force); Set-Content (Join-Path (Get-BenchmarkRoot) 'bin\compute-benchmark.exe') 'x'; Set-Content (Join-Path (Get-BenchmarkRoot) 'build-manifest.json') '[]' }
  [pscustomobject]@{ Code = $script:ProcCode; Output = 'process output' }
 }
 $st = [ordered]@{ Cards = [ordered]@{ Target = [ordered]@{ Bus = '01:00.0' } } }
 ExpectTrue 'not built at first' (-not (Test-BenchmarkBuilt))
 Initialize-Benchmark $st $tools -DryRun
 Expect 'dry run runs nothing' $script:Procs.Count 0
 Initialize-Benchmark $st $tools
 Expect 'setup then build' $script:Procs.Count 2
 ExpectTrue 'setup writes into the installer work folder, not the repo' ($script:Procs[0] -like "*setup.ps1* -Root '$(Get-BenchmarkRoot)'*")
 ExpectTrue 'build gets the work folder and the MSVC environment file' ($script:Procs[1] -like "*build.ps1* -Root '$(Get-BenchmarkRoot)' -VcVars 'C:\VS\vcvars64.bat'*")
 ExpectTrue 'built now' (Test-BenchmarkBuilt)
 Initialize-Benchmark $st $tools
 Expect 'a second call changes nothing' $script:Procs.Count 2
 Expect 'journaled and done' (@(Read-Journal) | Where-Object Action -like 'download and build*').Status 'done'
 Remove-Item (Get-BenchmarkRoot) -Recurse -Force; $script:Procs.Clear(); $script:ProcCode = 7
 ExpectThrows 'a failing download is reported with its output' { Initialize-Benchmark $st $tools } '*Downloading the CUDA components failed*process output*'
 Expect 'and failed in the journal' @(Read-Journal)[-1].Status 'failed'
 $script:ProcCode = 0

 # ---------------- a run through the mocked process ----------------
 $resDir = Join-Path $t 'res'; [void](New-Item -ItemType Directory $resDir)
 $summary = [pscustomobject]@{ Label = 'before'; Bus = '01:00.0'; Gpu = 'NVIDIA GeForce RTX 3060'; DriverVersion = '617.42'; MaxPowerWatts = 120; MaxTempC = 61; MaxSmClockMhz = 1900
  Benchmarks = @([pscustomobject]@{ Name = 'fp32_pedantic'; MedianTflops = 8.2 }, [pscustomobject]@{ Name = 'fp16_tensor_fp32_accumulate'; MedianTflops = 26.5 }, [pscustomobject]@{ Name = 'bf16_tensor_fp32_accumulate'; MedianTflops = 26.4 }) }
 $summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $resDir 'summary.json')
 $script:Out2 = "table`r`nRESULT_DIR=$resDir`r`n"
 function Invoke-SysBenchmarkProcess([string]$CommandText) { [void]$script:Procs.Add($CommandText); [pscustomobject]@{ Code = $script:ProcCode; Output = $script:Out2 } }
 $script:Procs.Clear()
 $rec = Invoke-BenchmarkRun $st 'before'
 Expect 'record: fp16' $rec.Fp16 26.5
 Expect 'record: gpu' $rec.Gpu 'NVIDIA GeForce RTX 3060'
 ExpectTrue 'the run is for the chosen bus only' ($script:Procs[0] -like "*run-benchmark.ps1* -Bus '01:00.0'*-Label 'before'*")
 $script:ProcCode = 1; $script:Out2 = "The card at 01:00.0 is busy (GPU 80%, memory 4000 MiB). Using it now: chrome.exe. Save and close those programs.`r`n    + CategoryInfo : x"
 ExpectThrows 'a busy card is reported with its reason' { Invoke-BenchmarkRun $st 'before' } '*busy*chrome.exe*'
 $script:ProcCode = 0; $script:Out2 = 'no result line'
 ExpectThrows 'a run without a result line is an error' { Invoke-BenchmarkRun $st 'before' } '*did not run*'
 Expect 'dry run runs no benchmark' (Invoke-BenchmarkRun $st 'before' -DryRun) $null
} finally { Remove-TestRoot $t }

# ---------------- the real run-benchmark.ps1 against fake programs ----------------
$t = New-TestRoot
try {
 $fakes = Join-Path $t 'fakes'; [void](New-Item -ItemType Directory $fakes)
 $smiSrc = @'
using System;
class P { static int Main(string[] a) {
  string q = string.Join(" ", a); string busy = Environment.GetEnvironmentVariable("FAKE_BUSY"); string hot = Environment.GetEnvironmentVariable("FAKE_HOT");
  if (q.Contains("--query-compute-apps")) { Console.WriteLine("00000000:01:00.0, C:\\Users\\someone\\Games\\game.exe"); Console.WriteLine("00000000:02:00.0, C:\\other\\x.exe"); return 0; }
  if (q.Contains("name,pci.bus_id,driver_version")) {
    Console.WriteLine("NVIDIA GeForce RTX 5070, 00000000:02:00.0, 617.42, 3, 1500, 40");
    Console.WriteLine("NVIDIA GeForce RTX 3060, 00000000:01:00.0, 617.42, " + (busy == "1" ? "88" : "0") + ", " + (busy == "1" ? "4000" : "10") + ", " + (hot == "1" ? "80" : "36")); return 0; }
  if (q.Contains("clocks.sm")) { Console.WriteLine("00000000:02:00.0, 2500, 80.0, 45"); Console.WriteLine("00000000:01:00.0, 1900, 148.5, 61"); return 0; }
  return 1; } }
'@
 $benchSrc = @'
using System;
class P { static int Main(string[] a) {
  if (a.Length == 1 && a[0] == "--inspect-only") { Console.WriteLine("{\"cuda_runtime\":12060,\"cublas_major\":12,\"cublas_minor\":6,\"cublas_patch\":0,\"gpu_workload_run\":false}"); return 0; }
  if (a.Length != 2 || a[0] != "--pci") return 2;
  if (a[1] != "0000:01:00.0") return 2;
  double f = double.Parse(Environment.GetEnvironmentVariable("FAKE_FP16") ?? "26500");
  Console.WriteLine("{\"gpu\":\"NVIDIA GeForce RTX 3060\",\"pci\":\"0000:01:00.0\",\"compute_capability\":\"8.6\",\"cuda_runtime\":12060,\"cuda_driver_api\":13000,\"cublas\":120600,\"benchmarks\":[" +
   "{\"name\":\"fp32_pedantic\",\"gflops\":8200.0},{\"name\":\"fp16_tensor_fp32_accumulate\",\"gflops\":" + f + "},{\"name\":\"bf16_tensor_fp32_accumulate\",\"gflops\":26400.0}]}");
  return 0; } }
'@
 Add-Type -TypeDefinition $smiSrc -OutputAssembly (Join-Path $fakes 'nvidia-smi.exe') -OutputType ConsoleApplication
 $root = Join-Path $t 'benchroot'; $bin = Join-Path $root 'bin'; [void](New-Item -ItemType Directory $bin -Force)
 Add-Type -TypeDefinition $benchSrc -OutputAssembly (Join-Path $bin 'compute-benchmark.exe') -OutputType ConsoleApplication
 $exe = Join-Path $bin 'compute-benchmark.exe'
 @([ordered]@{ Path = $exe; Bytes = (Get-Item $exe).Length; SHA256 = (Get-FileHash $exe -Algorithm SHA256).Hash }) | ConvertTo-Json | Set-Content (Join-Path $root 'build-manifest.json')
 $script:ProcOut = $null
 function Invoke-SysBenchmarkProcess([string]$CommandText) {
  $ErrorActionPreference = 'Continue'
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $CommandText 2>&1
  [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($o | Out-String) }
 }
 $savedPath = $env:PATH; $env:PATH = "$fakes;$savedPath"
 try {
  $script = Join-Path $repo 'benchmark\run-benchmark.ps1'
  $call = { param($bus, $label) New-ScriptCall $script ([ordered]@{ Bus = $bus; Root = $root; Label = $label }) }
  # preflight only
  $r = Invoke-SysBenchmarkProcess (New-ScriptCall $script ([ordered]@{ Bus = '01:00.0'; Root = $root; PreflightOnly = $true }))
  ExpectTrue 'preflight prints the runtime check and runs no workload' (($r.Code -eq 0) -and ($r.Output -like '*Preflight only*') -and ($r.Output -notlike '*RESULT_DIR*'))
  # success
  $r = Invoke-SysBenchmarkProcess (& $call '01:00.0' 'before')
  ExpectTrue 'a run on the chosen bus succeeds' (($r.Code -eq 0) -and ($r.Output -match '(?m)^RESULT_DIR='))
  $dir = ([regex]::Match($r.Output, '(?m)^RESULT_DIR=(.+)$')).Groups[1].Value.Trim()
  $s = Get-Content (Join-Path $dir 'summary.json') -Raw | ConvertFrom-Json
  Expect 'summary: card name from the benchmark, not assumed' $s.Gpu 'NVIDIA GeForce RTX 3060'
  Expect 'summary: bus' $s.Bus '01:00.0'
  Expect 'summary: FP16 median in TFLOPS' ([double]($s.Benchmarks | Where-Object Name -eq 'fp16_tensor_fp32_accumulate').MedianTflops) 26.5
  Expect 'summary: highest power seen on that card only' ([double]$s.MaxPowerWatts) 148.5
  Expect 'summary: highest temperature on that card only' ([double]$s.MaxTempC) 61
  Expect 'summary: driver' $s.DriverVersion '617.42'
  Expect 'three trial files were kept' @(Get-ChildItem $dir -Filter 'trial-?.json').Count 3
  ExpectTrue 'the result folder carries the label' ((Split-Path -Leaf $dir) -like 'before-*')
  $rec = ConvertTo-BenchmarkRecord $s
  Expect 'record conversion' $rec.Bf16 26.4
  # the other card is never used
  $r = Invoke-SysBenchmarkProcess (& $call '02:00.0' 'x')
  ExpectTrue 'a bus the benchmark program does not offer fails' ($r.Code -ne 0)
  $r = Invoke-SysBenchmarkProcess (& $call '05:00.0' 'x')
  ExpectTrue 'a bus with no card is reported' (($r.Code -ne 0) -and ($r.Output -like '*No NVIDIA card at bus 05:00.0*'))
  # busy card: names the programs using THAT card (file name only), stops
  $env:FAKE_BUSY = '1'
  $r = Invoke-SysBenchmarkProcess (& $call '01:00.0' 'busy')
  Remove-Item Env:FAKE_BUSY
  ExpectTrue 'a busy card is refused' (($r.Code -ne 0) -and ($r.Output -like '*is busy*88%*'))
  ExpectTrue 'it names the program using the card by file name, without its path' (($r.Output -like '*game.exe*') -and ($r.Output -notlike '*someone*') -and ($r.Output -notlike '*x.exe*'))
  ExpectTrue 'it says nothing was stopped' ($r.Output -like '*Nothing was stopped*')
  $env:FAKE_HOT = '1'
  $r = Invoke-SysBenchmarkProcess (& $call '01:00.0' 'hot')
  Remove-Item Env:FAKE_HOT
  ExpectTrue 'a hot card is refused' (($r.Code -ne 0) -and ($r.Output -like '*still hot*'))
  # a tampered benchmark program is refused
  Add-Content $exe 'tampered'
  $r = Invoke-SysBenchmarkProcess (& $call '01:00.0' 'tamper')
  ExpectTrue 'a changed benchmark program is refused' (($r.Code -ne 0) -and ($r.Output -like '*Artifact changed*'))
  # bad bus strings never reach the card
  $r = Invoke-SysBenchmarkProcess (New-ScriptCall $script ([ordered]@{ Bus = '1:0'; Root = $root }))
  ExpectTrue 'a malformed bus address is rejected' ($r.Code -ne 0)
  # through the installer wrapper: the record the installer stores
  $state = [ordered]@{ Cards = [ordered]@{ Target = [ordered]@{ Bus = '01:00.0' } } }
  Set-InstallerRoot (Join-Path $t 'inst2')
  Set-RepoRoot $repo
  function Get-BenchmarkRoot { $root }
  Remove-Item $exe -Force
  Add-Type -TypeDefinition $benchSrc.Replace('class P', 'class P2') -OutputAssembly $exe -OutputType ConsoleApplication
  @([ordered]@{ Path = $exe; Bytes = (Get-Item $exe).Length; SHA256 = (Get-FileHash $exe -Algorithm SHA256).Hash }) | ConvertTo-Json | Set-Content (Join-Path $root 'build-manifest.json')
  $rec = Invoke-BenchmarkRun $state 'after'
  Expect 'installer wrapper: label' $rec.Label 'after'
  Expect 'installer wrapper: FP32' $rec.Fp32 8.2
 } finally { $env:PATH = $savedPath; Remove-Item Env:FAKE_BUSY, Env:FAKE_HOT -ErrorAction SilentlyContinue }
} finally { Remove-TestRoot $t }

Complete-Tests
