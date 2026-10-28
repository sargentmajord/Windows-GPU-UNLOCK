# The two optional extras, offered only at the very end (plan requirement 25). Each has its own screen with a plain description, what it
# does not change, its warnings and a disclaimer, and needs the typed words I ACCEPT; declining leaves the safe setup exactly as it is.
#  - Extra 1 removes the U key press: the unlock program runs by itself on a boot that was queued (automatic mode).
#  - Extra 2 removes the two short Esc cancel windows of automatic mode (patches/no-cancel-windows.patch). Offered only after Extra 1 works.
# Every replaced file is saved first (Copy-ToBootPartition), so the manual setup can always be put back ("Switch the extras off" in the
# start menu, or Roll back). Needs Ui.ps1, State.ps1, Capture.ps1, BootEntry.ps1, BuildTest.ps1, Unlock.ps1, Schedule.ps1, Resume.ps1.

$script:AcceptPhrase = 'I ACCEPT'

# --- system calls (replaceable in tests) ---
function Get-SysGitPath { $c = Get-Command git.exe -ErrorAction SilentlyContinue; if ($c) { [string]$c.Source } else { $null } }

# --- what goes on the boot partition ---
# Variant 'standard' = the default automatic pair (with the Esc windows); 'noesc' = the pair built with patches/no-cancel-windows.patch.
function Get-AutomaticStagePlan($State, [string]$Variant = 'standard') {
 $files = if ($Variant -eq 'noesc') { if ($State.Build.Contains('NoEsc') -and $State.Build.NoEsc) { @($State.Build.NoEsc.Files) } else { @() } } else { @($State.Build.Files) }
 $byRole = @{}; foreach ($f in $files) { $byRole[$f.Role] = $f }
 foreach ($need in 'automatic-wrapper', 'automatic-unlock') { if (-not $byRole[$need]) { throw "The build record has no $need ($Variant)." } }
 @(
  [pscustomobject]@{ Source = $byRole['automatic-unlock'].Path; Dest = 'EFI\WindowsGPUUnlock\UNLOCK-AUTO.EFI'; Sha256 = $byRole['automatic-unlock'].Sha256 }
  [pscustomobject]@{ Source = $byRole['automatic-wrapper'].Path; Dest = 'EFI\WindowsGPUUnlock\AUTO.EFI'; Sha256 = $byRole['automatic-wrapper'].Sha256 }
  [pscustomobject]@{ Source = $byRole['automatic-wrapper'].Path; Dest = 'EFI\BOOT\BOOTX64.EFI'; Sha256 = $byRole['automatic-wrapper'].Sha256 }
 )
}

function Copy-PlanToBootPartition($State, $Plan, [switch]$DryRun) {
 foreach ($p in $Plan) {
  if ($DryRun) { Write-Plain ("DRYRUN: copy {0} to the boot partition as {1}" -f (Split-Path -Leaf $p.Source), $p.Dest); continue }
  if ((Get-SysFileHash $p.Source) -ne $p.Sha256) { throw ("A file to stage changed since it was built or tested: $($p.Dest)") }
  [void](Copy-ToBootPartition $State $p.Source $p.Dest $State.BackupFolder)
 }
 if (-not $DryRun) {
  foreach ($p in $Plan) {
   $f = Join-Path (Get-BootRoot $State) $p.Dest
   if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or (Get-SysFileHash $f) -ne $p.Sha256) { throw "After copying, $($p.Dest) on the boot partition does not match the tested build." }
  }
 }
}
function Stage-AutomaticPair($State, [string]$Variant = 'standard', [switch]$DryRun) { Copy-PlanToBootPartition $State (Get-AutomaticStagePlan $State $Variant) -DryRun:$DryRun }

# Puts the manual wrapper back as the file the firmware entry starts (the manual pair itself stays on the partition).
function Restore-ManualWrapper($State, [switch]$DryRun) {
 $plan = @(Get-ManualStagePlan $State | Where-Object { $_.Dest -eq 'EFI\BOOT\BOOTX64.EFI' })
 Copy-PlanToBootPartition $State $plan -DryRun:$DryRun
}

