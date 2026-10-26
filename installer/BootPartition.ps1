# Boot partition choice (plan requirement 9). The user always chooses; nothing is picked or defaulted.
# Needs Ui.ps1 and State.ps1. System queries and changes sit in Get-Sys* / Invoke-Sys* so tests can replace them.

$script:EspType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:PartitionBytes = 2GB
$script:ShrinkExtraBytes = 16MB      # alignment slack so a 2 GiB partition fits in the freed space
$script:KeepFreeOnCBytes = 10GB      # C: must keep at least this much free space after a shrink
$script:UnlockLabel = 'GPUUNLOCK'

# --- system queries / changes (replaceable in tests) ---
function Get-SysDiskLayout {
 $c = Get-Partition -DriveLetter C -ErrorAction Stop
 $sup = Get-PartitionSupportedSize -DriveLetter C
 $cv = Get-Volume -DriveLetter C
 $disks = @(Get-Disk | ForEach-Object {
  [pscustomobject]@{ Number = $_.Number; BusType = [string]$_.BusType; PartitionStyle = [string]$_.PartitionStyle; IsSystem = [bool]$_.IsSystem
   IsOffline = [bool]$_.IsOffline; SizeBytes = [int64]$_.Size; LargestFreeBytes = [int64]$_.LargestFreeExtent; Name = $_.FriendlyName }
 })
 $parts = @(Get-Partition | ForEach-Object {
  $v = $_ | Get-Volume -ErrorAction SilentlyContinue
  [pscustomobject]@{ Disk = $_.DiskNumber; Number = $_.PartitionNumber; Guid = [string]$_.Guid; GptType = [string]$_.GptType
   IsWindowsEsp = ([bool]$_.IsSystem -and $_.GptType -eq $script:EspType); FileSystem = $(if ($v) { [string]$v.FileSystem } else { '' })
   Label = $(if ($v) { [string]$v.FileSystemLabel } else { '' }); SizeBytes = [int64]$_.Size; DriveLetter = $(if ($_.DriveLetter) { [string]$_.DriveLetter } else { '' }) }
 })
 [pscustomobject]@{ WindowsDisk = $c.DiskNumber; CSizeBytes = [int64]$c.Size; CShrinkableBytes = [int64]($c.Size - $sup.SizeMin); CFreeBytes = [int64]$cv.SizeRemaining; Disks = $disks; Partitions = $parts }
}
function Invoke-SysResizeC([int64]$NewSizeBytes) { Resize-Partition -DriveLetter C -Size $NewSizeBytes -ErrorAction Stop }
# Creates the ESP-type partition on a disk, formats it FAT32 with the unlock label and gives it a drive letter. Returns its record.
function Get-SysCEndOffset { $c = Get-Partition -DriveLetter C -ErrorAction Stop; [int64]($c.Offset + $c.Size) }
function Invoke-SysNewDedicatedPartition([int]$DiskNumber, [int64]$SizeBytes, [string]$Label, [int64]$OffsetBytes = 0) {
 # With an offset (right after a C: shrink) the partition is created exactly in the space that was just freed, not in some other free extent.
 $p = if ($OffsetBytes -gt 0) { New-Partition -DiskNumber $DiskNumber -Size $SizeBytes -Offset $OffsetBytes -GptType $script:EspType -ErrorAction Stop }
  else { New-Partition -DiskNumber $DiskNumber -Size $SizeBytes -GptType $script:EspType -ErrorAction Stop }
 [void](Format-Volume -Partition $p -FileSystem FAT32 -NewFileSystemLabel $Label -Confirm:$false -ErrorAction Stop)
 Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -AssignDriveLetter -ErrorAction Stop
 $q = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber
 [pscustomobject]@{ Disk = $DiskNumber; Number = $q.PartitionNumber; Guid = [string]$q.Guid; DriveLetter = [string]$q.DriveLetter; SizeBytes = [int64]$q.Size; Offset = [int64]$q.Offset }
}

