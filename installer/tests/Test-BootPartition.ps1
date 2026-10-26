# Boot partition choice, partition creation order, backups and plan screen tests (plan requirements 9, 12, 30), all mocked.
$base = Split-Path -Parent $PSScriptRoot
. (Join-Path $base 'Ui.ps1'); . (Join-Path $base 'State.ps1'); . (Join-Path $base 'Checks.ps1'); . (Join-Path $base 'BootPartition.ps1'); . (Join-Path $base 'Backup.ps1'); . (Join-Path $base 'Plan.ps1')
. (Join-Path $PSScriptRoot 'Harness.ps1')

$ESP = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
function Part($Disk, $Num, $Type, $Fs, $Label, $Size, $Letter = '', $WinEsp = $false) {
 [pscustomobject]@{ Disk = $Disk; Number = $Num; Guid = "{guid-$Disk-$Num}"; GptType = $Type; IsWindowsEsp = $WinEsp; FileSystem = $Fs; Label = $Label; SizeBytes = [int64]$Size; DriveLetter = $Letter }
}
function Disk($Num, $Bus, $Free, $Sys = $false, $Style = 'GPT', $Offline = $false) {
 [pscustomobject]@{ Number = $Num; BusType = $Bus; PartitionStyle = $Style; IsSystem = $Sys; IsOffline = $Offline; SizeBytes = [int64]1TB; LargestFreeBytes = [int64]$Free; Name = "Disk $Num" }
}
function Layout($Parts, $Disks, $CShrink = 155GB, $CFree = 400GB) {
 [pscustomobject]@{ WindowsDisk = 0; CSizeBytes = [int64]1860GB; CShrinkableBytes = [int64]$CShrink; CFreeBytes = [int64]$CFree; Disks = $Disks; Partitions = $Parts }
}
$winEsp = Part 0 1 $ESP 'FAT32' '' 100MB '' $true
$cPart = Part 0 3 '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' 'NTFS' '' 1860GB 'C'
$dedicated = Part 0 4 $ESP 'FAT32' 'GPUUNLOCK' 2GB 'U'

# --- classification ---
$L = Layout @($winEsp, $cPart, $dedicated) @((Disk 0 'NVMe' 0 $true))
Expect 'one dedicated partition found' (@(Find-DedicatedPartitions $L)).Count 1
$L = Layout @($winEsp, $cPart) @((Disk 0 'NVMe' 0 $true))
Expect 'windows ESP is never dedicated' (@(Find-DedicatedPartitions $L)).Count 0
$L = Layout @($winEsp, (Part 0 4 $ESP 'FAT32' '' 500MB), (Part 0 5 $ESP 'NTFS' '' 2GB), (Part 0 6 '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' 'FAT32' '' 2GB)) @((Disk 0 'NVMe' 0 $true))
Expect 'small, non-FAT32 or wrongly typed partitions are not dedicated' (@(Find-DedicatedPartitions $L)).Count 0

$disks = @((Disk 0 'NVMe' 0 $true), (Disk 1 'USB' 500GB), (Disk 2 'SATA' 100GB), (Disk 3 'NVMe' 1GB), (Disk 4 'SATA' 100GB $false 'MBR'), (Disk 5 'SATA' 100GB $false 'GPT' $true), (Disk 6 'Virtual' 100GB))
$alt = @(Find-AlternateDisks (Layout @() $disks))
Expect 'only the internal GPT online disk with room qualifies' ($alt.Number -join ',') '2'

ExpectTrue 'C: with 155 GiB shrinkable and 400 GiB free can shrink' (Test-CanShrinkC (Layout @() @() 155GB 400GB))
ExpectTrue 'C: that cannot give 2 GiB cannot shrink' (-not (Test-CanShrinkC (Layout @() @() 1GB 400GB)))
ExpectTrue 'C: that would be left with under 10 GiB free cannot shrink' (-not (Test-CanShrinkC (Layout @() @() 155GB 11GB)))

