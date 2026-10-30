# The two optional extras (requirement 25): gating, screens, typed acceptance, staging with saved originals, the first run, the revert paths
# and "switch the extras off". Real files in temporary folders; every system call is replaced.
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$repo = Split-Path -Parent $base
Set-RepoRoot $repo

$script:BootDir = $null
function Get-BootRoot($State) { $script:BootDir + '\' }
$script:Entries = 1; $script:IsQueued = $false; $script:Restarts = 0
function Find-UnlockEntries([string]$Label = 'GPUUNLOCK') { if ($script:Entries -eq 0) { , @() } else { , @('{entry}') } }
function Invoke-SysQueueBoot([string]$EntryId) { $script:IsQueued = $true }
function Get-SysFwBootMgrText { if ($script:IsQueued) { 'bootsequence {entry}' } else { 'displayorder {bootmgr}' } }
function Invoke-SysRestart([int]$Seconds, [string]$Reason) { $script:Restarts++; 0 }
$script:Git = 'C:\git\git.exe'
function Get-SysGitPath { $script:Git }
$script:Calls = New-Object System.Collections.ArrayList
$script:BuildFails = $false; $script:TestFails = $false; $script:PatchApplied = $false
function Invoke-SysScriptProcess([string]$CommandText) {
 [void]$script:Calls.Add($CommandText)
 if ($CommandText -like '*-Undo*') { $script:PatchApplied = $false; return [pscustomobject]@{ Code = 0; Output = 'removed' } }
 if ($CommandText -like '*git apply -R --check*') { return [pscustomobject]@{ Code = $(if ($script:PatchApplied) { 0 } else { 1 }); Output = '' } }
 if ($CommandText -like '*Apply-NoCancelWindows*') {
  if ($script:BuildFails) { return [pscustomobject]@{ Code = 1; Output = 'compile error' } }
  $script:PatchApplied = $true
  foreach ($f in $script:NoEscFiles) { [void](New-Item -ItemType Directory (Split-Path -Parent $f.Path) -Force); Set-Content $f.Path ('noesc ' + $f.Role) -NoNewline }
  return [pscustomobject]@{ Code = 0; Output = 'built' }
 }
 [pscustomobject]@{ Code = $(if ($script:TestFails) { 1 } else { 0 }); Output = 'test output' }
}
function Get-ToolStatus { @() }
function Get-ExpectedAssets { @() }
function Get-BuildEnvironment($Tools, $Dir) { [pscustomobject]@{ Clang = 'clang'; LldLink = 'lld-link'; Python = 'python'; VcVars = 'v' } }
function Invoke-WithBuildEnvironment($BuildEnv, [scriptblock]$Do) { & $Do }
function Convert-CaptureToReport($Tools, $Dir) { }
function Get-HostTestPlan($State, $Tools, $AssetsDir) { @([pscustomobject]@{ Name = 'automatic mode'; File = 'C:\x\test-automatic.ps1'; Params = [ordered]@{ A = 1 } }, [pscustomobject]@{ Name = 'manual mode'; File = 'C:\x\test-automatic.ps1'; Params = [ordered]@{ B = 1 } }, [pscustomobject]@{ Name = 'other'; File = 'C:\x\o.ps1'; Params = [ordered]@{} }) }
function Get-NoEscBuiltFileList { $script:NoEscFiles }
$script:Shortcuts = @(); $script:EveryBootOn = 0; $script:EveryBootOff = 0
function New-UnlockShortcut($State, [string]$Mode = 'manual', [switch]$DryRun) { if (-not $DryRun) { $script:Shortcuts += "$Mode" }; [pscustomobject]@{ Script = 'S'; Links = @('a') } }
function Enable-EveryBoot($State, [switch]$DryRun) { $script:EveryBootOn++; $State.Schedule = [ordered]@{ Mode = 'EveryBoot' } }
function Disable-EveryBoot([switch]$DryRun) { $script:EveryBootOff++; 'Off' }
$script:Records = New-Object System.Collections.Queue
function Invoke-BenchmarkRun($State, [string]$Label, [switch]$DryRun) { $script:Records.Dequeue() }
function BenchRec($Fp32, $Fp16, $Bf16) { [ordered]@{ Label = ''; Fp32 = $Fp32; Fp16 = $Fp16; Bf16 = $Bf16 } }

function New-World([switch]$WithOriginal) {
 $t = New-TestRoot
 $script:BootDir = Join-Path $t 'boot'; [void](New-Item -ItemType Directory $script:BootDir)
 if (-not $script:BootDir.StartsWith([IO.Path]::GetTempPath())) { throw 'the test boot folder is not temporary' }
 $src = Join-Path $t 'src'; [void](New-Item -ItemType Directory $src)
 $files = @()
 foreach ($r in 'manual-wrapper', 'manual-unlock', 'automatic-wrapper', 'automatic-unlock') { $p = Join-Path $src "$r.efi"; Set-Content $p "standard $r" -NoNewline; $files += [ordered]@{ Role = $r; Path = $p; Sha256 = (Get-SysFileHash $p) } }
 $script:NoEscFiles = @(foreach ($r in 'automatic-wrapper', 'automatic-unlock') { [pscustomobject]@{ Role = $r; Path = (Join-Path $t "noesc\$r.efi") } })
 $assets = Join-Path $t 'assets'; [void](New-Item -ItemType Directory $assets)
 $bk = Join-Path $t 'installer\Backups\i1'; [void](New-Item -ItemType Directory $bk -Force)
 # the manual setup as the first unlock left it
 [void](New-Item -ItemType Directory (Join-Path $script:BootDir 'EFI\BOOT') -Force); [void](New-Item -ItemType Directory (Join-Path $script:BootDir 'EFI\WindowsGPUUnlock') -Force)
 if ($WithOriginal) { Set-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') 'user original' -NoNewline }
 $st = [ordered]@{ Version = 1; Phase = 'extra1-offer'; BackupFolder = $bk; BootPartition = [ordered]@{ DriveLetter = 'U'; Disk = 0; Number = 3; Guid = 'g' }
  Build = [ordered]@{ Files = $files }; Assets = $assets; TestsPassed = 'x'; Unlock = [ordered]@{ Applied = $true }
  Benchmark = [ordered]@{ Enabled = $true; Verdict = 'clear improvement' }; AutoResume = [ordered]@{ Consent = $false; Asked = 'x' }
  Shortcut = [ordered]@{ Script = 'S'; Links = @('a'); Mode = 'manual' }
  CaptureDir = (Join-Path $t 'cap'); Profile = [ordered]@{ Dir = (Join-Path $t 'prof') } }
 Stage-ManualProgram $st
 Save-InstallerState $st
 $script:Entries = 1; $script:IsQueued = $false; $script:Restarts = 0; $script:Calls.Clear(); $script:Shortcuts = @(); $script:EveryBootOn = 0; $script:EveryBootOff = 0
 $script:BuildFails = $false; $script:TestFails = $false; $script:PatchApplied = $false; $script:Git = 'C:\git\git.exe'; $script:FakeRunOnce = $null
 $script:Records = New-Object System.Collections.Queue
 [pscustomobject]@{ T = $t; State = $st }
}
function Opt { @{ DryRun = $false; ReportFolder = (Join-Path (Get-InstallerRoot) 'rep'); CaptureFolder = $null } }
function BootHash([string]$Rel) { Get-SysFileHash (Join-Path $script:BootDir $Rel) }
function MakeRun([string]$Name, [string]$Final) {
 $d = Join-Path $script:BootDir "RTX3060-UNLOCK\$Name"; [void](New-Item -ItemType Directory $d -Force)
 Set-Content (Join-Path $d 'REPORT.TXT') "SS0=88888888 SS1=00000008`r`n$Final`r`n"
}
$applied = 'FINAL status=0 stage=transaction attempted=1 driver_release=0 clean=1'

# ---------- the stage plans ----------
$w = New-World
try {
 $s = $w.State
 $p = @(Get-AutomaticStagePlan $s 'standard')
 Expect 'standard plan: three files' $p.Count 3
 Expect 'the unlock program goes to UNLOCK-AUTO.EFI' ($p[0].Dest) 'EFI\WindowsGPUUnlock\UNLOCK-AUTO.EFI'
 Expect 'the wrapper goes to AUTO.EFI and to the file the firmware entry starts' (($p[1].Dest, $p[2].Dest) -join '|') 'EFI\WindowsGPUUnlock\AUTO.EFI|EFI\BOOT\BOOTX64.EFI'
 ExpectThrows 'a no-cancel plan without a no-cancel build is refused' { Get-AutomaticStagePlan $s 'noesc' } '*no automatic-wrapper*'
 $s.Build.NoEsc = [ordered]@{ Files = @($script:NoEscFiles | ForEach-Object { [ordered]@{ Role = $_.Role; Path = $_.Path; Sha256 = 'h' } }) }
 ExpectTrue 'a no-cancel plan uses the no-cancel files' ((Get-AutomaticStagePlan $s 'noesc')[0].Source -like '*noesc*')
} finally { Remove-TestRoot $w.T }

# ---------- Extra 1: the offer ----------
$w = New-World
try {
 $s = $w.State
 $s2 = [ordered]@{ Version = 1; Phase = 'x' }
 Set-Answers @()
 Expect 'no verified unlock: no extras, nothing asked' (Invoke-Phase-extra1-offer $s2 (Opt)).Next 'done'
 $s.Benchmark.Verdict = 'no meaningful improvement: consider rolling back'
 Set-Answers @()
 Expect 'the benchmark showed no gain: the extras are not offered' (Invoke-Phase-extra1-offer $s (Opt)).Next 'done'
 ExpectTrue 'and it says why' ((OutText) -like '*only when the benchmark showed the unlock helps*')
 $s.Benchmark.Verdict = 'clear improvement'
 $s3 = [ordered]@{ Version = 1; Phase = 'x'; TestsPassed = 'x'; Unlock = [ordered]@{ Applied = $true } }
 Set-Answers @('N'); Expect 'a benchmark that was skipped does not block the offer' (Invoke-Phase-extra1-offer $s3 (Opt)).Next 'done'
 ExpectTrue '... and the question was asked' ($script:Asked.Count -eq 1)
 Set-Answers @('N')
 $r = Invoke-Phase-extra1-offer $s (Opt)
 ExpectTrue 'declining to read about it changes nothing' (($r.Next -eq 'done') -and -not $s.Contains('Automatic'))
 Set-Answers @('Y', 'yes i accept')
 $r = Invoke-Phase-extra1-offer $s (Opt)
 ExpectTrue 'the wrong words do not accept it' (($r.Next -eq 'done') -and -not $s.Contains('Automatic') -and ((OutText) -like '*Extra 1 was not accepted. Nothing was changed.*'))
 ExpectTrue 'the screen explains the change, the checks that stay, the freeze and the power button, and the disclaimer' (((OutText) -like '*Optional extra 1*') -and ((OutText) -like '*every hardware check stays*') -and ((OutText) -like '*hold the power button*') -and ((OutText) -like '*"as is", with no warranty*') -and ((OutText) -like '*Esc cancels*'))
 Set-Answers @('Y', 'i accept')
 Expect 'words are case-sensitive' (Invoke-Phase-extra1-offer $s (Opt)).Next 'done'
 Set-Answers @('Y', 'I ACCEPT')
 $r = Invoke-Phase-extra1-offer $s (Opt)
 ExpectTrue 'I ACCEPT goes on to staging, automatic mode not active yet' (($r.Next -eq 'extra1-stage') -and ($s.Automatic.Active -eq $false))
 $s.Remove('TestsPassed')
 Expect 'untested programs are never offered' (Invoke-Phase-extra1-offer $s (Opt)).Stop 'the boot programs have not passed the host tests'
}
finally { Remove-TestRoot $w.T }

# ---------- Extra 1: stage, queue, collect ----------
$w = New-World
try {
 $s = $w.State; $s.Automatic = [ordered]@{ Active = $false }
 $manualHash = BootHash 'EFI\BOOT\BOOTX64.EFI'
 $std = @(Get-AutomaticStagePlan $s 'standard')
 Set-Answers @()
 Expect 'stage: goes to the queue step' (Invoke-Phase-extra1-stage $s (Opt)).Next 'extra1-queue'
 Expect 'the firmware entry now starts the automatic wrapper' (BootHash 'EFI\BOOT\BOOTX64.EFI') $std[1].Sha256
 Expect 'AUTO.EFI is the wrapper' (BootHash 'EFI\WindowsGPUUnlock\AUTO.EFI') $std[1].Sha256
 Expect 'UNLOCK-AUTO.EFI is the unlock program' (BootHash 'EFI\WindowsGPUUnlock\UNLOCK-AUTO.EFI') $std[0].Sha256
 Expect 'the manual pair is still there' (Get-Content (Join-Path $script:BootDir 'EFI\WindowsGPUUnlock\UNLOCK.EFI') -Raw) 'standard manual-unlock'
 ExpectTrue 'the replaced manual wrapper was saved first' (@(Get-ChildItem (Join-Path $w.State.BackupFolder 'staged') | Where-Object { (Get-SysFileHash $_.FullName) -eq $manualHash }).Count -eq 1)
 Set-Content $s.Build.Files[2].Path 'changed after the tests' -NoNewline
 ExpectThrows 'a program that changed after its tests is not staged' { Stage-AutomaticPair $s 'standard' } '*changed since it was built or tested*'
 Set-Content $s.Build.Files[2].Path 'standard automatic-wrapper' -NoNewline

 # queue
 Set-Answers @('Y')
 $r = Invoke-Phase-extra1-queue $s (Opt)
 ExpectTrue 'queue: one-time boot queued, restart asked, resume at collect' (($r.Resume -eq 'extra1-collect') -and $script:IsQueued -and $script:Restarts -eq 1)
 ExpectTrue 'the user was told what happens and how to recover' (((OutText) -like '*You press nothing*') -and ((OutText) -like '*hold the power button*'))
 ExpectTrue 'the run folders before the queue were recorded' ($s.Contains('RunFoldersBefore'))
 $script:Entries = 0; $script:IsQueued = $false
 Expect 'no firmware entry: stops, nothing else changed' (Invoke-Phase-extra1-queue $s (Opt)).Stop 'no firmware boot entry'
 $script:Entries = 1
 Expect 'dry run: nothing is queued or restarted' (Invoke-Phase-extra1-queue $s @{ DryRun = $true; ReportFolder = ''; CaptureFolder = $null }).Next 'extra1-collect'

 # collect
 $s.RunFoldersBefore = @(); $s.UnlockQueuedAt = (Get-Date).AddMinutes(-5).ToString('o')
 $script:IsQueued = $true; Set-Answers @()
 ExpectTrue 'still queued: wait for the restart' ((Invoke-Phase-extra1-collect $s (Opt)).Stop -like '*restart needed*')
 $script:IsQueued = $false
 Set-Answers @('N')
 $r = Invoke-Phase-extra1-collect $s (Opt)
 ExpectTrue 'no report and no retry: the manual setup is put back' (($r.Stop -like '*manual setup was put back*') -and ((BootHash 'EFI\BOOT\BOOTX64.EFI') -eq $manualHash) -and ($s.Automatic.Active -eq $false))
 Stage-AutomaticPair $s 'standard'
 Set-Answers @('Y'); Expect 'no report, retry: back to queueing' (Invoke-Phase-extra1-collect $s (Opt)).Next 'extra1-queue'
 MakeRun 'AUTO000001' 'FINAL status=0 stage=cancelled attempted=0 clean=1'
 Set-Answers @('N')
 $r = Invoke-Phase-extra1-collect $s (Opt)
 ExpectTrue 'cancelled and no retry: manual setup back' (($r.Stop -like '*cancelled*') -and ((BootHash 'EFI\BOOT\BOOTX64.EFI') -eq $manualHash))
 Stage-AutomaticPair $s 'standard'
 $s.RunFoldersBefore = @('AUTO000001')
 MakeRun 'AUTO000002' 'FINAL status=8000000000000007 stage=gfw attempted=0 clean=0'
 Set-Answers @()
 $r = Invoke-Phase-extra1-collect $s (Opt)
 ExpectTrue 'a failed check: manual setup back at once, no skip, a report is written' (($r.Stop -like '*stopped on a check*') -and ((BootHash 'EFI\BOOT\BOOTX64.EFI') -eq $manualHash) -and ((OutText) -like '*no way to skip the check*') -and @(Get-ChildItem (Get-InstallerRoot) -Recurse -Filter 'automatic-failed-*').Count -eq 1)
 Stage-AutomaticPair $s 'standard'
 $s.RunFoldersBefore = @('AUTO000001', 'AUTO000002')
 MakeRun 'AUTO000003' $applied
 # applied, benchmark measures a card that does not look unlocked
 $script:Records.Enqueue((BenchRec 8.2 26.5 26.4)); Set-Answers @('N')
 $r = Invoke-Phase-extra1-collect $s (Opt)
 ExpectTrue 'applied but the card does not look unlocked: not confirmed, manual back' (($r.Stop -like '*could not be confirmed*') -and ($s.Automatic.Active -eq $false) -and ((BootHash 'EFI\BOOT\BOOTX64.EFI') -eq $manualHash))
 Stage-AutomaticPair $s 'standard'
 $script:Records.Enqueue((BenchRec 8.2 48.1 50.3)); Set-Answers @()
 $r = Invoke-Phase-extra1-collect $s (Opt)
 ExpectTrue 'applied and measured unlocked: automatic mode is active' (($r.Next -eq 'extra1-shortcut') -and ($s.Automatic.Active -eq $true) -and ($s.Automatic.Measured.Fp16 -eq 48.1))
 $s.Benchmark.Enabled = $false; $s.Automatic.Active = $false
 $r = Invoke-Phase-extra1-collect $s (Opt)
 ExpectTrue 'applied with no benchmark: the report alone confirms it' (($r.Next -eq 'extra1-shortcut') -and ($s.Automatic.Active -eq $true))
 Expect 'dry run does not read anything' (Invoke-Phase-extra1-collect $s @{ DryRun = $true; ReportFolder = ''; CaptureFolder = $null }).Next 'extra1-shortcut'

 # shortcut and every start
 $script:Shortcuts = @()
 Set-Answers @('N')
 $r = Invoke-Phase-extra1-shortcut $s (Opt)
 ExpectTrue 'the shortcut is made again for automatic mode, every start declined' (($script:Shortcuts[0] -eq 'automatic') -and $script:EveryBootOn -eq 0 -and $r.Next -eq 'extra2-offer' -and $s.Shortcut.Mode -eq 'automatic')
 ExpectTrue 'every start was offered with its warning' (((OutText) -like '*Unlock at every start*') -and $script:Asked[0] -like 'Unlock at every start?*')
 $s.Shortcut.Links = @('a'); $script:Shortcuts = @()
 Set-Answers @('Y')
 $r = Invoke-Phase-extra1-shortcut $s (Opt)
 ExpectTrue 'a shortcut that existed is remade; Y sets up every start' (($script:Shortcuts[0] -eq 'automatic') -and $script:EveryBootOn -eq 1)
 Set-Answers @()
 $r = Invoke-Phase-extra1-shortcut $s (Opt)
 ExpectTrue 'once every start is on, it is not asked again' ($r.Next -eq 'extra2-offer' -and $script:EveryBootOn -eq 1)
 $s2 = [ordered]@{ Version = 1; Phase = 'x'; Automatic = [ordered]@{ Active = $true } }
 Set-Answers @('N'); Expect 'without a shortcut there is nothing to remake' (Invoke-Phase-extra1-shortcut $s2 (Opt)).Next 'extra2-offer'
 Expect 'and no shortcut was created' $script:Shortcuts.Count 2
}
finally { Remove-TestRoot $w.T }

# ---------- Extra 2 ----------
$w = New-World
try {
 $s = $w.State
 Set-Answers @()
 Expect 'extra 2 is not offered until extra 1 is active' (Invoke-Phase-extra2-offer $s (Opt)).Next 'done'
 $s.Automatic = [ordered]@{ Active = $true }
 Set-Answers @('N'); Expect 'declining to read about it changes nothing' (Invoke-Phase-extra2-offer $s (Opt)).Next 'done'
 $script:Git = $null
 Set-Answers @('Y')
 $r = Invoke-Phase-extra2-offer $s (Opt)
 ExpectTrue 'without Git it says so plainly and changes nothing' (($r.Next -eq 'done') -and ((OutText) -like '*needs Git for Windows*') -and ((OutText) -like '*git-scm.com*'))
 $script:Git = 'C:\git\git.exe'
 Set-Answers @('Y', 'maybe')
 $r = Invoke-Phase-extra2-offer $s (Opt)
 ExpectTrue 'the screen: no keyboard cancel, frozen screen, power button, Boot Manager first, disclaimer; wrong words do not accept' (($r.Next -eq 'done') -and ((OutText) -like '*can no longer cancel from the keyboard*') -and ((OutText) -like '*hold the power button*') -and ((OutText) -like '*Windows Boot Manager first*') -and ((OutText) -like '*no warranty*') -and ((OutText) -like '*Extra 2 was not accepted*'))
 Set-Answers @('Y', 'I ACCEPT')
 Expect 'accepted: build' (Invoke-Phase-extra2-offer $s (Opt)).Next 'extra2-build'
 $s.Automatic.NoEsc = $true
 Set-Answers @(); Expect 'already on: not offered again' (Invoke-Phase-extra2-offer $s (Opt)).Next 'done'
 $s.Automatic.NoEsc = $false

 # build
 $s.CaptureDir = $w.T
 Set-Answers @()
 $script:Calls.Clear()
 $r = Invoke-Phase-extra2-build $s (Opt)
 ExpectTrue 'build: passes and goes on to staging' (($r.Next -eq 'extra2-stage') -and $s.Build.NoEsc.TestsPassed)
 $apply = @($script:Calls | Where-Object { $_ -like '*Apply-NoCancelWindows*' -and $_ -notlike '*-Undo*' })
 ExpectTrue 'the patch script was given the typed acceptance and the build tools' (($apply.Count -eq 1) -and ($apply[0] -like "*-Accept 'I ACCEPT'*") -and ($apply[0] -like "*-Clang 'clang'*"))
 ExpectTrue 'only the two automatic-mode test groups were run on the patched build' (@($script:Calls | Where-Object { $_ -like '*test-automatic.ps1*' }).Count -eq 2 -and @($script:Calls | Where-Object { $_ -like '*o.ps1*' }).Count -eq 0)
 ExpectTrue 'the patch was taken off again afterwards' ((-not $script:PatchApplied) -and (@($script:Calls | Where-Object { $_ -like '*-Undo*' }).Count -ge 1))
 ExpectTrue 'the build record has hashes for both files' (@($s.Build.NoEsc.Files).Count -eq 2 -and $s.Build.NoEsc.Files[0].Sha256.Length -eq 64)
 # a failing test
 $s.Build.Remove('NoEsc'); $script:TestFails = $true; $script:Calls.Clear()
 $r = Invoke-Phase-extra2-build $s (Opt)
 ExpectTrue 'a failed test: stops, nothing recorded, patch removed, no skip' (($r.Stop -like '*test of the no-cancel build failed*') -and -not $s.Build.Contains('NoEsc') -and (-not $script:PatchApplied) -and ((OutText) -like '*no way to skip a test*'))
 $script:TestFails = $false
 # a failing build
 $script:BuildFails = $true
 ExpectThrows 'a failed build is reported with its output' { Invoke-Phase-extra2-build $s (Opt) } '*compile error*'
 ExpectTrue 'and the patch is not left applied' (-not $script:PatchApplied)
 $script:BuildFails = $false
 # a patch left over from an interrupted build is taken off first
 $script:PatchApplied = $true; $script:Calls.Clear()
 $r = Invoke-Phase-extra2-build $s (Opt)
 ExpectTrue 'a leftover patch is removed before building' (($script:Calls[1] -like '*-Undo*') -and $r.Next -eq 'extra2-stage')
 Expect 'dry run builds nothing' (Invoke-Phase-extra2-build $s @{ DryRun = $true; ReportFolder = ''; CaptureFolder = $null }).Next 'extra2-stage'

 # stage
 $s.Build.Remove('NoEsc')
 Expect 'untested no-cancel programs are never staged' (Invoke-Phase-extra2-stage $s (Opt)).Stop 'the no-cancel build has not passed its tests'
 $r = Invoke-Phase-extra2-build $s (Opt)
 Stage-AutomaticPair $s 'standard'
 $stdHash = BootHash 'EFI\BOOT\BOOTX64.EFI'
 $r = Invoke-Phase-extra2-stage $s (Opt)
 ExpectTrue 'staged: the entry now starts the no-cancel wrapper and the standard one was saved' (($r.Next -eq 'extra2-queue') -and ((BootHash 'EFI\BOOT\BOOTX64.EFI') -ne $stdHash) -and ((Get-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') -Raw) -eq 'noesc automatic-wrapper') -and @(Get-ChildItem (Join-Path $s.BackupFolder 'staged') | Where-Object { (Get-SysFileHash $_.FullName) -eq $stdHash }).Count -ge 1)

 # queue / collect
 $s.AutoResume.Consent = $false; Set-Answers @('Y')
 $r = Invoke-Phase-extra2-queue $s (Opt)
 ExpectTrue 'queued, with the no-cancel warning in the text' (($r.Resume -eq 'extra2-collect') -and ((OutText) -like '*cannot cancel from the keyboard*'))
 $s.RunFoldersBefore = @(); $s.UnlockQueuedAt = (Get-Date).AddMinutes(-5).ToString('o'); $script:IsQueued = $false
 MakeRun 'AUTO000010' $applied
 Set-Answers @()
 $r = Invoke-Phase-extra2-collect $s (Opt)
 ExpectTrue 'applied: extra 2 is recorded as on' (($r.Next -eq 'done') -and $s.Automatic.NoEsc -eq $true)
 $s.Automatic.NoEsc = $false; $s.RunFoldersBefore = @('AUTO000010')
 MakeRun 'AUTO000011' 'FINAL status=8000000000000007 stage=gfw attempted=0 clean=0'
 $r = Invoke-Phase-extra2-collect $s (Opt)
 ExpectTrue 'a failed run puts the version with the Esc windows back' (($r.Stop -like '*Esc windows was put back*') -and ((BootHash 'EFI\BOOT\BOOTX64.EFI') -eq $stdHash) -and ($s.Automatic.NoEsc -eq $false))
 # AUTO000011 (made just above) must count as already-known here, or it would look like a fresh
 # report on its own and this "still queued, nothing new yet" case would no longer be testing what
 # it says it tests.
 $s.RunFoldersBefore = @('AUTO000010', 'AUTO000011')
 $script:IsQueued = $true
 ExpectTrue 'still queued: wait' ((Invoke-Phase-extra2-collect $s (Opt)).Stop -like '*restart needed*')
 $script:IsQueued = $false
 Set-Answers @('N')
 $r = Invoke-Phase-extra2-collect $s (Opt)
 ExpectTrue 'no report, no retry: Esc version back' (($r.Stop -like '*left no report*') -and ((BootHash 'EFI\BOOT\BOOTX64.EFI') -eq $stdHash))
}
finally { Remove-TestRoot $w.T }

# ---------- switching the extras off ----------
$w = New-World
try {
 $s = $w.State; $s.Automatic = [ordered]@{ Active = $true }; $s.Schedule = [ordered]@{ Mode = 'EveryBoot' }
 $manualHash = BootHash 'EFI\BOOT\BOOTX64.EFI'
 Stage-AutomaticPair $s 'standard'
 $script:Shortcuts = @()
 Disable-Extras $s -DryRun
 ExpectTrue 'dry run changes nothing' (((BootHash 'EFI\BOOT\BOOTX64.EFI') -ne $manualHash) -and $s.Automatic.Active -and $script:EveryBootOff -eq 0 -and $script:Shortcuts.Count -eq 0)
 Disable-Extras $s
 ExpectTrue 'the manual wrapper is the firmware entry''s file again' ((BootHash 'EFI\BOOT\BOOTX64.EFI') -eq $manualHash)
 ExpectTrue 'the startup task is removed' ($script:EveryBootOff -eq 1 -and $s.Schedule.Mode -eq 'Off')
 ExpectTrue 'the shortcut says manual again' (($script:Shortcuts[0] -eq 'manual') -and $s.Shortcut.Mode -eq 'manual')
 ExpectTrue 'automatic mode is off in the state' ($s.Automatic.Active -eq $false)
 ExpectTrue 'the automatic programs stay on the partition (nothing was deleted)' (Test-Path (Join-Path $script:BootDir 'EFI\WindowsGPUUnlock\UNLOCK-AUTO.EFI'))
 # the start menu offers it only while the extras are on
 $s.Automatic.Active = $true
 Set-Answers @('3'); Expect 'start menu with extras on: 3 switches them off' (Select-StartAction $s) 'SwitchOff'
 ExpectTrue 'and Exit is then number 4' ((OutText) -like '*4. Exit*')
 Set-Answers @('4'); Expect 'start menu: 4 is Exit' (Select-StartAction $s) 'Exit'
 $s.Automatic.Active = $false
 Set-Answers @('3'); Expect 'start menu with extras off: 3 is Exit' (Select-StartAction $s) 'Exit'
}
finally { Remove-TestRoot $w.T }

# ---------- Roll back after the extras: the saved originals come back ----------
$w = New-World -WithOriginal
try {
 $s = $w.State; $s.Automatic = [ordered]@{ Active = $true }
 $origFile = Join-Path $w.T 'orig.bin'; Set-Content $origFile 'user original' -NoNewline; $origHash = Get-SysFileHash $origFile
 Stage-AutomaticPair $s 'standard'
 $s.Build.NoEsc = [ordered]@{ Files = @(foreach ($f in $script:NoEscFiles) { [void](New-Item -ItemType Directory (Split-Path -Parent $f.Path) -Force); Set-Content $f.Path "noesc $($f.Role)" -NoNewline; [ordered]@{ Role = $f.Role; Path = $f.Path; Sha256 = (Get-SysFileHash $f.Path) } }); TestsPassed = 'x' }
 Stage-AutomaticPair $s 'noesc'
 Save-InstallerState $s
 function Get-SysPartitionIdentity([int]$Disk, [int]$Number) { [pscustomobject]@{ Disk = $Disk; Number = $Number; Guid = 'g'; Offset = 1; SizeBytes = 2GB; DriveLetter = 'U' } }
 function Get-SysVolumeLabel([string]$Letter) { 'GPUUNLOCK' }
 function Get-RelativeBootPath([string]$Target) { $Target.Substring($script:BootDir.Length + 1) }
 function Get-BootRootFromLetter([string]$Letter) { $script:BootDir + '\' }
 function Get-SysFastStartup { 0 }
 function Compare-WithBackup([string]$Dir) { [pscustomobject]@{ FastStartup = $true; DisplayOrder = $true } }
 function Invoke-SysClearQueue { $true }
 Set-Content (Join-Path $w.State.BackupFolder 'fast-startup.json') '{"HiberbootEnabled":0}'
 Set-Answers @('Y', 'N', 'N')
 $r = Invoke-Rollback
 Expect 'after the manual setup, two extras and a roll back the user''s own original file is back, byte for byte' (BootHash 'EFI\BOOT\BOOTX64.EFI') $origHash
 ExpectTrue 'the automatic files the installer added are gone' ((-not (Test-Path (Join-Path $script:BootDir 'EFI\WindowsGPUUnlock\UNLOCK-AUTO.EFI'))) -and (-not (Test-Path (Join-Path $script:BootDir 'EFI\WindowsGPUUnlock\AUTO.EFI'))))
}
finally { Remove-TestRoot $w.T }

# ---------- the whole chain through the phase loop ----------
$w = New-World
try {
 $s = $w.State; Save-InstallerState $s
 Set-Answers @('Y', 'I ACCEPT', 'Y')            # read extra 1, accept, restart now (resume consent was answered earlier)
 $r1 = Invoke-Installer -ReportFolder (Join-Path $w.T 'rep')
 ExpectTrue 'run 1: staged, queued, stops for the restart' ((-not $r1.Done) -and $r1.Phase -eq 'extra1-collect' -and $script:IsQueued)
 $script:IsQueued = $false
 MakeRun 'AUTO000001' $applied
 $script:Records.Enqueue((BenchRec 8.2 48.1 50.3))
 Set-Answers @('N', 'N')                          # no every-start; no look at extra 2
 $r2 = Invoke-Installer -ReportFolder (Join-Path $w.T 'rep')
 ExpectTrue 'run 2: confirmed, shortcut remade, finished' ($r2.Done -and (Read-InstallerState).Automatic.Active -eq $true -and (Read-InstallerState).Phase -eq 'done')
}
finally { Remove-TestRoot $w.T }

# ---------- the real patch still applies to the real source tree (read-only check) ----------
$realGit = (Get-Command git.exe -ErrorAction SilentlyContinue)
if ($realGit) {
 Push-Location $repo
 $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # git's messages go to stderr
 try {
  & git apply --check (Join-Path $repo 'patches/no-cancel-windows.patch') 2>$null
  Expect 'patches/no-cancel-windows.patch applies cleanly to the current sources (git apply --check)' $LASTEXITCODE 0
  & git apply -R --check (Join-Path $repo 'patches/no-cancel-windows.patch') 2>$null
  ExpectTrue 'and is not left applied in the source tree' ($LASTEXITCODE -ne 0)
 } finally { $ErrorActionPreference = $eap; Pop-Location }
} else { Write-Host 'skip: git is not installed here' }

# ---------- the phase list ----------
foreach ($ph in 'extra1-offer', 'extra1-stage', 'extra1-queue', 'extra1-collect', 'extra1-shortcut', 'extra2-offer', 'extra2-build', 'extra2-stage', 'extra2-queue', 'extra2-collect') {
 ExpectTrue "phase $ph exists and has a plain name" (($script:PhaseOrder -contains $ph) -and (Get-Command "Invoke-Phase-$ph" -ErrorAction SilentlyContinue) -and $script:PhaseNames.Contains($ph))
}
Expect 'the extras come after the schedule step' ($script:PhaseOrder.IndexOf('extra1-offer')) ($script:PhaseOrder.IndexOf('schedule') + 1)

Complete-Tests