function Invoke-SysAssignLetter([int]$Disk, [int]$Number) {
 Add-PartitionAccessPath -DiskNumber $Disk -PartitionNumber $Number -AssignDriveLetter -ErrorAction Stop
 [string](Get-Partition -DiskNumber $Disk -PartitionNumber $Number).DriveLetter
}

function Format-GiB([int64]$Bytes) { '{0:N2} GiB' -f ($Bytes / 1GB) }

# --- decisions (pure) ---
function Test-InternalDisk($Layout, $DiskNumber) {
 $d = @($Layout.Disks | Where-Object Number -eq $DiskNumber) | Select-Object -First 1
 [bool]$d -and $d.BusType -notin 'USB', 'SD', 'MMC', 'Virtual', 'File Backed Virtual'
}
function Test-EspCandidate($p) { $p.GptType -eq $script:EspType -and -not $p.IsWindowsEsp -and $p.FileSystem -eq 'FAT32' -and $p.SizeBytes -ge 1GB }
# A partition is used without being created only if it is labelled GPUUNLOCK (so it is clearly the one made for this) and sits on an
# internal disk. Any other EFI-type partition may belong to another operating system, and a USB disk can be unplugged.
function Find-DedicatedPartitions($Layout) {
 @($Layout.Partitions | Where-Object { (Test-EspCandidate $_) -and $_.Label -ceq $script:UnlockLabel -and (Test-InternalDisk $Layout $_.Disk) })
}
# EFI-type partitions that were found but are NOT used, for the message that explains why.
function Find-UnusedEspPartitions($Layout) {
 $ded = @(Find-DedicatedPartitions $Layout)
 @($Layout.Partitions | Where-Object { (Test-EspCandidate $_) -and -not ($ded | Where-Object { $_.Disk -eq $_.Disk }) } | Where-Object { $p = $_; -not ($ded | Where-Object { $_.Disk -eq $p.Disk -and $_.Number -eq $p.Number }) })
}
function Find-AlternateDisks($Layout) {
 @($Layout.Disks | Where-Object {
  -not $_.IsSystem -and $_.Number -ne $Layout.WindowsDisk -and -not $_.IsOffline -and $_.PartitionStyle -eq 'GPT' -and
  $_.BusType -notin 'USB', 'SD', 'MMC', 'Virtual', 'File Backed Virtual' -and $_.LargestFreeBytes -ge ($script:PartitionBytes + 1MB) })
}
function Test-CanShrinkC($Layout) {
 $need = $script:PartitionBytes + $script:ShrinkExtraBytes
 $Layout.CShrinkableBytes -ge $need -and ($Layout.CFreeBytes - $need) -ge $script:KeepFreeOnCBytes
}