# --- the screens ---
function Show-Extra1Screen {
 Write-Plain ''
 Write-Plain '================ Optional extra 1: no key press ================'
 Write-Plain 'What it changes: the unlock program runs by itself on a start that was queued (by the shortcut, or by the startup task if you choose it).'
 Write-Plain '  You no longer press U. At the start there is still a 5 second window, and another 3 seconds after the drivers are released, where Esc cancels.'
 Write-Plain 'What it does NOT change: every hardware check stays (card ID, subsystem, video BIOS hash, PCI layout, clean power-on state, display topology,'
 Write-Plain '  driver ownership, one attempt, stop on any failure). A mismatch stops the start before anything is written. Nothing is written to the card''s stored firmware.'
 Write-Plain 'Warnings:'
 Write-Plain '  - If a check fails, the screen stays frozen (by design; it never retries or resets). Hold the power button until the PC turns off, then power on.'
 Write-Plain '    The queued start is already used up, so Windows then starts normally. No BIOS or boot menu is needed.'
 Write-Plain '  - Do not use this on a PC you cannot reach to do that.'
 Write-Plain '  - It is verified on one reference PC only. Other hardware may behave differently.'
 Write-Plain '  - It replaces the file the firmware entry starts; the previous file is saved first. "Switch the extras off" (start menu) or Roll back puts it back.'
 Write-Plain 'Disclaimer: this is third-party experimental software, provided "as is", with no warranty of any kind, under GPL-2.0-only. You use it at your own risk.'
 Write-Plain 'The installer first runs it once and checks its report and the benchmark. If that does not work, the manual setup is put back.'
}

function Show-Extra2Screen {
 Write-Plain ''
 Write-Plain '================ Optional extra 2: no Esc countdown ================'
 Write-Plain 'What it changes: it removes the two Esc windows (5 seconds, and 3 seconds after the drivers are released) of automatic mode, so a start goes straight'
 Write-Plain '  through (about 8 seconds faster). It is a build option applied with patches/no-cancel-windows.patch.'
 Write-Plain 'What it does NOT change: every hardware check stays. The patch adds no switch that skips a check.'
 Write-Plain 'Warnings:'
 Write-Plain '  - You can no longer cancel from the keyboard during the start. The only way to abort is to power the PC off.'
 Write-Plain '  - If a check fails, the screen stays frozen. Hold the power button, then power on; Windows then starts normally.'
 Write-Plain '  - Do not use it on a PC you cannot reach, or whose only boot entry is the unlock program. Keep Windows Boot Manager first in the boot order (the installer never changes it).'
 Write-Plain '  - It needs Git for Windows (to apply the patch). The patch is applied only while building and taken off again afterwards.'
 Write-Plain '  - Verified on one reference PC only.'
 Write-Plain 'Disclaimer: experimental third-party software, provided "as is", with no warranty of any kind, under GPL-2.0-only. You use it at your own risk.'
 Write-Plain 'The installer builds it, runs the automatic-mode tests on it, then runs it once and checks its report. If that does not work, the version with the Esc windows is put back.'
}

function Ask-Extra([string]$Name) {
 Ask-Phrase ("Do you accept the warnings and the disclaimer for $Name?") $script:AcceptPhrase
}

# --- the shared queue / collect steps ---
function Get-VerdictAllowsExtras($State) {
 if (-not $State.Contains('Unlock') -or -not $State.Unlock -or -not $State.Unlock.Applied) { return $false }
 $v = if ($State.Contains('Benchmark') -and $State.Benchmark -and $State.Benchmark.Contains('Verdict')) { [string]$State.Benchmark.Verdict } else { '' }
 -not ($v -like 'no meaningful*')
}

