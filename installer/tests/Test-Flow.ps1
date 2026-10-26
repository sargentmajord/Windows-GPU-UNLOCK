# End-to-end phase loop tests (resume, dry run, stops) with every system query mocked.
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')

$ESP = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
function A($Name, $Dev, $Sub, $Bus, $Ven = '10DE') { $b = $Bus -split '[:.]'; [pscustomobject]@{ Name = $Name; InstanceId = "PCI\VEN_$Ven&DEV_$Dev&SUBSYS_$Sub\X"; Location = ('PCI bus {0}, device {1}, function {2}' -f [int]$b[0], [int]$b[1], [int]$b[2]) } }
$script:Adapters = @((A 'NVIDIA GeForce RTX 3060' '2544' '397D1462' '01:00.0'), (A 'NVIDIA GeForce RTX 5070' '2F04' '89F21043' '02:00.0'))
function Get-SysAdapters { $script:Adapters }
function Get-SysNvidiaSmi { @() }

# this file covers the phases up to the boot partition; the capture phases have their own tests (Test-Capture.ps1)
function Get-ToolStatus { @('llvm', 'python', 'msvc' | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $_; Ok = $true; Detail = 'found'; Info = $null } }) }
function Invoke-Phase-diag-build($State, $Opt) { @{ Next = 'done' } }

# a PC where every check passes
function Get-SysIsAdmin { $true }
function Get-SysOs { [pscustomobject]@{ Build = 26300; Is64 = $true; Caption = 'Windows 11' } }
function Get-SysBootMgrPath { '\EFI\Microsoft\Boot\bootmgfw.efi' }
function Get-SysSecureBoot { 'Off' }
function Get-SysBitLocker { [pscustomobject]@{ Known = $true; ProtectionStatus = 0; ConversionStatus = 0 } }
function Get-SysChassis { [pscustomobject]@{ Types = @(3); Manufacturer = 'X'; Model = 'Y' } }
function Get-SysFastStartup { 0 }
function Get-SysQueuedBoot { $false }
function Get-SysDisk { [pscustomobject]@{ Style = 'GPT'; EspCount = 1; ShrinkableBytes = [int64]155GB; Candidates = @() } }

$script:Calls = New-Object System.Collections.ArrayList
function Part($Disk, $Num, $Type, $Fs, $Label, $Size, $Letter = '', $WinEsp = $false) { [pscustomobject]@{ Disk = $Disk; Number = $Num; Guid = "{g$Num}"; GptType = $Type; IsWindowsEsp = $WinEsp; FileSystem = $Fs; Label = $Label; SizeBytes = [int64]$Size; DriveLetter = $Letter } }
$script:Layout = [pscustomobject]@{ WindowsDisk = 0; CSizeBytes = [int64]1860GB; CShrinkableBytes = [int64]155GB; CFreeBytes = [int64]400GB
 Disks = @([pscustomobject]@{ Number = 0; BusType = 'NVMe'; PartitionStyle = 'GPT'; IsSystem = $true; IsOffline = $false; SizeBytes = [int64]1TB; LargestFreeBytes = [int64]0; Name = 'D0' })
 Partitions = @((Part 0 1 $ESP 'FAT32' '' 100MB '' $true), (Part 0 3 'x' 'NTFS' '' 1860GB 'C')) }
function Get-SysDiskLayout { $script:Layout }
function Invoke-SysResizeC([int64]$NewSizeBytes) { [void]$script:Calls.Add("resize $NewSizeBytes") }
function Invoke-SysNewDedicatedPartition([int]$DiskNumber, [int64]$SizeBytes, [string]$Label, [int64]$OffsetBytes = 0) { [void]$script:Calls.Add("new $DiskNumber $SizeBytes $Label"); [pscustomobject]@{ Disk = $DiskNumber; Number = 9; Guid = '{new}'; DriveLetter = 'W'; SizeBytes = $SizeBytes; Offset = $OffsetBytes } }
function Get-SysCEndOffset { [int64]1997139443712 }
function Invoke-SysBcdExport([string]$Path) { Set-Content -LiteralPath $Path -Value 'bcd' }
function Get-SysBcdText([string[]]$BcdArgs) { 'x' }
function Get-SysPartitionTable { @() }

# --- full run on a PC that needs a shrink: Y card, Y console, option 1 (shrink), SHRINK, Y plan ---
$t = New-TestRoot
try {
 Set-Answers @('Y', 'Y', '1', 'SHRINK', 'Y')
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'reports')
 ExpectTrue 'run finishes' $r.Done
 Expect 'shrink then create, in that order' ($script:Calls -join '|') ("resize $([int64](1860GB - 2GB - 16MB))|new 0 $([int64]2GB) GPUUNLOCK")
 $s = Read-InstallerState
 Expect 'state phase saved' $s.Phase 'done'
 Expect 'target saved' $s.Cards.Target.Bus '01:00.0'
 Expect 'partition record saved' $s.BootPartition.DriveLetter 'W'
 ExpectTrue 'plan confirmation recorded' ([bool]$s.PlanConfirmed)
 ExpectTrue 'backup folder recorded' ([bool]$s.BackupFolder)
 ExpectTrue 'backup exists' (Test-Path (Join-Path $s.BackupFolder 'bcd-store'))
 Expect 'journal has backup, shrink, create and the new partition identity' @(Read-Journal).Count 4
 # the plan was confirmed BEFORE any change: the answer order proves it (5 answers consumed in order)
 Expect 'no extra questions' $script:Answers.Count 0
} finally { Remove-TestRoot $t }