# Returns a decision: @{ Kind = Existing | Alternate | Shrink; ... } or $null (nothing changed).
function Select-BootPartition($Layout) {
 $ded = @(Find-DedicatedPartitions $Layout)
 if ($ded.Count -eq 1) {
  $d = $ded[0]
  Write-Plain ('A dedicated boot partition already exists and will be used: drive {0}: ({1}, {2}, label "{3}").' -f $(if ($d.DriveLetter) { $d.DriveLetter } else { '(no letter)' }), $d.FileSystem, (Format-GiB $d.SizeBytes), $d.Label)
  return [ordered]@{ Kind = 'Existing'; Disk = $d.Disk; Number = $d.Number; Guid = $d.Guid; DriveLetter = $d.DriveLetter }
 }
 if ($ded.Count -gt 1) {
  Write-Plain 'More than one possible dedicated boot partition exists:'
  for ($i = 0; $i -lt $ded.Count; $i++) { Write-Plain ('  {0}. disk {1} partition {2}, drive {3}, {4}, label "{5}"' -f ($i + 1), $ded[$i].Disk, $ded[$i].Number, $(if ($ded[$i].DriveLetter) { $ded[$i].DriveLetter + ':' } else { '(no letter)' }), (Format-GiB $ded[$i].SizeBytes), $ded[$i].Label) }
  $n = Ask-Number 'Which one should be used?' $ded.Count
  if ($null -eq $n) { Write-Plain 'Nothing was changed.'; return $null }
  $d = $ded[$n - 1]
  return [ordered]@{ Kind = 'Existing'; Disk = $d.Disk; Number = $d.Number; Guid = $d.Guid; DriveLetter = $d.DriveLetter }
 }

 foreach ($u in (Find-UnusedEspPartitions $Layout)) {
  $why = if (-not (Test-InternalDisk $Layout $u.Disk)) { 'it is on a removable or USB disk' } else { 'it is not labelled ' + $script:UnlockLabel }
  Write-Plain ('Found but not used: disk {0} partition {1} (label "{2}", {3}): {4}. It may belong to another operating system. If you made it for this installer, give it the label {5} and run the installer again.' -f $u.Disk, $u.Number, $u.Label, (Format-GiB $u.SizeBytes), $why, $script:UnlockLabel)
 }
 $options = @()
 foreach ($a in (Find-AlternateDisks $Layout)) { $options += [pscustomobject]@{ Kind = 'Alternate'; Disk = $a } }
 if (Test-CanShrinkC $Layout) { $options += [pscustomobject]@{ Kind = 'Shrink' } }
 Write-Plain 'There is no dedicated boot partition on this PC. The installer needs a small FAT32 partition of 2 GiB. You choose where it goes.'
 if (-not $options.Count) {
  Write-Plain ('No option is available: C: cannot give back {0} and keep {1} free, and no other internal GPT drive has {2} of unallocated space. Nothing was changed.' -f (Format-GiB ($script:PartitionBytes + $script:ShrinkExtraBytes)), (Format-GiB $script:KeepFreeOnCBytes), (Format-GiB $script:PartitionBytes))
  return $null
 }
 for ($i = 0; $i -lt $options.Count; $i++) {
  $o = $options[$i]
  if ($o.Kind -eq 'Shrink') { Write-Plain ('  {0}. Shrink drive C: by {1} (C: is now {2}, free {3}) and create the partition in the freed space.' -f ($i + 1), (Format-GiB ($script:PartitionBytes + $script:ShrinkExtraBytes)), (Format-GiB $Layout.CSizeBytes), (Format-GiB $Layout.CFreeBytes)) }
  else { $dk = $Layout.Disks | Where-Object Number -eq $o.Disk.Number; Write-Plain ('  {0}. Use another drive: disk {1} ({2}, {3}, {4} unallocated). A 2 GiB partition is created in its unallocated space; nothing else on that disk is changed.' -f ($i + 1), $dk.Number, $dk.Name, $dk.BusType, (Format-GiB $dk.LargestFreeBytes)) }
 }
 $n = Ask-Number 'Which option do you want?' $options.Count
 if ($null -eq $n) { Write-Plain 'Nothing was changed.'; return $null }
 $o = $options[$n - 1]
 if ($o.Kind -eq 'Shrink') {
  $total = $script:PartitionBytes + $script:ShrinkExtraBytes
  Write-Plain ''
  Write-Plain 'Shrinking C: moves no files, but it is a change to your Windows drive.'
  Write-Plain ('  C: now:   {0}' -f (Format-GiB $Layout.CSizeBytes))
  Write-Plain ('  C: after: {0}' -f (Format-GiB ($Layout.CSizeBytes - $total)))
  Write-Plain ('  New partition: {0} FAT32, label {1}' -f (Format-GiB $script:PartitionBytes), $script:UnlockLabel)
  if (-not (Ask-Phrase 'This is separate from the choice above.' 'SHRINK')) { Write-Plain 'Nothing was changed.'; return $null }
  return [ordered]@{ Kind = 'Shrink'; Disk = $Layout.WindowsDisk; CSizeBytes = $Layout.CSizeBytes; ShrinkBytes = $total }
 }
 $dk = $Layout.Disks | Where-Object Number -eq $o.Disk.Number
 if (-not (Ask-YesNo ('Create a {0} partition on disk {1} ({2})?' -f (Format-GiB $script:PartitionBytes), $dk.Number, $dk.Name))) { Write-Plain 'Nothing was changed.'; return $null }
 [ordered]@{ Kind = 'Alternate'; Disk = $dk.Number }
}

