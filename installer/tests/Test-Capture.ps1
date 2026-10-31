# Boot entry lookup, one-time boot queue, restart prompt, file staging, diagnostic build, the capture phases and profile
# generation. Everything touching the PC is mocked; the boot partition is a temporary folder. Profile generation also runs the
# real tools/profile_gen.py on the reference machine's private capture when it is available (skipped otherwise).
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')

$repo = Split-Path -Parent $base
$capDir = if ($env:GPU_UNLOCK_CAPTURES) { $env:GPU_UNLOCK_CAPTURES } else { Join-Path (Split-Path -Parent $repo) 'captures' }
$run03 = Join-Path $capDir 'run03-restart-adapter-on-3060'
$haveCapture = (Test-Path (Join-Path $run03 'DIAG02.TXT')) -and (Test-Path (Join-Path $run03 'IMG34.BIN'))
$python = (Get-Command python.exe -All | Where-Object { $_.Source -notlike '*WindowsApps*' } | Select-Object -First 1).Source

# ---------------- boot entries ----------------
$script:FwText = @'
Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
displayorder            {bootmgr}
                        {330a049f-d095-11f1-89aa-806e6f6e6963}
timeout                 0

Windows Boot Manager
--------------------
identifier              {bootmgr}
device                  partition=\Device\HarddiskVolume1
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager

Firmware Application (101fffff)
-------------------------------
identifier              {330a049f-d095-11f1-89aa-806e6f6e6963}
device                  partition=U:
path                    \EFI\BOOT\BOOTX64.EFI
description             UEFI OS
'@
$script:Labels = @{ U = 'GPUUNLOCK' }
function Get-SysFirmwareEntriesText { $script:FwText }
function Get-SysVolumeLabel([string]$Letter) { $script:Labels[$Letter] }
$script:QueueText = 'displayorder {bootmgr}'
function Get-SysFwBootMgrText { $script:QueueText }
$script:Queued = New-Object System.Collections.ArrayList
function Invoke-SysQueueBoot([string]$EntryId) { [void]$script:Queued.Add($EntryId); $script:QueueText = "displayorder {bootmgr}`r`nbootsequence $EntryId" }

$hits = Find-UnlockEntries
Expect 'one entry found by label and path' $hits.Count 1
Expect 'its id' $hits[0] '{330a049f-d095-11f1-89aa-806e6f6e6963}'
$script:Labels = @{ U = 'OTHER' }
Expect 'another label is not our partition' (Find-UnlockEntries).Count 0
$script:Labels = @{ U = 'gpuunlock' }
Expect 'the label match is case sensitive' (Find-UnlockEntries).Count 0
$script:Labels = @{ U = 'GPUUNLOCK' }
$script:FwText = $script:FwText.Replace('\EFI\BOOT\BOOTX64.EFI', '\EFI\Other\X.EFI')
Expect 'another path is not our entry' (Find-UnlockEntries).Count 0
$script:FwText = $script:FwText.Replace('\EFI\Other\X.EFI', '\EFI\BOOT\BOOTX64.EFI')
$script:FwText += "`r`n`r`nFirmware Application (101fffff)`r`n--------------`r`nidentifier              {11111111-2222-3333-4444-555555555555}`r`ndevice                  partition=U:`r`npath                    \EFI\BOOT\BOOTX64.EFI`r`ndescription             Second`r`n"
Expect 'two matching entries are both reported' (Find-UnlockEntries).Count 2
ExpectThrows 'queueing with two entries is refused' { Queue-OneTimeBoot } '*expected exactly one*'
$script:FwText = $script:FwText.Substring(0, $script:FwText.IndexOf('Firmware Application (101fffff)', $script:FwText.IndexOf('UEFI OS')))