# --- declining the plan changes nothing ---
$t = New-TestRoot
try {
 $script:Calls.Clear()
 Set-Answers @('Y', 'Y', '1', 'SHRINK', 'N')
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'reports')
 ExpectTrue 'declined plan stops' (-not $r.Done)
 Expect 'stopped at the plan' $r.Phase 'plan'
 Expect 'no system call was made' $script:Calls.Count 0
 Expect 'no journal' @(Read-Journal).Count 0
 # same command again resumes at the plan, with the saved choices, and asks only the plan question
 Set-Answers @('Y')
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'reports')
 ExpectTrue 'resumed run finishes' $r.Done
 Expect 'resume asked one question' $script:Asked.Count 1
 Expect 'partition created once' @($script:Calls | Where-Object { $_ -like 'new*' }).Count 1
} finally { Remove-TestRoot $t }

# --- a stopped run keeps its choices; a changed card set forces choosing again ---
$t = New-TestRoot
try {
 $script:Calls.Clear()
 Set-Answers @('Y', 'Y', '1', 'SHRINK', 'N')
 [void](Invoke-Installer -ReportFolder (Join-Path $t 'reports'))
 $script:Adapters = @($script:Adapters + (A 'NVIDIA GeForce RTX 3080' '2206' '12345678' '03:00.0'))
 Set-Answers @('3', '2', '1', 'SHRINK', 'N')
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'reports')
 ExpectTrue 'the changed card set was noticed' ((OutText) -like '*changed since you chose*')
 Expect 'card question was asked again' (Read-InstallerState).Cards.Target.Bus '03:00.0'
 $script:Adapters = @($script:Adapters[0], $script:Adapters[1])
} finally { Remove-TestRoot $t }

# --- dry run: questions still asked, nothing saved or changed ---
$t = New-TestRoot
try {
 $script:Calls.Clear()
 Set-Answers @('Y', 'Y', '1', 'SHRINK', 'Y')
 $r = Invoke-Installer -DryRun -ReportFolder (Join-Path $t 'reports')
 ExpectTrue 'dry run finishes' $r.Done
 Expect 'dry run: no system calls' $script:Calls.Count 0
 ExpectTrue 'dry run: no state file' (-not (Test-Path (Get-StatePath)))
 ExpectTrue 'dry run: no journal' (-not (Test-Path (Get-JournalPath)))
 ExpectTrue 'dry run: no backup folder' (-not (Test-Path (Join-Path (Get-InstallerRoot) 'Backups')))
} finally { Remove-TestRoot $t }

# --- an existing dedicated partition needs no partition question and creates nothing ---
$t = New-TestRoot
try {
 $script:Calls.Clear()
 $script:Layout.Partitions = @($script:Layout.Partitions + (Part 0 4 $ESP 'FAT32' 'GPUUNLOCK' 2GB 'U'))
 Set-Answers @('Y', 'Y', 'Y')
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'reports')
 ExpectTrue 'existing-partition run finishes' $r.Done
 Expect 'no partition change' $script:Calls.Count 0
 Expect 'existing partition recorded' (Read-InstallerState).BootPartition.DriveLetter 'U'
 Expect 'only the backup is journaled' @(Read-Journal).Count 1
} finally { Remove-TestRoot $t }

# --- failing checks stop before any question and write a report ---
$t = New-TestRoot
try {
 function Get-SysSecureBoot { 'On' }
 Set-Answers @()
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'reports')
 ExpectTrue 'failed check stops' (-not $r.Done)
 Expect 'stopped at checks' $r.Phase 'checks'
 Expect 'no question was asked' $script:Asked.Count 0
 $rep = @(Get-ChildItem (Join-Path $t 'reports'))
 Expect 'one report written' $rep.Count 1
 $txt = Get-Content $rep[0].FullName -Raw
 ExpectTrue 'report names the failed check' ($txt.Contains('[FAIL] C03'))
 ExpectTrue 'report holds no user name' ($txt -notlike "*$env:USERNAME*")
 function Get-SysSecureBoot { 'Off' }
} finally { Remove-TestRoot $t }

# --- unreadable check needs an explicit yes ---
$t = New-TestRoot
try {
 function Get-SysBitLocker { [pscustomobject]@{ Known = $false } }
 Set-Answers @('N')
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'reports')
 Expect 'declined unreadable check stops' $r.Reason 'unreadable checks'
} finally { Remove-TestRoot $t }

# --- no card chosen / no partition chosen stop with the phase kept ---
$t = New-TestRoot
try {
 function Get-SysBitLocker { [pscustomobject]@{ Known = $true; ProtectionStatus = 0; ConversionStatus = 0 } }
 Set-Answers @('N')
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'reports')
 Expect 'declined card stops at cards' $r.Phase 'cards'
 Expect 'state remembers the phase' (Read-InstallerState).Phase 'cards'
} finally { Remove-TestRoot $t }

Complete-Tests
