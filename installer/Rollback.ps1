# Roll back (plan requirements 12 and 14). Driven by the journal: it undoes only what the installer's journal says it did, in reverse
# order, and checks each thing before touching it (a file only if its hash is still the one the installer wrote, a partition only if it
# is still the one the installer made and holds nothing else). Anything that needs a decision is asked first; nothing is assumed.
# Needs Ui.ps1, State.ps1, BootPartition.ps1, BootEntry.ps1, Capture.ps1, Schedule.ps1, Backup.ps1 and Resume.ps1.

$script:RollbackResults = New-Object System.Collections.ArrayList
$script:RollbackNeedsRestart = $false

# --- system calls (replaceable in tests) ---
function Get-SysPartitionIdentity([int]$Disk, [int]$Number) {
 $p = Get-Partition -DiskNumber $Disk -PartitionNumber $Number -ErrorAction SilentlyContinue
 if (-not $p) { return $null }
 [pscustomobject]@{ Disk = $Disk; Number = $Number; Guid = [string]$p.Guid; Offset = [int64]$p.Offset; SizeBytes = [int64]$p.Size; DriveLetter = $(if ($p.DriveLetter) { [string]$p.DriveLetter } else { '' }) }
}
function Invoke-SysRemovePartition([int]$Disk, [int]$Number) { Remove-Partition -DiskNumber $Disk -PartitionNumber $Number -Confirm:$false -ErrorAction Stop }
function Get-SysCSize {
 $c = Get-Partition -DriveLetter C -ErrorAction Stop
 $sup = Get-PartitionSupportedSize -DriveLetter C
 [pscustomobject]@{ SizeBytes = [int64]$c.Size; MaxSizeBytes = [int64]$sup.SizeMax }
}
function Get-SysShortcutInfo([string]$LinkPath) {
 $l = (New-Object -ComObject WScript.Shell).CreateShortcut($LinkPath)
 [pscustomobject]@{ Target = [string]$l.TargetPath; Arguments = [string]$l.Arguments }
}

function Get-RollbackExplanation {
 @(
  'What Roll back does. It undoes only what this installer changed on your PC, and nothing else. It removes the automatic-resume',
  'entry and any queued one-time boot; deletes the files the installer added to its boot partition (only if they are',
  'unchanged); checks that the boot order still has Windows first (the installer never changes it); removes the startup task; puts the',
  'Fast Startup setting back to what it was; stops the unlock from being applied at boot; and deletes the installer''s working files.',
  'It keeps the report and log files unless you tell it to delete them.',
  'It asks you before it deletes the NVIDIA firmware files it generated, and before it gives disk space back to C: if it had shrunk it.',
  'It never touches your Windows files, your own data, BIOS/UEFI settings or the graphics card''s stored firmware. Settings you changed yourself as a prerequisite, such as turning Secure Boot',
  'off in the BIOS, are not reversed: turn them back on yourself if you want them (some games'' anti-cheat needs Secure Boot). After you restart, the card behaves as if the installer had never run.',
  'At the end it prints a checklist of what was removed, what was already gone and what it left because you had changed it.')
}

function Add-RollbackResult([string]$Item, [ValidateSet('Removed', 'AlreadyGone', 'Left', 'Kept', 'WouldDo')][string]$Outcome, [string]$Detail = '') {
 [void]$script:RollbackResults.Add([pscustomobject]@{ Item = $Item; Outcome = $Outcome; Detail = $Detail })
}

function Get-JournalPrevious($Entry, [string]$Name) {
 if ($Entry.Contains('Previous') -and $Entry.Previous -and $Entry.Previous.Contains($Name)) { $Entry.Previous[$Name] } else { $null }
}
function Get-JournalEntries($Entries, [string]$Action) { @($Entries | Where-Object { $_.Action -eq $Action }) }
# The journal keeps full paths such as U:\EFI\BOOT\BOOTX64.EFI; the drive letter can differ now, so only the part after it is used.
function Get-RelativeBootPath([string]$Target) { $Target -replace '^[A-Za-z]:\\', '' }
function Format-Size([int64]$Bytes) { '{0:N2} GiB' -f ($Bytes / 1GB) }