function Invoke-ExtraQueue($State, $Opt, [string]$Reason, [string]$ResumePhase, [string]$NextOnDry, [string[]]$Lines) {
 if (-not $Opt.DryRun) { $State.RunFoldersBefore = @(Get-RunFolderNames $State) }
 $id = Queue-OneTimeBoot -DryRun:$Opt.DryRun
 if (-not $id -and -not $Opt.DryRun) { Write-Plain 'The firmware has no boot entry for the boot partition, so the one-time boot cannot be queued. Nothing else was changed.'; return @{ Stop = 'no firmware boot entry' } }
 $State.UnlockQueuedAt = (Get-Date).ToString('o')
 Write-Plain ''
 foreach ($l in $Lines) { Write-Plain $l }
 Write-Plain 'If the screen freezes: hold the power button until the PC turns off, then power on. Windows then starts normally.'
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: the real run restarts here.'; return @{ Next = $NextOnDry } }
 Save-InstallerState $State
 [void](Request-RestartWithResume $State $Reason (Get-InstallerScriptPath))
 @{ Stop = "restart: $Reason"; Resume = $ResumePhase }
}

# Returns @{ Kind = Waiting | NoReport | Report; Report = <Read-RunReport result> }
# Checks for the actual new report before Test-QueuedBoot: that only sees whether the firmware's
# single one-time-boot slot has anything queued right now, firmware-wide, with no way to tell
# whose - every-boot mode's own startup task can independently re-arm that same slot for an
# unrelated reason. A report that already exists means this run finished, no matter what else is
# queued now.
function Get-ExtraRunOutcome($State) {
 $path = Get-LatestRunReport $State $(if ($State.Contains('RunFoldersBefore')) { $State.RunFoldersBefore } else { $null }) ([datetime]::Parse($State.UnlockQueuedAt))
 if ($path) { return @{ Kind = 'Report'; Report = (Read-RunReport $path); Path = $path } }
 if (Test-QueuedBoot) { return @{ Kind = 'Waiting' } }
 @{ Kind = 'NoReport' }
}

# --- Extra 1 ---
function Invoke-Phase-extra1-offer($State, $Opt) {
 if (-not (Get-VerdictAllowsExtras $State)) {
  if ($State.Contains('Unlock') -and $State.Unlock -and $State.Unlock.Applied) { Write-Plain 'The optional extras are offered only when the benchmark showed the unlock helps. Roll back is available if you want to undo everything.' }
  return @{ Next = 'done' }
 }
 if (-not $State.Contains('TestsPassed') -and -not $Opt.DryRun) { return @{ Stop = 'the boot programs have not passed the host tests'; Resume = 'hosttests' } }
 if ($State.Contains('Automatic') -and $State.Automatic -and $State.Automatic.Active) { return @{ Next = 'extra2-offer' } }
 Write-Plain ''
 Write-Plain 'The installer is finished. Two optional extras remain. They are off unless you accept them, and the safe setup stays as it is if you decline.'
 if (-not (Ask-YesNo 'Do you want to read about optional extra 1 (no key press)?')) { return @{ Next = 'done' } }
 Show-Extra1Screen
 if (-not (Ask-Extra 'extra 1')) { Write-Plain 'Extra 1 was not accepted. Nothing was changed.'; return @{ Next = 'done' } }
 $State.Automatic = [ordered]@{ Active = $false; Accepted = (Get-Date).ToString('o') }
 @{ Next = 'extra1-stage' }
}

function Invoke-Phase-extra1-stage($State, $Opt) {
 if (-not $Opt.DryRun -and -not $State.Contains('TestsPassed')) { return @{ Stop = 'the boot programs have not passed the host tests'; Resume = 'hosttests' } }
 Write-Plain 'Putting the tested automatic boot programs on the boot partition (replaced files are saved first)...'
 Stage-AutomaticPair $State 'standard' -DryRun:$Opt.DryRun
 @{ Next = 'extra1-queue' }
}

function Invoke-Phase-extra1-queue($State, $Opt) {
 Invoke-ExtraQueue $State $Opt 'Windows GPU Unlock installer: testing automatic mode.' 'extra1-collect' 'extra1-collect' @(
  'What happens at the next start (the first run of automatic mode):',
  '  - You press nothing. There is a 5 second window at the start and 3 seconds after the drivers are released where Esc cancels.',
  '  - After a good run Windows starts by itself and the installer checks the result.')
}

