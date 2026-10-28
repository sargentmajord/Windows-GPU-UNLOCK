# Roll back (requirements 12, 14): journal-driven undo, checked step by step. Real files in temporary folders; every system call
# (partition, C: size, boot queue, registry, startup task) is replaced. Nothing on the real PC is touched.
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$repo = Split-Path -Parent $base
Set-RepoRoot $repo

# ---------- replaced system calls ----------
$script:BootDir = $null
function Get-BootRoot($State) { $script:BootDir + '\' }
function Get-RelativeBootPath([string]$Target) { $Target.Substring($script:BootDir.Length + 1) }
$script:LastLetter = ''
# never a real drive: a test must not read or write a real partition
function Get-BootRootFromLetter([string]$Letter) { $script:LastLetter = $Letter.TrimEnd(':'); $script:BootDir + '\' }
$script:PartGuid = 'guid-1'; $script:PartGone = $false; $script:Removed = 0; $script:Resized = @(); $script:CSize = 0; $script:CPrev = 0; $script:CFreeAfterPartition = $true
$script:Letter = 'U'; $script:Label = 'GPUUNLOCK'; $script:Assigned = 0
function Get-SysPartitionIdentity([int]$Disk, [int]$Number) { if ($script:PartGone -or $Disk -ne 0) { $null } else { [pscustomobject]@{ Disk = $Disk; Number = $Number; Guid = $script:PartGuid; Offset = 1000; SizeBytes = 2GB; DriveLetter = $script:Letter } } }
function Invoke-SysRemovePartition([int]$Disk, [int]$Number) { $script:Removed++; $script:PartGone = $true }
function Get-SysCSize { [pscustomobject]@{ SizeBytes = $script:CSize; MaxSizeBytes = $(if ($script:PartGone -or $script:CFreeAfterPartition) { $script:CPrev } else { $script:CSize }) } }
function Invoke-SysResizeC([int64]$NewSizeBytes) { $script:Resized += $NewSizeBytes; $script:CSize = $NewSizeBytes }
function Get-SysVolumeLabel([string]$Letter) { $script:Label }
function Invoke-SysAssignLetter([int]$Disk, [int]$Number) { $script:Assigned++; 'V' }
$script:Queued = $false; $script:ClearOk = $true; $script:Disabled = 0; $script:DisableFails = $false; $script:Restarts = 0
function Get-SysFwBootMgrText { if ($script:Queued) { 'bootsequence {entry}' } else { 'displayorder {bootmgr}' } }
function Invoke-SysClearQueue { if ($script:ClearOk) { $script:Queued = $false }; $script:ClearOk }
function Invoke-SysRestart([int]$Seconds, [string]$Reason) { $script:Restarts++; 0 }
function Disable-EveryBoot([switch]$DryRun) { if ($script:DisableFails) { throw 'the task could not be removed' }; $script:Disabled++; 'Off' }
$script:LinkArgs = @{}
function Get-SysShortcutInfo([string]$LinkPath) { [pscustomobject]@{ Target = 'powershell.exe'; Arguments = $script:LinkArgs[$LinkPath] } }
function Get-SysFastStartup { 0 }
function Compare-WithBackup([string]$Dir) { [pscustomobject]@{ FastStartup = $true; DisplayOrder = $true } }

# A fresh world: temp root, boot partition folder (with the user's own with-esc and previous folders), state, empty journal.
function New-World([switch]$WithOriginalBootFile) {
 $t = New-TestRoot
 $script:BootDir = Join-Path $t 'boot'; [void](New-Item -ItemType Directory $script:BootDir)
 if (-not $script:BootDir.StartsWith([IO.Path]::GetTempPath())) { throw 'the test boot folder is not temporary' }
 foreach ($f in 'with-esc', 'previous') { [void](New-Item -ItemType Directory (Join-Path $script:BootDir $f)); Set-Content (Join-Path $script:BootDir "$f\keep.txt") "the user's own $f file" }
 $src = Join-Path $t 'src'; [void](New-Item -ItemType Directory $src)
 Set-Content (Join-Path $src 'diag.efi') 'diagnostic program' -NoNewline
 Set-Content (Join-Path $src 'unlock.efi') 'unlock program' -NoNewline
 $bk = Join-Path $t 'installer\Backups\install-1'; [void](New-Item -ItemType Directory $bk -Force)
 Set-Content (Join-Path $bk 'fast-startup.json') '{"HiberbootEnabled":0}'
 if ($WithOriginalBootFile) { [void](New-Item -ItemType Directory (Join-Path $script:BootDir 'EFI\BOOT') -Force); Set-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') 'the original program' -NoNewline }
 $script:PartGone = $false; $script:Removed = 0; $script:Resized = @(); $script:Queued = $false; $script:ClearOk = $true; $script:Disabled = 0; $script:DisableFails = $false; $script:Restarts = 0
 $script:Label = 'GPUUNLOCK'; $script:Letter = 'U'; $script:Assigned = 0; $script:CFreeAfterPartition = $false
 $script:FakeRunOnce = $null
 $st = [ordered]@{ Version = 1; Phase = 'verdict'; BackupFolder = $bk; BootPartition = [ordered]@{ Disk = 0; Number = 3; Guid = 'guid-1'; DriveLetter = 'U'; Created = $false; ShrankC = $false } }
 [pscustomobject]@{ T = $t; Src = $src; State = $st; Backup = $bk }
}
function ResultFor($Res, [string]$Like) { @($Res.Results | Where-Object { $_.Item -like $Like }) | Select-Object -First 1 }
function Run-Rollback($W, [string[]]$Answers = @('Y'), [switch]$DryRun) {
 Save-InstallerState $W.State
 Set-Answers $Answers
 $res = Invoke-Rollback -DryRun:$DryRun
 if ($env:RB_DEBUG) { $res.Results | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host }
 $res
}
function Stage($W, [string]$Source, [string]$Rel) { Copy-ToBootPartition $W.State (Join-Path $W.Src $Source) $Rel $W.Backup }

# ---------- the explanation text (requirement 14) ----------
$txt = (Get-RollbackExplanation) -join ' '
foreach ($k in 'undoes only what this installer changed', 'automatic-resume', 'queued one-time boot', 'only if they are unchanged', 'boot order still has Windows first', 'startup task', 'Fast Startup setting back to what it was', 'working files', 'report and log files', 'NVIDIA firmware files', 'shrunk') {
 ExpectTrue "the explanation says: $k" (($txt -replace '\s+', ' ') -like "*$k*")
}

# ---------- nothing was installed ----------
$w = New-World
try {
 Set-Answers @()
 $r = Invoke-Rollback
 ExpectTrue 'a PC the installer never changed: finished, nothing to do' ($r.Finished -and -not $r.Cancelled -and $r.Results.Count -eq 0)
 ExpectTrue 'and it says so, asking nothing' (((OutText) -like '*nothing to roll back*') -and $script:Asked.Count -eq 0)
} finally { Remove-TestRoot $w.T }

# ---------- a normal install on an existing partition, then rolled back ----------
$w = New-World -WithOriginalBootFile
try {
 $originalHash = Get-SysFileHash (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI')
 New-BootFolder $w.State 'RTX3060-UNLOCK'
 New-BootFolder $w.State 'EFI\WindowsGPUUnlock'
 [void](Stage $w 'diag.efi' 'EFI\WindowsGPUUnlock\DIAGNOSTIC.EFI')
 [void](Stage $w 'diag.efi' 'EFI\BOOT\BOOTX64.EFI')           # replaces the user's file (saved to the backup first)
 [void](Stage $w 'unlock.efi' 'EFI\BOOT\BOOTX64.EFI')         # replaced again by the unlock program
 Set-Content (Join-Path $script:BootDir 'RTX3060-UNLOCK\DIAG01.TXT') 'log written by the diagnostic'
 Add-JournalEntry -Phase 'queue' -Action 'queue one-time boot' -Target '{entry}' -Previous ([ordered]@{ Queued = $false }) | ForEach-Object { Set-JournalStatus $_ 'done' }
 $script:Queued = $true
 Set-SysRunOnceValue 'resume command'
 # work files
 $work = Get-WorkRoot
 foreach ($d in 'assets', 'benchmark', 'discovery', 'profile') { [void](New-Item -ItemType Directory (Join-Path $work $d) -Force); Set-Content (Join-Path $work "$d\f.bin") 'x' }
 [void](New-Item -ItemType Directory (Join-Path $work 'capture-1') -Force); Set-Content (Join-Path $work 'capture-1\PROM.BIN') 'card image'
 $cfg = Join-Path $w.T 'platform-config.h'; Set-Content $cfg 'x'
 Add-JournalEntry -Phase 'build' -Action 'write local partition configuration' -Target $cfg | ForEach-Object { Set-JournalStatus $_ 'done' }
 Add-JournalEntry -Phase 'tools' -Action 'install LLVM.LLVM' -Target 'LLVM' | ForEach-Object { Set-JournalStatus $_ 'done' }
 Set-Content (Join-Path (Get-InstallerRoot) 'reports.txt') 'a report'
 $reportDir = Join-Path $w.T 'reports'; [void](New-Item -ItemType Directory $reportDir); Set-Content (Join-Path $reportDir 'r.txt') 'report'
 Save-InstallerState $w.State

 # declining changes nothing
 Set-Answers @('N'); $r = Invoke-Rollback
 ExpectTrue 'declining the first question cancels' ($r.Cancelled -and -not $r.Finished)
 Expect 'the unlock program is still on the partition' (Get-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') -Raw) 'unlock program'
 ExpectTrue 'the resume entry and the state are untouched' ((Test-ResumeEntry) -and (Test-Path (Get-StatePath)))

 # a dry run shows the plan and asks nothing
 $r = Run-Rollback $w @() -DryRun
 ExpectTrue 'dry run asks nothing' ($script:Asked.Count -eq 0)
 ExpectTrue 'dry run changes nothing' (((Get-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') -Raw) -eq 'unlock program') -and (Test-ResumeEntry) -and $script:Queued -and (Test-Path (Get-StatePath)) -and (Test-Path (Join-Path (Get-WorkRoot) 'assets')))
 ExpectTrue 'dry run lists what it would do' (@($r.Results | Where-Object Outcome -eq 'WouldDo').Count -ge 5)

 # the real thing: delete the firmware files (Y), keep the benchmark (N)
 $r = Run-Rollback $w @('Y', 'Y', 'N')
 ExpectTrue 'finished' ($r.Finished -and -not $r.Cancelled)
 Expect 'the user''s original BOOTX64.EFI is back, byte for byte (two replacements undone in order)' (Get-SysFileHash (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI')) $originalHash
 ExpectTrue 'the diagnostic copy is gone' (-not (Test-Path (Join-Path $script:BootDir 'EFI\WindowsGPUUnlock\DIAGNOSTIC.EFI')))
 ExpectTrue 'the empty folder the installer made is gone' (-not (Test-Path (Join-Path $script:BootDir 'EFI\WindowsGPUUnlock')))
 ExpectTrue 'the log folder with the programs'' own logs is left' ((Test-Path (Join-Path $script:BootDir 'RTX3060-UNLOCK\DIAG01.TXT')) -and ((ResultFor $r '*folder RTX3060-UNLOCK*').Outcome -eq 'Left'))
 Expect 'the user''s with-esc folder is untouched' (Get-Content (Join-Path $script:BootDir 'with-esc\keep.txt') -Raw).Trim() 'the user''s own with-esc file'
 Expect 'and so is previous' (Get-Content (Join-Path $script:BootDir 'previous\keep.txt') -Raw).Trim() 'the user''s own previous file'
 ExpectTrue 'the partition was not deleted (the installer did not create it)' ($script:Removed -eq 0 -and (ResultFor $r '*boot partition').Outcome -eq 'Kept')
 ExpectTrue 'the queued boot was cleared' ((-not $script:Queued) -and (ResultFor $r '*queued one-time boot*').Outcome -eq 'Removed')
 ExpectTrue 'the resume entry was removed' ((-not (Test-ResumeEntry)) -and (ResultFor $r '*automatic resume*').Outcome -eq 'Removed')
 ExpectTrue 'no startup task existed, none was touched' ($script:Disabled -eq 0)
 ExpectTrue 'firmware files deleted when asked' (-not (Test-Path (Join-Path (Get-WorkRoot) 'assets')))
 ExpectTrue 'benchmark download kept when asked' (Test-Path (Join-Path (Get-WorkRoot) 'benchmark\f.bin'))
 ExpectTrue 'the other working files, including the card image, are deleted' ((-not (Test-Path (Join-Path (Get-WorkRoot) 'capture-1'))) -and (-not (Test-Path (Join-Path (Get-WorkRoot) 'profile'))) -and (-not (Test-Path (Join-Path (Get-WorkRoot) 'discovery'))))
 ExpectTrue 'the generated partition configuration is deleted' (-not (Test-Path $cfg))
 ExpectTrue 'build tools are reported as left installed' ((ResultFor $r '*build tool*').Outcome -eq 'Kept')
 ExpectTrue 'reports and backups are kept' ((Test-Path (Join-Path $reportDir 'r.txt')) -and (Test-Path $w.Backup))
 ExpectTrue 'the state file is gone and the journal is archived' ((-not (Test-Path (Get-StatePath))) -and (-not (Test-Path (Get-JournalPath))) -and @(Get-ChildItem (Get-InstallerRoot) -Filter 'journal-rolled-back-*.jsonl').Count -eq 1)
 ExpectTrue 'the closing checklist is printed with the three kinds of outcome' (((OutText) -like '*[removed]*') -and ((OutText) -like '*[LEFT]*') -and ((OutText) -like '*[kept]*'))
 ExpectTrue 'and compares Fast Startup and the boot order with the backup' (((OutText) -like '*Fast Startup is back to the value it had before*') -and ((OutText) -like '*boot order is the same as before*'))
 ExpectTrue 'it asked exactly three questions: roll back, delete firmware files, delete benchmark' ($script:Asked.Count -eq 3)
 ExpectTrue 'no restart was needed or offered' ($script:Restarts -eq 0 -and -not $r.NeedsRestart)

 # a second run finds nothing to do
 Set-Answers @(); $r2 = Invoke-Rollback
 ExpectTrue 'running Roll back again is harmless' ($r2.Finished -and $r2.Results.Count -eq 0)
} finally { Remove-TestRoot $w.T }

# ---------- a file that changed since the installer wrote it is left ----------
$w = New-World
try {
 [void](Stage $w 'unlock.efi' 'EFI\BOOT\BOOTX64.EFI')
 Set-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') 'edited by someone else' -NoNewline
 $r = Run-Rollback $w @('Y')
 Expect 'the changed file is not deleted' (Get-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') -Raw) 'edited by someone else'
 ExpectTrue 'and is reported as left with the reason' (((ResultFor $r '*BOOTX64.EFI').Outcome -eq 'Left') -and ((ResultFor $r '*BOOTX64.EFI').Detail -like '*changed afterwards*'))
} finally { Remove-TestRoot $w.T }

# ---------- the installer replaced a file but its saved copy is gone ----------
$w = New-World -WithOriginalBootFile
try {
 [void](Stage $w 'unlock.efi' 'EFI\BOOT\BOOTX64.EFI')
 Remove-Item (Join-Path $w.Backup 'staged') -Recurse -Force
 $r = Run-Rollback $w @('Y')
 Expect 'without an intact saved copy the installed file is left alone' (Get-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') -Raw) 'unlock program'
 ExpectTrue 'and the reason is given' ((ResultFor $r '*BOOTX64.EFI').Detail -like '*saved copy is missing or changed*')
} finally { Remove-TestRoot $w.T }

# ---------- an interrupted copy (journal says planned) is still recognised by its hash ----------
$w = New-World
try {
 [void](Stage $w 'diag.efi' 'EFI\BOOT\BOOTX64.EFI')
 $lines = @(Get-Content (Get-JournalPath))
 ExpectTrue 'the copy was journaled before it was done' ($lines.Count -ge 2)
 $r = Run-Rollback $w @('Y')
 ExpectTrue 'the file is removed by hash even if the journal were not marked done' (-not (Test-Path (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI')))
} finally { Remove-TestRoot $w.T }

# ---------- the partition is not the one the installer recorded ----------
$w = New-World
try {
 [void](Stage $w 'unlock.efi' 'EFI\BOOT\BOOTX64.EFI')
 $script:PartGuid = 'someone-elses'
 $r = Run-Rollback $w @('Y')
 Expect 'a partition with a different identity is not touched' (Get-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') -Raw) 'unlock program'
 ExpectTrue 'and the reason names the number clash' ((ResultFor $r '*BOOTX64.EFI').Detail -like '*different partition*')
 $script:PartGuid = 'guid-1'
 $script:Label = 'MYDATA'
 $w.State.BootPartition.Guid = 'guid-1'
 $res = Resolve-RollbackBootRoot $w.State
 ExpectTrue 'a partition that lost its label is not touched' ((-not $res.Root) -and $res.Reason -like '*no longer labelled GPUUNLOCK*')
 $script:Label = 'GPUUNLOCK'
 $res = Resolve-RollbackBootRoot $w.State
 Expect 'the right partition resolves through its current drive letter' $script:LastLetter 'U'
 $script:Letter = ''
 $res = Resolve-RollbackBootRoot $w.State
 ExpectTrue 'a partition without a letter gets one' (($script:LastLetter -eq 'V') -and $script:Assigned -eq 1)
 $script:Letter = 'U'
 $script:PartGone = $true
 ExpectTrue 'a vanished partition is reported' ((Resolve-RollbackBootRoot $w.State).Reason -like '*not there any more*')
 $script:PartGone = $false
 $st2 = [ordered]@{ Version = 1; Phase = 'x' }
 ExpectTrue 'no recorded partition is reported' ((Resolve-RollbackBootRoot $st2).Reason -like '*never chose*')
} finally { Remove-TestRoot $w.T; $script:PartGuid = 'guid-1' }

# ---------- a partition the installer created, with C: shrunk ----------
function New-ShrinkWorld {
 $w = New-World
 $w.State.BootPartition.Created = $true; $w.State.BootPartition.ShrankC = $true
 $script:CPrev = 500GB; $script:CSize = 500GB - 2GB - 16MB
 $sj = Add-JournalEntry -Phase 'partition' -Action 'shrink C:' -Target 'C: ...' -Previous ([ordered]@{ CSizeBytes = $script:CPrev }); Set-JournalStatus $sj 'done'
 $ij = Add-JournalEntry -Phase 'partition' -Action 'created partition identity' -Target 'disk 0 partition 3' -Previous ([ordered]@{ Disk = 0; Number = 3; Guid = 'guid-1'; Offset = 1000; SizeBytes = 2GB }); Set-JournalStatus $ij 'done'
 $w
}
$w = New-ShrinkWorld
try {
 New-BootFolder $w.State 'RTX3060-UNLOCK'
 [void](Stage $w 'unlock.efi' 'EFI\BOOT\BOOTX64.EFI')
 Set-Content (Join-Path $script:BootDir 'RTX3060-UNLOCK\DIAG01.TXT') 'log'
 Get-ChildItem $script:BootDir -Directory | Where-Object { $_.Name -in 'with-esc', 'previous' } | Remove-Item -Recurse -Force   # this partition is the installer's own
 # wrong typed words change nothing
 $r = Run-Rollback $w @('Y', 'delete', 'no')
 ExpectTrue 'a wrong word does not delete the partition' ($script:Removed -eq 0 -and (ResultFor $r '*partition the installer created').Outcome -eq 'Left')
 ExpectTrue 'and C: is not extended while the partition is still there' ($script:Resized.Count -eq 0 -and (ResultFor $r '*drive C:*').Outcome -eq 'Left')
}
finally { Remove-TestRoot $w.T }
$w = New-ShrinkWorld
try {
 New-BootFolder $w.State 'RTX3060-UNLOCK'
 [void](Stage $w 'unlock.efi' 'EFI\BOOT\BOOTX64.EFI')
 Set-Content (Join-Path $script:BootDir 'RTX3060-UNLOCK\DIAG01.TXT') 'log'
 Get-ChildItem $script:BootDir -Directory | Where-Object { $_.Name -in 'with-esc', 'previous' } | Remove-Item -Recurse -Force
 $r = Run-Rollback $w @('Y', 'DELETE', 'EXTEND', 'Y', 'Y')
 ExpectTrue 'the created partition is deleted after the typed word' ($script:Removed -eq 1 -and (ResultFor $r '*partition the installer created').Outcome -eq 'Removed')
 ExpectTrue 'then C: is extended back to exactly its old size after its own typed word' (($script:Resized.Count -eq 1) -and $script:Resized[0] -eq 500GB)
 ExpectTrue 'the screen showed the exact sizes' (((OutText) -like '*C: now:*') -and ((OutText) -like '*C: after: 500.00 GiB*'))
 ExpectTrue 'C: is reported restored' ((ResultFor $r '*drive C:*').Outcome -eq 'Removed')
}
finally { Remove-TestRoot $w.T }

# a foreign file on the created partition: not deleted, nothing asked about it
$w = New-ShrinkWorld
try {
 New-BootFolder $w.State 'RTX3060-UNLOCK'
 Set-Content (Join-Path $script:BootDir 'notes-from-the-user.txt') 'mine'
 $script:CFreeAfterPartition = $false
 $r = Run-Rollback $w @('Y')
 ExpectTrue 'a partition that holds someone else''s file is not deleted' ($script:Removed -eq 0 -and (ResultFor $r '*partition the installer created').Detail -like '*notes-from-the-user.txt*')
 ExpectTrue 'and C: is left as it is, with the Disk Management hint' (($script:Resized.Count -eq 0) -and ((ResultFor $r '*drive C:*').Detail -like '*Disk Management*'))
 ExpectTrue 'only the roll back question was asked' ($script:Asked.Count -eq 1)
 ExpectTrue 'the user''s file is still there' (Test-Path (Join-Path $script:BootDir 'notes-from-the-user.txt'))
}
finally { Remove-TestRoot $w.T }

# a partition that is not the recorded one (different size) is not deleted
$w = New-ShrinkWorld
try {
 $w.State.BootPartition.Guid = 'guid-1'
 $script:PartGuid = 'guid-other'
 $r = Run-Rollback $w @('Y')
 ExpectTrue 'identity mismatch: not deleted, no question about it' ($script:Removed -eq 0 -and ((ResultFor $r '*partition the installer created').Detail -like '*not the one the installer made*'))
}
finally { Remove-TestRoot $w.T; $script:PartGuid = 'guid-1' }

# ---------- C3: C: was shrunk but the partition was never created ----------
$w = New-World
try {
 $script:CPrev = 400GB; $script:CSize = 400GB - 2GB - 16MB; $script:CFreeAfterPartition = $true
 $sj = Add-JournalEntry -Phase 'partition' -Action 'shrink C:' -Target 'C: ...' -Previous ([ordered]@{ CSizeBytes = $script:CPrev }); Set-JournalStatus $sj 'done'
 $fj = Add-JournalEntry -Phase 'partition' -Action 'create boot partition' -Target 'disk 0' ; Set-JournalStatus $fj 'failed'
 $w.State.BootPartition = [ordered]@{ Disk = 0; Number = 0; Guid = ''; DriveLetter = ''; Created = $true; ShrankC = $true }
 $r = Run-Rollback $w @('Y', 'EXTEND')
 ExpectTrue 'C3: Roll back offers to give the space back' ($script:Resized.Count -eq 1 -and $script:Resized[0] -eq 400GB)
 ExpectTrue 'C3: it showed the sizes and asked for the typed word' (((OutText) -like '*C: now:*') -and ($script:Asked.Count -eq 2) -and ($script:Asked[1] -like '*Type EXTEND*'))
 # declining keeps the space unallocated and says how to add it later
 $w2 = New-World
 $script:CPrev = 400GB; $script:CSize = 400GB - 2GB - 16MB; $script:CFreeAfterPartition = $true
 $sj = Add-JournalEntry -Phase 'partition' -Action 'shrink C:' -Target 'C: ...' -Previous ([ordered]@{ CSizeBytes = $script:CPrev }); Set-JournalStatus $sj 'done'
 $r = Run-Rollback $w2 @('Y', 'no')
 ExpectTrue 'C3: declining leaves C: smaller and says why and how' (($script:Resized.Count -eq 0) -and ((ResultFor $r '*drive C:*').Detail -like '*Disk Management*'))
 # C: already its old size: nothing to do
 $w3 = New-World
 $script:CPrev = 400GB; $script:CSize = 400GB
 $sj = Add-JournalEntry -Phase 'partition' -Action 'shrink C:' -Target 'C: ...' -Previous ([ordered]@{ CSizeBytes = $script:CPrev }); Set-JournalStatus $sj 'done'
 $r = Run-Rollback $w3 @('Y')
 ExpectTrue 'C: already at its old size: reported, no question' ((ResultFor $r '*drive C:*').Outcome -eq 'AlreadyGone' -and $script:Asked.Count -eq 1)
 Remove-TestRoot $w2.T; Remove-TestRoot $w3.T
}
finally { Remove-TestRoot $w.T }

# ---------- the unfinished-partition case: free space after C: is not available ----------
$w = New-World
try {
 $script:CPrev = 400GB; $script:CSize = 400GB - 2GB - 16MB; $script:CFreeAfterPartition = $false
 $sj = Add-JournalEntry -Phase 'partition' -Action 'shrink C:' -Target 'C: ...' -Previous ([ordered]@{ CSizeBytes = $script:CPrev }); Set-JournalStatus $sj 'done'
 $r = Run-Rollback $w @('Y')
 ExpectTrue 'if the space after C: is not free, nothing is resized and a hint is given' (($script:Resized.Count -eq 0) -and ((ResultFor $r '*drive C:*').Detail -like '*space after C: is not free*'))
} finally { Remove-TestRoot $w.T; $script:CFreeAfterPartition = $true }

# ---------- one-time boot that the installer did not queue ----------
$w = New-World
try {
 $script:Queued = $true
 $r = Run-Rollback $w @('Y')
 ExpectTrue 'a queued boot the installer did not make is left alone' ($script:Queued -and (ResultFor $r '*queued one-time boot*').Outcome -eq 'Left')
}
finally { Remove-TestRoot $w.T }
$w = New-World
try {
 $qj = Add-JournalEntry -Phase 'queue' -Action 'queue one-time boot' -Target '{e}'; Set-JournalStatus $qj 'done'
 $script:Queued = $true; $script:ClearOk = $false
 $r = Run-Rollback $w @('Y', 'N')
 ExpectTrue 'a queued boot that cannot be cleared offers a restart (asked, not assumed)' ((ResultFor $r '*queued one-time boot*').Outcome -eq 'Left' -and $r.NeedsRestart -and $script:Restarts -eq 0 -and ($script:Asked[-1] -like 'Restart now?*'))
}
finally { Remove-TestRoot $w.T }

# ---------- startup task, shortcuts, scripts ----------
$w = New-World
try {
 $data = Get-DataRoot
 Set-Content (Join-Path $data 'Arm-NextBoot.ps1') 'arm'; Set-Content (Join-Path $data 'arm-state.json') '{}'; Set-Content (Join-Path $data 'arm.log') 'log'
 $scr = Join-Path $data 'Unlock-Next-Boot.ps1'; Set-Content $scr 'script'
 $startLink = Join-Path $w.T 'start.lnk'; $deskLink = Join-Path $w.T 'desk.lnk'; $oldLink = Join-Path $w.T 'old.lnk'
 foreach ($l in $startLink, $deskLink, $oldLink) { Set-Content $l 'lnk' }
 $script:LinkArgs = @{ $startLink = "-File `"$scr`""; $deskLink = '-File "C:\other\evil.ps1"'; $oldLink = "-File `"$scr`"" }
 $jj = Add-JournalEntry -Phase 'schedule' -Action 'write the next-boot unlock script' -Target $scr -Previous ([ordered]@{ Existed = $false }); Set-JournalStatus $jj 'done'
 $jj = Add-JournalEntry -Phase 'schedule' -Action 'create the Start menu shortcut' -Target $startLink -Previous ([ordered]@{ Existed = $false }); Set-JournalStatus $jj 'done'
 $jj = Add-JournalEntry -Phase 'schedule' -Action 'create the desktop shortcut' -Target $deskLink -Previous ([ordered]@{ Existed = $false }); Set-JournalStatus $jj 'done'
 $jj = Add-JournalEntry -Phase 'schedule' -Action 'create the desktop shortcut' -Target $oldLink -Previous ([ordered]@{ Existed = $true }); Set-JournalStatus $jj 'done'
 $jj = Add-JournalEntry -Phase 'schedule' -Action 'unlock at every start (startup task, Fast Startup off)' -Target 'WindowsGPUUnlock-ArmNextBoot' -Previous ([ordered]@{ FastStartup = 1 }); Set-JournalStatus $jj 'done'
 $r = Run-Rollback $w @('Y')
 ExpectTrue 'the startup task is removed through the schedule script (which restores Fast Startup)' ($script:Disabled -eq 1 -and (ResultFor $r '*startup task*').Outcome -eq 'Removed')
 ExpectTrue 'its generated script and state are deleted, its log is kept' ((-not (Test-Path (Join-Path $data 'Arm-NextBoot.ps1'))) -and (-not (Test-Path (Join-Path $data 'arm-state.json'))) -and (Test-Path (Join-Path $data 'arm.log')))
 ExpectTrue 'the shortcut that points at the installer''s script is deleted' (-not (Test-Path $startLink))
 ExpectTrue 'a shortcut someone re-pointed is left' ((Test-Path $deskLink) -and (ResultFor $r "*desk.lnk").Detail -like '*no longer points*')
 ExpectTrue 'a shortcut that existed before the installer is left' ((Test-Path $oldLink) -and (ResultFor $r '*old.lnk').Detail -like '*before the installer*')
 ExpectTrue 'the next-boot script is deleted' (-not (Test-Path $scr))
}
finally { Remove-TestRoot $w.T }
$w = New-World
try {
 $jj = Add-JournalEntry -Phase 'schedule' -Action 'unlock at every start (startup task, Fast Startup off)' -Target 'T'; Set-JournalStatus $jj 'done'
 $script:DisableFails = $true
 $r = Run-Rollback $w @('Y')
 ExpectTrue 'a startup task that cannot be removed is reported, and Roll back goes on' ((ResultFor $r '*startup task*').Outcome -eq 'Left' -and $r.Finished)
}
finally { Remove-TestRoot $w.T }

# ---------- the strings Roll back looks for are the ones the modules write ----------
$sched = Get-Content (Join-Path $base 'Schedule.ps1') -Raw; $cap = Get-Content (Join-Path $base 'Capture.ps1') -Raw; $bp = Get-Content (Join-Path $base 'BootPartition.ps1') -Raw
$be = Get-Content (Join-Path $base 'BootEntry.ps1') -Raw; $bt = Get-Content (Join-Path $base 'BuildTest.ps1') -Raw; $rb = Get-Content (Join-Path $base 'Rollback.ps1') -Raw
foreach ($a in 'write the next-boot unlock script', 'create the Start menu shortcut', 'create the desktop shortcut', 'unlock at every start (startup task, Fast Startup off)') { ExpectTrue "Schedule.ps1 journals '$a'" ($sched.Contains($a) -and $rb.Contains($a)) }
foreach ($a in 'copy file to boot partition', 'create folder on boot partition') { ExpectTrue "Capture.ps1 journals '$a'" ($cap.Contains($a) -and $rb.Contains($a)) }
foreach ($a in 'shrink C:', 'created partition identity') { ExpectTrue "BootPartition.ps1 journals '$a'" ($bp.Contains($a) -and $rb.Contains($a)) }
ExpectTrue 'BootEntry.ps1 journals the queued boot' ($be.Contains('queue one-time boot') -and $rb.Contains('queue one-time boot'))
ExpectTrue 'BuildTest.ps1 journals the local configuration' ($bt.Contains('write local partition configuration') -and $rb.Contains('write local partition configuration'))

# ---------- deleting only inside the work folder ----------
$w = New-World
try {
 $outside = Join-Path $w.T 'not-work'; [void](New-Item -ItemType Directory $outside); Set-Content (Join-Path $outside 'f') 'x'
 $script:RollbackResults = New-Object System.Collections.ArrayList
 Remove-WorkFolder $outside 'outside folder'
 ExpectTrue 'a folder outside the work folder is never deleted' ((Test-Path $outside) -and $script:RollbackResults[0].Outcome -eq 'Left')
 $script:RollbackResults = New-Object System.Collections.ArrayList
 Remove-WorkFolder (Get-WorkRoot) 'the work folder itself'
 ExpectTrue 'and neither is the work folder path itself' ($script:RollbackResults[0].Outcome -in 'Left', 'AlreadyGone')
 $evil = (Get-WorkRoot) + '-sibling'; [void](New-Item -ItemType Directory $evil -Force)
 $script:RollbackResults = New-Object System.Collections.ArrayList
 Remove-WorkFolder $evil 'sibling with the same prefix'
 ExpectTrue 'a sibling folder whose name starts the same is not deleted' ((Test-Path $evil) -and $script:RollbackResults[0].Outcome -eq 'Left')
}
finally { Remove-TestRoot $w.T }

# ---------- through the phase loop ----------
$w = New-World
try {
 Save-InstallerState $w.State
 [void](Stage $w 'unlock.efi' 'EFI\BOOT\BOOTX64.EFI')
 Set-Answers @('Y')
 $r = Invoke-Installer -Rollback -ReportFolder (Join-Path $w.T 'reports')
 ExpectTrue 'Invoke-Installer -Rollback rolls back and ends' ($r.Done -and $r.RolledBack)
 ExpectTrue 'no state file is written afterwards' (-not (Test-Path (Get-StatePath)))
 ExpectTrue 'the staged file is gone' (-not (Test-Path (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI')))
}
finally { Remove-TestRoot $w.T }
$w = New-World
try {
 Save-InstallerState $w.State
 [void](Stage $w 'unlock.efi' 'EFI\BOOT\BOOTX64.EFI')
 Set-Answers @('N')
 $r = Invoke-Installer -Rollback -ReportFolder (Join-Path $w.T 'reports')
 ExpectTrue 'declining stops without changes and keeps the phase' ((-not $r.Done) -and (Test-Path (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI')) -and (Read-InstallerState).Phase -eq 'verdict')
 # the verdict screen leads here
 $st = Read-InstallerState; $st.Benchmark = [ordered]@{ Enabled = $true }
 $r = Invoke-Phase-rollback $st @{ DryRun = $true; ReportFolder = ''; CaptureFolder = $null }
 ExpectTrue 'dry run of the rollback phase finishes the run without saving' ($r.RolledBack -eq $true -and (Test-Path (Get-StatePath)))
}
finally { Remove-TestRoot $w.T }

Complete-Tests
