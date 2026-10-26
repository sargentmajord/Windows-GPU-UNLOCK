# Requirements 14, 16 and 31: the Roll back text, a changed BIOS or board forces a new capture, the state of the boot setup (lost firmware entry,
# missing or replaced fallback file, Secure Boot, Fast Startup) with repairs that ask first, and an update to newer boot programs that shows what changed and asks.
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main', 'Session') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$repo = Split-Path -Parent $base
Set-RepoRoot $repo

# ---------- requirement 14: the full text ----------
$txt = ((Get-RollbackExplanation) -join ' ') -replace '\s+', ' '
foreach ($k in 'never touches your Windows files, your own data, BIOS/UEFI settings or the graphics card''s stored firmware', 'such as turning Secure Boot off in the BIOS, are not reversed', 'the card behaves as if the installer had never run', 'prints a checklist of what was removed, what was already gone and what it left because you had changed it') {
 ExpectTrue "the Roll back text says: $k" ($txt -like "*$k*")
}

# ---------- replaced system calls ----------
$script:Board = [pscustomobject]@{ Board = 'MS-7E25'; Bios = '1.I0' }
function Get-SysBoard { $script:Board }
$script:SecureBoot = 'Off'; $script:FastStartup = 0; $script:EntryCount = 1; $script:RootOk = $true
function Get-SysSecureBoot { $script:SecureBoot }
function Get-SysFastStartup { $script:FastStartup }
function Find-UnlockEntries([string]$Label = 'GPUUNLOCK') { if ($script:EntryCount -eq 0) { , @() } else { , @(1..$script:EntryCount | ForEach-Object { '{entry}' }) } }
$script:BootDir = $null
function Resolve-RollbackBootRoot($State) { if ($script:RootOk) { [pscustomobject]@{ Root = ($script:BootDir + '\'); Reason = '' } } else { [pscustomobject]@{ Root = $null; Reason = 'the boot partition is not there any more' } } }
$script:Restaged = 0; $script:AutoRestaged = 0; $script:Restarts = 0; $script:Disabled = 0
function Stage-ManualProgram($State, [switch]$DryRun) { $script:Restaged++ }
function Stage-AutomaticPair($State, [string]$Variant = 'standard', [switch]$DryRun) { $script:AutoRestaged++ }
function Request-Restart([string]$Reason, [switch]$DryRun) { $script:Restarts++; $true }
function Disable-EveryBoot([switch]$DryRun) { $script:Disabled++; 'Off' }

function NewState([hashtable]$Extra = @{}) {
 $s = [ordered]@{ Version = 1; Phase = 'done'; Environment = [ordered]@{ Board = 'MS-7E25'; Bios = '1.I0' }
  Build = [ordered]@{ Files = @([ordered]@{ Role = 'manual-wrapper'; Path = 'a'; Sha256 = 'MANUAL' }, [ordered]@{ Role = 'automatic-wrapper'; Path = 'b'; Sha256 = 'AUTO' }); SourceFingerprint = 'OLD' }
  Cards = [ordered]@{ Target = [ordered]@{ Id = 'x' } }; Profile = [ordered]@{ Dir = 'p' }; CaptureDir = 'c'; TestsPassed = 't'; Unlock = [ordered]@{ Applied = $true }
  BootPartition = [ordered]@{ DriveLetter = 'U'; Disk = 0; Number = 3; Guid = 'g' } }
 foreach ($k in $Extra.Keys) { $s[$k] = $Extra[$k] }
 $s
}

$t = New-TestRoot
try {
 $script:BootDir = Join-Path $t 'boot'; [void](New-Item -ItemType Directory (Join-Path $script:BootDir 'EFI\BOOT') -Force)

 # ---------- the PC the profile was made on ----------
 $rec = Get-EnvironmentRecord
 ExpectTrue 'the record holds the board and BIOS version' (($rec.Board -eq 'MS-7E25') -and ($rec.Bios -eq '1.I0') -and $rec.Recorded)
 Expect 'unchanged: no change reported' (Test-EnvironmentChanged (NewState)).Changed $false
 $script:Board = [pscustomobject]@{ Board = 'MS-7E25'; Bios = '1.J0' }
 $c = Test-EnvironmentChanged (NewState)
 ExpectTrue 'a new BIOS version is a change, named with both versions' ($c.Changed -and $c.Reasons[0] -like '*1.I0*1.J0*')
 $script:Board = [pscustomobject]@{ Board = 'Z790-X'; Bios = '1.I0' }
 ExpectTrue 'a different board is a change' ((Test-EnvironmentChanged (NewState)).Reasons[0] -like '*motherboard*')
 Expect 'a state with no record (a mid-install state) is never flagged' (Test-EnvironmentChanged ([ordered]@{ Version = 1; Phase = 'plan' })).Changed $false

 # ---------- forcing a new capture ----------
 $s = NewState @{ Schedule = [ordered]@{ Mode = 'Off' }; Automatic = [ordered]@{ Active = $true }; BackupFolder = 'bk'; EntryRestarts = 1 }
 Reset-ForNewCapture $s
 ExpectTrue 'everything that depended on the old capture is forgotten' (-not ($s.Contains('Profile') -or $s.Contains('CaptureDir') -or $s.Contains('Build') -or $s.Contains('TestsPassed') -or $s.Contains('Unlock') -or $s.Contains('Automatic') -or $s.Contains('Environment')))
 ExpectTrue 'the choices stay (cards, boot partition, backup) and the capture starts again' ($s.Contains('Cards') -and $s.Contains('BootPartition') -and $s.BackupFolder -eq 'bk' -and $s.Phase -eq 'diag-build' -and $s.EntryRestarts -eq 0)

 $script:Board = [pscustomobject]@{ Board = 'MS-7E25'; Bios = '1.J0' }
 $opt = @{ DryRun = $false; ReportFolder = (Join-Path $t 'rep'); CaptureFolder = $null }
 $s = NewState
 $script:Board = [pscustomobject]@{ Board = 'MS-7E25'; Bios = '1.I0' }
 Expect 'nothing changed: no result and no question' ((Invoke-EnvironmentChange (NewState) $opt) -eq $null -and $script:Asked.Count -eq 0) $true
 $script:Board = [pscustomobject]@{ Board = 'MS-7E25'; Bios = '1.J0' }
 Set-Answers @('N')
 $r = Invoke-EnvironmentChange $s $opt
 ExpectTrue 'a changed BIOS: explained, declining stops and changes nothing' (($r.Stop -like '*new capture is needed*') -and $s.Contains('Profile') -and ((OutText) -like '*tied*' -or (OutText) -like '*new capture of this PC*'))
 ExpectTrue 'and the message names the old and the new version' ((OutText) -like '*1.I0*1.J0*')
 Set-Answers @('Y')
 $r = Invoke-EnvironmentChange $s $opt
 ExpectTrue 'accepting resets the state and goes to the capture' (($r.Next -eq 'diag-build') -and -not $s.Contains('Profile') -and $s.Phase -eq 'diag-build')
 $s = NewState @{ Schedule = [ordered]@{ Mode = 'EveryBoot' } }
 Set-Answers @('Y', 'Y'); $script:Disabled = 0
 [void](Invoke-EnvironmentChange $s $opt)
 ExpectTrue 'an every-start task is only removed after a question, and it was' (($script:Disabled -eq 1) -and $s.Schedule.Mode -eq 'Off' -and $script:Asked[0] -like 'Stop unlocking at every start*')
 $s = NewState @{ Schedule = [ordered]@{ Mode = 'EveryBoot' } }
 Set-Answers @('N', 'N'); $script:Disabled = 0
 [void](Invoke-EnvironmentChange $s $opt)
 ExpectTrue 'declining the question leaves the task alone' ($script:Disabled -eq 0 -and $s.Schedule.Mode -eq 'EveryBoot')
 $s = NewState
 Set-Answers @()
 $r = Invoke-EnvironmentChange $s @{ DryRun = $true; ReportFolder = ''; CaptureFolder = $null }
 ExpectTrue 'dry run asks nothing and changes nothing' (($r.Stop -like '*new capture*') -and $s.Contains('Profile') -and $script:Asked.Count -eq 0)

 # through the phase loop
 function Invoke-Phase-diag-build($State, $Opt) { @{ Stop = 'capture started (test)' } }
 function Test-CardsUnchanged($Saved) { [pscustomobject]@{ Ok = $true; Detail = '' } }
 $st = NewState; $st.Phase = 'stage'; Save-InstallerState $st
 Set-Answers @('Y')
 $res = Invoke-Installer -ReportFolder (Join-Path $t 'rep')
 $saved = Read-InstallerState
 ExpectTrue 'the phase loop notices the change in the middle of an install and starts a new capture' ((-not $res.Done) -and $res.Phase -eq 'diag-build' -and $res.Reason -like 'capture started*' -and -not $saved.Contains('Profile'))
 $st = NewState; $st.Phase = 'stage'; Save-InstallerState $st
 Set-Answers @('N')
 $res = Invoke-Installer -ReportFolder (Join-Path $t 'rep')
 ExpectTrue 'declining stops the run at the same phase, state untouched' ((-not $res.Done) -and $res.Phase -eq 'stage' -and (Read-InstallerState).Contains('Profile'))
 Remove-Item Function:\Invoke-Phase-diag-build, Function:\Test-CardsUnchanged
 $script:Board = [pscustomobject]@{ Board = 'MS-7E25'; Bios = '1.I0' }

 # ---------- the state of the boot setup ----------
 $good = NewState
 Set-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') 'x' -NoNewline
 $script:ExpectedHash = Get-SysFileHash (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI')
 $good.Build.Files[0].Sha256 = $script:ExpectedHash
 $items = @(Get-InstallStatus $good)
 ExpectTrue 'everything fine: every item is ok' (@($items | Where-Object { -not $_.Ok }).Count -eq 0 -and $items.Count -ge 6)
 $script:SecureBoot = 'On'
 $items = @(Get-InstallStatus $good)
 ExpectTrue 'Secure Boot turned back on is reported, no repair offered (the installer never changes it)' ((@($items | Where-Object { $_.Id -eq 'secure-boot' })[0].Ok -eq $false) -and (@($items | Where-Object { $_.Id -eq 'secure-boot' })[0].Repair -eq ''))
 $script:SecureBoot = 'Off'; $script:FastStartup = 1
 ExpectTrue 'Fast Startup turned back on is reported' (-not (@(Get-InstallStatus $good) | Where-Object { $_.Id -eq 'fast-startup' }).Ok)
 $script:FastStartup = 0
 $script:EntryCount = 0
 $i = @(Get-InstallStatus $good) | Where-Object { $_.Id -eq 'entry' }
 ExpectTrue 'a lost firmware entry is reported with a restart as the repair, and no BIOS step' ((-not $i.Ok) -and $i.Repair -eq 'restart' -and $i.Text -like '*BIOS update or a CMOS clear*' -and $i.Text -like '*by itself from the fallback file*' -and $i.Text -notlike '*F11*')
 $script:EntryCount = 2
 ExpectTrue 'two entries is reported (not repaired)' ((@(Get-InstallStatus $good) | Where-Object { $_.Id -eq 'entry' }).Text -like '*more than one*')
 $script:EntryCount = 1
 Remove-Item (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI')
 $i = @(Get-InstallStatus $good) | Where-Object { $_.Id -eq 'fallback' }
 ExpectTrue 'a missing fallback file is reported, repair is to put the programs back' ((-not $i.Ok) -and $i.Repair -eq 'restage' -and $i.Text -like '*missing*')
 Set-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') 'someone else' -NoNewline
 $i = @(Get-InstallStatus $good) | Where-Object { $_.Id -eq 'fallback' }
 ExpectTrue 'a replaced fallback file is reported' ((-not $i.Ok) -and $i.Text -like '*replaced*')
 # with automatic mode the fallback file must be the automatic wrapper
 $auto = NewState @{ Automatic = [ordered]@{ Active = $true } }
 Set-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') 'x' -NoNewline
 $auto.Build.Files[0].Sha256 = $script:ExpectedHash; $auto.Build.Files[1].Sha256 = 'SOMETHING ELSE'
 ExpectTrue 'with extra 1 on, the expected fallback file is the automatic wrapper' (-not (@(Get-InstallStatus $auto) | Where-Object { $_.Id -eq 'fallback' }).Ok)
 $auto.Build.Files[1].Sha256 = $script:ExpectedHash
 ExpectTrue 'and it is ok when it is' ((@(Get-InstallStatus $auto) | Where-Object { $_.Id -eq 'fallback' }).Ok)
 $script:RootOk = $false
 $i = @(Get-InstallStatus $good)
 ExpectTrue 'a boot partition that is gone is reported with the reason, and the file check is skipped' ((@($i | Where-Object { $_.Id -eq 'partition' })[0].Text -like '*not there any more*') -and -not ($i | Where-Object { $_.Id -eq 'fallback' }))
 $script:RootOk = $true
 $script:Board = [pscustomobject]@{ Board = 'MS-7E25'; Bios = '9.9' }
 ExpectTrue 'a changed BIOS shows in the status too' ((@(Get-InstallStatus $good) | Where-Object { $_.Id -eq 'bios' }).Text -like '*new capture is needed*')
 $script:Board = [pscustomobject]@{ Board = 'MS-7E25'; Bios = '1.I0' }

 # ---------- showing and repairing ----------
 Set-Answers @()
 $script:SecureBoot = 'On'
 Show-InstallStatus (Get-InstallStatus $good)
 ExpectTrue 'the status screen marks what needs a look' ((OutText).Contains('[CHECK] Secure Boot') -and (OutText).Contains('[ok]'))
 $script:SecureBoot = 'Off'
 Remove-Item (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI')
 $items = @(Get-InstallStatus $good)
 $script:Restaged = 0
 Set-Answers @('N'); $ch = Invoke-StatusRepairs $good $items
 ExpectTrue 'declining the repair changes nothing' ((-not $ch) -and $script:Restaged -eq 0)
 Set-Answers @('Y'); $ch = Invoke-StatusRepairs $good $items
 ExpectTrue 'accepting puts the manual programs back (and only those when extras are off)' ($ch -and $script:Restaged -eq 1 -and $script:AutoRestaged -eq 0)
 $script:Restaged = 0
 Set-Answers @('Y'); $ch = Invoke-StatusRepairs $auto $items
 ExpectTrue 'with extra 1 on, the automatic pair is put back too' ($script:Restaged -eq 1 -and $script:AutoRestaged -eq 1)
 $script:Restaged = 0
 Set-Answers @(); [void](Invoke-StatusRepairs $good $items -DryRun)
 ExpectTrue 'dry run offers nothing and changes nothing' ($script:Restaged -eq 0 -and $script:Asked.Count -eq 0)
 $script:EntryCount = 0; $script:Restarts = 0; $script:Restaged = 0
 Set-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') 'x' -NoNewline
 Set-Answers @()
 [void](Invoke-StatusRepairs $good @(Get-InstallStatus $good))
 ExpectTrue 'a lost entry: the repair is a restart, requested through Request-Restart (which asks first; tested in Test-Capture), nothing else is changed' ($script:Restarts -eq 1 -and $script:Restaged -eq 0)
 $script:EntryCount = 1

 # ---------- newer boot programs ----------
 $fake = Join-Path $t 'repo'; foreach ($d in 'internal-boot\boot\build', 'internal-boot\unlock\build', 'internal-boot\boot\__pycache__') { [void](New-Item -ItemType Directory (Join-Path $fake $d) -Force) }
 Set-Content (Join-Path $fake 'internal-boot\boot\a.c') 'int a;' -NoNewline; Set-Content (Join-Path $fake 'internal-boot\unlock\b.h') '#define B 1' -NoNewline
 Set-Content (Join-Path $fake 'CHANGES.md') "# Changes`n`n## 2026-10-27 - newest thing`n- x`n`n## 2026-10-26 - older thing`n"
 Set-RepoRoot $fake
 $f1 = Get-BootSourceFingerprint
 Expect 'the fingerprint is stable' (Get-BootSourceFingerprint) $f1
 Set-Content (Join-Path $fake 'internal-boot\boot\build\out.c') 'junk'; Set-Content (Join-Path $fake 'internal-boot\boot\platform-config.h') 'local'; Set-Content (Join-Path $fake 'internal-boot\boot\__pycache__\x.py') 'junk'
 Expect 'build output, the local partition configuration and caches do not count' (Get-BootSourceFingerprint) $f1
 Set-Content (Join-Path $fake 'internal-boot\boot\a.c') 'int a; /* changed */' -NoNewline
 ExpectTrue 'a changed source file changes it' ((Get-BootSourceFingerprint) -ne $f1)
 $f2 = Get-BootSourceFingerprint
 Expect 'recent changes come from CHANGES.md headings, newest first' ((Get-RecentChanges) -join '|') '2026-10-27 - newest thing|2026-10-26 - older thing'

 $s = NewState; $s.Build.SourceFingerprint = $f1
 ExpectTrue 'newer programs are noticed' (Test-BootProgramsOutdated $s)
 $s.Build.SourceFingerprint = $f2
 Expect 'the same programs are not' (Test-BootProgramsOutdated $s) $false
 Expect 'a different recorded fingerprint counts as outdated' (Test-BootProgramsOutdated (NewState)) $true
 $s0 = NewState; $s0.Build.Remove('SourceFingerprint')
 Expect 'no recorded fingerprint: nothing to compare' (Test-BootProgramsOutdated $s0) $false
 $s = NewState; $s.Build.SourceFingerprint = $f1
 Set-Answers @('N')
 Expect 'declined: nothing changes' ((Offer-BootProgramUpdate $s) -or $s.Contains('Update') -or $s.Phase -ne 'done') $false
 ExpectTrue 'the offer shows what changed and that nothing is replaced before the tests and a first run' (((OutText) -like '*2026-10-27 - newest thing*') -and ((OutText) -like '*replaces the ones on the boot partition*' -or (OutText) -like '*only then replaces*') -and ((OutText) -like '*If you decline, the programs you have keep working*'))
 $s = NewState @{ Automatic = [ordered]@{ Active = $true; NoEsc = $true } }; $s.Build.SourceFingerprint = $f1; $s.Build.NoEsc = [ordered]@{ Files = @() }
 Set-Answers @('Y')
 $started = Offer-BootProgramUpdate $s
 ExpectTrue 'accepted: the build restarts from the existing capture, tests are required again, extra 2 is reset' ($started -and $s.Phase -eq 'build' -and $s.Update.Previous -eq $f1 -and -not $s.Contains('TestsPassed') -and $s.Automatic.NoEsc -eq $false -and -not $s.Build.Contains('NoEsc') -and $s.Contains('Profile') -and $s.Contains('CaptureDir'))
 ExpectTrue 'and it said extra 2 goes back to the Esc version' ((OutText) -like '*without the Esc windows (extra 2) is put back*')
 $s = NewState; $s.Phase = 'verdict'; $s.Build.SourceFingerprint = $f1
 Set-Answers @(); Expect 'an install that is not finished is never offered an update' (Offer-BootProgramUpdate $s) $false
 $s = NewState; $s.Build.SourceFingerprint = $f1
 $script:Asked.Clear(); Expect 'dry run does not even ask' ((Offer-BootProgramUpdate $s -DryRun) -eq $false -and $script:Asked.Count -eq 0) $true
 Set-RepoRoot $repo

 # ---------- hosttests branches to the update ----------
 function Invoke-HostTests($State, $Tools, [string]$AssetsDir, [switch]$DryRun) { [pscustomobject]@{ Ok = $true; Results = @() } }
 function Get-ToolStatus { @() }
 $s = NewState @{ Update = [ordered]@{ Previous = 'x' }; Assets = 'a' }
 Expect 'with an update running, passing tests lead to staging, not to the benchmark questions' (Invoke-Phase-hosttests $s @{ DryRun = $false; ReportFolder = ''; CaptureFolder = $null }).Next 'update-stage'
 $s = NewState @{ Assets = 'a' }
 Expect 'without an update the flow is unchanged' (Invoke-Phase-hosttests $s @{ DryRun = $false; ReportFolder = ''; CaptureFolder = $null }).Next 'benchmark-offer'
 Remove-Item Function:\Invoke-HostTests; Remove-Item Function:\Get-ToolStatus

 # ---------- the update's own phases ----------
 function Test-StagedFiles($State) { @() }
 $script:Queued = $null; $script:RunBefore = $null
 function Invoke-ExtraQueue($State, $Opt, [string]$Reason, [string]$ResumePhase, [string]$NextOnDry, [string[]]$Lines) { $script:Queued = @{ Resume = $ResumePhase; Lines = $Lines }; @{ Stop = 'restart'; Resume = $ResumePhase } }
 $script:Outcome = @{ Kind = 'Waiting' }
 function Get-ExtraRunOutcome($State) { $script:Outcome }
 $o = @{ DryRun = $false; ReportFolder = ''; CaptureFolder = $null }
 $s = NewState @{ Update = [ordered]@{ Previous = 'x' } }; $s.Remove('TestsPassed')
 Expect 'untested new programs are never staged' (Invoke-Phase-update-stage $s $o).Stop 'the new boot programs have not passed the host tests'
 $s.TestsPassed = 't'; $script:Restaged = 0; $script:AutoRestaged = 0
 Expect 'staging goes on to the check run' (Invoke-Phase-update-stage $s $o).Next 'update-queue'
 ExpectTrue 'the manual pair is staged, the automatic pair only when extra 1 is on' ($script:Restaged -eq 1 -and $script:AutoRestaged -eq 0)
 $s.Automatic = [ordered]@{ Active = $true }; $script:Restaged = 0
 [void](Invoke-Phase-update-stage $s $o)
 ExpectTrue 'with extra 1 on both are staged' ($script:Restaged -eq 1 -and $script:AutoRestaged -eq 1)
 $r = Invoke-Phase-update-queue $s $o
 ExpectTrue 'the check run is queued and resumes at the collection' ($r.Resume -eq 'update-collect' -and $script:Queued.Lines[1] -like '*automatic mode*')
 $s.Automatic = [ordered]@{ Active = $false }
 [void](Invoke-Phase-update-queue $s $o)
 ExpectTrue 'the manual version says to press U' ($script:Queued.Lines[1] -like '*press U*')
 Expect 'still queued: wait' (Invoke-Phase-update-collect $s $o).Stop 'restart needed to run the updated programs'
 $script:Outcome = @{ Kind = 'NoReport' }; Set-Answers @('Y')
 Expect 'no report, retry' (Invoke-Phase-update-collect $s $o).Next 'update-queue'
 Set-Answers @('N'); Expect 'no report, no retry: stop' (Invoke-Phase-update-collect $s $o).Stop 'the updated programs left no report'
 $script:Outcome = @{ Kind = 'Report'; Report = [pscustomobject]@{ Class = 'NotApplied'; Detail = 'cancelled'; Selectors = $null; Final = '' } }
 Set-Answers @('Y'); Expect 'cancelled, retry' (Invoke-Phase-update-collect $s $o).Next 'update-queue'
 Set-Answers @('N'); Expect 'cancelled, no retry: stop' (Invoke-Phase-update-collect $s $o).Stop 'the updated programs were not run'
 $script:Outcome = @{ Kind = 'Report'; Report = [pscustomobject]@{ Class = 'Failed'; Detail = 'status=8000'; Selectors = $null; Final = 'FINAL status=8000' } }
 Set-Answers @()
 $r = Invoke-Phase-update-collect $s $o
 ExpectTrue 'a failed check stops, keeps the update marked, and points to Roll back' (($r.Stop -like '*stopped on a check*') -and $s.Contains('Update') -and ((OutText) -like '*Roll back*'))
 $script:Outcome = @{ Kind = 'Report'; Report = [pscustomobject]@{ Class = 'Applied'; Detail = 'ok'; Selectors = '88888888/00000008'; Final = 'FINAL status=0' } }
 $r = Invoke-Phase-update-collect $s $o
 ExpectTrue 'applied: the update is finished and cleared, the unlock recorded again' (($r.Next -eq 'done') -and -not $s.Contains('Update') -and $s.Unlock.Applied -and $s.Unlock.Selectors -eq '88888888/00000008')
 foreach ($ph in 'update-stage', 'update-queue', 'update-collect') { ExpectTrue "phase $ph exists and has a plain name" (($script:PhaseOrder -contains $ph) -and (Get-Command "Invoke-Phase-$ph" -ErrorAction SilentlyContinue) -and $script:PhaseNames.Contains($ph)) }
 Remove-Item Function:\Invoke-ExtraQueue, Function:\Get-ExtraRunOutcome, Function:\Test-StagedFiles

 # ---------- the whole session on a finished install ----------
 function Test-CardsUnchanged($Saved) { [pscustomobject]@{ Ok = $true; Detail = '' } }
 function Invoke-Phase-diag-build($State, $Opt) { @{ Stop = 'capture started (test)' } }
 function Get-BootSourceFingerprint { 'NEWFP' }
 function Invoke-Phase-build($State, $Opt) { @{ Stop = 'build started (test)' } }   # the real one would write the local partition configuration
 Set-Content (Join-Path $script:BootDir 'EFI\BOOT\BOOTX64.EFI') 'x' -NoNewline
 $st = NewState; $st.Build.Files[0].Sha256 = $script:ExpectedHash; $st.Build.SourceFingerprint = 'NEWFP'; Save-InstallerState $st
 Set-Answers @('1', '')
 $end = Invoke-InstallerSession -Here $repo
 ExpectTrue 'a finished, healthy install: the status is shown, Continue changes nothing' (($end -eq 'Finished') -and ((OutText) -like '*State of your install*') -and (Read-InstallerState).Phase -eq 'done')
 $script:Board = [pscustomobject]@{ Board = 'MS-7E25'; Bios = '2.0' }
 Set-Answers @('1', 'Y', '')
 $end = Invoke-InstallerSession -Here $repo
 ExpectTrue 'a finished install on a changed BIOS: status says so, Continue offers the new capture, and the capture starts' (($end -eq 'Stopped') -and ((OutText) -like '*The BIOS version changed*') -and (Read-InstallerState).Phase -eq 'diag-build' -and -not (Read-InstallerState).Contains('Profile'))
 $script:Board = [pscustomobject]@{ Board = 'MS-7E25'; Bios = '1.I0' }
 $st = NewState; $st.Build.Files[0].Sha256 = $script:ExpectedHash; $st.Build.SourceFingerprint = 'OLDFP'; Save-InstallerState $st
 Set-Answers @('1', 'N', '')
 $end = Invoke-InstallerSession -Here $repo
 ExpectTrue 'newer boot programs: shown and asked, declining leaves everything as it was' (($end -eq 'Finished') -and ((OutText) -like '*newer boot programs*') -and (Read-InstallerState).Phase -eq 'done' -and -not (Read-InstallerState).Contains('Update'))
 Set-Answers @('1', 'Y', '')
 $end = Invoke-InstallerSession -Here $repo
 ExpectTrue 'accepting the update starts the build from the existing capture' ((Read-InstallerState).Contains('Update') -and (Read-InstallerState).Contains('Profile'))
 Remove-Item Function:\Invoke-Phase-diag-build, Function:\Test-CardsUnchanged, Function:\Get-BootSourceFingerprint, Function:\Invoke-Phase-build

 # ---------- every-boot's own circuit breaker: detected, explained, and a confirmed repair ----------
 $script:DataRoot = Join-Path $t 'data'; [void](New-Item -ItemType Directory $script:DataRoot -Force)
 function Get-SysDataRoot { $script:DataRoot }
 $armLog = Join-Path $script:DataRoot 'arm.log'
 $armState = Join-Path $script:DataRoot 'arm-state.json'

 ExpectTrue 'not every-boot mode: no check at all' ((Test-EveryBootStuck (NewState @{ Schedule = [ordered]@{ Mode = 'Off' } })) -eq $null)
 ExpectTrue 'every-boot mode but no log yet (never run once): no check' ((Test-EveryBootStuck (NewState @{ Schedule = [ordered]@{ Mode = 'EveryBoot' } })) -eq $null)

 Set-Content -LiteralPath $armLog -Value '2026-01-01T00:00:00 armed one unlock for the next boot (entry {x}, runs on record: 3)'
 Expect 'every-boot mode, last line is a normal arm: not stuck' (Test-EveryBootStuck (NewState @{ Schedule = [ordered]@{ Mode = 'EveryBoot' } })) $false
 $items = Get-InstallStatus (NewState @{ Schedule = [ordered]@{ Mode = 'EveryBoot' } })
 $ebItem = $items | Where-Object { $_.Id -eq 'every-boot' }
 ExpectTrue 'status lists every-boot as ok when queuing normally' ($ebItem.Ok -and ($ebItem.Repair -eq ''))

 Set-Content -LiteralPath $armLog -Value '2026-01-01T00:00:00 not armed: the previously queued unlock left no report (it did not run or did not finish)'
 Expect 'every-boot mode, last line is the stuck message: stuck' (Test-EveryBootStuck (NewState @{ Schedule = [ordered]@{ Mode = 'EveryBoot' } })) $true
 $stateForRepair = NewState @{ Schedule = [ordered]@{ Mode = 'EveryBoot' } }
 $items = Get-InstallStatus $stateForRepair
 $ebItem = $items | Where-Object { $_.Id -eq 'every-boot' }
 ExpectTrue 'status explains the stuck state and offers the rearm repair' ((-not $ebItem.Ok) -and ($ebItem.Repair -eq 'rearm') -and ($ebItem.Text -like '*left no report*') -and ($ebItem.Text -like '*not start queuing again on its own*'))

 Set-Content -LiteralPath $armState -Value '{"Armed":true,"RunsWhenArmed":3}'
 Set-Answers @('N')
 $changed = Invoke-StatusRepairs $stateForRepair @($ebItem)
 ExpectTrue 'declining the repair changes nothing and leaves the stuck file in place' ((-not $changed) -and (Test-Path -LiteralPath $armState))
 Set-Answers @('Y')
 $changed = Invoke-StatusRepairs $stateForRepair @($ebItem)
 ExpectTrue 'confirming the repair clears the stuck state file and reports changed' ($changed -and -not (Test-Path -LiteralPath $armState) -and ((OutText) -like '*queue normally again*'))

 Remove-Item Function:\Get-SysDataRoot
}
finally { Set-RepoRoot $repo; Remove-TestRoot $t }

Complete-Tests