# --- only a partition labelled GPUUNLOCK on an internal disk is used as it is (review item C1) ---
$unlabelled = Part 0 4 $ESP 'FAT32' '' 2GB 'U'
$other = Layout @($winEsp, $cPart, $unlabelled) @((Disk 0 'NVMe' 0 $true))
Expect 'an unlabelled EFI-type partition is not dedicated' (@(Find-DedicatedPartitions $other)).Count 0
Expect 'a partition with another label is not dedicated' (@(Find-DedicatedPartitions (Layout @($winEsp, $cPart, (Part 0 4 $ESP 'FAT32' 'ARCH_ESP' 2GB 'U')) @((Disk 0 'NVMe' 0 $true))))).Count 0
Expect 'the label match is case sensitive' (@(Find-DedicatedPartitions (Layout @($winEsp, $cPart, (Part 0 4 $ESP 'FAT32' 'gpuunlock' 2GB 'U')) @((Disk 0 'NVMe' 0 $true))))).Count 0
$usb = Layout @($winEsp, $cPart, (Part 1 1 $ESP 'FAT32' 'GPUUNLOCK' 2GB 'V')) @((Disk 0 'NVMe' 0 $true), (Disk 1 'USB' 0))
Expect 'a labelled partition on a USB disk is not used' (@(Find-DedicatedPartitions $usb)).Count 0
Expect 'a labelled partition on an internal disk is used' (@(Find-DedicatedPartitions (Layout @($winEsp, $cPart, (Part 1 1 $ESP 'FAT32' 'GPUUNLOCK' 2GB 'V')) @((Disk 0 'NVMe' 0 $true), (Disk 1 'SATA' 0))))).Count 1
Set-Answers @('NONE')
$null = Select-BootPartition $other
ExpectTrue 'the unlabelled partition is reported as found but not used, with the reason and the way to use it' (((OutText) -like '*Found but not used: disk 0 partition 4*') -and ((OutText) -like '*not labelled GPUUNLOCK*') -and ((OutText) -like '*give it the label GPUUNLOCK*'))
Set-Answers @('NONE'); $null = Select-BootPartition $usb
ExpectTrue 'a USB partition is reported as such' ((OutText) -like '*removable or USB disk*')
Set-Answers @('NONE')
$null = Select-BootPartition (Layout @($winEsp, $cPart, $dedicated) @((Disk 0 'NVMe' 0 $true)))
ExpectTrue 'nothing is reported when the labelled partition is used' ((OutText) -notlike '*Found but not used*')

# --- selection ---
# existing dedicated partition: shown, no question
$L = Layout @($winEsp, $cPart, $dedicated) @((Disk 0 'NVMe' 0 $true))
Set-Answers @()
$d = Select-BootPartition $L
Expect 'existing kind' $d.Kind 'Existing'
Expect 'existing letter' $d.DriveLetter 'U'
ExpectTrue 'existing partition is shown' ((OutText) -like '*drive U:*')
# two dedicated: asks
$L2 = Layout @($winEsp, $cPart, $dedicated, (Part 1 1 $ESP 'FAT32' 'GPUUNLOCK' 2GB 'V')) @((Disk 0 'NVMe' 0 $true), (Disk 1 'NVMe' 0))
Set-Answers @('2'); $d = Select-BootPartition $L2
Expect 'second dedicated chosen' $d.Number 1
Set-Answers @('NONE'); ExpectTrue 'NONE with two dedicated changes nothing' ($null -eq (Select-BootPartition $L2))

