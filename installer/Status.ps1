# What the installer notices about an install that already exists (plan requirements 16 and 31):
#  - the PC changed under the profile (BIOS version or board): the profile is tied to the BIOS, so a new capture is needed;
#  - the boot setup was damaged (the firmware lost its boot entry after a BIOS update or CMOS clear, the fallback file is missing or changed);
#  - this installer carries newer boot programs than the ones that are on the boot partition: show what changed and ask before replacing them.
# Everything here is read-only until the user agrees to a repair or an update. Needs State.ps1, Ui.ps1, BootEntry.ps1, Capture.ps1, Rollback.ps1,
# Unlock.ps1, Extras.ps1, Checks.ps1 (Get-SysSecureBoot, Get-SysFastStartup).

# --- the PC the profile was made on ---
function Get-EnvironmentRecord { $b = Get-SysBoard; [ordered]@{ Board = [string]$b.Board; Bios = [string]$b.Bios; Recorded = (Get-Date).ToString('o') } }

function Test-EnvironmentChanged($State) {
 if (-not ($State.Contains('Environment') -and $State.Environment)) { return [pscustomobject]@{ Changed = $false; Reasons = @() } }
 $now = Get-SysBoard
 $why = @()
 if ([string]$now.Bios -cne [string]$State.Environment.Bios) { $why += ('The BIOS version changed (it was "{0}", it is now "{1}").' -f $State.Environment.Bios, $now.Bios) }
 if ([string]$now.Board -cne [string]$State.Environment.Board) { $why += ('The motherboard model changed (it was "{0}", it is now "{1}").' -f $State.Environment.Board, $now.Board) }
 [pscustomobject]@{ Changed = ($why.Count -gt 0); Reasons = $why }
}

# Forgets everything that depended on the old capture; keeps the choices (cards, boot partition, tools, backup) and the journal.
function Reset-ForNewCapture($State) {
 foreach ($k in 'Profile', 'CaptureDir', 'Build', 'TestsPassed', 'Unlock', 'Automatic', 'Environment', 'Diagnostic', 'DiagFilesBefore', 'CaptureQueuedAt', 'RunFoldersBefore', 'UnlockQueuedAt', 'Update') { if ($State.Contains($k)) { $State.Remove($k) } }
 $State.EntryRestarts = 0
 $State.Phase = 'diag-build'
}

# Called by the phase loop. Returns $null when nothing changed, else @{ Next } or @{ Stop }.
function Invoke-EnvironmentChange($State, $Opt) {
 $e = Test-EnvironmentChanged $State
 if (-not $e.Changed) { return $null }
 Write-Plain ''
 foreach ($r in $e.Reasons) { Write-Plain $r }
 Write-Plain 'The profile, the boot programs and the tests were made for the old setup, so they are not reused: the installer needs a new capture of this PC.'
 Write-Plain 'Until then the unlock is not applied again; a repeated start-up unlock would only be refused by the programs'' own checks.'
 if ($State.Contains('Schedule') -and $State.Schedule -and $State.Schedule.Mode -eq 'EveryBoot') {
  if ($Opt.DryRun) { Write-Plain 'DRY RUN: the startup task would be removed until the new capture is done (it is asked first).' }
  elseif (Ask-YesNo 'Stop unlocking at every start until the new capture is done? (removes the startup task)') {
   try { [void](Disable-EveryBoot); $State.Schedule = [ordered]@{ Mode = 'Off'; Set = (Get-Date).ToString('o') } } catch { Write-Plain ('The startup task could not be removed: ' + $_.Exception.Message) }
  }
 }
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: it would ask whether to make the new capture now.'; return @{ Stop = 'the PC changed: a new capture is needed' } }
 if (-not (Ask-YesNo 'Make a new capture now?')) { Write-Plain 'Nothing else was changed. Run the installer again when you want to; Roll back is available.'; return @{ Stop = 'the PC changed: a new capture is needed'; Resume = $State.Phase } }
 Reset-ForNewCapture $State
 @{ Next = 'diag-build' }
}

# --- the state of the boot setup ---
function Get-ExpectedFallbackHash($State) {
 $files = @($State.Build.Files)
 $role = 'manual-wrapper'
 if ($State.Contains('Automatic') -and $State.Automatic -and $State.Automatic.Active) {
  $role = 'automatic-wrapper'
  if ($State.Automatic.Contains('NoEsc') -and $State.Automatic.NoEsc -and $State.Build.Contains('NoEsc') -and $State.Build.NoEsc) { $files = @($State.Build.NoEsc.Files) }
 }
 $f = @($files | Where-Object { $_.Role -eq $role }) | Select-Object -First 1
 if ($f) { [string]$f.Sha256 } else { $null }
}