$t = New-TestRoot
try {
 ExpectTrue 'nothing queued at first' (-not (Test-QueuedBoot))
 $id = Queue-OneTimeBoot
 Expect 'queue returns the id' $id '{330a049f-d095-11f1-89aa-806e6f6e6963}'
 Expect 'bcdedit was told the same id' $script:Queued[0] $id
 ExpectTrue 'queued now' (Test-QueuedBoot)
 Expect 'journaled and done' @(Read-Journal)[-1].Status 'done'
 $script:Queued.Clear(); $script:QueueText = 'displayorder {bootmgr}'; $j0 = @(Read-Journal).Count
 [void](Queue-OneTimeBoot -DryRun)
 Expect 'dry run queues nothing' $script:Queued.Count 0
 Expect 'dry run journals nothing' @(Read-Journal).Count $j0
 $keep = $script:FwText; $script:FwText = $script:FwText.Substring(0, $script:FwText.IndexOf('Firmware Application (101fffff)'))
 ExpectTrue 'no entry gives null' ($null -eq (Queue-OneTimeBoot))
 $script:FwText = $keep

 # restart prompt
 $script:ShutdownCalls = New-Object System.Collections.ArrayList; $script:ShutdownCode = 0
 function Invoke-SysRestart([int]$Seconds, [string]$Reason) { [void]$script:ShutdownCalls.Add("$Seconds|$Reason"); $script:ShutdownCode }
 Set-Answers @('N'); ExpectTrue 'N does not restart' (-not (Request-Restart 'why'))
 Expect 'no shutdown call after N' $script:ShutdownCalls.Count 0
 ExpectTrue 'N says to restart by hand' ((OutText) -like '*run this same command again*')
 Set-Answers @('Y'); ExpectTrue 'Y restarts' (Request-Restart 'why')
 Expect 'shutdown has a 30 second countdown and the reason' $script:ShutdownCalls[0] '30|why'
 ExpectTrue 'the abort command is printed' ((OutText) -like '*shutdown /a*')
 $script:ShutdownCalls.Clear(); $script:ShutdownCode = 5
 Set-Answers @('Y'); ExpectTrue 'a failing shutdown call is reported' (-not (Request-Restart 'why'))
 ExpectTrue 'and says to restart by hand' ((OutText) -like '*Restart by hand*')
 $script:ShutdownCalls.Clear(); $script:ShutdownCode = 0
 Set-Answers @('Y'); ExpectTrue 'dry run never restarts' (-not (Request-Restart 'why' -DryRun))
 Expect 'dry run: no shutdown call' $script:ShutdownCalls.Count 0
 Set-Answers @('maybe', 'Y'); [void](Request-Restart 'why')
 Expect 'only an explicit Y/N is accepted' $script:Asked.Count 2
} finally { Remove-TestRoot $t }