function Revert-ToManual($State, $Opt) {
 Write-Plain 'Putting the manual setup back (the program that waits for the U key)...'
 Restore-ManualWrapper $State -DryRun:$Opt.DryRun
 if ($State.Contains('Automatic') -and $State.Automatic) { $State.Automatic.Active = $false }
}

function Invoke-Phase-extra1-collect($State, $Opt) {
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: the real run reads the automatic run''s report and measures the card here.'; return @{ Next = 'extra1-shortcut' } }
 $o = Get-ExtraRunOutcome $State
 if ($o.Kind -eq 'Waiting') { Write-Plain 'The automatic run has not happened yet: its boot is still queued. Restart, then run this same command again.'; return @{ Stop = 'restart needed to run automatic mode' } }
 if ($o.Kind -eq 'NoReport') {
  Write-Plain 'Automatic mode left no new report. Possible reasons: the restart did not happen, or the firmware did not start the boot partition.'
  if (Ask-YesNo 'Queue it again?') { return @{ Next = 'extra1-queue' } }
  Revert-ToManual $State $Opt
  return @{ Stop = 'automatic mode left no report; the manual setup was put back' }
 }
 $rr = $o.Report
 switch ($rr.Class) {
  'Applied' {
   if ($State.Contains('Benchmark') -and $State.Benchmark -and $State.Benchmark.Enabled) {
    Write-Plain 'Measuring your card after the automatic run (about a minute of full load)...'
    $m = Invoke-MeasurementPhase $State $Opt 'automatic' 'extra1-collect'
    if ($m.Result) { return $m.Result }
    if ($m.Record -and -not (Test-LooksUnlocked $m.Record)) {
     Write-Plain ('The card does not look unlocked right now (FP16 is {0:N1} times FP32). Was the PC shut down since the run? A confirmation made now would be wrong.' -f (Get-TensorRatio $m.Record))
     if (Ask-YesNo 'Run automatic mode again and measure right after the restart?') { return @{ Next = 'extra1-queue' } }
     Revert-ToManual $State $Opt
     return @{ Stop = 'automatic mode could not be confirmed; the manual setup was put back' }
    }
    if ($m.Record) { $State.Automatic.Measured = $m.Record }
   }
   $State.Automatic.Active = $true; $State.Automatic.Confirmed = (Get-Date).ToString('o')
   Write-Plain 'Automatic mode worked. From now on the unlock needs no key press.'
   @{ Next = 'extra1-shortcut' }
  }
  'NotApplied' {
   Write-Plain 'No unlock was applied: Esc was pressed or a check cancelled the run. Windows started normally and nothing was changed.'
   if (Ask-YesNo 'Try again?') { return @{ Next = 'extra1-queue' } }
   Revert-ToManual $State $Opt
   return @{ Stop = 'automatic mode was cancelled; the manual setup was put back' }
  }
  default {
   Write-Plain ('Automatic mode stopped on a safety check or an error: ' + $rr.Detail)
   Write-Plain 'The card keeps its normal speed and Windows started. There is no way to skip the check.'
   Revert-ToManual $State $Opt
   $f = Save-CheckReport @([pscustomobject]@{ Id = 'AUTO'; Name = 'first automatic run'; Status = 'Fail'; Detail = $rr.Detail; Fix = 'Post this report in a public issue.' }) $Opt.ReportFolder 'automatic-failed'
   Write-Plain ('Report saved: {0} (safe to post in a public issue).' -f (Split-Path -Leaf $f))
   @{ Stop = 'automatic mode stopped on a check; the manual setup was put back' }
  }
 }
}