# Every-boot mode's own startup task (internal-boot\Set-UnlockSchedule.ps1 -Mode EveryBoot) has a circuit breaker:
# if a queued unlock left no report (a real freeze, a power loss, or a deliberate test), it stops queuing new ones
# and waits. That is the right call on its own, but until now nothing told the user it happened or offered a way
# back - they would just notice "every boot" had quietly stopped, with no explanation. Read-only; the repair below
# only clears the stuck flag after the user agrees, so the task's own normal check does the rest at the next start.
function Test-EveryBootStuck($State) {
 if (-not ($State.Contains('Schedule') -and $State.Schedule -and $State.Schedule.Mode -eq 'EveryBoot')) { return $null }
 $log = Join-Path (Get-SysDataRoot) 'arm.log'
 if (-not (Test-Path -LiteralPath $log)) { return $null }
 $last = Get-Content -LiteralPath $log -Tail 1 -ErrorAction SilentlyContinue
 if ($last -match 'not armed: the previously queued unlock left no report') { return $true }
 return $false
}

# Returns a list of @{ Id; Ok; Text; Repair } where Repair is '', 'restage', 'restart' or 'rearm'.
function Get-InstallStatus($State) {
 $items = New-Object System.Collections.ArrayList
 function Add-Item([string]$Id, [bool]$Ok, [string]$Text, [string]$Repair = '') { [void]$items.Add([pscustomobject]@{ Id = $Id; Ok = $Ok; Text = $Text; Repair = $Repair }) }
 $sb = Get-SysSecureBoot
 Add-Item 'secure-boot' ($sb -eq 'Off') $(if ($sb -eq 'Off') { 'Secure Boot is off.' } else { 'Secure Boot is not off (a BIOS update can turn it back on). The firmware refuses the unlock program while it is on.' })
 $fs = Get-SysFastStartup
 Add-Item 'fast-startup' ($fs -eq 0) $(if ($fs -eq 0) { 'Windows Fast Startup is off.' } else { 'Windows Fast Startup is on. "Shut down" is then not a cold start, so the unlock may not run. Turn it off in Power Options.' })
 $envState = Test-EnvironmentChanged $State
 Add-Item 'bios' (-not $envState.Changed) $(if ($envState.Changed) { ($envState.Reasons -join ' ') + ' A new capture is needed.' } else { 'The BIOS version and the motherboard are the ones the profile was made on.' })
 $hits = Find-UnlockEntries   # (it returns the list wrapped, so that an empty list survives)
 $hits = @($hits)
 $entryText = switch ($hits.Count) { 0 { 'The firmware has no boot entry for the unlock partition (a BIOS update or a CMOS clear removes entries). The firmware makes one again by itself from the fallback file after a restart.' } 1 { 'The firmware has its boot entry for the unlock partition.' } default { 'The firmware lists more than one boot entry for the unlock partition; the unlock will not be queued until there is exactly one.' } }
 Add-Item 'entry' ($hits.Count -eq 1) $entryText $(if ($hits.Count -eq 0) { 'restart' } else { '' })
 $root = Resolve-RollbackBootRoot $State
 if (-not $root.Root) {
  Add-Item 'partition' $false ('The boot partition cannot be used: ' + $root.Reason + '.')
 } else {
  Add-Item 'partition' $true 'The boot partition is there and is the one the installer recorded.'
  $want = Get-ExpectedFallbackHash $State
  $file = Join-Path $root.Root 'EFI\BOOT\BOOTX64.EFI'
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Add-Item 'fallback' $false 'The fallback file EFI\BOOT\BOOTX64.EFI is missing from the boot partition, so the firmware has nothing to start.' 'restage' }
  elseif ($want -and (Get-SysFileHash $file) -ne $want) { Add-Item 'fallback' $false 'The fallback file EFI\BOOT\BOOTX64.EFI is not the program the installer put there (something replaced it).' 'restage' }
  else { Add-Item 'fallback' $true 'The fallback file is the one the installer put there.' }
 }
 $stuck = Test-EveryBootStuck $State
 if ($stuck) {
  Add-Item 'every-boot' $false 'A queued unlock left no report (a real freeze, a power loss, or a deliberate test can all cause this), so every-boot mode safely stopped queuing new ones and has been waiting since. It will not start queuing again on its own.' 'rearm'
 } elseif ($stuck -eq $false) {
  Add-Item 'every-boot' $true 'Every-boot mode is queuing normally.'
 }
 @($items)
}