# none exists: options listed, never defaulted
$bare = Layout @($winEsp, $cPart) @((Disk 0 'NVMe' 0 $true), (Disk 2 'SATA' 100GB))
Set-Answers @('NONE')
ExpectTrue 'declining both stops with nothing changed' ($null -eq (Select-BootPartition $bare))
ExpectTrue 'both options were listed' (((OutText) -like '*Use another drive*') -and ((OutText) -like '*Shrink drive C:*'))
Set-Answers @('')
ExpectThrows 'an empty answer is not a choice (the prompt repeats until answered)' { Select-BootPartition $bare } '*UNEXPECTED QUESTION*'
# choose the alternate drive, confirm Y
Set-Answers @('1', 'Y'); $d = Select-BootPartition $bare
Expect 'alternate kind' $d.Kind 'Alternate'
Expect 'alternate disk' $d.Disk 2
Set-Answers @('1', 'N'); ExpectTrue 'declining the alternate drive changes nothing' ($null -eq (Select-BootPartition $bare))
# choose shrink: needs the separate SHRINK phrase and shows exact sizes
Set-Answers @('2', 'SHRINK'); $d = Select-BootPartition $bare
Expect 'shrink kind' $d.Kind 'Shrink'
Expect 'shrink bytes include slack' $d.ShrinkBytes (2GB + 16MB)
ExpectTrue 'exact sizes shown' (((OutText) -like '*C: now:   1,860.00 GiB*') -and ((OutText) -like '*C: after: 1,857.98 GiB*'))
Set-Answers @('2', 'yes'); ExpectTrue 'anything but the phrase cancels the shrink' ($null -eq (Select-BootPartition $bare))
Set-Answers @('2', 'shrink'); ExpectTrue 'phrase is case sensitive' ($null -eq (Select-BootPartition $bare))
# only shrink possible / only alternate possible / nothing possible
$onlyShrink = Layout @($winEsp, $cPart) @((Disk 0 'NVMe' 0 $true))
Set-Answers @('1', 'SHRINK'); Expect 'only-shrink layout' (Select-BootPartition $onlyShrink).Kind 'Shrink'
$none = Layout @($winEsp, $cPart) @((Disk 0 'NVMe' 0 $true), (Disk 1 'USB' 500GB)) 1GB 400GB
Set-Answers @(); ExpectTrue 'no option available gives null without questions' ($null -eq (Select-BootPartition $none))
ExpectTrue 'says nothing was changed' ((OutText) -like '*Nothing was changed*')