# The boot partition as it is NOW: found by its disk and number, accepted only if it is still the partition the installer recorded
# (same GUID) and still carries the GPUUNLOCK label. Drive letters can change between runs, so the journal's paths are re-based on it.
function Resolve-RollbackBootRoot($State) {
 $bp = if ($State.Contains('BootPartition')) { $State.BootPartition } else { $null }
 if (-not $bp) { return [pscustomobject]@{ Root = $null; Reason = 'the installer never chose a boot partition' } }
 $info = Get-SysPartitionIdentity ([int]$bp.Disk) ([int]$bp.Number)
 if (-not $info) { return [pscustomobject]@{ Root = $null; Reason = 'the boot partition is not there any more' } }
 if ($bp.Guid -and $info.Guid -ne $bp.Guid) { return [pscustomobject]@{ Root = $null; Reason = 'a different partition now has the boot partition''s number, so nothing on it is touched' } }
 $letter = $info.DriveLetter
 if (-not $letter) { $letter = Invoke-SysAssignLetter ([int]$bp.Disk) ([int]$bp.Number) }
 if (-not $letter) { return [pscustomobject]@{ Root = $null; Reason = 'the boot partition has no drive letter' } }
 if ((Get-SysVolumeLabel $letter) -cne $script:UnlockLabel) { return [pscustomobject]@{ Root = $null; Reason = ('the partition is no longer labelled ' + $script:UnlockLabel + ', so nothing on it is touched') } }
 [pscustomobject]@{ Root = (Get-BootRootFromLetter $letter); Reason = '' }
}

# The root folder of a drive letter (a seam, so tests can point it at a temporary folder).
function Get-BootRootFromLetter([string]$Letter) { $Letter.TrimEnd(':') + ':\' }

# --- the steps ---
function Undo-ResumeEntry([switch]$DryRun) {
 if (-not (Test-ResumeEntry)) { Add-RollbackResult 'automatic resume after login' 'AlreadyGone'; return }
 if ($DryRun) { Add-RollbackResult 'automatic resume after login' 'WouldDo' 'remove the entry'; return }
 Remove-ResumeEntry
 Add-RollbackResult 'automatic resume after login' 'Removed'
}

function Undo-QueuedBoot($Entries, [switch]$DryRun) {
 $queued = Test-QueuedBoot
 if (-not $queued) { Add-RollbackResult 'queued one-time boot' 'AlreadyGone'; return }
 if (-not (Get-JournalEntries $Entries 'queue one-time boot').Count) { Add-RollbackResult 'queued one-time boot' 'Left' 'a one-time boot is queued, but this installer did not queue it'; return }
 if ($DryRun) { Add-RollbackResult 'queued one-time boot' 'WouldDo' 'clear it'; return }
 if (Invoke-SysClearQueue) { Add-RollbackResult 'queued one-time boot' 'Removed' }
 else { $script:RollbackNeedsRestart = $true; Add-RollbackResult 'queued one-time boot' 'Left' 'Windows could not clear it; restart once so the unlock program runs and ends by itself' }
}

function Undo-EveryBoot($State, $Entries, [switch]$DryRun) {
 $had = (Get-JournalEntries $Entries 'unlock at every start (startup task, Fast Startup off)').Count -gt 0
 if (-not $had -and $State.Contains('Schedule') -and $State.Schedule -and $State.Schedule.Mode -eq 'EveryBoot') { $had = $true }
 if (-not $had) { Add-RollbackResult 'startup task (unlock at every start)' 'AlreadyGone' 'the installer never made one'; return }
 if ($DryRun) { Add-RollbackResult 'startup task (unlock at every start)' 'WouldDo' 'remove it and put Fast Startup back to its saved value'; return }
 try { [void](Disable-EveryBoot); Add-RollbackResult 'startup task (unlock at every start)' 'Removed' 'Fast Startup put back to the value it had before the installer' }
 catch { Add-RollbackResult 'startup task (unlock at every start)' 'Left' $_.Exception.Message; return }
 $root = Get-DataRoot
 foreach ($n in 'Arm-NextBoot.ps1', 'unlock-schedule-state.json') {
  $p = Join-Path $root $n
  if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; Add-RollbackResult ('startup file ' + $n) 'Removed' }
 }
}