# The shortcut now needs no key; and every-boot becomes possible (it is offered here, with Extra 1).
function Invoke-Phase-extra1-shortcut($State, $Opt) {
 $links = if ($State.Contains('Shortcut') -and $State.Shortcut) { @($State.Shortcut.Links) } else { @() }
 if ($links.Count -or $Opt.DryRun) {
  $withDesktop = ($links.Count -gt 1)
  $r = New-UnlockShortcut $State 'automatic' -Desktop:$withDesktop -DryRun:$Opt.DryRun
  if (-not $Opt.DryRun) { $State.Shortcut = [ordered]@{ Script = $r.Script; Links = @($r.Links); Mode = 'automatic' }; Write-Plain 'The shortcut "Unlock my GPU on next boot" now says that no key is needed.' }
 }
 if (-not $Opt.DryRun -and ($State.Contains('Schedule') -and $State.Schedule -and $State.Schedule.Mode -eq 'EveryBoot')) { return @{ Next = 'extra2-offer' } }
 if (Ask-EveryBoot) {
  try { Enable-EveryBoot $State -DryRun:$Opt.DryRun } catch { Write-Plain ('The startup task was not set up: ' + $_.Exception.Message) }
 } else { Write-Plain 'The unlock will not run at every start. Use the shortcut after each power-off.' }
 @{ Next = 'extra2-offer' }
}

# --- Extra 2 ---
function Invoke-Phase-extra2-offer($State, $Opt) {
 if (-not ($State.Contains('Automatic') -and $State.Automatic -and $State.Automatic.Active)) { return @{ Next = 'done' } }
 if ($State.Automatic.Contains('NoEsc') -and $State.Automatic.NoEsc) { return @{ Next = 'done' } }
 if (-not (Ask-YesNo 'Do you want to read about optional extra 2 (no Esc countdown)?')) { return @{ Next = 'done' } }
 Show-Extra2Screen
 if (-not (Get-SysGitPath) -and -not $Opt.DryRun) {
  Write-Plain 'Extra 2 needs Git for Windows to apply its patch, and Git was not found. Install it from https://git-scm.com/download/win and run the installer again to be offered Extra 2. Nothing was changed.'
  return @{ Next = 'done' }
 }
 if (-not (Ask-Extra 'extra 2')) { Write-Plain 'Extra 2 was not accepted. Nothing was changed.'; return @{ Next = 'done' } }
 @{ Next = 'extra2-build' }
}

function Get-NoEscBuiltFileList {
 $r = Get-RepoRoot
 $u = Join-Path $r 'internal-boot\unlock\build\experimental\entryLatchedSs1Full\internal\automatic-noesc'
 $b = Join-Path $r 'internal-boot\boot\build\automatic-noesc'
 $child = @(Get-ChildItem -LiteralPath $u -Filter '*-AUTO-NOESC.EFI' -ErrorAction SilentlyContinue | Select-Object -First 1)
 @(
  [pscustomobject]@{ Role = 'automatic-wrapper'; Path = (Join-Path $b 'AUTO.EFI') }
  [pscustomobject]@{ Role = 'automatic-unlock'; Path = $(if ($child.Count) { $child[0].FullName } else { Join-Path $u '(missing)-AUTO-NOESC.EFI' }) }
 )
}

# Is the patch applied in the source tree right now? Used to take it off again if a build was interrupted.
function Test-NoEscPatchApplied {
 $r = Invoke-SysScriptProcess ('Set-Location ' + (ConvertTo-PsLiteral (Get-RepoRoot)) + '; git apply -R --check ' + (ConvertTo-PsLiteral (Join-Path (Get-RepoRoot) 'patches\no-cancel-windows.patch')))
 ($r.Code -eq 0)
}
function Undo-NoEscPatch {
 $call = New-ScriptCall (Join-Path (Get-RepoRoot) 'patches\Apply-NoCancelWindows.ps1') ([ordered]@{ Undo = $true })
 $r = Invoke-SysScriptProcess $call
 if ($r.Code -ne 0) { throw ('The patch could not be taken off the source tree again: ' + $r.Output) }
}

