# The installer's phase loop (plan requirement 8: one command, resumable). Each phase is a function
# Invoke-Phase-<name> ($State, $Opt) that returns @{ Next = '<phase>' } to go on, or @{ Stop = '<reason>'; Resume = '<phase>' }
# to stop (Resume names the phase the next run starts with; default is the phase that stopped), leaving the state saved so the
# same command carries on later. -DryRun prints what would happen and saves nothing.
# Later stages add phases to $script:PhaseOrder.

$script:PhaseOrder = @('checks', 'cards', 'tools', 'partition', 'plan', 'backup', 'make-partition',
 'diag-build', 'diag-stage', 'diag-entry', 'diag-queue', 'diag-collect', 'profile', 'firmware', 'build', 'hosttests',
 'benchmark-offer', 'benchmark-prepare', 'benchmark-before', 'stage', 'unlock-queue', 'unlock-collect', 'benchmark-after', 'verdict', 'schedule',
 'extra1-offer', 'extra1-stage', 'extra1-queue', 'extra1-collect', 'extra1-shortcut', 'extra2-offer', 'extra2-build', 'extra2-stage', 'extra2-queue', 'extra2-collect',
 'update-stage', 'update-queue', 'update-collect')

function Show-CheckResults($Results) {
 $color = @{ Pass = 'Green'; Fail = 'Red'; Info = 'Yellow'; Unknown = 'Yellow' }
 foreach ($r in $Results) {
  Write-Host ('[{0,-7}] {1}  {2}' -f $r.Status.ToUpper(), $r.Id, $r.Name) -ForegroundColor $color[$r.Status]
  foreach ($line in ($r.Detail -split "`n")) { Write-Host ('           ' + $line) }
  if ($r.Status -in 'Fail', 'Unknown' -and $r.Fix) { Write-Host ('           What to do: ' + $r.Fix) -ForegroundColor Yellow }
 }
}