# --- partition creation: order, sizes, journal, dry run ---
$script:Calls = New-Object System.Collections.ArrayList
function Invoke-SysResizeC([int64]$NewSizeBytes) { [void]$script:Calls.Add("resize C $NewSizeBytes") }
function Invoke-SysNewDedicatedPartition([int]$DiskNumber, [int64]$SizeBytes, [string]$Label, [int64]$OffsetBytes = 0) {
 [void]$script:Calls.Add("new disk $DiskNumber size $SizeBytes label $Label")
 $script:LastOffset = $OffsetBytes
 [pscustomobject]@{ Disk = $DiskNumber; Number = 7; Guid = '{new}'; DriveLetter = 'W'; SizeBytes = $SizeBytes; Offset = $(if ($null -ne $script:LandAt) { $script:LandAt } else { $OffsetBytes }) }
}
$script:LandAt = $null; $script:LastOffset = -1
function Get-SysCEndOffset { [int64]1997139443712 }
$t = New-TestRoot
try {
 $r = New-BootPartition ([ordered]@{ Kind = 'Existing'; Disk = 0; Number = 4; Guid = '{g}'; DriveLetter = 'U' })
 Expect 'existing partition changes nothing' $script:Calls.Count 0
 ExpectTrue 'existing record says not created' (-not $r.Created)

 $r = New-BootPartition ([ordered]@{ Kind = 'Shrink'; Disk = 0; CSizeBytes = [int64]1860GB; ShrinkBytes = [int64](2GB + 16MB) })
 Expect 'shrink first' $script:Calls[0] ('resize C ' + [int64](1860GB - 2GB - 16MB))
 Expect 'then create 2 GiB labelled GPUUNLOCK' $script:Calls[1] ('new disk 0 size ' + [int64]2GB + ' label GPUUNLOCK')
 ExpectTrue 'record shows C: was shrunk' $r.ShrankC
 Expect 'new letter recorded' $r.DriveLetter 'W'
 $j = @(Read-Journal)
 Expect 'three journal entries: the shrink, the creation and the new partition''s identity' $j.Count 3
 Expect 'shrink journaled first' $j[0].Action 'shrink C:'
 Expect 'previous C: size is journaled' $j[0].Previous.CSizeBytes ([int64]1860GB)
 ExpectTrue 'all done' (($j | Where-Object Status -eq 'done').Count -eq 3)

 $script:Calls.Clear()
 $r = New-BootPartition ([ordered]@{ Kind = 'Alternate'; Disk = 2 })
 Expect 'alternate creates only' $script:Calls.Count 1
 ExpectTrue 'alternate did not shrink C:' (-not $r.ShrankC)

 $script:Calls.Clear(); $jBefore = @(Read-Journal).Count
 $r = New-BootPartition ([ordered]@{ Kind = 'Shrink'; Disk = 0; CSizeBytes = [int64]1860GB; ShrinkBytes = [int64](2GB + 16MB) }) -DryRun
 Expect 'dry run makes no system calls' $script:Calls.Count 0
 Expect 'dry run writes no journal' @(Read-Journal).Count $jBefore

 # if creating fails after the shrink, the journal still shows the shrink so Roll back can offer to extend C:
 function Invoke-SysNewDedicatedPartition([int]$DiskNumber, [int64]$SizeBytes, [string]$Label, [int64]$OffsetBytes = 0) { throw 'format failed' }
 ExpectThrows 'a failing create is reported' { New-BootPartition ([ordered]@{ Kind = 'Shrink'; Disk = 0; CSizeBytes = [int64]1860GB; ShrinkBytes = [int64](2GB + 16MB) }) } '*format failed*'
 $j = @(Read-Journal)
 Expect 'failed create is marked failed' $j[-1].Status 'failed'
 Expect 'the shrink before it stays done' $j[-2].Status 'done'
} finally { Remove-TestRoot $t }

# --- the partition must land in the space the shrink freed (review item C2) ---
# (the earlier failure test replaced the mock with one that throws; put the normal one back)
function Invoke-SysNewDedicatedPartition([int]$DiskNumber, [int64]$SizeBytes, [string]$Label, [int64]$OffsetBytes = 0) {
 [void]$script:Calls.Add("new disk $DiskNumber size $SizeBytes label $Label")
 $script:LastOffset = $OffsetBytes
 [pscustomobject]@{ Disk = $DiskNumber; Number = 7; Guid = '{new}'; DriveLetter = 'W'; SizeBytes = $SizeBytes; Offset = $(if ($null -ne $script:LandAt) { $script:LandAt } else { $OffsetBytes }) }
}
$t = New-TestRoot
try {
 $script:Calls.Clear(); $script:LandAt = [int64]5000000000000     # the partition tool picked some other free extent
 ExpectThrows 'a partition created somewhere else is an error' { New-BootPartition ([ordered]@{ Kind = 'Shrink'; Disk = 0; CSizeBytes = [int64]1860GB; ShrinkBytes = [int64](2GB + 16MB) }) } '*not in the space freed from C:*'
 $j = @(Read-Journal)
 $idEntry = @($j | Where-Object Action -eq 'created partition identity')
 Expect 'its identity was journaled before the check, so Roll back can find it' $idEntry.Count 1
 Expect 'identity: disk and number' ('{0}/{1}' -f $idEntry[0].Previous.Disk, $idEntry[0].Previous.Number) '0/7'
 Expect 'the create step is marked failed' (@($j | Where-Object Action -eq 'create boot partition')[0].Status) 'failed'
 Expect 'the shrink before it stays done' (@($j | Where-Object Action -eq 'shrink C:')[0].Status) 'done'
 $script:LandAt = $null
 $script:Calls.Clear()
 $r = New-BootPartition ([ordered]@{ Kind = 'Shrink'; Disk = 0; CSizeBytes = [int64]1860GB; ShrinkBytes = [int64](2GB + 16MB) })
 Expect 'when it lands where C: now ends the creation succeeds' $r.DriveLetter 'W'
 Expect 'the offset passed to the partition tool is the end of C:' $script:LastOffset ([int64]1997139443712)
} finally { Remove-TestRoot $t }