# ---------------- staging files on the boot partition ----------------
$t = New-TestRoot
try {
 $root = Join-Path $t 'boot'; [void](New-Item -ItemType Directory $root)
 function Get-BootRoot($State) { $root + '\' }
 $state = [ordered]@{ BootPartition = [ordered]@{ DriveLetter = 'U' }; BackupFolder = (Join-Path $t 'backup') }
 $src = Join-Path $t 'a.efi'; Set-Content -LiteralPath $src -Value 'ONE' -Encoding ascii
 $r = Copy-ToBootPartition $state $src 'EFI\BOOT\BOOTX64.EFI' $state.BackupFolder
 ExpectTrue 'new file copied' (Test-Path (Join-Path $root 'EFI\BOOT\BOOTX64.EFI'))
 ExpectTrue 'reported as changed' $r.Changed
 $j = @(Read-Journal)[-1]
 Expect 'journal says the file did not exist' $j.Previous.Existed $false
 $n = @(Read-Journal).Count
 $r = Copy-ToBootPartition $state $src 'EFI\BOOT\BOOTX64.EFI' $state.BackupFolder
 ExpectTrue 'identical file is left alone' (-not $r.Changed)
 Expect 'and not journaled again' @(Read-Journal).Count $n
 $src2 = Join-Path $t 'b.efi'; Set-Content -LiteralPath $src2 -Value 'TWO' -Encoding ascii
 $r = Copy-ToBootPartition $state $src2 'EFI\BOOT\BOOTX64.EFI' $state.BackupFolder
 ExpectTrue 'a different file is replaced' $r.Changed
 $j = @(Read-Journal)[-1]
 ExpectTrue 'the previous file was backed up first' ((Get-Content -LiteralPath $j.Previous.Backup -Raw).Trim() -eq 'ONE')
 Expect 'previous hash recorded' $j.Previous.Sha256 (Get-SysFileHash $src)
 Expect 'the hash of what was written is journaled too (Roll back deletes only a file that still matches it)' $j.Previous.WrittenSha256 (Get-SysFileHash $src2)
 Expect 'new content in place' (Get-Content -LiteralPath (Join-Path $root 'EFI\BOOT\BOOTX64.EFI') -Raw).Trim() 'TWO'
 $n = @(Read-Journal).Count
 [void](Copy-ToBootPartition $state $src 'EFI\X\Y.EFI' $state.BackupFolder -DryRun)
 ExpectTrue 'dry run copies nothing' (-not (Test-Path (Join-Path $root 'EFI\X')))
 Expect 'dry run journals nothing' @(Read-Journal).Count $n
 New-BootFolder $state 'RTX3060-UNLOCK'
 ExpectTrue 'folder created' (Test-Path (Join-Path $root 'RTX3060-UNLOCK'))
 $n = @(Read-Journal).Count; New-BootFolder $state 'RTX3060-UNLOCK'
 Expect 'existing folder: no second journal entry' @(Read-Journal).Count $n
 function Get-BootRoot($State) { throw 'no drive letter' }
 ExpectThrows 'a missing drive letter is an error' { Copy-ToBootPartition ([ordered]@{ BootPartition = [ordered]@{ DriveLetter = '' } }) $src 'x' $t } '*no drive letter*'
 function Get-BootRoot($State) { $l = [string]$State.BootPartition.DriveLetter; if (-not $l) { throw 'The boot partition has no drive letter yet.' }; "$($l.TrimEnd(':')):\" }
 Expect 'boot root from the letter' (Get-BootRoot ([ordered]@{ BootPartition = [ordered]@{ DriveLetter = 'U:' } })) 'U:\'

 # clearing stale outputs touches only the diagnostic's own files
 function Get-BootRoot($State) { $root + '\' }
 $d = Join-Path $root 'RTX3060-UNLOCK'
 foreach ($f in 'IMG00.BIN', 'IMG34.BIN', 'PROM.BIN', 'DIAG00.TXT', 'REPORT.TXT', 'OTHER.BIN') { Set-Content -LiteralPath (Join-Path $d $f) -Value 'x' }
 Clear-OldCaptureOutput $state -DryRun
 Expect 'dry run removes nothing' @(Get-ChildItem $d).Count 6
 Clear-OldCaptureOutput $state
 Expect 'IMG and PROM files removed, logs and others kept' ((Get-ChildItem $d | Sort-Object Name | ForEach-Object Name) -join ',') 'DIAG00.TXT,OTHER.BIN,REPORT.TXT'
} finally { Remove-TestRoot $t }

# ---------------- diagnostic build ----------------
$t = New-TestRoot
try {
 $fakeRepo = Join-Path $t 'repo'
 foreach ($d in 'tools', 'internal-boot\boot\build\diagnostic') { [void](New-Item -ItemType Directory -Path (Join-Path $fakeRepo $d) -Force) }
 Set-RepoRoot $fakeRepo
 Set-Content (Join-Path $fakeRepo 'internal-boot\boot\build\diagnostic\DIAGNOSTIC.EFI') 'EFI' -Encoding ascii
 $manifest = '{"CanUnlock":false,"CanDetach":false,"WritesFirmwareVariables":false}'
 Set-Content (Join-Path $fakeRepo 'internal-boot\boot\build\diagnostic\manifest.json') $manifest -Encoding ascii
 $tools = @(
  [pscustomobject]@{ Id = 'llvm'; Info = [pscustomobject]@{ Path = 'C:\LLVM\bin\clang.exe'; Dir = 'C:\LLVM\bin'; Lld = 'C:\LLVM\bin\lld-link.exe' } },
  [pscustomobject]@{ Id = 'python'; Info = [pscustomobject]@{ Path = 'C:\Py\python.exe' } },
  [pscustomobject]@{ Id = 'msvc'; Info = [pscustomobject]@{ VcVars = 'C:\VS\vcvars64.bat'; VswhereDir = 'C:\VSI' } })
 $state = [ordered]@{ Cards = [ordered]@{ Target = [ordered]@{ Id = '10de:2544'; Bus = '01:00.0' } } }
 $script:PyCalls = New-Object System.Collections.ArrayList; $script:PsCalls = New-Object System.Collections.ArrayList
 $script:CpathSeen = $null
 function Invoke-SysPython([string]$Python, [string[]]$PyArgs) {
  [void]$script:PyCalls.Add($PyArgs -join ' ')
  $out = $PyArgs[$PyArgs.IndexOf('--out') + 1]; [void](New-Item -ItemType Directory -Path (Split-Path -Parent $out) -Force); Set-Content $out '// profile' -Encoding ascii
  [pscustomobject]@{ Code = 0; Output = '' }
 }
 function Invoke-SysPowerShellFile([string]$File, [string[]]$FileArgs) { [void]$script:PsCalls.Add($File + ' ' + ($FileArgs -join ' ')); $script:CpathSeen = $env:CPATH; [pscustomobject]@{ Code = 0; Output = '' } }
 $genHeader = Join-Path $fakeRepo 'internal-boot\boot\generated.h'
 ExpectTrue 'before the build: no generated.h (a fresh clone has none, it is gitignored)' (-not (Test-Path -LiteralPath $genHeader))
 $b = Build-Diagnostic $state $tools
 ExpectTrue 'discovery profile requested for the chosen id' ($script:PyCalls[0] -like '*--discovery --target-id 10de:2544*')
 ExpectTrue 'build script was run with the tool paths' ($script:PsCalls[0] -like '*build-diagnostic.ps1 -Clang C:\LLVM\bin\clang.exe -LldLink C:\LLVM\bin\lld-link.exe -Python C:\Py\python.exe')
 Expect 'the profile folder was on CPATH during the build' $script:CpathSeen (Get-DiscoveryProfileDir $state)
 ExpectTrue 'returns the built file with its hash' (($b.Path -like '*DIAGNOSTIC.EFI') -and ($b.Sha256 -match '^[0-9a-f]{64}$'))
 ExpectTrue 'a placeholder generated.h was written before the build script ran, so handoff.c has something to #include' ((Test-Path -LiteralPath $genHeader) -and ((Get-Content -LiteralPath $genHeader -Raw) -like '*GU_UNLOCK_SHA256*0000000000000000000000000000000000000000000000000000000000000000*') -and ((Get-Content -LiteralPath $genHeader -Raw) -like '*GU_UNLOCK_BYTES 0*'))
 Set-Content -LiteralPath $genHeader -Value 'a real one from a full build, left alone on purpose' -Encoding ascii
 [void](Build-Diagnostic $state $tools)
 Expect 'a real generated.h already there is never overwritten' (Get-Content -LiteralPath $genHeader -Raw).Trim() 'a real one from a full build, left alone on purpose'
 Set-Content (Join-Path $fakeRepo 'internal-boot\boot\build\diagnostic\manifest.json') '{"CanUnlock":true,"CanDetach":false,"WritesFirmwareVariables":false}' -Encoding ascii
 ExpectThrows 'a diagnostic that can unlock is refused' { Build-Diagnostic $state $tools } '*can change things*'
 Set-Content (Join-Path $fakeRepo 'internal-boot\boot\build\diagnostic\manifest.json') $manifest -Encoding ascii
 function Invoke-SysPowerShellFile([string]$File, [string[]]$FileArgs) { [pscustomobject]@{ Code = 1; Output = 'compile error' } }
 ExpectThrows 'a failing build is an error' { Build-Diagnostic $state $tools } '*did not build*compile error*'
 function Invoke-SysPython([string]$Python, [string[]]$PyArgs) { [pscustomobject]@{ Code = 1; Output = 'bad id' } }
 ExpectThrows 'a failing discovery profile is an error' { Build-Diagnostic $state $tools } '*discovery profile*'
 $script:PyCalls.Clear()
 $b = Build-Diagnostic $state $tools -DryRun
 Expect 'dry run runs nothing' $script:PyCalls.Count 0
} finally { Remove-TestRoot $t }

# ---------------- capture phases ----------------
$t = New-TestRoot
try {
 $root = Join-Path $t 'boot'; [void](New-Item -ItemType Directory $root); [void](New-Item -ItemType Directory (Join-Path $root 'RTX3060-UNLOCK'))
 function Get-BootRoot($State) { $root + '\' }
 $script:Entries = 0
 function Find-UnlockEntries([string]$Label = 'GPUUNLOCK') { if ($script:Entries -eq 0) { , @() } else { , @(1..$script:Entries | ForEach-Object { '{entry}' }) } }
 $script:IsQueued = $false
 function Test-QueuedBoot { $script:IsQueued }
 $script:Restarts = New-Object System.Collections.ArrayList
 function Request-Restart([string]$Reason, [switch]$DryRun) { [void]$script:Restarts.Add($Reason); $true }
 function Queue-OneTimeBoot([switch]$DryRun) { if ($script:Entries -eq 0) { return $null }; $script:IsQueued = $true; '{entry}' }
 $opt = @{ DryRun = $false; ReportFolder = (Join-Path $t 'reports'); CaptureFolder = $null }
 $st = [ordered]@{ Version = 1; Phase = 'diag-entry'; AutoResume = [ordered]@{ Consent = $false; Asked = 'earlier' }; BootPartition = [ordered]@{ DriveLetter = 'U' }; Cards = [ordered]@{ Target = [ordered]@{ Name = 'x'; Id = '10de:2544'; Subsystem = '1462:397d'; Bus = '01:00.0' }; Console = [ordered]@{ Name = 'y'; Id = '10de:2f04'; Subsystem = '1043:89f2'; Bus = '02:00.0' } } }

 # diag-entry
 $script:Entries = 1
 Expect 'entry present: go on to queueing' (Invoke-Phase-diag-entry $st $opt).Next 'diag-queue'
 $script:Entries = 2
 ExpectTrue 'two entries: stop' ((Invoke-Phase-diag-entry $st $opt).Stop -like '*2 boot entries*')
 $script:Entries = 0
 Set-Answers @()
 $r = Invoke-Phase-diag-entry $st $opt
 ExpectTrue 'no entry: restart once so the firmware makes one' ($r.Stop -like '*firmware notices*')
 Expect 'the restart counter is saved' $st.EntryRestarts 1
 Expect 'a restart was requested' $script:Restarts.Count 1
 ExpectTrue 'state saved before the restart' ((Read-InstallerState).EntryRestarts -eq 1)
 $script:Restarts.Clear(); Set-Answers @()
 $r = Invoke-Phase-diag-entry $st $opt
 Expect 'still no entry after a restart: stop' $r.Stop 'no firmware boot entry'
 Expect 'no second restart is requested' $script:Restarts.Count 0
 ExpectTrue 'the message never mentions the BIOS as a step to take' (((OutText) -like '*never asks you to use the BIOS*') -and ((OutText) -notlike '*press F*'))
 $dry = @{ DryRun = $true; ReportFolder = $opt.ReportFolder; CaptureFolder = $null }
 Expect 'dry run with no entry carries on' (Invoke-Phase-diag-entry $st $dry).Next 'diag-queue'

 # diag-queue
 $script:Entries = 1; $script:Restarts.Clear(); $script:IsQueued = $false
 $r = Invoke-Phase-diag-queue $st $opt
 Expect 'queued, restart requested, resume at collect' $r.Resume 'diag-collect'
 ExpectTrue 'queue time recorded' ([bool]$st.CaptureQueuedAt)
 ExpectTrue 'recovery instruction shown' ((OutText) -like '*hold the power button*')
 $script:Entries = 0
 $r = Invoke-Phase-diag-queue $st $opt
 Expect 'no entry at queue time: back to the entry phase' $r.Resume 'diag-entry'

 # diag-collect
 $script:IsQueued = $true; Set-Answers @()
 ExpectTrue 'still queued: wait for the restart' ((Invoke-Phase-diag-collect $st $opt).Stop -like '*restart needed*')
 $script:IsQueued = $false
 $st.CaptureQueuedAt = (Get-Date).ToString('o')
 $d = Join-Path $root 'RTX3060-UNLOCK'
 Set-Content (Join-Path $d 'DIAG00.TXT') 'old' ; (Get-Item (Join-Path $d 'DIAG00.TXT')).LastWriteTime = (Get-Date).AddMinutes(-30)
 Set-Answers @('N')
 $r = Invoke-Phase-diag-collect $st $opt
 Expect 'a log from before the queueing is ignored' $r.Stop 'the diagnostic left no log'
 Set-Answers @('Y')
 Expect 'N then Y: asked to queue again' (Invoke-Phase-diag-collect $st $opt).Next 'diag-queue'
 Set-Content (Join-Path $d 'DIAG01.TXT') 'new'; Set-Content (Join-Path $d 'IMG00.BIN') 'img'; Set-Content (Join-Path $d 'PROM.BIN') 'prom'
 Set-Answers @()
 $r = Invoke-Phase-diag-collect $st $opt
 Expect 'a fresh log is collected' $r.Next 'profile'
 ExpectTrue 'DIAG.TXT copied locally' (Test-Path (Join-Path $st.CaptureDir 'DIAG.TXT'))
 Expect 'the newest log was taken' (Get-Content (Join-Path $st.CaptureDir 'DIAG.TXT') -Raw).Trim() 'new'
 ExpectTrue 'image dumps copied' (Test-Path (Join-Path $st.CaptureDir 'IMG00.BIN'))
 ExpectTrue 'the video BIOS image is kept in the local work folder for the host tests' (Test-Path (Join-Path $st.CaptureDir 'PROM.BIN'))
 # the counter works whatever the clocks say
 $st.DiagFilesBefore = @(Get-DiagFileNames $st)
 Expect 'the diag file names are listed' ($st.DiagFilesBefore -contains 'DIAG01.TXT') $true
 $stale = Join-Path $d 'DIAG01.TXT'; (Get-Item $stale).LastWriteTime = (Get-Date).AddHours(6)
 ExpectTrue 'a stale log with a future time is not taken as new' ($null -eq (Get-LatestCapture $st $st.DiagFilesBefore (Get-Date).AddMinutes(-1)))
 Set-Content (Join-Path $d 'DIAG02.TXT') 'newer'; (Get-Item (Join-Path $d 'DIAG02.TXT')).LastWriteTime = (Get-Date).AddHours(-7)
 ExpectTrue 'a new log with a time hours in the past is found' ((Get-LatestCapture $st $st.DiagFilesBefore (Get-Date).AddMinutes(-1)).Log -like '*DIAG02.TXT')
 Remove-Item (Join-Path $d 'DIAG02.TXT'); $st.Remove('DiagFilesBefore'); (Get-Item $stale).LastWriteTime = Get-Date
 # dry run: capture folder rehearsal
 Expect 'dry run with a capture folder rehearses the rest' (Invoke-Phase-diag-collect $st @{ DryRun = $true; CaptureFolder = 'C:\saved'; ReportFolder = $opt.ReportFolder }).Next 'profile'
 Expect 'dry run without one stops and says why' (Invoke-Phase-diag-collect $st $dry).Stop 'dry run: waiting for the diagnostic'
 ExpectThrows '-CaptureFolder is refused outside a dry run' { Invoke-Installer -CaptureFolder 'C:\saved' } '*only for a dry run*'
} finally { Remove-TestRoot $t }

# ---------------- profile generation (mocked generator) ----------------
$t = New-TestRoot
try {
 $tools = @([pscustomobject]@{ Id = 'python'; Info = [pscustomobject]@{ Path = 'C:\Py\python.exe' } })
 $st = [ordered]@{ Cards = [ordered]@{ Target = [ordered]@{ Name = 'NVIDIA GeForce RTX 3060'; Id = '10de:2544'; Subsystem = '1462:397d'; Bus = '01:00.0'; VramMiB = 12288 }; Console = [ordered]@{ Name = 'NVIDIA GeForce RTX 5070'; Id = '10de:2f04'; Subsystem = '1043:89f2'; Bus = '02:00.0' } } }
 function Get-SysBoard { [pscustomobject]@{ Board = 'MS 7D85'; Bios = '1.I0' } }
 $script:PyArgs = $null; $script:PyResult = $null
 function Invoke-SysPython([string]$Python, [string[]]$PyArgs) { $script:PyArgs = $PyArgs; $script:PyResult }
 $script:PyResult = [pscustomobject]@{ Code = 0; Output = '{"ok": true, "summary": {"target": {"bus": 1}}}' }
 $r = New-Profile $st $tools 'C:\cap'
 ExpectTrue 'ok result' $r.Ok
 $a = $script:PyArgs -join ' '
 ExpectTrue 'bus numbers are passed as integers' ($a -like '*--target-bus 1 *' -and $a -like '*--console-bus 2 *')
 ExpectTrue 'ids, subsystems and names are passed' ($a -like '*--target-id 10de:2544*--target-subsystem 1462:397d*--target-name NVIDIA GeForce RTX 3060*--console-id 10de:2f04*')
 ExpectTrue 'vram is passed' ($a -like '*--target-vram-mib 12288*')
 ExpectTrue 'profile name has no spaces or odd characters' ($a -match '--profile-name MS-7D85-1\.I0-RTX-3060')
 $script:PyResult = [pscustomobject]@{ Code = 2; Output = '{"ok": false, "findings": [{"code": "not-cold", "message": "The card is not cold.", "fix": "Power off completely."}]}' }
 $r = New-Profile $st $tools 'C:\cap'
 ExpectTrue 'refusal is returned, not thrown' (-not $r.Ok)
 Expect 'with its finding' $r.Findings[0].code 'not-cold'
 $script:PyResult = [pscustomobject]@{ Code = 1; Output = 'Traceback ...' }
 ExpectThrows 'a crashing generator is an error' { New-Profile $st $tools 'C:\cap' } '*generator failed*'
 $script:PyResult = [pscustomobject]@{ Code = 0; Output = 'not json' }
 ExpectThrows 'unreadable generator output is an error' { New-Profile $st $tools 'C:\cap' } '*generator failed*'

 # the profile phase
 $script:PyResult = [pscustomobject]@{ Code = 2; Output = '{"ok": false, "findings": [{"code": "no-display-on-target", "message": "No display output.", "fix": "Attach a display, then run the capture again."}]}' }
 $opt = @{ DryRun = $false; ReportFolder = (Join-Path $t 'reports'); CaptureFolder = $null }
 function Get-ToolStatus { $tools | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Ok = $true; Info = $_.Info } } }
 $st.CaptureDir = 'C:\cap'; $st.EntryRestarts = 1
 Set-Answers @('N')
 $r = Invoke-Phase-profile $st $opt
 Expect 'refusal stops' $r.Stop 'no safe profile for this PC'
 ExpectTrue 'plain message and fix shown' (((OutText) -like '*No display output.*') -and ((OutText) -like '*Attach a display*'))
 $rep = @(Get-ChildItem (Join-Path $t 'reports'))
 Expect 'a refusal report was written' $rep.Count 1
 $txt = Get-Content $rep[0].FullName -Raw
 ExpectTrue 'report has the finding code' ($txt -like '*[[]no-display-on-target[]]*')
 ExpectTrue 'report holds no user name and no capture addresses' (($txt -notlike "*$env:USERNAME*") -and ($txt -notmatch '0x[0-9a-f]{8}'))
 Set-Answers @('Y')
 $r = Invoke-Phase-profile $st $opt
 Expect 'Y: capture again' $r.Next 'diag-queue'
 Expect 'the restart counter is reset for the new capture' $st.EntryRestarts 0
 $script:PyResult = [pscustomobject]@{ Code = 0; Output = ('{"ok": true, "summary": {"target": {"bus": 1, "id": "10de:2544", "subsystem": "1462:397d", "display_output_found": true}, "screen_adapter": {"bus": 2, "id": "10de:2f04"}, "console_drivers": {"shared_by_both_cards": true}, "card_gop_driver": {"name": "nvgop-ga1xx"}}}') }
 Set-Answers @('Y')
 $r = Invoke-Phase-profile $st $opt
 Expect 'accepted profile goes on to the firmware step' $r.Next 'firmware'
 ExpectTrue 'summary shown in plain words' (((OutText) -like '*display output for it: yes*') -and ((OutText) -like '*never touched*'))
 ExpectTrue 'profile recorded in the state' ([bool]$st.Profile.Dir)
 Set-Answers @('N')
 Expect 'declining the profile stops' (Invoke-Phase-profile $st $opt).Stop 'profile not accepted'
} finally { Remove-TestRoot $t }

# ---------------- the real generator on the reference capture, and a whole simulated install ----------------
if (-not ($haveCapture -and $python)) {
 Write-Host 'skip real-capture tests (private capture or python not available)'
} else {
 $t = New-TestRoot
 try {
  # real python, real profile_gen.py, real saved capture
  $capLocal = Join-Path $t 'cap'; [void](New-Item -ItemType Directory $capLocal)
  Copy-Item (Join-Path $run03 'DIAG02.TXT') (Join-Path $capLocal 'DIAG.TXT')
  Get-ChildItem $run03 -Filter 'IMG*.BIN' | Copy-Item -Destination $capLocal
  Set-RepoRoot $repo
  function Invoke-SysPython([string]$Python, [string[]]$PyArgs) { $o = & $Python -X utf8 -I @PyArgs 2>&1; [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($o | Out-String) } }
  function Get-SysBoard { [pscustomobject]@{ Board = 'MS-7D85'; Bios = '1.I0' } }
  $tools = @([pscustomobject]@{ Id = 'python'; Info = [pscustomobject]@{ Path = $python } })
  $st = [ordered]@{ Cards = [ordered]@{ Target = [ordered]@{ Name = 'NVIDIA GeForce RTX 3060'; Id = '10de:2544'; Subsystem = '1462:397d'; Bus = '01:00.0'; VramMiB = 12288 }; Console = [ordered]@{ Name = 'NVIDIA GeForce RTX 5070'; Id = '10de:2f04'; Subsystem = '1043:89f2'; Bus = '02:00.0' } } }
  $r = New-Profile $st $tools $capLocal
  ExpectTrue 'the real generator accepts the reference capture' $r.Ok
  $h = Get-Content (Join-Path $r.Dir 'profile.h') -Raw
  ExpectTrue 'generated profile has the card id' ($h -match '(?m)^#define GU_BOARD_ID 0x254410deU')
  ExpectTrue 'generated profile has the display path bytes' ($h -match 'GU_RTX_PATH_BYTES 2,1,12,0,208,65,3,10,0,0,0,0,1,1,6,0,0,1,1,1,6,0,0,0,2,3,8,0,112,3,1,128,127,255,4,0')
  ExpectTrue 'generated profile contains no user name' ($h -notlike "*$env:USERNAME*")
  Show-ProfileSummary $r.Summary
  # the same capture for the WRONG card choice is refused
  $st2 = [ordered]@{ Cards = [ordered]@{ Target = [ordered]@{ Name = 'NVIDIA GeForce RTX 3090'; Id = '10de:2204'; Subsystem = '1462:397d'; Bus = '01:00.0' }; Console = $st.Cards.Console } }
  $r2 = New-Profile $st2 $tools $capLocal
  ExpectTrue 'a different chosen card is refused' ((-not $r2.Ok) -and $r2.Findings[0].code -eq 'identity-mismatch')
 } finally { Remove-TestRoot $t }
}

Complete-Tests