function Undo-Shortcuts($Entries, [switch]$DryRun) {
 $scriptEntries = Get-JournalEntries $Entries 'write the next-boot unlock script'
 $scriptPath = $null
 foreach ($e in $scriptEntries) { $scriptPath = $e.Target }
 foreach ($e in @(Get-JournalEntries $Entries 'create the Start menu shortcut') + @(Get-JournalEntries $Entries 'create the desktop shortcut')) {
  $link = $e.Target
  if (-not (Test-Path -LiteralPath $link)) { Add-RollbackResult ('shortcut ' + $link) 'AlreadyGone'; continue }
  if (Get-JournalPrevious $e 'Existed') { Add-RollbackResult ('shortcut ' + $link) 'Left' 'a shortcut with this name was there before the installer, so it cannot be told apart'; continue }
  $ours = $false
  try { $i = Get-SysShortcutInfo $link; $ours = [bool]($scriptPath -and $i.Arguments.IndexOf($scriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) } catch { }
  if (-not $ours) { Add-RollbackResult ('shortcut ' + $link) 'Left' 'it no longer points at the installer''s script (you or another program changed it)'; continue }
  if ($DryRun) { Add-RollbackResult ('shortcut ' + $link) 'WouldDo' 'delete'; continue }
  Remove-Item -LiteralPath $link -Force; Add-RollbackResult ('shortcut ' + $link) 'Removed'
 }
 foreach ($e in $scriptEntries) {
  if (-not (Test-Path -LiteralPath $e.Target)) { Add-RollbackResult ('script ' + $e.Target) 'AlreadyGone'; continue }
  if (Get-JournalPrevious $e 'Existed') { Add-RollbackResult ('script ' + $e.Target) 'Left' 'a file with this name was there before the installer'; continue }
  if ($DryRun) { Add-RollbackResult ('script ' + $e.Target) 'WouldDo' 'delete'; continue }
  Remove-Item -LiteralPath $e.Target -Force; Add-RollbackResult ('script ' + $e.Target) 'Removed'
 }
}

# Files the installer put on the boot partition, newest first. A file goes only if it is still what the installer wrote; if the
# installer replaced a file, the previous one is put back from the backup (after checking the backup is intact).
function Undo-StagedFiles($State, $Entries, [string]$BootRoot, [string]$WhyNot, [switch]$DryRun) {
 $files = @(Get-JournalEntries $Entries 'copy file to boot partition')
 [array]::Reverse($files)
 foreach ($e in $files) {
  $name = Get-RelativeBootPath $e.Target
  if (-not $BootRoot) { Add-RollbackResult ('boot partition file ' + $name) 'Left' $WhyNot; continue }
  $path = Join-Path $BootRoot $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-RollbackResult ('boot partition file ' + $name) 'AlreadyGone'; continue }
  $wrote = Get-JournalPrevious $e 'WrittenSha256'
  $now = Get-SysFileHash $path
  if (-not $wrote -or $now -ne $wrote) { Add-RollbackResult ('boot partition file ' + $name) 'Left' 'it is not the file the installer wrote (it was changed afterwards)'; continue }
  if (Get-JournalPrevious $e 'Existed') {
   $bk = Get-JournalPrevious $e 'Backup'; $prev = Get-JournalPrevious $e 'Sha256'
   if (-not $bk -or -not (Test-Path -LiteralPath $bk) -or (Get-SysFileHash $bk) -ne $prev) { Add-RollbackResult ('boot partition file ' + $name) 'Left' 'the installer replaced a file here, but its saved copy is missing or changed, so nothing was touched'; continue }
   if ($DryRun) { Add-RollbackResult ('boot partition file ' + $name) 'WouldDo' 'put the previous file back'; continue }
   Copy-Item -LiteralPath $bk -Destination $path -Force
   if ((Get-SysFileHash $path) -ne $prev) { Add-RollbackResult ('boot partition file ' + $name) 'Left' 'the previous file was copied back but does not match; check it'; continue }
   Add-RollbackResult ('boot partition file ' + $name) 'Removed' 'the previous file was put back'
   continue
  }
  if ($DryRun) { Add-RollbackResult ('boot partition file ' + $name) 'WouldDo' 'delete'; continue }
  Remove-Item -LiteralPath $path -Force
  Add-RollbackResult ('boot partition file ' + $name) 'Removed'
 }
 $dirs = @(Get-JournalEntries $Entries 'create folder on boot partition')
 [array]::Reverse($dirs)
 foreach ($e in $dirs) {
  $name = Get-RelativeBootPath $e.Target
  if (-not $BootRoot) { Add-RollbackResult ('boot partition folder ' + $name) 'Left' $WhyNot; continue }
  $path = Join-Path $BootRoot $name
  if (-not (Test-Path -LiteralPath $path)) { Add-RollbackResult ('boot partition folder ' + $name) 'AlreadyGone'; continue }
  if (@(Get-ChildItem -LiteralPath $path -Force).Count) { Add-RollbackResult ('boot partition folder ' + $name) 'Left' 'it is not empty (the unlock programs write their logs here)'; continue }
  if ($DryRun) { Add-RollbackResult ('boot partition folder ' + $name) 'WouldDo' 'delete (empty)'; continue }
  Remove-Item -LiteralPath $path -Force
  Add-RollbackResult ('boot partition folder ' + $name) 'Removed'
 }
}