# Applies the patch, builds the private pair, runs the automatic-mode host tests on it, and ALWAYS takes the patch off again.
function Build-NoEscPrograms($State, $Tools, [string]$ProfileDir, [string]$AssetsDir, [switch]$DryRun) {
 if ($DryRun) { Write-Plain 'DRYRUN: apply the no-cancel patch, build the private automatic pair, run the automatic-mode tests on it, take the patch off again'; return $null }
 if (Test-NoEscPatchApplied) { Undo-NoEscPatch }
 $be = Get-BuildEnvironment $Tools $ProfileDir
 $call = New-ScriptCall (Join-Path (Get-RepoRoot) 'patches\Apply-NoCancelWindows.ps1') ([ordered]@{ Clang = $be.Clang; LldLink = $be.LldLink; Python = $be.Python; Accept = $script:AcceptPhrase })
 $tests = $null; $files = $null; $err = $null
 try {
  Invoke-WithBuildEnvironment $be { $script:__res = Invoke-SysScriptProcess $call }
  if ($script:__res.Code -ne 0) { throw ('The no-cancel build did not work: ' + $script:__res.Output) }
  $files = @(Get-NoEscBuiltFileList)
  foreach ($f in $files) {
   if (-not (Test-Path -LiteralPath $f.Path)) { throw ("The no-cancel build finished but $($f.Role) is missing.") }
   $f | Add-Member -NotePropertyName Sha256 -NotePropertyValue (Get-SysFileHash $f.Path) -Force
  }
  Convert-CaptureToReport $Tools $State.CaptureDir
  $plan = @(Get-HostTestPlan $State $Tools $AssetsDir | Where-Object { $_.Name -in 'automatic mode', 'manual mode' })
  $logs = Join-Path (Get-WorkRoot) 'tests'; [void](New-Item -ItemType Directory -Path $logs -Force)
  $tests = @()
  foreach ($t in $plan) {
   $tc = New-ScriptCall $t.File $t.Params
   Invoke-WithBuildEnvironment $be { $script:__res = Invoke-SysScriptProcess $tc }
   $r = $script:__res
   $r.Output | Set-Content -LiteralPath (Join-Path $logs ((('noesc-' + $t.Name) -replace '[^A-Za-z0-9]+', '-').Trim('-') + '.log')) -Encoding utf8
   $last = @($r.Output -split "`r?`n" | Where-Object { $_.Trim() })
   $tests += [pscustomobject]@{ Name = ('no-cancel build: ' + $t.Name); Passed = ($r.Code -eq 0); Detail = $(if ($last.Count) { $last[-1].Trim() } else { '' }) }
  }
 } catch { $err = $_ }
 finally { try { if (Test-NoEscPatchApplied) { Undo-NoEscPatch } } catch { if (-not $err) { $err = $_ } } }
 if ($err) { throw $err }
 [pscustomobject]@{ Files = $files; Tests = $tests }
}

function Invoke-Phase-extra2-build($State, $Opt) {
 Write-Plain 'Building the version without the Esc windows and testing it (this takes a few minutes)...'
 $b = Build-NoEscPrograms $State (Get-ToolStatus) $State.Profile.Dir $State.Assets -DryRun:$Opt.DryRun
 if ($Opt.DryRun) { return @{ Next = 'extra2-stage' } }
 Write-Plain ''
 foreach ($t in $b.Tests) { Write-Plain ('  [{0}] {1}' -f $(if ($t.Passed) { 'pass' } else { 'FAIL' }), $t.Name); if (-not $t.Passed) { Write-Plain ('         ' + $t.Detail) } }
 if (@($b.Tests | Where-Object { -not $_.Passed }).Count -or -not @($b.Tests).Count) {
  Write-Plain 'A test of the no-cancel build failed, so it will not be put on your PC. There is no way to skip a test. The version with the Esc windows stays.'
  return @{ Stop = 'a test of the no-cancel build failed' }
 }
 $State.Build.NoEsc = [ordered]@{ Files = @($b.Files | ForEach-Object { [ordered]@{ Role = $_.Role; Path = $_.Path; Sha256 = $_.Sha256 } }); Built = (Get-Date).ToString('o'); TestsPassed = (Get-Date).ToString('o') }
 @{ Next = 'extra2-stage' }
}

