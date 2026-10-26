# The benchmark phases (offer, preparation, before, after) and the closing verdict screen, including every awkward case:
# busy card, already-unlocked baseline, unlock lost before the second measurement, skipped benchmark, no improvement.
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')

function Rec($Fp32, $Fp16, $Bf16, $W = 120, $C = 62) { [ordered]@{ Label = ''; Gpu = 'NVIDIA GeForce RTX 3060'; Bus = '01:00.0'; Driver = '617.42'; Fp32 = $Fp32; Fp16 = $Fp16; Bf16 = $Bf16; MaxPowerWatts = $W; MaxTempC = $C; MaxSmClockMhz = 1900 } }
$locked = Rec 8.20 26.51 26.40; $unlocked = Rec 8.18 48.13 50.34
$script:Next = New-Object System.Collections.Queue; $script:RunLabels = New-Object System.Collections.ArrayList; $script:Prepared = 0
function Invoke-BenchmarkRun($State, [string]$Label, [switch]$DryRun) {
 [void]$script:RunLabels.Add($Label)
 $n = $script:Next.Dequeue()
 if ($n -is [string]) { throw $n }
 $n.Label = $Label; $n
}
function Initialize-Benchmark($State, $Tools, [switch]$DryRun) { $script:Prepared++ }
function Get-ToolStatus { @() }
$t = New-TestRoot
try {
 $opt = @{ DryRun = $false; ReportFolder = (Join-Path $t 'reports'); CaptureFolder = $null }
 function NewState { [ordered]@{ TestsPassed = 'x'; Cards = [ordered]@{ Target = [ordered]@{ Bus = '01:00.0' } }; Benchmark = [ordered]@{ Enabled = $true } } }

 # ---- offer ----
 $s = NewState; $s.Remove('Benchmark')
 Set-Answers @('Y'); Expect 'Y: prepare the benchmark' (Invoke-Phase-benchmark-offer $s $opt).Next 'benchmark-prepare'
 ExpectTrue 'Y: enabled' $s.Benchmark.Enabled
 Set-Answers @('N'); $r = Invoke-Phase-benchmark-offer $s $opt
 Expect 'N: go straight to staging' $r.Next 'stage'
 ExpectTrue 'N: recorded as skipped' ($s.Benchmark.Skipped -and -not $s.Benchmark.Enabled)
 Expect 'preparation moves on to the baseline' (Invoke-Phase-benchmark-prepare (NewState) $opt).Next 'benchmark-before'

 # ---- before ----
 $s = NewState
 $script:Next.Enqueue($locked); $script:RunLabels.Clear()
 Set-Answers @(); $r = Invoke-Phase-benchmark-before $s $opt
 Expect 'a locked card: baseline stored, go on to staging' $r.Next 'stage'
 Expect 'baseline value' $s.Benchmark.Before.Fp16 26.51
 Expect 'the measurement is labelled before' $script:RunLabels[0] 'before'
 ExpectTrue 'baseline is shown in words' ((OutText) -like '*Before: FP16 26.51*')
 $script:Next.Enqueue('The card at 01:00.0 is busy (GPU 80%, memory 4000 MiB). Using it now: chrome.exe.')
 Set-Answers @('Y'); $r = Invoke-Phase-benchmark-before (NewState) $opt
 Expect 'busy card, Y: measure again' $r.Next 'benchmark-before'
 ExpectTrue 'the reason names the program' ((OutText) -like '*chrome.exe*')
 $script:Next.Enqueue('The card at 01:00.0 is busy.')
 Set-Answers @('N'); Expect 'busy card, N: stop' (Invoke-Phase-benchmark-before (NewState) $opt).Stop 'the benchmark could not run'
 $script:Next.Enqueue($unlocked); $s = NewState
 Set-Answers @('N'); $r = Invoke-Phase-benchmark-before $s $opt
 ExpectTrue 'an unlocked-looking baseline stops unless the user insists' ($r.Stop -like '*power off completely*')
 ExpectTrue 'and explains the full power-off' ((OutText) -like '*Shut down, not Restart*')
 $script:Next.Enqueue($unlocked); $s = NewState
 Set-Answers @('Y'); $r = Invoke-Phase-benchmark-before $s $opt
 Expect 'insisting continues' $r.Next 'stage'
 ExpectTrue 'and flags the baseline as unreliable' $s.Benchmark.BaselineUnlocked

 # ---- after ----
 $s = NewState; $s.Benchmark.Before = $locked
 $script:Next.Enqueue($unlocked); Set-Answers @()
 $r = Invoke-Phase-benchmark-after $s $opt
 Expect 'unlocked after: go to the verdict' $r.Next 'verdict'
 Expect 'after value stored' $s.Benchmark.After.Bf16 50.34
 $script:Next.Enqueue($locked); $s = NewState; $s.Benchmark.Before = $locked
 Set-Answers @('Y'); $r = Invoke-Phase-benchmark-after $s $opt
 Expect 'still locked after: offer to queue the unlock again' $r.Next 'unlock-queue'
 ExpectTrue 'and explains that no comparison is made' (((OutText) -like '*does not look unlocked*') -and ((OutText) -like '*none is made*'))
 ExpectTrue 'nothing was stored as the after value' (-not $s.Benchmark.Contains('After'))
 $script:Next.Enqueue($locked); Set-Answers @('N')
 ExpectTrue 'still locked, N: stop' ((Invoke-Phase-benchmark-after (NewState) $opt).Stop -like '*nothing to compare*')
 $script:Next.Enqueue('The card is still hot (80 C).'); Set-Answers @('N')
 Expect 'a hot card after the unlock can be retried or stopped' (Invoke-Phase-benchmark-after (NewState) $opt).Stop 'the benchmark could not run'

 # ---- verdict ----
 function Verdict($before, $after, $answers = @()) { $s = NewState; $s.Benchmark.Before = $before; $s.Benchmark.After = $after; Set-Answers $answers; $r = Invoke-Phase-verdict $s $opt; [pscustomobject]@{ Result = $r; State = $s } }
 $v = Verdict $locked $unlocked
 Expect 'a clear improvement moves on to the schedule step' $v.Result.Next 'schedule'
 Expect 'verdict stored' $v.State.Benchmark.Verdict 'clear improvement'
 ExpectTrue 'a clear improvement does not suggest rolling back' ((OutText) -notlike '*Rolling back is recommended*')
 $v = Verdict $locked (Rec 8.2 28 26.4)
 Expect 'a small improvement is named' $v.State.Benchmark.Verdict 'small improvement'
 # no improvement: rollback is recommended and offered
 $v = Verdict $locked (Rec 8.2 26.6 26.5) @('N')
 ExpectTrue 'no improvement is said plainly' ($v.State.Benchmark.Verdict -like 'no meaningful improvement*')
 ExpectTrue 'rolling back is recommended' ((OutText) -like '*Rolling back is recommended*')
 $v = Verdict $locked (Rec 8.2 26.6 26.5) @('Y')
 Expect 'with Roll back available, Y goes there' $v.Result.Next 'rollback'
 $v = Verdict $locked (Rec 8.2 26.6 26.5) @('N')
 Expect 'N moves on without rolling back' $v.Result.Next 'schedule'
 # unreliable baseline
 $s = NewState; $s.Benchmark.Before = $unlocked; $s.Benchmark.After = $unlocked; $s.Benchmark.BaselineUnlocked = $true; Set-Answers @()
 Expect 'an unlocked baseline gives no verdict' (Invoke-Phase-verdict $s $opt).Next 'schedule'
 ExpectTrue 'and says why' ((OutText) -like '*no reliable comparison*')
 # skipped benchmark
 $s = NewState; $s.Benchmark = [ordered]@{ Enabled = $false; Skipped = $true }; Set-Answers @('N')
 Expect 'skipped, declined at the end: on to the schedule step' (Invoke-Phase-verdict $s $opt).Next 'schedule'
 ExpectTrue 'the closing screen says improvement is not measured and Roll back exists' (((OutText) -like '*Improvement not measured*') -and ((OutText) -like '*Roll back is available*'))
 ExpectTrue 'it never prints a verdict' ((OutText) -notlike '*Verdict:*')
 $script:Prepared = 0; $script:Next.Enqueue($unlocked)
 $s = NewState; $s.Benchmark = [ordered]@{ Enabled = $false; Skipped = $true }; Set-Answers @('Y')
 $r = Invoke-Phase-verdict $s $opt
 Expect 'skipped, accepted at the end: prepared and measured once' $script:Prepared 1
 ExpectTrue 'absolute numbers only, no comparison' (((OutText) -like '*Right now: FP16 48.13*') -and ((OutText) -like '*no comparison and no verdict*'))
 Expect 'then the schedule step' $r.Next 'schedule'
 # dry run
 $s = NewState; $s.Benchmark.Before = $locked; $s.Benchmark.After = $unlocked; Set-Answers @()
 Expect 'dry run: nothing is judged' (Invoke-Phase-verdict $s @{ DryRun = $true; ReportFolder = ''; CaptureFolder = $null }).Next 'schedule'
} finally { Remove-TestRoot $t }
Complete-Tests