# Files on the partition that the installer and its two programs did not write. The programs write their logs and images in
# RTX3060-UNLOCK; Windows adds System Volume Information. Anything else belongs to someone else.
function Get-ForeignFiles([string]$BootRoot) {
 $out = @()
 foreach ($f in @(Get-ChildItem -LiteralPath $BootRoot -Recurse -Force -File -ErrorAction SilentlyContinue)) {
  $rel = $f.FullName.Substring($BootRoot.Length)
  if ($rel -like 'RTX3060-UNLOCK\*' -or $rel -like 'System Volume Information\*') { continue }
  $out += $rel
 }
 $out
}

# Returns $true when the partition the installer created is gone afterwards (or never existed).
function Undo-BootPartition($State, $Entries, [string]$BootRoot, [switch]$DryRun) {
 $id = @(Get-JournalEntries $Entries 'created partition identity') | Select-Object -Last 1
 if (-not $id) { Add-RollbackResult 'boot partition' 'Kept' 'the installer did not create one (it used an existing partition, which is never deleted)'; return $false }
 $want = $id.Previous
 $now = Get-SysPartitionIdentity ([int]$want.Disk) ([int]$want.Number)
 if (-not $now) { Add-RollbackResult 'boot partition the installer created' 'AlreadyGone'; return $true }
 if ($now.Guid -ne $want.Guid -or $now.Offset -ne [int64]$want.Offset -or $now.SizeBytes -ne [int64]$want.SizeBytes) {
  Add-RollbackResult 'boot partition the installer created' 'Left' 'the partition with that number is not the one the installer made (different GUID, place or size), so it is not touched'; return $false
 }
 if (-not $BootRoot) { Add-RollbackResult 'boot partition the installer created' 'Left' 'its files could not be checked, so it is not deleted'; return $false }
 $foreign = @(Get-ForeignFiles $BootRoot)
 if ($foreign.Count) {
  Add-RollbackResult 'boot partition the installer created' 'Left' ('it also holds files the installer did not write (' + (($foreign | Select-Object -First 3) -join ', ') + '), so it is not deleted'); return $false
 }
 if ($DryRun) { Add-RollbackResult 'boot partition the installer created' 'WouldDo' ('ask, then delete disk {0} partition {1} ({2})' -f $want.Disk, $want.Number, (Format-Size $now.SizeBytes)); return $false }
 Write-Plain ''
 Write-Plain ('The installer created a {0} partition (disk {1}, partition {2}, drive {3}:, label {4}). It now holds only the installer''s own files.' -f (Format-Size $now.SizeBytes), $want.Disk, $want.Number, $now.DriveLetter, $script:UnlockLabel)
 Write-Plain 'Deleting it removes the unlock boot programs and the logs on it for good.'
 if (-not (Ask-Phrase 'Delete this partition?' 'DELETE')) { Add-RollbackResult 'boot partition the installer created' 'Left' 'you chose to keep it'; return $false }
 try { Invoke-SysRemovePartition ([int]$want.Disk) ([int]$want.Number); Add-RollbackResult 'boot partition the installer created' 'Removed'; $true }
 catch { Add-RollbackResult 'boot partition the installer created' 'Left' ('Windows could not delete it: ' + $_.Exception.Message); $false }
}