function Show-InstallStatus($Items) {
 Write-Plain ''
 Write-Plain 'State of your install:'
 foreach ($i in $Items) { Write-Plain ('  [{0}] {1}' -f $(if ($i.Ok) { 'ok' } else { 'CHECK' }), $i.Text) }
}

# Offers each repair; every one asks first. Returns $true if something was changed.
function Invoke-StatusRepairs($State, $Items, [switch]$DryRun) {
 $changed = $false
 foreach ($i in @($Items | Where-Object { -not $_.Ok -and $_.Repair -eq 'restage' })) {
  if ($DryRun) { Write-Plain 'DRY RUN: it would offer to put the boot programs back (saved copies of anything it replaces).'; break }
  if (Ask-YesNo 'Put the boot programs back on the boot partition now?') {
   Stage-ManualProgram $State
   if ($State.Contains('Automatic') -and $State.Automatic -and $State.Automatic.Active) { Stage-AutomaticPair $State 'standard' }
   Write-Plain 'The boot programs were put back and read back against the tested build.'
   $changed = $true
  }
  break
 }
 if (@($Items | Where-Object { -not $_.Ok -and $_.Repair -eq 'restart' }).Count -and -not $DryRun) {
  Write-Plain 'To get the firmware to make its boot entry again, restart once.'
  [void](Request-Restart 'Windows GPU Unlock installer: the firmware needs to notice the boot partition again.')
 }
 foreach ($i in @($Items | Where-Object { -not $_.Ok -and $_.Repair -eq 'rearm' })) {
  if ($DryRun) { Write-Plain 'DRY RUN: it would offer to clear the stopped every-boot state so it starts queuing again.'; break }
  if (Ask-YesNo 'Clear this and let every-boot mode start queuing again from your next restart?') {
   $stateFile = Join-Path (Get-SysDataRoot) 'arm-state.json'
   if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
   Write-Plain 'Cleared. Every-boot mode will queue normally again starting with your next restart.'
   $changed = $true
  }
  break
 }
 $changed
}

# --- newer boot programs (requirement 31) ---
# A fingerprint of the sources the boot programs are built from. It is stored when they are built; a newer installer with different sources has different programs.
function Get-BootSourceFingerprint {
 $r = Get-RepoRoot
 $lines = @()
 foreach ($d in 'internal-boot\boot', 'internal-boot\unlock') {
  $dir = Join-Path $r $d
  if (-not (Test-Path -LiteralPath $dir)) { continue }
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Include '*.c', '*.h', '*.ps1', '*.py', '*.json', '*.S' | Where-Object { $_.FullName -notmatch '\\(build|__pycache__)\\' -and $_.Name -ne 'platform-config.h' } | Sort-Object FullName)) {
   $lines += ('{0}|{1}' -f $f.FullName.Substring($r.Length).ToLower(), (Get-SysFileHash $f.FullName))
  }
 }
 $sha = [Security.Cryptography.SHA256]::Create()
 -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))) | ForEach-Object { $_.ToString('x2') })
}

function Get-RecentChanges([int]$Count = 5) {
 $f = Join-Path (Get-RepoRoot) 'CHANGES.md'
 if (-not (Test-Path -LiteralPath $f)) { return @() }
 @(Get-Content -LiteralPath $f | Where-Object { $_ -like '## *' } | Select-Object -First $Count | ForEach-Object { $_.Substring(3) })
}

function Test-BootProgramsOutdated($State) {
 if (-not ($State.Contains('Build') -and $State.Build -and $State.Build.Contains('SourceFingerprint') -and $State.Build.SourceFingerprint)) { return $false }
 (Get-BootSourceFingerprint) -cne [string]$State.Build.SourceFingerprint
}

