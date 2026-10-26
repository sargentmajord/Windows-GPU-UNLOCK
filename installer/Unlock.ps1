# Putting the boot programs on the boot partition and running the first unlock (plan requirements 8, 10, 12, 22, 23, 24, 25).
# The default installer stages the MANUAL pair only: the unlock needs a deliberate U key press and Esc cancels. The permanent firmware
# boot order and the Windows boot entry are never changed; the run is one queued one-time boot, recovered by the power button.
# Needs State.ps1, Ui.ps1, Capture.ps1 (Copy-ToBootPartition, Get-BootRoot), BootEntry.ps1.

# What goes where on the boot partition (relative paths). Source paths come from the build record in the state.
function Get-ManualStagePlan($State) {
 $byRole = @{}; foreach ($f in $State.Build.Files) { $byRole[$f.Role] = $f }
 foreach ($need in 'manual-wrapper', 'manual-unlock') { if (-not $byRole[$need]) { throw "The build record has no $need." } }
 $plan = @(
  [pscustomobject]@{ Source = $byRole['manual-unlock'].Path; Dest = 'EFI\WindowsGPUUnlock\UNLOCK.EFI'; Sha256 = $byRole['manual-unlock'].Sha256 }
  [pscustomobject]@{ Source = $byRole['manual-wrapper'].Path; Dest = 'EFI\WindowsGPUUnlock\MANUAL.EFI'; Sha256 = $byRole['manual-wrapper'].Sha256 }
 )
 foreach ($a in (Get-ExpectedAssets)) { $plan += [pscustomobject]@{ Source = (Join-Path $State.Assets $a.Name); Dest = ('RTX3060-UNLOCK\ASSETS\' + $a.Name); Sha256 = $a.Sha256 } }
 # the file the firmware's own boot entry starts: the manual wrapper
 $plan += [pscustomobject]@{ Source = $byRole['manual-wrapper'].Path; Dest = 'EFI\BOOT\BOOTX64.EFI'; Sha256 = $byRole['manual-wrapper'].Sha256 }
 $plan
}

# Copies the manual pair and the five firmware files; every replaced file is first saved in the backup folder.
function Stage-ManualProgram($State, [switch]$DryRun) {
 if ($DryRun -and -not ($State.Contains('Build') -and $State.Build -and @($State.Build.Files).Count)) {
  # a dry run has built nothing, so there is no record of files yet; describe the step instead
  Write-Plain 'DRYRUN: copy the two manual boot programs and the five firmware files to the boot partition, and make the manual program the one the firmware entry starts'
  return
 }
 $plan = @(Get-ManualStagePlan $State)
 foreach ($p in $plan) {
  if (-not $DryRun -and (Get-SysFileHash $p.Source) -ne $p.Sha256) { throw ("A file to stage changed since it was built or tested: $($p.Dest)") }
 }
 New-BootFolder $State 'RTX3060-UNLOCK\ASSETS' -DryRun:$DryRun
 foreach ($p in $plan) {
  if ($DryRun) { Write-Plain ("DRYRUN: copy {0} to the boot partition as {1}" -f (Split-Path -Leaf $p.Source), $p.Dest); continue }
  [void](Copy-ToBootPartition $State $p.Source $p.Dest $State.BackupFolder)
 }
}

# Reads every staged file back and compares it with the tested build. Returns the list of problems (empty when all is right).
function Test-StagedFiles($State) {
 $bad = @()
 foreach ($p in (Get-ManualStagePlan $State)) {
  $f = Join-Path (Get-BootRoot $State) $p.Dest
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $bad += "$($p.Dest) is missing"; continue }
  if ((Get-SysFileHash $f) -ne $p.Sha256) { $bad += "$($p.Dest) differs from the tested build" }
 }
 $bad
}

# Reads a run's REPORT.TXT. Classes: Applied | NotApplied (cancelled or timed out) | Failed | Unreadable
function Read-RunReport([string]$Path) {
 $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
 $m = [regex]::Matches($text, '(?m)^FINAL (.*)$')
 if (-not $m.Count) { return [pscustomobject]@{ Class = 'Unreadable'; Final = ''; Detail = 'The report has no final line (the run did not finish).' } }
 $final = $m[$m.Count - 1].Groups[1].Value.Trim()
 $kv = @{}; foreach ($t in ($final -split '\s+')) { if ($t -match '^([a-z_]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] } }
 $ss = [regex]::Match($text, '(?m)SS0=([0-9a-fA-F]{8}) SS1=([0-9a-fA-F]{8})')
 $class = if ($kv['attempted'] -eq '1' -and $kv['clean'] -eq '1' -and $kv['status'] -eq '0') { 'Applied' }
  elseif ($kv['attempted'] -eq '1') { 'Failed' }
  elseif ($kv['attempted'] -eq '0' -and $kv['status'] -eq '0') { 'NotApplied' }
  else { 'Failed' }
 [pscustomobject]@{ Class = $class; Final = "FINAL $final"; Detail = $final; Selectors = $(if ($ss.Success) { $ss.Groups[1].Value + '/' + $ss.Groups[2].Value } else { $null }) }
}

# Names of the run folders on the boot partition: manual runs write RUNnn, automatic runs AUTOnnnnnn.
function Get-RunFolderNames($State) {
 $dir = Join-Path (Get-BootRoot $State) 'RTX3060-UNLOCK'
 if (-not (Test-Path -LiteralPath $dir)) { return @() }
 @(Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -match '^(RUN\d+|AUTO\d+)$' } | ForEach-Object { $_.Name })
}

# The report of the run that happened after the boot was queued. The new run is the folder that was not there before (a folder
# counter, like Arm-NextBoot.ps1 uses): file times on the FAT partition come from the firmware's clock, which can be hours off
# (a PC whose clock is kept in UTC, drift), so time is used only when no earlier list of folders exists.
function Get-LatestRunReport($State, $Before, [datetime]$Since) {
 $dir = Join-Path (Get-BootRoot $State) 'RTX3060-UNLOCK'
 if (-not (Test-Path -LiteralPath $dir)) { return $null }
 $reports = @(Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -match '^(RUN\d+|AUTO\d+)$' } |
  ForEach-Object { $f = Join-Path $_.FullName 'REPORT.TXT'; if (Test-Path -LiteralPath $f) { Get-Item -LiteralPath $f } })
 if ($null -ne $Before) {
  $known = @($Before)
  $new = @($reports | Where-Object { $known -cnotcontains $_.Directory.Name } | Sort-Object { $_.Directory.Name })
  if ($new.Count) { return $new[-1].FullName } else { return $null }
 }
 $r = $reports | Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime | Select-Object -Last 1
 if ($r) { $r.FullName } else { $null }
}

function Show-UnlockInstructions {
 Write-Plain ''
 Write-Plain 'What happens at the next start (this is the first unlock, and it is the safe, manual version):'
 Write-Plain '  - The screen shows a short message from the unlock program. Your screen adapter keeps working; the card being unlocked may go blank for a moment.'
 Write-Plain '  - The program waits for you to press U once. Esc, or doing nothing for 30 seconds, cancels it and Windows simply starts.'
 Write-Plain '  - After a good run Windows starts by itself and the installer can measure the result.'
 Write-Plain 'If the screen freezes: hold the power button until the PC turns off, then power on. Windows then starts normally.'
 Write-Plain 'The unlock lasts until the PC is powered off or goes to sleep. Nothing is written to the card''s stored firmware.'
}