function Invoke-Phase-extra2-stage($State, $Opt) {
 if (-not $Opt.DryRun -and -not ($State.Build.Contains('NoEsc') -and $State.Build.NoEsc -and $State.Build.NoEsc.TestsPassed)) { return @{ Stop = 'the no-cancel build has not passed its tests'; Resume = 'extra2-build' } }
 Write-Plain 'Putting the tested no-cancel programs on the boot partition (the previous files are saved first)...'
 if ($Opt.DryRun) { Write-Plain 'DRYRUN: copy UNLOCK-AUTO.EFI and AUTO.EFI (no-cancel versions) and the file the firmware entry starts'; return @{ Next = 'extra2-queue' } }
 Stage-AutomaticPair $State 'noesc'
 @{ Next = 'extra2-queue' }
}

function Invoke-Phase-extra2-queue($State, $Opt) {
 Invoke-ExtraQueue $State $Opt 'Windows GPU Unlock installer: testing automatic mode without the Esc windows.' 'extra2-collect' 'extra2-collect' @(
  'What happens at the next start (the first run without the Esc windows):',
  '  - You press nothing and cannot cancel from the keyboard. The start goes straight through.',
  '  - After a good run Windows starts by itself and the installer checks the result.')
}

function Revert-ToEscVersion($State, $Opt) {
 Write-Plain 'Putting the version with the Esc windows back...'
 Stage-AutomaticPair $State 'standard' -DryRun:$Opt.DryRun
}

function Invoke-Phase-extra2-collect($State, $Opt) {
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: the real run reads the report here.'; return @{ Next = 'done' } }
 $o = Get-ExtraRunOutcome $State
 if ($o.Kind -eq 'Waiting') { Write-Plain 'The run has not happened yet: its boot is still queued. Restart, then run this same command again.'; return @{ Stop = 'restart needed to run the no-cancel version' } }
 if ($o.Kind -eq 'NoReport') {
  Write-Plain 'The no-cancel version left no new report. Possible reasons: the restart did not happen, or the firmware did not start the boot partition.'
  if (Ask-YesNo 'Queue it again?') { return @{ Next = 'extra2-queue' } }
  Revert-ToEscVersion $State $Opt
  return @{ Stop = 'the no-cancel version left no report; the version with the Esc windows was put back' }
 }
 $rr = $o.Report
 if ($rr.Class -eq 'Applied') {
  $State.Automatic.NoEsc = $true; $State.Automatic.NoEscConfirmed = (Get-Date).ToString('o')
  Write-Plain 'The no-cancel version worked. Starts now go straight through.'
  return @{ Next = 'done' }
 }
 Write-Plain ('The no-cancel version did not complete: ' + $rr.Detail)
 Write-Plain 'Windows started and nothing permanent changed. There is no way to skip a check.'
 Revert-ToEscVersion $State $Opt
 @{ Stop = 'the no-cancel version did not work; the version with the Esc windows was put back' }
}

# --- switching the extras off again (start menu) ---
function Disable-Extras($State, [switch]$DryRun) {
 Write-Plain 'Switching the extras off: the manual setup (the program that waits for the U key) is put back.'
 Restore-ManualWrapper $State -DryRun:$DryRun
 if ($State.Contains('Schedule') -and $State.Schedule -and $State.Schedule.Mode -eq 'EveryBoot') {
  if ($DryRun) { Write-Plain 'DRYRUN: remove the startup task and restore Fast Startup' }
  else { [void](Disable-EveryBoot); $State.Schedule = [ordered]@{ Mode = 'Off'; Set = (Get-Date).ToString('o') }; Write-Plain 'The startup task was removed and Fast Startup put back to its saved value.' }
 }
 if ($State.Contains('Shortcut') -and $State.Shortcut) {
  $withDesktop = (@($State.Shortcut.Links).Count -gt 1)
  $r = New-UnlockShortcut $State 'manual' -Desktop:$withDesktop -DryRun:$DryRun
  if (-not $DryRun) { $State.Shortcut = [ordered]@{ Script = $r.Script; Links = @($r.Links); Mode = 'manual' } }
 }
 if (-not $DryRun) { $State.Automatic = [ordered]@{ Active = $false; SwitchedOff = (Get-Date).ToString('o') } }
}