# For a finished install. Returns $true if an update was started (the phase is set; the caller runs the loop).
function Offer-BootProgramUpdate($State, [switch]$DryRun) {
 if ([string]$State.Phase -ne 'done' -or -not (Test-BootProgramsOutdated $State)) { return $false }
 Write-Plain ''
 Write-Plain 'This installer carries newer boot programs than the ones on your boot partition. What changed lately:'
 foreach ($c in (Get-RecentChanges)) { Write-Plain ('  - ' + $c) }
 Write-Plain 'Details are in CHANGES.md. Updating rebuilds the programs for your PC from your own capture, runs the same host tests, and only then replaces the ones on the boot partition (every replaced file is saved first),'
 Write-Plain 'then runs one unlock to check them. Your choices (cards, boot partition, shortcut, extras) are kept. If you decline, the programs you have keep working exactly as they are.'
 if ($State.Contains('Automatic') -and $State.Automatic -and $State.Automatic.Contains('NoEsc') -and $State.Automatic.NoEsc) { Write-Plain 'Your version without the Esc windows (extra 2) is put back to the version with them; you can accept extra 2 again afterwards.' }
 if ($DryRun) { Write-Plain 'DRY RUN: it would ask whether to update now.'; return $false }
 if (-not (Ask-YesNo 'Update the boot programs now?')) { Write-Plain 'Nothing was changed.'; return $false }
 $State.Update = [ordered]@{ Started = (Get-Date).ToString('o'); Previous = [string]$State.Build.SourceFingerprint }
 foreach ($k in 'TestsPassed') { if ($State.Contains($k)) { $State.Remove($k) } }
 if ($State.Contains('Automatic') -and $State.Automatic -and $State.Automatic.Contains('NoEsc')) { $State.Automatic.NoEsc = $false }
 if ($State.Build.Contains('NoEsc')) { $State.Build.Remove('NoEsc') }
 $State.Phase = 'build'
 $true
}

# --- the update's own phases (after the host tests) ---
function Invoke-Phase-update-stage($State, $Opt) {
 if (-not $Opt.DryRun -and -not $State.Contains('TestsPassed')) { return @{ Stop = 'the new boot programs have not passed the host tests'; Resume = 'hosttests' } }
 Write-Plain 'Putting the tested new boot programs on the boot partition (replaced files are saved first)...'
 Stage-ManualProgram $State -DryRun:$Opt.DryRun
 if ($State.Contains('Automatic') -and $State.Automatic -and $State.Automatic.Active) { Stage-AutomaticPair $State 'standard' -DryRun:$Opt.DryRun }
 if (-not $Opt.DryRun) {
  $bad = @(Test-StagedFiles $State)
  if ($bad.Count) { $bad | ForEach-Object { Write-Plain ('  - ' + $_) }; return @{ Stop = 'the staged files do not match the tested build' } }
 }
 @{ Next = 'update-queue' }
}

function Invoke-Phase-update-queue($State, $Opt) {
 Invoke-ExtraQueue $State $Opt 'Windows GPU Unlock installer: checking the updated boot programs.' 'update-collect' 'update-collect' @(
  'What happens at the next start (one unlock with the updated programs):',
  $(if ($State.Contains('Automatic') -and $State.Automatic -and $State.Automatic.Active) { '  - You press nothing (automatic mode); Esc cancels during the short windows.' } else { '  - The program waits for you to press U once. Esc, or 30 seconds with no key, cancels it.' }))
}

function Invoke-Phase-update-collect($State, $Opt) {
 if ($Opt.DryRun) { Write-Plain 'DRY RUN: the real run reads the report here.'; return @{ Next = 'done' } }
 $o = Get-ExtraRunOutcome $State
 if ($o.Kind -eq 'Waiting') { Write-Plain 'The run has not happened yet: its boot is still queued. Restart, then run this same command again.'; return @{ Stop = 'restart needed to run the updated programs' } }
 if ($o.Kind -eq 'NoReport') {
  Write-Plain 'The updated programs left no new report.'
  if (Ask-YesNo 'Queue it again?') { return @{ Next = 'update-queue' } }
  return @{ Stop = 'the updated programs left no report' }
 }
 if ($o.Report.Class -eq 'Applied') {
  $State.Unlock = [ordered]@{ Applied = $true; Selectors = $o.Report.Selectors; Final = $o.Report.Final; At = (Get-Date).ToString('o') }
  $State.Remove('Update')
  Write-Plain 'The updated boot programs ran cleanly. The update is finished.'
  return @{ Next = 'done' }
 }
 if ($o.Report.Class -eq 'NotApplied') {
  Write-Plain 'No unlock was applied (cancelled or timed out). Windows started normally.'
  if (Ask-YesNo 'Try again?') { return @{ Next = 'update-queue' } }
  return @{ Stop = 'the updated programs were not run' }
 }
 Write-Plain ('The updated programs stopped on a check or an error: ' + $o.Report.Detail)
 Write-Plain 'The card keeps its normal speed and Windows started. Roll back puts back every file the update replaced, as it was before the whole install.'
 @{ Stop = 'the updated programs stopped on a check' }
}