function Save-CheckReport($Results, [string]$Folder, [string]$Prefix = 'checks') {
 # Report for a public issue: no user name, serials, MAC addresses or profile paths are collected.
 New-Item -ItemType Directory -Path $Folder -Force | Out-Null
 $file = Join-Path $Folder ('{0}-{1}.txt' -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'))
 $lines = @('Windows GPU UNLOCK installer report', ('Date: {0:s}' -f (Get-Date)), '')
 foreach ($r in $Results) { $lines += ('[{0}] {1} {2}' -f $r.Status.ToUpper(), $r.Id, $r.Name); $lines += ($r.Detail -split "`n" | ForEach-Object { '    ' + $_ }); if ($r.Fix) { $lines += '    What to do: ' + $r.Fix } }
 $lines | Set-Content -LiteralPath $file -Encoding utf8
 $file
}

function Save-RefusalReport($Findings, $State, [string]$Folder) {
 New-Item -ItemType Directory -Path $Folder -Force | Out-Null
 $file = Join-Path $Folder ('profile-refused-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
 $lines = @('Windows GPU UNLOCK installer: no profile could be made', ('Date: {0:s}' -f (Get-Date)),
  ('Card: {0} [{1}] subsystem {2}' -f $State.Cards.Target.Name, $State.Cards.Target.Id, $State.Cards.Target.Subsystem),
  ('Screen adapter: {0} [{1}]' -f $State.Cards.Console.Name, $State.Cards.Console.Id), '')
 foreach ($f in $Findings) { $lines += ('- [{0}] {1}' -f $f.code, $f.message); if ($f.fix) { $lines += ('    What to do: ' + $f.fix) } }
 $lines | Set-Content -LiteralPath $file -Encoding utf8
 $file
}

function Invoke-Phase-checks($State, $Opt) {
 Write-Plain 'Checking your PC (read-only)...'
 Write-Plain ''
 $results = @(Invoke-AllChecks)
 Show-CheckResults $results
 $fails = @($results | Where-Object Status -eq 'Fail')
 $unknown = @($results | Where-Object Status -eq 'Unknown')
 Write-Plain ''
 if ($fails.Count) {
  Write-Host ('{0} check(s) failed. The installer cannot go on until they pass. There is no way to skip a check.' -f $fails.Count) -ForegroundColor Red
  $f = Save-CheckReport $results $Opt.ReportFolder
  Write-Plain ('Report saved: {0} (safe to post in a public issue).' -f (Split-Path -Leaf $f))
  return @{ Stop = 'checks failed' }
 }
 if ($unknown.Count) {
  Write-Host ('{0} check(s) could not be read. Look at them by hand before going on.' -f $unknown.Count) -ForegroundColor Yellow
  if (-not (Ask-YesNo 'Have you looked at them and want to go on?')) { return @{ Stop = 'unreadable checks' } }
 } else { Write-Host 'All checks passed.' -ForegroundColor Green }
 $State.ChecksPassed = (Get-Date).ToString('o')
 @{ Next = 'cards' }
}

function Invoke-Phase-cards($State, $Opt) {
 $sel = Select-Cards
 if (-not $sel) { return @{ Stop = 'no card chosen' } }
 $State.Cards = $sel
 @{ Next = 'tools' }
}

function Invoke-Phase-tools($State, $Opt) {
 Write-Plain ''
 Write-Plain 'Build tools (the boot programs are built on your own PC):'
 if (-not (Resolve-Tools -DryRun:$Opt.DryRun)) { return @{ Stop = 'build tools missing' } }
 @{ Next = 'partition' }
}

function Invoke-Phase-partition($State, $Opt) {
 $layout = Get-SysDiskLayout
 $d = Select-BootPartition $layout
 if (-not $d) { return @{ Stop = 'no boot partition chosen' } }
 $State.BootPartition = $d
 @{ Next = 'plan' }
}

function Invoke-Phase-plan($State, $Opt) {
 $items = Get-FullPlan $State
 if (-not (Confirm-Plan $items)) { Write-Plain 'Nothing was changed.'; return @{ Stop = 'plan declined' } }
 $State.PlanConfirmed = (Get-Date).ToString('o')
 @{ Next = 'backup' }
}

function Invoke-Phase-backup($State, $Opt) {
 $State.BackupFolder = Backup-SystemState -DryRun:$Opt.DryRun
 @{ Next = 'make-partition' }
}

function Invoke-Phase-make-partition($State, $Opt) {
 $State.BootPartition = New-BootPartition $State.BootPartition -DryRun:$Opt.DryRun
 Write-Plain 'The boot partition is ready.'
 @{ Next = 'diag-build' }
}

function Invoke-Phase-diag-build($State, $Opt) {
 Write-Plain 'Building the read-only diagnostic for your card...'
 [void](New-PlatformConfig $State -DryRun:$Opt.DryRun)
 $built = Build-Diagnostic $State (Get-ToolStatus) -DryRun:$Opt.DryRun
 $State.Diagnostic = [ordered]@{ Path = $built.Path; Sha256 = $built.Sha256 }
 @{ Next = 'diag-stage' }
}

function Invoke-Phase-diag-stage($State, $Opt) {
 Stage-Diagnostic $State $State.Diagnostic -DryRun:$Opt.DryRun
 @{ Next = 'diag-entry' }
}

function Invoke-Phase-diag-entry($State, $Opt) {
 $hits = Find-UnlockEntries
 if ($hits.Count -eq 1) { return @{ Next = 'diag-queue' } }
 if ($hits.Count -gt 1) { return @{ Stop = ('the firmware lists {0} boot entries for the boot partition' -f $hits.Count) } }
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: the firmware has no boot entry for the new partition yet; the real run restarts once so it can create one.'; return @{ Next = 'diag-queue' } }
 $tries = [int]$State.EntryRestarts
 if ($tries -ge 1) {
  Write-Plain 'The firmware did not create a boot entry for the new partition, even after a restart.'
  Write-Plain 'Without it the one-time boot cannot be queued from Windows, and this installer never asks you to use the BIOS or a boot menu.'
  Write-Plain 'Nothing else was changed. Roll back removes the files the installer put on the partition.'
  return @{ Stop = 'no firmware boot entry' }
 }
 $State.EntryRestarts = $tries + 1
 Save-InstallerState $State
 Write-Plain 'The firmware makes a boot entry for the new partition by itself at the next start. One restart is needed first.'
 [void](Request-RestartWithResume $State 'Windows GPU Unlock installer: the firmware needs to notice the new boot partition.' (Get-InstallerScriptPath))
 @{ Stop = 'restart needed so the firmware notices the new boot partition' }
}

function Invoke-Phase-diag-queue($State, $Opt) {
 Clear-OldCaptureOutput $State -DryRun:$Opt.DryRun
 if (-not $Opt.DryRun) { $State.DiagFilesBefore = @(Get-DiagFileNames $State) }
 $id = Queue-OneTimeBoot -DryRun:$Opt.DryRun
 if (-not $id -and -not $Opt.DryRun) { return @{ Stop = 'no firmware boot entry'; Resume = 'diag-entry' } }
 $State.CaptureQueuedAt = (Get-Date).ToString('o')
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: the real run restarts here; the diagnostic reads your PC and returns to Windows by itself.'; return @{ Next = 'diag-collect' } }
 Save-InstallerState $State
 Write-Plain ''
 Write-Plain 'The diagnostic runs once at the next start: it reads your PC (it cannot change it) and then Windows starts by itself.'
 Write-Plain 'If the screen freezes: hold the power button until the PC turns off, then power on. Windows then starts normally.'
 [void](Request-RestartWithResume $State 'Windows GPU Unlock installer: running the read-only diagnostic.' (Get-InstallerScriptPath))
 @{ Stop = 'restart to run the diagnostic'; Resume = 'diag-collect' }
}

function Invoke-Phase-diag-collect($State, $Opt) {
 if ($Opt.DryRun) {
  if ($Opt.CaptureFolder) { $State.CaptureDir = $Opt.CaptureFolder; Write-Plain "DRY RUN: using the saved capture $($Opt.CaptureFolder)"; return @{ Next = 'profile' } }
  Write-Plain 'DRY RUN ends here: the real run restarts the PC, then collects the diagnostic''s log. (Use -CaptureFolder to rehearse the rest.)'
  return @{ Stop = 'dry run: waiting for the diagnostic' ; Resume = 'diag-collect' }
 }
 # Check for the diagnostic's own new log before Test-QueuedBoot: that check only sees whether
 # *some* one-time boot is currently queued, firmware-wide, with no way to tell whose. Every-boot
 # mode's own startup task queues and consumes that same single slot independently (found
 # 2026-10-28: it can re-arm a real unlock boot after this diagnostic already ran, making this
 # otherwise-finished diagnostic look perpetually still-queued). A new log already means it ran,
 # regardless of what else is queued now for an unrelated reason.
 $since = [datetime]::Parse($State.CaptureQueuedAt)
 $found = Get-LatestCapture $State $(if ($State.Contains('DiagFilesBefore')) { $State.DiagFilesBefore } else { $null }) $since
 if (-not $found) {
  if (Test-QueuedBoot) { Write-Plain 'The diagnostic has not run yet: its boot is still queued. Restart, then run this same command again.'; return @{ Stop = 'restart needed to run the diagnostic' } }
  Write-Plain 'The diagnostic left no new log. Possible reasons: the restart did not happen, Secure Boot is on, or the firmware did not start the boot partition.'
  if (Ask-YesNo 'Queue the diagnostic again?') { return @{ Next = 'diag-queue' } }
  return @{ Stop = 'the diagnostic left no log' }
 }
 $State.CaptureDir = Copy-CaptureLocal $found (Get-Date -Format 'yyyyMMdd-HHmmss')
 Write-Plain 'The capture was collected.'
 @{ Next = 'profile' }
}

function Invoke-Phase-profile($State, $Opt) {
 $res = New-Profile $State (Get-ToolStatus) $State.CaptureDir -DryRun:$Opt.DryRun
 if (-not $res.Ok) {
  Show-Refusal $res.Findings
  $f = Save-RefusalReport $res.Findings $State $Opt.ReportFolder
  Write-Plain ('Report saved: {0} (safe to post in a public issue).' -f (Split-Path -Leaf $f))
  if ($res.Findings | Where-Object { $_.fix -match 'capture' }) {
   if (Ask-YesNo 'Run the capture again now?') { $State.EntryRestarts = 0; return @{ Next = 'diag-queue' } }
  }
  return @{ Stop = 'no safe profile for this PC' }
 }
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: the profile would be shown here for your approval.'; return @{ Next = 'firmware' } }
 Show-ProfileSummary $res.Summary
 if (-not (Ask-YesNo 'Is this your PC, and do you want to use this profile?')) { return @{ Stop = 'profile not accepted' } }
 $State.Profile = [ordered]@{ Dir = $res.Dir; Summary = $res.Summary }
 $State.Environment = Get-EnvironmentRecord   # the profile is tied to this BIOS version and board
 @{ Next = 'firmware' }
}

function Invoke-Phase-firmware($State, $Opt) {
 $dir = Resolve-Assets $State (Get-ToolStatus) -DryRun:$Opt.DryRun
 if (-not $dir) { return @{ Stop = 'the NVIDIA firmware files are not available' } }
 $State.Assets = $dir
 @{ Next = 'build' }
}

function Invoke-Phase-build($State, $Opt) {
 Write-Plain 'Building the boot programs for your PC (this takes a minute)...'
 [void](New-PlatformConfig $State -DryRun:$Opt.DryRun)
 $files = Build-BootPrograms $State (Get-ToolStatus) $State.Profile.Dir -DryRun:$Opt.DryRun
 $State.Build = [ordered]@{ Files = @($files | ForEach-Object { [ordered]@{ Role = $_.Role; Path = $_.Path; Sha256 = $_.Sha256 } }); Built = (Get-Date).ToString('o'); SourceFingerprint = $(if ($Opt.DryRun) { '' } else { Get-BootSourceFingerprint }) }
 foreach ($f in $files) { Write-Plain ('  {0}: {1}' -f $f.Role, $f.Sha256.Substring(0, 12)) }
 @{ Next = 'hosttests' }
}

function Invoke-Phase-hosttests($State, $Opt) {
 Write-Plain 'Testing the boot programs on your own capture (no hardware is touched; this takes a few minutes)...'
 $out = Invoke-HostTests $State (Get-ToolStatus) $State.Assets -DryRun:$Opt.DryRun
 Show-HostTestResults $out
 if (-not $out.Ok) {
  $failed = @($out.Results | Where-Object { -not $_.Passed })
  $f = Save-CheckReport @($failed | ForEach-Object { [pscustomobject]@{ Id = 'TEST'; Name = $_.Name; Status = 'Fail'; Detail = $_.Detail; Fix = 'Post this report in a public issue; do not continue.' } }) $Opt.ReportFolder 'host-tests'
  Write-Plain ''
  Write-Plain 'A host test failed on your capture, so the installer will not put these boot programs on your PC. There is no way to skip a test.'
  Write-Plain ('Report saved: {0} (safe to post in a public issue).' -f (Split-Path -Leaf $f))
  return @{ Stop = 'a host test failed' }
 }
 $State.TestsPassed = (Get-Date).ToString('o')
 if ($State.Contains('Update') -and $State.Update) { return @{ Next = 'update-stage' } }   # an update of an installed setup: no benchmark, no first-time questions
 @{ Next = 'benchmark-offer' }
}

function Invoke-Phase-benchmark-offer($State, $Opt) {
 if (-not $State.Contains('TestsPassed') -and -not $Opt.DryRun) { return @{ Stop = 'the boot programs have not passed the host tests'; Resume = 'hosttests' } }
 $run = Ask-Benchmark
 $State.Benchmark = [ordered]@{ Enabled = $run; Skipped = (-not $run); Offered = (Get-Date).ToString('o') }
 @{ Next = $(if ($run) { 'benchmark-prepare' } else { 'stage' }) }
}

function Invoke-Phase-benchmark-prepare($State, $Opt) {
 Write-Plain 'Preparing the benchmark (download, check and build)...'
 Initialize-Benchmark $State (Get-ToolStatus) -DryRun:$Opt.DryRun
 @{ Next = 'benchmark-before' }
}

# Runs one measurement; on a busy or hot card shows the reason and offers to try again. Returns the record, or $null (and a result to return).
function Invoke-MeasurementPhase($State, $Opt, [string]$Label, [string]$PhaseName) {
 try { $rec = Invoke-BenchmarkRun $State $Label -DryRun:$Opt.DryRun }
 catch {
  Write-Plain ''
  Write-Plain $_.Exception.Message
  if (Ask-YesNo 'Try the measurement again?') { return @{ Result = @{ Next = $PhaseName } } }
  return @{ Result = @{ Stop = 'the benchmark could not run' } }
 }
 @{ Record = $rec }
}

function Invoke-Phase-benchmark-before($State, $Opt) {
 Write-Plain 'Measuring your card before the unlock (about a minute of full load)...'
 $m = Invoke-MeasurementPhase $State $Opt 'before' 'benchmark-before'
 if ($m.Result) { return $m.Result }
 $rec = $m.Record
 if ($rec) {
  if (Test-LooksUnlocked $rec) {
   Write-Plain ('The numbers look like an already unlocked card (FP16 is {0:N1} times FP32; a locked card is near 3). A fair "before" needs a full power-off first (Shut down, not Restart, with Fast Startup off).' -f (Get-TensorRatio $rec))
   if (-not (Ask-YesNo 'Use this measurement anyway? (the final comparison will then not be reliable)')) { return @{ Stop = 'the card already looks unlocked; power off completely, then run the installer again' } }
   $State.Benchmark.BaselineUnlocked = $true
  }
  $State.Benchmark.Before = $rec
  Write-Plain ('Before: FP16 {0:N2}, BF16 {1:N2}, FP32 {2:N2} TFLOPS.' -f $rec.Fp16, $rec.Bf16, $rec.Fp32)
 }
 @{ Next = 'stage' }
}

function Invoke-Phase-stage($State, $Opt) {
 if (-not $State.Contains('TestsPassed') -and -not $Opt.DryRun) { return @{ Stop = 'the boot programs have not passed the host tests'; Resume = 'hosttests' } }
 Write-Plain 'Putting the tested boot programs on the boot partition (replaced files are saved first)...'
 Stage-ManualProgram $State -DryRun:$Opt.DryRun
 if (-not $Opt.DryRun) {
  $bad = @(Test-StagedFiles $State)
  if ($bad.Count) { Write-Plain 'After copying, the boot partition does not match the tested build:'; $bad | ForEach-Object { Write-Plain ('  - ' + $_) }; return @{ Stop = 'the staged files do not match the tested build' } }
  Write-Plain 'Every staged file was read back and matches the tested build.'
 }
 @{ Next = 'unlock-queue' }
}

function Invoke-Phase-unlock-queue($State, $Opt) {
 if (-not $Opt.DryRun) { $State.RunFoldersBefore = @(Get-RunFolderNames $State) }
 $id = Queue-OneTimeBoot -DryRun:$Opt.DryRun
 if (-not $id -and -not $Opt.DryRun) {
  Write-Plain 'The firmware has no boot entry for the boot partition, so the one-time boot cannot be queued. Nothing else was changed.'
  return @{ Stop = 'no firmware boot entry' }
 }
 $State.UnlockQueuedAt = (Get-Date).ToString('o')
 Show-UnlockInstructions
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: the real run restarts here.'; return @{ Next = 'unlock-collect' } }
 Save-InstallerState $State
 [void](Request-RestartWithResume $State 'Windows GPU Unlock installer: running the first unlock.' (Get-InstallerScriptPath))
 @{ Stop = 'restart to run the first unlock'; Resume = 'unlock-collect' }
}

function Invoke-Phase-unlock-collect($State, $Opt) {
 $next = if ($State.Benchmark -and $State.Benchmark.Enabled) { 'benchmark-after' } else { 'verdict' }
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: the real run reads the unlock program''s report here.'; return @{ Next = $next } }
 # See the matching comment in Invoke-Phase-diag-collect: check for the actual new report before
 # Test-QueuedBoot, which cannot tell this boot's queue apart from an unrelated one (such as
 # every-boot mode's own startup task re-arming a boot for an entirely different reason).
 $path = Get-LatestRunReport $State $(if ($State.Contains('RunFoldersBefore')) { $State.RunFoldersBefore } else { $null }) ([datetime]::Parse($State.UnlockQueuedAt))
 if (-not $path) {
  if (Test-QueuedBoot) { Write-Plain 'The unlock has not run yet: its boot is still queued. Restart, then run this same command again.'; return @{ Stop = 'restart needed to run the first unlock' } }
  Write-Plain 'The unlock program left no new report. Possible reasons: the restart did not happen, or the firmware did not start the boot partition.'
  if (Ask-YesNo 'Queue the unlock again?') { return @{ Next = 'unlock-queue' } }
  return @{ Stop = 'the unlock program left no report' }
 }
 $rr = Read-RunReport $path
 switch ($rr.Class) {
  'Applied' {
   $State.Unlock = [ordered]@{ Applied = $true; Selectors = $rr.Selectors; Final = $rr.Final; At = (Get-Date).ToString('o') }
   Write-Plain 'The unlock ran cleanly and Windows started.'
   return @{ Next = $next }
  }
  'NotApplied' {
   Write-Plain 'No unlock was applied: it was cancelled or the 30 seconds ran out before U was pressed. Windows started normally and nothing was changed.'
   if (Ask-YesNo 'Try again?') { return @{ Next = 'unlock-queue' } }
   return @{ Stop = 'the unlock was not applied' }
  }
  'Failed' {
   Write-Plain ('The unlock program stopped on a safety check or an error: ' + $rr.Final)
   Write-Plain 'The card keeps its normal speed, nothing permanent was changed, and Windows started. There is no way to skip the check.'
   $f = Save-CheckReport @([pscustomobject]@{ Id = 'RUN'; Name = 'first unlock run'; Status = 'Fail'; Detail = $rr.Final; Fix = 'Post this report in a public issue.' }) $Opt.ReportFolder 'unlock-failed'
   Write-Plain ('Report saved: {0} (safe to post in a public issue).' -f (Split-Path -Leaf $f))
   return @{ Stop = 'the unlock program stopped on a check' }
  }
  default {
   Write-Plain ('The unlock program''s report could not be read: ' + $rr.Detail)
   if (Ask-YesNo 'Queue the unlock again?') { return @{ Next = 'unlock-queue' } }
   return @{ Stop = 'the unlock report is unreadable' }
  }
 }
}

function Invoke-Phase-benchmark-after($State, $Opt) {
 Write-Plain 'Measuring your card after the unlock (about a minute of full load)...'
 $m = Invoke-MeasurementPhase $State $Opt 'after' 'benchmark-after'
 if ($m.Result) { return $m.Result }
 $rec = $m.Record
 if ($rec) {
  if (-not (Test-LooksUnlocked $rec) -and -not $State.Benchmark.BaselineUnlocked) {
   Write-Plain ('The card does not look unlocked right now (FP16 is {0:N1} times FP32). The unlock lasts only until power-off or sleep: was the PC shut down since the unlock?' -f (Get-TensorRatio $rec))
   Write-Plain 'A comparison made now would be wrong, so none is made.'
   if (Ask-YesNo 'Queue the unlock again and measure right after the restart?') { return @{ Next = 'unlock-queue' } }
   return @{ Stop = 'the card does not look unlocked, so there is nothing to compare' }
  }
  $State.Benchmark.After = $rec
 }
 @{ Next = 'verdict' }
}

function Invoke-Phase-verdict($State, $Opt) {
 $b = $State.Benchmark
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: the comparison and verdict would be shown here.'; return @{ Next = 'schedule' } }
 if (-not $b -or $b.Skipped -or -not $b.Before -or -not $b.After) {
  Write-Plain ''
  Write-Plain 'Improvement not measured: the benchmark was skipped, so the installer cannot say whether the unlock helped. Roll back is available if you want to undo everything.'
  if ($b -and $b.Skipped -and (Ask-Benchmark)) {
   Initialize-Benchmark $State (Get-ToolStatus)
   $m = Invoke-MeasurementPhase $State $Opt 'now' 'verdict'
   if ($m.Result) { return $m.Result }
   $r = $m.Record
   Write-Plain ('Right now: FP16 {0:N2}, BF16 {1:N2}, FP32 {2:N2} TFLOPS. Without a measurement from before the unlock there is no comparison and no verdict; FP16 is {3:N1} times FP32 (near 3 means locked, near 6 unlocked).' -f $r.Fp16, $r.Bf16, $r.Fp32, (Get-TensorRatio $r))
  }
  return @{ Next = 'schedule' }
 }
 if ($b.BaselineUnlocked) {
  Write-Plain 'The "before" measurement looked like an already unlocked card, so no reliable comparison is possible and no verdict is given.'
  return @{ Next = 'schedule' }
 }
 $v = Get-Verdict $b.Before $b.After
 Show-Verdict $b.Before $b.After $v
 $f = Save-BenchmarkReport $b.Before $b.After $v $Opt.ReportFolder
 Write-Plain ('Report saved: {0} (numbers only; nothing is uploaded).' -f (Split-Path -Leaf $f))
 $State.Benchmark.Verdict = $v.Text
 if ($v.Level -eq 'none') {
  Write-Plain ''
  Write-Plain 'The unlock did not make this card meaningfully faster, so keeping it installed has no benefit. Rolling back is recommended.'
  if (Get-Command Invoke-Rollback -ErrorAction SilentlyContinue) {
   if (Ask-YesNo 'Roll back now?') { return @{ Next = 'rollback' } }
  } else { Write-Plain 'Run the installer with -Rollback to undo everything it did.' }
 }
 @{ Next = 'schedule' }
}

function Invoke-Phase-schedule($State, $Opt) {
 Write-Plain ''
 Write-Plain 'After today:'
 Write-Plain '  The unlock lasts until the PC is powered off or goes to sleep.'
 Write-Plain '  To apply it again, use the shortcut "Unlock my GPU on next boot": it asks Windows for administrator approval, queues one unlock and offers the restart.'
 $mode = if ($State.Contains('Automatic') -and $State.Automatic -and $State.Automatic.Active) { 'automatic' } else { 'manual' }
 if (Ask-YesNo 'Create the shortcut "Unlock my GPU on next boot" in the Start menu (all users; only administrators can change it)?') {
  Write-Plain '  A copy on the desktop is easier to find, but any program running as you can edit a desktop shortcut, and an approved click would then run what it was changed to as administrator.'
  $wantDesktopCopy = Ask-YesNo 'Also put a copy on the desktop?'
  try {
   $r = New-UnlockShortcut $State $mode -Desktop:$wantDesktopCopy -DryRun:$Opt.DryRun
   $State.Shortcut = [ordered]@{ Script = $r.Script; Links = @($r.Links); Mode = $mode }
   if (-not $Opt.DryRun) { Write-Plain ('The shortcut is in the Start menu: search for "' + 'Unlock my GPU on next boot' + '".') }
  } catch {
   Write-Plain ('The shortcut was not made: ' + $_.Exception.Message)
   Write-Plain '  This is optional and does not affect the unlock itself. Continuing without it; to unlock again after a power-off, run this installer again.'
  }
 } else {
  Write-Plain 'No shortcut was made. To unlock again after a power-off, run this installer again.'
 }
 @{ Next = 'extra1-offer' }
}

function Get-InstallerScriptPath { Join-Path (Get-RepoRoot) 'Install-GpuUnlock.ps1' }

function Invoke-Phase-rollback($State, $Opt) {
 $r = Invoke-Rollback -DryRun:$Opt.DryRun
 if ($r.Cancelled) { return @{ Stop = 'roll back cancelled' ; Resume = $State.Phase } }
 @{ RolledBack = $true }
}

function Invoke-Installer {
 param([switch]$DryRun, [string]$ReportFolder, [string]$CaptureFolder, [switch]$Rollback)
 $opt = @{ DryRun = [bool]$DryRun; ReportFolder = $ReportFolder; CaptureFolder = $CaptureFolder }
 Set-ReadOnlyMode ([bool]$DryRun)   # a dry run only reports an unsafe data folder; it never changes permissions
 if ($CaptureFolder -and -not $DryRun) { throw '-CaptureFolder is only for a dry run; a real run always makes a fresh capture.' }
 $state = Read-InstallerState
 $phase = if ($Rollback) { 'rollback' } elseif ($state.Phase -eq 'new') { $script:PhaseOrder[0] } else { $state.Phase }
 if ($DryRun) { Write-Plain 'DRY RUN: nothing will be changed and nothing is saved.' }
 $script:RestartStarted = $false
 # A resume entry that is still there when a run starts is a leftover (the resumed run removes its own entry first): report and remove it.
 if (Test-ResumeEntry) {
  Write-Plain 'A leftover automatic-resume entry from an earlier run was found.'
  if ($DryRun) { Write-Plain 'DRY RUN: it would be removed.' } else { Remove-ResumeEntry; Write-Plain 'It was removed, so nothing relaunches by itself at the next login.' }
 }
 try {
 while ($phase -ne 'done') {
  if ($phase -ne 'checks' -and $phase -ne 'cards' -and $phase -ne 'rollback' -and $state.Contains('Cards')) {
   $c = Test-CardsUnchanged $state.Cards
   if (-not $c.Ok) { Write-Plain $c.Detail; $state.Phase = 'cards'; if (-not $DryRun) { Save-InstallerState $state }; $phase = 'cards'; continue }
  }
  if ($phase -ne 'checks' -and $phase -ne 'cards' -and $phase -ne 'rollback' -and $state.Contains('Environment')) {
   $envChange = Invoke-EnvironmentChange $state $opt
   if ($envChange) {
    if ($envChange.Stop) { $state.Phase = $(if ($envChange.Resume) { $envChange.Resume } else { $phase }); if (-not $DryRun) { Save-InstallerState $state }; return [pscustomobject]@{ Done = $false; Reason = $envChange.Stop; Phase = $state.Phase } }
    $phase = $envChange.Next; $state.Phase = $phase; if (-not $DryRun) { Save-InstallerState $state }; continue
   }
  }
  if (Get-Command Set-UiPhase -ErrorAction SilentlyContinue) { Set-UiPhase $phase }   # the graphical window shows the step; the console has no such function
  $handler = "Invoke-Phase-$phase"
  if (-not (Get-Command $handler -ErrorAction SilentlyContinue)) { throw "Unknown installer phase '$phase'." }
  $r = & $handler $state $opt
  if ($r.RolledBack) { return [pscustomobject]@{ Done = $true; Reason = ''; Phase = 'rolled back'; RolledBack = $true } }
  if ($r.Stop) {
   $state.Phase = $(if ($r.Resume) { $r.Resume } else { $phase })
   if (-not $DryRun) { Save-InstallerState $state }
   return [pscustomobject]@{ Done = $false; Reason = $r.Stop; Phase = $state.Phase }
  }
  $phase = $r.Next
  $state.Phase = $phase
  if (-not $DryRun) { Save-InstallerState $state }
 }
 [pscustomobject]@{ Done = $true; Reason = ''; Phase = 'done' }
 } finally {
  # no restart was started in this run: nothing may relaunch the installer at the next login
  if (-not $DryRun -and -not $script:RestartStarted) { Remove-ResumeEntry }
 }
}