# Gives the space back to C: if the installer shrank it. Always asked first, with the exact sizes and a typed word.
function Undo-ShrinkC($Entries, [switch]$DryRun) {
 $sh = @(Get-JournalEntries $Entries 'shrink C:') | Select-Object -First 1
 if (-not $sh) { return }
 $prev = [int64](Get-JournalPrevious $sh 'CSizeBytes')
 $c = Get-SysCSize
 if ($c.SizeBytes -ge $prev) { Add-RollbackResult 'drive C: size' 'AlreadyGone' 'C: is already its original size'; return }
 if ($c.MaxSizeBytes -lt $prev) {
  Add-RollbackResult 'drive C: size' 'Left' ('C: can grow to only {0}, its original size was {1}: the space after C: is not free (an unfinished partition may still be there; look in Disk Management, delete it, then run Roll back again)' -f (Format-Size $c.MaxSizeBytes), (Format-Size $prev)); return
 }
 if ($DryRun) { Add-RollbackResult 'drive C: size' 'WouldDo' ('ask, then extend C: from {0} to {1}' -f (Format-Size $c.SizeBytes), (Format-Size $prev)); return }
 Write-Plain ''
 Write-Plain 'The installer made drive C: smaller to create the boot partition. It can give that space back.'
 Write-Plain ('  C: now:   {0}' -f (Format-Size $c.SizeBytes))
 Write-Plain ('  C: after: {0}  (its size before the installer)' -f (Format-Size $prev))
 Write-Plain 'Extending C: moves no files, but it is a change to your Windows drive.'
 if (-not (Ask-Phrase 'Give the space back to C:?' 'EXTEND')) { Add-RollbackResult 'drive C: size' 'Left' 'you chose not to extend C:; the space stays unallocated and can be added later in Disk Management'; return }
 try { Invoke-SysResizeC $prev; Add-RollbackResult 'drive C: size' 'Removed' ('C: is {0} again' -f (Format-Size $prev)) }
 catch { Add-RollbackResult 'drive C: size' 'Left' ('Windows could not extend C:: ' + $_.Exception.Message) }
}