# Carries out a decision. Returns the partition record to store in the state. Every change is journaled first.
function New-BootPartition($Decision, [switch]$DryRun) {
 if ($Decision.Kind -eq 'Existing') {
  $letter = [string]$Decision.DriveLetter
  if (-not $letter) {
   # the partition exists but has no drive letter; the installer needs one to copy files
   [void](Invoke-JournaledChange -Phase 'partition' -Action 'give the boot partition a drive letter' -Target ('disk {0} partition {1}' -f $Decision.Disk, $Decision.Number) `
    -Undo 'remove the drive letter again' -DryRun:$DryRun -Do { $script:__letter = Invoke-SysAssignLetter $Decision.Disk $Decision.Number })
   $letter = if ($DryRun) { 'X' } else { $script:__letter }
  }
  return [ordered]@{ Disk = $Decision.Disk; Number = $Decision.Number; Guid = $Decision.Guid; DriveLetter = $letter; Created = $false; ShrankC = $false }
 }
 $shrank = $false
 if ($Decision.Kind -eq 'Shrink') {
  [void](Invoke-JournaledChange -Phase 'partition' -Action 'shrink C:' -Target ('C: {0} -> {1} bytes' -f $Decision.CSizeBytes, ($Decision.CSizeBytes - $Decision.ShrinkBytes)) `
   -Previous ([ordered]@{ CSizeBytes = $Decision.CSizeBytes }) -Undo 'extend C: back to its previous size (asks first)' -DryRun:$DryRun -Do { Invoke-SysResizeC ($Decision.CSizeBytes - $Decision.ShrinkBytes) })
  $shrank = $true
 }
 $made = $null
 $freedAt = 0
 if ($shrank -and -not $DryRun) { $freedAt = Get-SysCEndOffset }   # the freed space starts right where C: now ends
 $id = Invoke-JournaledChange -Phase 'partition' -Action 'create boot partition' -Target ('disk {0}, 2 GiB FAT32 {1}' -f $Decision.Disk, $script:UnlockLabel) `
  -Undo 'delete this partition only if it is still empty of other data (asks first)' -DryRun:$DryRun -Do {
   $newPart = Invoke-SysNewDedicatedPartition $Decision.Disk $script:PartitionBytes $script:UnlockLabel $freedAt
   $script:__made = $newPart
   # Record the new partition's identity at once, so Roll back can find it even if the check below fails.
   $idEntry = Add-JournalEntry -Phase 'partition' -Action 'created partition identity' -Target ('disk {0} partition {1}' -f $newPart.Disk, $newPart.Number) `
    -Previous ([ordered]@{ Disk = $newPart.Disk; Number = $newPart.Number; Guid = $newPart.Guid; Offset = $newPart.Offset; SizeBytes = $newPart.SizeBytes }) -Undo 'delete this partition if it holds only the installer''s files (asks first)'
   Set-JournalStatus $idEntry 'done'
   if ($freedAt -gt 0 -and $newPart.Offset -ne $freedAt) { throw ('The new partition was created at {0}, not in the space freed from C: ({1}). Nothing else was changed; Roll back will offer to remove it and give the space back to C:.' -f $newPart.Offset, $freedAt) }
  }
 if ($DryRun) { return [ordered]@{ Disk = $Decision.Disk; Number = 0; Guid = ''; DriveLetter = ''; Created = $true; ShrankC = $shrank; DryRun = $true } }
 $made = $script:__made
 [ordered]@{ Disk = $made.Disk; Number = $made.Number; Guid = $made.Guid; DriveLetter = $made.DriveLetter; Created = $true; ShrankC = $shrank; JournalId = $id; CShrinkBytes = $(if ($shrank) { $Decision.ShrinkBytes } else { 0 }) }
}