# --- backup ---
$t = New-TestRoot
try {
 function Invoke-SysBcdExport([string]$Path) { Set-Content -LiteralPath $Path -Value 'bcd' }
 function Get-SysBcdText([string[]]$BcdArgs) { if ($BcdArgs -contains '{fwbootmgr}') { "displayorder {bootmgr}`r`nbootsequence {abc}" } else { 'entries' } }
 function Get-SysPartitionTable { @([pscustomobject]@{ DiskNumber = 0; PartitionNumber = 1 }) }
 function Get-SysFastStartup { 0 }
 $dir = Backup-SystemState -Stamp 'T1'
 foreach ($f in 'bcd-store', 'firmware-entries.txt', 'fwbootmgr.txt', 'partition-table.json', 'fast-startup.json') { ExpectTrue "backup has $f" (Test-Path -LiteralPath (Join-Path $dir $f)) }
 ExpectTrue 'backup folder is inside the installer folder' ($dir.StartsWith((Get-InstallerRoot)))
 $cmp = Compare-WithBackup $dir
 ExpectTrue 'unchanged PC compares equal (Fast Startup)' $cmp.FastStartup
 ExpectTrue 'unchanged PC compares equal (boot order)' $cmp.DisplayOrder
 function Get-SysFastStartup { 1 }
 ExpectTrue 'changed Fast Startup is noticed' (-not (Compare-WithBackup $dir).FastStartup)
 function Get-SysFastStartup { 0 }
 function Get-SysBcdText([string[]]$BcdArgs) { "displayorder {abc}`r`n" }
 ExpectTrue 'changed boot order is noticed' (-not (Compare-WithBackup $dir).DisplayOrder)
 $before = @(Get-ChildItem (Join-Path (Get-InstallerRoot) 'Backups')).Count
 [void](Backup-SystemState -Stamp 'T2' -DryRun)
 Expect 'dry run backup writes nothing' @(Get-ChildItem (Join-Path (Get-InstallerRoot) 'Backups')).Count $before
} finally { Remove-TestRoot $t }

# --- plan ---
$st = [ordered]@{ BootPartition = [ordered]@{ Kind = 'Shrink'; Disk = 0; CSizeBytes = [int64]1860GB; ShrinkBytes = [int64](2GB + 16MB) } }
$items = @(Get-FullPlan $st)
ExpectTrue 'plan mentions the shrink with exact sizes' (@($items | Where-Object { $_.What -like '*Shrink drive C: by 2.02 GiB (from 1,860.00 GiB)*' }).Count -eq 1)
Set-Answers @('Y'); ExpectTrue 'Y confirms the plan' (Confirm-Plan $items)
ExpectTrue 'plan screen states what is never changed' ((OutText) -like '*never changes the permanent boot order*')
Set-Answers @('N'); ExpectTrue 'N declines the plan' (-not (Confirm-Plan $items))
$items2 = @(Get-FullPlan ([ordered]@{ BootPartition = [ordered]@{ Kind = 'Existing'; Disk = 0; Number = 4 } }))
ExpectTrue 'existing partition plan says nothing is resized' (@($items2 | Where-Object { $_.What -like '*Nothing is resized*' }).Count -eq 1)
ExpectTrue 'every plan item names how to undo or says nothing to undo' (@($items2 | Where-Object { -not $_.Undo -and $_.Known }).Count -eq 0)
ExpectTrue 'plan is never silent about the restart' (@($items | Where-Object { $_.What -like '*you confirm the restart*' }).Count -ge 1)

Complete-Tests