# Deletes a folder only if it lies inside the installer's own work folder.
function Remove-WorkFolder([string]$Path, [string]$Label, [switch]$DryRun) {
 $work = [IO.Path]::GetFullPath((Get-WorkRoot)).TrimEnd('\') + '\'
 $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
 if (-not $full.StartsWith($work, [StringComparison]::OrdinalIgnoreCase) -or $full.Length -le $work.Length) { Add-RollbackResult $Label 'Left' 'it is outside the installer''s work folder, so it is not touched'; return }
 if (-not (Test-Path -LiteralPath $Path)) { Add-RollbackResult $Label 'AlreadyGone'; return }
 if ($DryRun) { Add-RollbackResult $Label 'WouldDo' 'delete'; return }
 Remove-Item -LiteralPath $Path -Recurse -Force
 Add-RollbackResult $Label 'Removed'
}

function Undo-LocalFiles($State, $Entries, [switch]$DryRun) {
 foreach ($e in (Get-JournalEntries $Entries 'write local partition configuration')) {
  if (Test-Path -LiteralPath $e.Target) { if ($DryRun) { Add-RollbackResult 'local partition configuration' 'WouldDo' 'delete' } else { Remove-Item -LiteralPath $e.Target -Force; Add-RollbackResult 'local partition configuration' 'Removed' } }
  else { Add-RollbackResult 'local partition configuration' 'AlreadyGone' }
 }
 if (Get-Command Test-NoEscPatchApplied -ErrorAction SilentlyContinue) {
  if (-not $DryRun -and (Test-NoEscPatchApplied)) { try { Undo-NoEscPatch; Add-RollbackResult 'no-cancel patch in the source folder' 'Removed' } catch { Add-RollbackResult 'no-cancel patch in the source folder' 'Left' $_.Exception.Message } }
 }
 $work = Get-WorkRoot
 $keep = @()
 $assets = Join-Path $work 'assets'
 if (Test-Path -LiteralPath $assets) {
  $mb = [math]::Round((Get-ChildItem -LiteralPath $assets -Recurse -File -Force | Measure-Object Length -Sum).Sum / 1MB, 1)
  if ($DryRun) { Add-RollbackResult 'NVIDIA firmware files the installer generated' 'WouldDo' 'ask whether to keep or delete them' ; $keep += $assets }
  else {
   Write-Plain ''
   Write-Plain ('The installer generated NVIDIA firmware files on this PC ({0} MB). They take a few minutes to make again and a new install can reuse them.' -f $mb)
   if (Ask-YesNo 'Delete them?') { Remove-WorkFolder $assets 'NVIDIA firmware files the installer generated' } else { $keep += $assets; Add-RollbackResult 'NVIDIA firmware files the installer generated' 'Kept' $assets }
  }
 }
 $bench = Join-Path $work 'benchmark'
 if (Test-Path -LiteralPath $bench) {
  $mb = [math]::Round((Get-ChildItem -LiteralPath $bench -Recurse -File -Force | Measure-Object Length -Sum).Sum / 1MB, 1)
  if ($DryRun) { Add-RollbackResult 'benchmark download (CUDA files)' 'WouldDo' 'ask whether to keep or delete it'; $keep += $bench }
  else {
   Write-Plain ''
   Write-Plain ('The benchmark download and build is on this PC ({0} MB). A new install can reuse it.' -f $mb)
   if (Ask-YesNo 'Delete it?') { Remove-WorkFolder $bench 'benchmark download (CUDA files)' } else { $keep += $bench; Add-RollbackResult 'benchmark download (CUDA files)' 'Kept' $bench }
  }
 }
 # everything else in the work folder (diagnostic, captured card image, profile, build output, test logs)
 if (Test-Path -LiteralPath $work) {
  foreach ($d in @(Get-ChildItem -LiteralPath $work -Force)) {
   if ($keep -contains $d.FullName) { continue }
   Remove-WorkFolder $d.FullName ('working file ' + $d.Name) -DryRun:$DryRun
  }
 }
 foreach ($e in @($Entries | Where-Object { $_.Action -like 'install *' })) { Add-RollbackResult ('build tool ' + $e.Target) 'Kept' 'left installed; remove it in Settings > Apps if you do not need it' }
}

function Write-RollbackChecklist([string]$BackupFolder) {
 Write-Plain ''
 Write-Plain 'Roll back finished. What happened:'
 $label = @{ Removed = 'removed'; AlreadyGone = 'already gone'; Left = 'LEFT'; Kept = 'kept'; WouldDo = 'would do' }
 foreach ($r in $script:RollbackResults) {
  $line = '  [{0}] {1}' -f $label[$r.Outcome], $r.Item
  if ($r.Detail) { $line += ': ' + $r.Detail }
  Write-Plain $line
 }
 if ($BackupFolder -and (Test-Path -LiteralPath (Join-Path $BackupFolder 'fast-startup.json'))) {
  try {
   $c = Compare-WithBackup $BackupFolder
   Write-Plain ''
   Write-Plain ('  Fast Startup is {0} the value it had before the installer.' -f $(if ($c.FastStartup) { 'back to' } else { 'NOT the same as' }))
   Write-Plain ('  The firmware boot order is {0} before the installer.' -f $(if ($c.DisplayOrder) { 'the same as' } else { 'NOT the same as' }))
  } catch { Write-Plain ('  Could not re-read the settings to compare them: ' + $_.Exception.Message) }
 }
 $left = @($script:RollbackResults | Where-Object Outcome -eq 'Left')
 if ($left.Count) { Write-Plain ''; Write-Plain ('{0} item(s) were left on purpose. The lines marked LEFT say why.' -f $left.Count) }
 Write-Plain 'Your reports, logs and backups were kept.'
}

# The whole roll back. Returns @{ Finished; Cancelled; NeedsRestart; Results }.
function Invoke-Rollback([switch]$DryRun) {
 $script:RollbackResults = New-Object System.Collections.ArrayList
 $script:RollbackNeedsRestart = $false
 $state = Read-InstallerState
 $entries = @(Read-Journal)
 Write-Plain ''
 foreach ($l in (Get-RollbackExplanation)) { Write-Plain $l }
 Write-Plain ''
 if ($state.Phase -eq 'new' -and -not $entries.Count) {
  Write-Plain 'The installer has not changed anything on this PC, so there is nothing to roll back.'
  if (-not $DryRun) { Remove-ResumeEntry }
  return [pscustomobject]@{ Finished = $true; Cancelled = $false; NeedsRestart = $false; Results = @() }
 }
 if ($DryRun) { Write-Plain 'DRY RUN: this shows what Roll back would do; nothing is changed and no question is asked.' }
 elseif (-not (Ask-YesNo 'Roll back now?')) { Write-Plain 'Nothing was changed.'; return [pscustomobject]@{ Finished = $false; Cancelled = $true; NeedsRestart = $false; Results = @() } }

 Undo-ResumeEntry -DryRun:$DryRun
 Undo-QueuedBoot $entries -DryRun:$DryRun
 Undo-EveryBoot $state $entries -DryRun:$DryRun
 Undo-Shortcuts $entries -DryRun:$DryRun
 $root = Resolve-RollbackBootRoot $state
 $bootRoot = $root.Root
 Undo-StagedFiles $state $entries $bootRoot $root.Reason -DryRun:$DryRun
 [void](Undo-BootPartition $state $entries $bootRoot -DryRun:$DryRun)
 Undo-ShrinkC $entries -DryRun:$DryRun
 Undo-LocalFiles $state $entries -DryRun:$DryRun
 Write-RollbackChecklist $(if ($state.Contains('BackupFolder')) { $state.BackupFolder } else { $null })

 if (-not $DryRun) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  if (Test-Path -LiteralPath (Get-JournalPath)) { Move-Item -LiteralPath (Get-JournalPath) -Destination (Join-Path (Get-InstallerRoot) "journal-rolled-back-$stamp.jsonl") -Force }
  if (Test-Path -LiteralPath (Get-StatePath)) { Remove-Item -LiteralPath (Get-StatePath) -Force }
  Remove-ResumeEntry
  if ($script:RollbackNeedsRestart) { [void](Request-Restart 'Windows GPU Unlock installer: finishing the roll back.') }
 }
 [pscustomobject]@{ Finished = $true; Cancelled = $false; NeedsRestart = $script:RollbackNeedsRestart; Results = @($script:RollbackResults) }
}
