# A whole install simulated across its restarts: three runs of the same command, with the firmware, restarts, build and host tests
# mocked and the profile generated for real from the reference machine's private capture (skipped when it is not available).
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$repo = Split-Path -Parent $base
$capDir = if ($env:GPU_UNLOCK_CAPTURES) { $env:GPU_UNLOCK_CAPTURES } else { Join-Path (Split-Path -Parent $repo) 'captures' }
$run03 = Join-Path $capDir 'run03-restart-adapter-on-3060'; $run04 = Join-Path $capDir 'run04'
$python = (Get-Command python.exe -All | Where-Object { $_.Source -notlike '*WindowsApps*' } | Select-Object -First 1).Source
if (-not ((Test-Path "$run03\DIAG02.TXT") -and (Test-Path "$run04\PROM.BIN") -and $python)) { Write-Host 'skip: private reference capture or python not available'; Complete-Tests; return }

$t = New-TestRoot
try {
 Set-RepoRoot $repo
 $boot = Join-Path $t 'bootpart'; [void](New-Item -ItemType Directory (Join-Path $boot 'RTX3060-UNLOCK') -Force)
 function Get-BootRoot($State) { $script:BootDir + '\' }
 $script:BootDir = $boot

 # a PC where everything passes, two cards, an existing boot partition
 function A($Name, $Dev, $Sub, $Bus, $Ven = '10DE') { $b = $Bus -split '[:.]'; [pscustomobject]@{ Name = $Name; InstanceId = "PCI\VEN_$Ven&DEV_$Dev&SUBSYS_$Sub\X"; Location = ('PCI bus {0}, device {1}, function {2}' -f [int]$b[0], [int]$b[1], [int]$b[2]) } }
 function Get-SysAdapters { @((A 'NVIDIA GeForce RTX 3060' '2544' '397D1462' '01:00.0'), (A 'NVIDIA GeForce RTX 5070' '2F04' '89F21043' '02:00.0')) }
 function Get-SysNvidiaSmi { @([pscustomobject]@{ Bus = '01:00.0'; VramMiB = 12288; Display = 'Disabled' }, [pscustomobject]@{ Bus = '02:00.0'; VramMiB = 12227; Display = 'Enabled' }) }
 function Get-SysIsAdmin { $true }
 function Get-SysOs { [pscustomobject]@{ Build = 26300; Is64 = $true; Caption = 'Windows 11' } }
 function Get-SysBootMgrPath { '\EFI\Microsoft\Boot\bootmgfw.efi' }
 function Get-SysSecureBoot { 'Off' }
 function Get-SysBitLocker { [pscustomobject]@{ Known = $true; ProtectionStatus = 0; ConversionStatus = 0 } }
 function Get-SysChassis { [pscustomobject]@{ Types = @(3); Manufacturer = 'X'; Model = 'Y' } }
 function Get-SysFastStartup { 0 }
 function Get-SysQueuedBoot { $script:IsQueued }
 function Get-SysDisk { [pscustomobject]@{ Style = 'GPT'; EspCount = 1; ShrinkableBytes = [int64]155GB; Candidates = @() } }
 $ESP = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
 $script:Layout = [pscustomobject]@{ WindowsDisk = 0; CSizeBytes = [int64]1860GB; CShrinkableBytes = [int64]155GB; CFreeBytes = [int64]400GB
  Disks = @([pscustomobject]@{ Number = 0; BusType = 'NVMe'; PartitionStyle = 'GPT'; IsSystem = $true; IsOffline = $false; SizeBytes = [int64]1TB; LargestFreeBytes = [int64]0; Name = 'D0' })
  Partitions = @([pscustomobject]@{ Disk = 0; Number = 1; Guid = '{w}'; GptType = $ESP; IsWindowsEsp = $true; FileSystem = 'FAT32'; Label = ''; SizeBytes = [int64]100MB; DriveLetter = '' },
   [pscustomobject]@{ Disk = 0; Number = 4; Guid = '{7188d005-9794-47ba-9c9b-f144488bdc1e}'; GptType = $ESP; IsWindowsEsp = $false; FileSystem = 'FAT32'; Label = 'GPUUNLOCK'; SizeBytes = [int64]2GB; DriveLetter = 'U' }) }
 function Get-SysDiskLayout { $script:Layout }
 function Invoke-SysBcdExport([string]$Path) { Set-Content -LiteralPath $Path -Value 'bcd' }
 function Get-SysBcdText([string[]]$BcdArgs) { 'x' }
 function Get-SysPartitionTable { @() }
 function Get-SysBoard { [pscustomobject]@{ Board = 'MS-7D85'; Bios = '1.I0' } }

 # tools, build, firmware, host tests: mocked at their outer edge
 $tools = @([pscustomobject]@{ Id = 'llvm'; Name = 'llvm'; Ok = $true; Detail = 'ok'; Info = [pscustomobject]@{ Path = 'C:\LLVM\bin\clang.exe'; Dir = 'C:\LLVM\bin'; Lld = 'x' } },
  [pscustomobject]@{ Id = 'python'; Name = 'python'; Ok = $true; Detail = 'ok'; Info = [pscustomobject]@{ Path = $python } },
  [pscustomobject]@{ Id = 'msvc'; Name = 'msvc'; Ok = $true; Detail = 'ok'; Info = [pscustomobject]@{ VcVars = 'v'; VswhereDir = 'd' } })
 function Get-ToolStatus { $tools }
 $diagEfi = Join-Path $t 'DIAGNOSTIC.EFI'; Set-Content $diagEfi 'DIAG-EFI' -Encoding ascii
 function Build-Diagnostic($State, $Tools, [switch]$DryRun) { [pscustomobject]@{ Path = $diagEfi; Sha256 = (Get-SysFileHash $diagEfi) } }
 function Resolve-Assets($State, $Tools, [switch]$DryRun) { 'C:\fake\assets' }
 function New-PlatformConfig($State, [switch]$DryRun) { 'hash' }
 function Build-BootPrograms($State, $Tools, [string]$ProfileDir, [switch]$DryRun) { @(1..4 | ForEach-Object { [pscustomobject]@{ Role = "r$_"; Path = "p$_"; Sha256 = ('{0:x64}' -f $_) } }) }
 $script:TestsOk = $true
 function Initialize-Benchmark($State, $Tools, [switch]$DryRun) { $script:BenchPrepared = $true }
 $script:Measurements = New-Object System.Collections.Queue
 function Invoke-BenchmarkRun($State, [string]$Label, [switch]$DryRun) { $m = $script:Measurements.Dequeue(); $m.Label = $Label; $m }
 function Stage-ManualProgram($State, [switch]$DryRun) { $script:Staged = $true }
 function Test-StagedFiles($State) { @() }
 function BenchRec($Fp32, $Fp16, $Bf16) { [ordered]@{ Label = ''; Gpu = 'NVIDIA GeForce RTX 3060'; Bus = '01:00.0'; Driver = '617.42'; Fp32 = $Fp32; Fp16 = $Fp16; Bf16 = $Bf16; MaxPowerWatts = 100; MaxTempC = 60; MaxSmClockMhz = 1900 } }
 $script:Measurements.Enqueue((BenchRec 8.20 26.51 26.40)); $script:Measurements.Enqueue((BenchRec 8.18 48.13 50.34))
 function Invoke-HostTests($State, $Tools, [string]$AssetsDir, [switch]$DryRun) { [pscustomobject]@{ Ok = $script:TestsOk; Results = @([pscustomobject]@{ Name = 'all'; Passed = $script:TestsOk; Detail = 'detail'; Log = '' }) } }

 # firmware entry / queue / restarts, mocked
 $script:Entries = 0; $script:IsQueued = $false; $script:Restarts = 0
 function Find-UnlockEntries([string]$Label = 'GPUUNLOCK') { if ($script:Entries -eq 0) { , @() } else { , @('{entry}') } }
 function Invoke-SysQueueBoot([string]$EntryId) { $script:IsQueued = $true }
 function Get-SysFwBootMgrText { if ($script:IsQueued) { "bootsequence {entry}" } else { 'displayorder {bootmgr}' } }
 function Invoke-SysRestart([int]$Seconds, [string]$Reason) { $script:Restarts++; 0 }
 function Invoke-SysPython([string]$Python, [string[]]$PyArgs) { $ErrorActionPreference = 'Continue'; $o = & $Python -X utf8 -I @PyArgs 2>&1; [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($o | Out-String) } }

 $rep = Join-Path $t 'reports'

 # ------------- run 1: checks, cards, tools, partition, plan, backup, stage, no firmware entry yet -------------
 Set-Answers @('Y', 'Y', 'Y', 'Y', 'Y')      # target card, screen adapter, plan, automatic resume, restart
 $r1 = Invoke-Installer -ReportFolder $rep
 ExpectTrue 'run 1 stops for the first restart' ((-not $r1.Done) -and $r1.Reason -like '*firmware notices*')
 Expect 'run 1 resumes at the entry phase' $r1.Phase 'diag-entry'
 Expect 'one restart was started' $script:Restarts 1
 Expect 'all five answers were used' $script:Answers.Count 0
 ExpectTrue 'the automatic resume entry was registered (consent given)' (Test-ResumeEntry)
 ExpectTrue 'and it starts the installer with -Resume' ((Get-SysResumeTask) -like '*Install-GpuUnlock.ps1* -Resume')
 ExpectTrue 'the diagnostic is on the boot partition (fallback path)' (Test-Path (Join-Path $boot 'EFI\BOOT\BOOTX64.EFI'))
 ExpectTrue 'and in its own folder' (Test-Path (Join-Path $boot 'EFI\WindowsGPUUnlock\DIAGNOSTIC.EFI'))
 ExpectTrue 'the log folder exists' (Test-Path (Join-Path $boot 'RTX3060-UNLOCK'))
 $s = Read-InstallerState
 Expect 'target saved' $s.Cards.Target.Bus '01:00.0'
 Expect 'letter of the existing partition saved' $s.BootPartition.DriveLetter 'U'
 ExpectTrue 'plan and backup recorded' ([bool]$s.PlanConfirmed -and [bool]$s.BackupFolder)

 # ------------- run 2: the firmware has made its entry; queue the diagnostic and restart -------------
 $script:Entries = 1
 Set-Answers @('Y')                      # restart
 $r2 = Invoke-Installer -ReportFolder $rep
 ExpectTrue 'run 2 stops for the diagnostic restart' ((-not $r2.Done) -and $r2.Reason -like '*restart to run the diagnostic*')
 Expect 'run 2 resumes at collect' $r2.Phase 'diag-collect'
 ExpectTrue 'the one-time boot is queued' $script:IsQueued
 Expect 'second restart' $script:Restarts 2
 Expect 'only the restart question was asked' $script:Asked.Count 1

 # ------------- the diagnostic runs (simulated): it writes its log next to the boot partition -------------
 $script:IsQueued = $false
 $d = Join-Path $boot 'RTX3060-UNLOCK'
 Copy-Item "$run03\DIAG02.TXT" "$d\DIAG01.TXT"; Get-ChildItem $run03 -Filter 'IMG*.BIN' | Copy-Item -Destination $d; Copy-Item "$run04\PROM.BIN" $d
 Get-ChildItem $d -File | ForEach-Object { $_.LastWriteTime = Get-Date }   # the diagnostic writes these now, not when they were captured

 # ------------- run 3: collect, profile, firmware, build, tests -------------
 Set-Answers @('Y', 'Y', 'Y')            # accept the profile, run the benchmark, restart for the first unlock
 $r3 = Invoke-Installer -ReportFolder $rep
 $shown = ((OutText) -like '*display output for it: yes*')   # the next Set-Answers clears the captured output
 ExpectTrue 'run 3 stops for the first unlock restart' ((-not $r3.Done) -and $r3.Reason -like '*restart to run the first unlock*')
 Expect 'run 3 resumes at the unlock collection' $r3.Phase 'unlock-collect'
 ExpectTrue 'the benchmark was prepared and the programs staged before the unlock' ($script:BenchPrepared -and $script:Staged)
 ExpectTrue 'the unlock boot is queued' $script:IsQueued
 Expect 'third restart' $script:Restarts 3
 ExpectTrue 'the profile is tied to this BIOS and board, and the boot programs to their sources' (((Read-InstallerState).Environment.Bios -is [string]) -and (Read-InstallerState).Build.SourceFingerprint.Length -eq 64)
 $s = Read-InstallerState
 Expect 'the baseline was measured before the unlock' $s.Benchmark.Before.Fp16 26.51
 ExpectTrue 'the user was told how to recover' ((OutText) -like '*hold the power button*')

 # ------------- the first unlock runs (simulated), then run 4 measures and judges -------------
 $script:IsQueued = $false
 $rd = Join-Path $boot 'RUN01'; [void](New-Item -ItemType Directory (Join-Path $boot 'RTX3060-UNLOCK\RUN01') -Force)
 Set-Content (Join-Path $boot 'RTX3060-UNLOCK\RUN01\REPORT.TXT') "SS0=88888888 SS1=00000008`r`nFINAL status=0 stage=transaction attempted=1 driver_release=0 clean=1`r`n"
 Set-Answers @('N', 'N')                 # no shortcut, no look at the extras
 $r3b = Invoke-Installer -ReportFolder $rep
 ExpectTrue 'run 4 finishes' $r3b.Done
 ExpectTrue 'and no automatic resume entry is left' (-not (Test-ResumeEntry))
 $s = Read-InstallerState
 Expect 'phase is done' $s.Phase 'done'
 Expect 'the unlock was recorded as applied' $s.Unlock.Applied $true
 Expect 'the unlocked speed was measured after' $s.Benchmark.After.Fp16 48.13
 Expect 'verdict stored' $s.Benchmark.Verdict 'clear improvement'
 ExpectTrue 'the verdict screen was shown' ((OutText) -like '*Verdict: clear improvement.*')
 ExpectTrue 'a public-safe benchmark report was written' (@(Get-ChildItem $rep -Filter 'benchmark-*').Count -eq 1)
 ExpectTrue 'the capture was collected into the work folder' (Test-Path (Join-Path $s.CaptureDir 'DIAG.TXT'))
 ExpectTrue 'the profile exists' (Test-Path (Join-Path $s.Profile.Dir 'profile.h'))
 Expect 'profile summary: the card' $s.Profile.Summary.target.id '10de:2544'
 Expect 'firmware folder recorded' $s.Assets 'C:\fake\assets'
 Expect 'four built files recorded' $s.Build.Files.Count 4
 ExpectTrue 'tests passed time recorded' ([bool]$s.TestsPassed)
 ExpectTrue 'the summary was shown to the user' $shown

 # journal shows every change, all done
 $j = @(Read-Journal)
 ExpectTrue 'no failed or planned-only journal entries (the staging is mocked here)' (@($j | Where-Object { $_.Status -ne 'done' }).Count -eq 0)
 ExpectTrue 'journal covers backup, staging and queue' ((@($j | Where-Object Phase -eq 'backup').Count -ge 1) -and (@($j | Where-Object Phase -eq 'stage').Count -ge 2) -and (@($j | Where-Object Phase -eq 'queue').Count -eq 2))

 # ------------- host test failure stops the run and keeps the phase -------------
 $s = Read-InstallerState; $s.Phase = 'hosttests'; Save-InstallerState $s
 $script:TestsOk = $false; Set-Answers @()
 $r4 = Invoke-Installer -ReportFolder $rep
 ExpectTrue 'a failing host test stops the installer' ((-not $r4.Done) -and $r4.Reason -eq 'a host test failed')
 Expect 'and keeps the phase for the next run' $r4.Phase 'hosttests'
 $script:TestsOk = $true

 # ------------- a refusal (no display on the target) offers a new capture -------------
 $s = Read-InstallerState; $s.Phase = 'diag-collect'; $s.CaptureQueuedAt = (Get-Date).AddHours(-1).ToString('o'); Save-InstallerState $s
 Remove-Item "$d\IMG34.BIN"        # the card's driver dump is missing
 (Get-Item "$d\DIAG01.TXT").LastWriteTime = Get-Date
 Set-Answers @('N')                 # do not capture again
 $r5 = Invoke-Installer -ReportFolder $rep
 ExpectTrue 'a capture the generator cannot use is refused' ((-not $r5.Done) -and $r5.Reason -eq 'no safe profile for this PC')
 ExpectTrue 'the reason is shown in words' ((OutText) -like '*GOP driver*')
 Set-Answers @('Y', 'N')            # capture again; do not restart yet
 $s = Read-InstallerState; $s.Phase = 'diag-collect'; Save-InstallerState $s
 $script:Entries = 1
 $r6 = Invoke-Installer -ReportFolder $rep
 ExpectTrue 'Y re-queues the diagnostic and waits for the restart the user postponed' ((-not $r6.Done) -and $r6.Reason -like '*restart to run the diagnostic*' -and $r6.Phase -eq 'diag-collect')
 ExpectTrue 'the diagnostic is queued again' $script:IsQueued
} finally { Remove-TestRoot $t }
Complete-Tests
