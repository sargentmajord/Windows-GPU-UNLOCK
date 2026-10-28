# Staging the manual boot programs, reading the unlock run's report, and the first-unlock phases, with the boot partition a temp folder.
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')

# ---------------- report reading (real FINAL line formats from the reference machine's runs) ----------------
$t = New-TestRoot
try {
 function Report($Name, $Text) { $p = Join-Path $t $Name; Set-Content -LiteralPath $p -Value $Text -Encoding ascii; $p }
 $ok = Report 'ok.txt' "line`r`npost-FLR SEC2 reset released, GSP halted, BME=0 pending=0 WPR2=1ffffe00:00000000 SS0=88888888 SS1=00000008`r`ntransaction result=0 containment=0 started=1 quiesced=1 fault=0 retained=0 maps=0 FLR=1`r`nFINAL status=0 stage=transaction attempted=1 driver_release=0 clean=1`r`n"
 $r = Read-RunReport $ok
 Expect 'a clean transaction is Applied' $r.Class 'Applied'
 Expect 'selectors read' $r.Selectors '88888888/00000008'
 ExpectTrue 'the final line is kept' ($r.Final -like 'FINAL status=0 stage=transaction attempted=1*')
 Expect 'not attempted with status 0 is NotApplied' (Read-RunReport (Report 'c.txt' "FINAL status=0 stage=cancelled attempted=0 driver_release=0 clean=1")).Class 'NotApplied'
 Expect 'attempted but not clean is Failed' (Read-RunReport (Report 'f.txt' "FINAL status=0 stage=transaction attempted=1 driver_release=0 clean=0")).Class 'Failed'
 Expect 'attempted with an error status is Failed' (Read-RunReport (Report 'f2.txt' "FINAL status=8000000000000007 stage=transaction attempted=1 driver_release=0 clean=1")).Class 'Failed'
 Expect 'not attempted with an error status is Failed' (Read-RunReport (Report 'f3.txt' "FINAL status=8000000000000007 stage=preflight attempted=0 driver_release=0 clean=0")).Class 'Failed'
 # Real format from app.c's FINAL line (GuLog "%#llx"): the # flag prepends 0x for any nonzero value
 # (only a literal 0 prints bare), matching the reference machine's actual captured report exactly.
 Expect 'not attempted, 30-second keypress timeout at arming is NotApplied' (Read-RunReport (Report 'to.txt' "FINAL status=0x8000000000000012 stage=arming attempted=0 driver_release=0 clean=1")).Class 'NotApplied'
 Expect 'not attempted, Esc at arming is NotApplied' (Read-RunReport (Report 'esc.txt' "FINAL status=0x8000000000000015 stage=arming attempted=0 driver_release=0 clean=1")).Class 'NotApplied'
 Expect 'the same timeout status at a different stage is still Failed - not a blanket pass' (Read-RunReport (Report 'to2.txt' "FINAL status=0x8000000000000012 stage=preflight attempted=0 driver_release=0 clean=1")).Class 'Failed'
 Expect 'no final line is Unreadable' (Read-RunReport (Report 'u.txt' "no final line here")).Class 'Unreadable'
 Expect 'the LAST final line counts' (Read-RunReport (Report 'm.txt' "FINAL status=0 stage=x attempted=0 clean=1`r`nFINAL status=0 stage=transaction attempted=1 driver_release=0 clean=1")).Class 'Applied'

 # ---------------- finding the newest report ----------------
 $boot = Join-Path $t 'boot'; $d = Join-Path $boot 'RTX3060-UNLOCK'
 function Get-BootRoot($State) { $boot + '\' }
 $st = [ordered]@{ BootPartition = [ordered]@{ DriveLetter = 'U' } }
 function MakeRun($Name, $Minutes, $Text = 'FINAL status=0 stage=transaction attempted=1 clean=1') {
  $dir = Join-Path $d $Name; [void](New-Item -ItemType Directory $dir -Force); $f = Join-Path $dir 'REPORT.TXT'; Set-Content $f $Text; (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes($Minutes)
 }
 ExpectTrue 'no folder: no report' ($null -eq (Get-LatestRunReport $st $null (Get-Date).AddHours(-1)))
 MakeRun 'RUN00' -120; MakeRun 'RUN01' -30; MakeRun 'AUTO000003' -10
 Set-Content (Join-Path $d 'FULL00.TXT') 'x'; [void](New-Item -ItemType Directory (Join-Path $d 'ASSETS') -Force)
 $since = (Get-Date).AddMinutes(-60)
 ExpectTrue 'the newest report after the queue time is chosen' ((Get-LatestRunReport $st $null $since) -like '*AUTO000003*')
 ExpectTrue 'reports older than the queue time are ignored' ($null -eq (Get-LatestRunReport $st $null (Get-Date).AddMinutes(-5)))
 Remove-Item (Join-Path $d 'AUTO000003') -Recurse
 ExpectTrue 'a manual run is found too' ((Get-LatestRunReport $st $null $since) -like '*RUN01*')

 # ---------------- the new run is found by folder counter, not by clock (FAT times come from the firmware clock) ----------------
 ExpectTrue 'run folder names are listed' ((@(Get-RunFolderNames $st)) -contains 'RUN01')
 $beforeNames = @(Get-RunFolderNames $st)
 (Get-Item (Join-Path $d 'RUN01\REPORT.TXT')).LastWriteTime = (Get-Date).AddHours(5)      # a stale report whose clock is hours ahead
 ExpectTrue 'a stale report with a FUTURE time is not taken as the new run' ($null -eq (Get-LatestRunReport $st $beforeNames (Get-Date).AddMinutes(-1)))
 MakeRun 'RUN06' -300 'FINAL status=0 stage=transaction attempted=1 clean=1'                  # the new run, its clock hours behind
 ExpectTrue 'a fresh run whose time is hours in the PAST is still found' ((Get-LatestRunReport $st $beforeNames (Get-Date).AddMinutes(-1)) -like '*RUN06*')
 MakeRun 'AUTO000009' 0 'FINAL status=0 stage=transaction attempted=1 clean=1'
 ExpectTrue 'with several new folders the highest name wins' ((Get-LatestRunReport $st $beforeNames (Get-Date)) -like '*RUN06*' -or (Get-LatestRunReport $st $beforeNames (Get-Date)) -like '*AUTO000009*')
 ExpectTrue 'an empty earlier list means every folder is new' ($null -ne (Get-LatestRunReport $st @() (Get-Date)))
 Remove-Item (Join-Path $d 'RUN06'), (Join-Path $d 'AUTO000009') -Recurse -Force
 (Get-Item (Join-Path $d 'RUN01\REPORT.TXT')).LastWriteTime = (Get-Date).AddMinutes(-30)

 # ---------------- staging plan and files ----------------
 $src = Join-Path $t 'src'; [void](New-Item -ItemType Directory $src)
 foreach ($f in 'wrap.efi', 'child.efi') { Set-Content (Join-Path $src $f) "content-of-$f" -Encoding ascii }
 $assets = Join-Path $t 'assets'; [void](New-Item -ItemType Directory $assets)
 $fakeRepo = Join-Path $t 'repo'; [void](New-Item -ItemType Directory (Join-Path $fakeRepo 'internal-boot\unlock') -Force)
 $assetList = foreach ($n in 'a.bin', 'b.bin') { Set-Content (Join-Path $assets $n) "asset-$n" -NoNewline -Encoding ascii; [ordered]@{ Name = $n; Bytes = (Get-Item (Join-Path $assets $n)).Length; Sha256 = (Get-FileHash (Join-Path $assets $n)).Hash.ToLower() } }
 (@($assetList) | ConvertTo-Json) | Set-Content (Join-Path $fakeRepo 'internal-boot\unlock\assets.json')
 Set-RepoRoot $fakeRepo
 $wrapHash = (Get-FileHash (Join-Path $src 'wrap.efi')).Hash.ToLower(); $childHash = (Get-FileHash (Join-Path $src 'child.efi')).Hash.ToLower()
 $state = [ordered]@{ BootPartition = [ordered]@{ DriveLetter = 'U' }; BackupFolder = (Join-Path $t 'backup'); Assets = $assets
  Build = [ordered]@{ Files = @([ordered]@{ Role = 'manual-wrapper'; Path = (Join-Path $src 'wrap.efi'); Sha256 = $wrapHash }, [ordered]@{ Role = 'manual-unlock'; Path = (Join-Path $src 'child.efi'); Sha256 = $childHash },
   [ordered]@{ Role = 'automatic-wrapper'; Path = 'p3'; Sha256 = 'x' }, [ordered]@{ Role = 'automatic-unlock'; Path = 'p4'; Sha256 = 'x' }) } }
 $plan = @(Get-ManualStagePlan $state)
 Expect 'two programs, the assets and the fallback entry file' $plan.Count 5
 Expect 'child program destination' ($plan | Where-Object Dest -eq 'EFI\WindowsGPUUnlock\UNLOCK.EFI').Sha256 $childHash
 Expect 'wrapper destination' ($plan | Where-Object Dest -eq 'EFI\WindowsGPUUnlock\MANUAL.EFI').Sha256 $wrapHash
 Expect 'the firmware entry file is the manual wrapper' ($plan | Where-Object Dest -eq 'EFI\BOOT\BOOTX64.EFI').Sha256 $wrapHash
 ExpectTrue 'firmware files go to the assets folder' (($plan | Where-Object Dest -like 'RTX3060-UNLOCK\ASSETS\*').Count -eq 2)
 ExpectTrue 'the automatic pair is NOT staged by the safe installer' (($plan | Where-Object Dest -like '*AUTO*').Count -eq 0)
 ExpectThrows 'a missing build role is an error' { Get-ManualStagePlan ([ordered]@{ Build = [ordered]@{ Files = @() }; Assets = $assets }) } '*no manual-wrapper*'

 [void](New-Item -ItemType Directory (Join-Path $boot 'EFI\BOOT') -Force)
 Set-Content (Join-Path $boot 'EFI\BOOT\BOOTX64.EFI') 'old diagnostic' -Encoding ascii
 $n0 = @(Read-Journal).Count
 Stage-ManualProgram $state -DryRun
 ExpectTrue 'dry run copies nothing' (-not (Test-Path (Join-Path $boot 'EFI\WindowsGPUUnlock')))
 Expect 'dry run journals nothing' @(Read-Journal).Count $n0
 Stage-ManualProgram $state
 ExpectTrue 'all files are on the partition' (@(Test-StagedFiles $state).Count -eq 0)
 Expect 'the entry file is now the manual wrapper' (Get-Content (Join-Path $boot 'EFI\BOOT\BOOTX64.EFI') -Raw).Trim() 'content-of-wrap.efi'
 $j = @(Read-Journal | Where-Object { $_.Target -like '*BOOTX64.EFI' })[-1]
 ExpectTrue 'the replaced file was saved first' ((Get-Content $j.Previous.Backup -Raw).Trim() -eq 'old diagnostic')
 $n = @(Read-Journal).Count; Stage-ManualProgram $state
 Expect 'staging twice changes nothing the second time' @(Read-Journal).Count $n
 Add-Content (Join-Path $boot 'EFI\WindowsGPUUnlock\UNLOCK.EFI') 'tamper'
 ExpectTrue 'a changed staged file is noticed' ((@(Test-StagedFiles $state)) -like '*UNLOCK.EFI differs*')
 Remove-Item (Join-Path $boot 'RTX3060-UNLOCK\ASSETS\a.bin')
 ExpectTrue 'a missing staged file is noticed' ((@(Test-StagedFiles $state)) -like '*a.bin is missing*')
 # a source that changed after the tests is never staged
 Set-Content (Join-Path $src 'child.efi') 'changed after the tests' -Encoding ascii
 ExpectThrows 'a build that changed after testing is refused' { Stage-ManualProgram $state } '*changed since it was built or tested*'

 Set-Answers @(); Show-UnlockInstructions
 $i = OutText
 ExpectTrue 'instructions: press U once, Esc or 30 seconds cancels' (($i -like '*press U once*') -and ($i -like '*Esc*') -and ($i -like '*30 seconds*'))
 ExpectTrue 'instructions: power button recovery, no BIOS or menu' (($i -like '*hold the power button*') -and ($i -notlike '*BIOS*') -and ($i -notlike '*F11*'))
 ExpectTrue 'instructions: the unlock does not survive power-off and nothing is written to the card' (($i -like '*until the PC is powered off*') -and ($i -like '*Nothing is written to the card''s stored firmware*'))

 # ---------------- phases ----------------
 $opt = @{ DryRun = $false; ReportFolder = (Join-Path $t 'reports'); CaptureFolder = $null }
 $script:Entries = 1; $script:IsQueued = $false; $script:Restarts = 0
 function Find-UnlockEntries([string]$Label = 'GPUUNLOCK') { if ($script:Entries -eq 0) { , @() } else { , @('{entry}') } }
 function Invoke-SysQueueBoot([string]$EntryId) { $script:IsQueued = $true }
 function Get-SysFwBootMgrText { if ($script:IsQueued) { 'bootsequence {entry}' } else { 'displayorder {bootmgr}' } }
 function Invoke-SysRestart([int]$Seconds, [string]$Reason) { $script:Restarts++; 0 }
 $s2 = [ordered]@{ Phase = 'stage'; Benchmark = [ordered]@{ Enabled = $true } }
 Set-Answers @()
 Expect 'untested programs are never staged' (Invoke-Phase-stage $s2 $opt).Stop 'the boot programs have not passed the host tests'
 Expect 'nor offered the benchmark before the tests passed' (Invoke-Phase-benchmark-offer $s2 $opt).Stop 'the boot programs have not passed the host tests'

 # unlock-queue
 $s2.TestsPassed = (Get-Date).ToString('o'); $s2.BootPartition = $state.BootPartition
 Set-Answers @('N', 'Y')                  # no automatic resume, then restart
 $r = Invoke-Phase-unlock-queue $s2 $opt
 Expect 'queued, restart asked, resume at collect' $r.Resume 'unlock-collect'
 ExpectTrue 'queue time saved' ([bool]$s2.UnlockQueuedAt)
 ExpectTrue 'the instructions were shown' ((OutText) -like '*hold the power button*')
 $script:Entries = 0; $script:IsQueued = $false
 Expect 'no entry: stop, nothing else changed' (Invoke-Phase-unlock-queue $s2 $opt).Stop 'no firmware boot entry'

 # unlock-collect
 $script:Entries = 1
 $s2.UnlockQueuedAt = (Get-Date).AddMinutes(-20).ToString('o')
 $script:IsQueued = $true; Set-Answers @()
 ExpectTrue 'still queued: wait for the restart' ((Invoke-Phase-unlock-collect $s2 $opt).Stop -like '*restart needed*')
 $script:IsQueued = $false
 $s2.BootPartition = $state.BootPartition
 Remove-Item (Join-Path $d 'RUN0*') -Recurse -Force
 Set-Answers @('N')
 $r = Invoke-Phase-unlock-collect $s2 $opt
 Expect 'no report: asks to queue again, N stops' $r.Stop 'the unlock program left no report'
 Set-Answers @('Y'); Expect 'no report, Y: back to queueing' (Invoke-Phase-unlock-collect $s2 $opt).Next 'unlock-queue'
 MakeRun 'RUN02' -1 'FINAL status=0 stage=transaction attempted=1 clean=1'
 Set-Answers @()
 $r = Invoke-Phase-unlock-collect $s2 $opt
 Expect 'applied, benchmark on: measure after' $r.Next 'benchmark-after'
 ExpectTrue 'applied recorded' $s2.Unlock.Applied
 $s3 = [ordered]@{ UnlockQueuedAt = $s2.UnlockQueuedAt; BootPartition = $state.BootPartition; Benchmark = [ordered]@{ Enabled = $false; Skipped = $true } }
 Expect 'applied, benchmark skipped: straight to the closing screen' (Invoke-Phase-unlock-collect $s3 $opt).Next 'verdict'
 MakeRun 'RUN03' 0 'FINAL status=0 stage=cancelled attempted=0 clean=1'
 Set-Answers @('N')
 $r = Invoke-Phase-unlock-collect $s3 $opt
 Expect 'cancelled: explained, N stops' $r.Stop 'the unlock was not applied'
 ExpectTrue 'and says nothing was changed' ((OutText) -like '*Windows started normally and nothing was changed*')
 Set-Answers @('Y'); Expect 'cancelled, Y: try again' (Invoke-Phase-unlock-collect $s3 $opt).Next 'unlock-queue'
 MakeRun 'RUN04' 0 'FINAL status=8000000000000007 stage=gfw attempted=0 clean=0'
 Set-Answers @()
 $r = Invoke-Phase-unlock-collect $s3 $opt
 Expect 'failed: stops, no retry offered' $r.Stop 'the unlock program stopped on a check'
 ExpectTrue 'failed: the card keeps its speed and there is no skip' (((OutText) -like '*keeps its normal speed*') -and ((OutText) -like '*no way to skip the check*'))
 ExpectTrue 'failed: a public-safe report is written' (@(Get-ChildItem (Join-Path $t 'reports') -Filter 'unlock-failed-*').Count -eq 1)
 MakeRun 'RUN05' 0 'garbage'
 Set-Answers @('N')
 Expect 'unreadable: stops' (Invoke-Phase-unlock-collect $s3 $opt).Stop 'the unlock report is unreadable'
 Expect 'dry run does not read anything' (Invoke-Phase-unlock-collect $s2 @{ DryRun = $true; ReportFolder = ''; CaptureFolder = $null }).Next 'benchmark-after'
} finally { Remove-TestRoot $t }

Complete-Tests
