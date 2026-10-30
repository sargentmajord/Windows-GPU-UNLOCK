# Restart with optional automatic resume after login, the resume dialog and the start menu (requirements 10, 11, 12).
# The scheduled task and the window are replaced by the harness (a fake store and a stub); the real window code is only built here, never
# shown, and the real task-registration code is exercised separately, further down, only when elevated.
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$repo = Split-Path -Parent $base
Set-RepoRoot $repo

$script:Restarts = 0; $script:RestartCode = 0
function Invoke-SysRestart([int]$Seconds, [string]$Reason) { $script:Restarts++; $script:RestartCode }
$scriptPath = 'C:\fake\Install-GpuUnlock.ps1'

# ---------- the command the registered task runs ----------
$cmd = Get-ResumeCommand $scriptPath
ExpectTrue 'it starts the installer with -Resume' ($cmd -like '*-File "C:\fake\Install-GpuUnlock.ps1" -Resume')
ExpectTrue 'it is not hidden by itself' ($cmd -notlike '*-WindowStyle*')
Expect 'the resume entry has its own task name (not a registry value, service or startup file)' $script:ResumeTaskName 'WindowsGPUUnlockResume'

$t = New-TestRoot
try {
 # ---------- setting and removing ----------
 Expect 'no entry at first' (Test-ResumeEntry) $false
 Set-ResumeEntry $scriptPath
 ExpectTrue 'the entry is set' (Test-ResumeEntry)
 $j = @(Read-Journal | Where-Object Action -eq 'register automatic resume after login')
 ExpectTrue 'and journaled before and after (so Roll back can see it)' (($j.Count -eq 1) -and $j[0].Status -eq 'done' -and ($j[0].Target -like '*WindowsGPUUnlockResume*'))
 Remove-ResumeEntry; Remove-ResumeEntry
 Expect 'removing twice is harmless' (Test-ResumeEntry) $false

 # ---------- step text ----------
 Expect 'step text for the first phase' (Get-StepText @{ Phase = 'checks' }) 'step 1 of 38 (checking your PC)'
 Expect 'step text for the unlock' (Get-StepText @{ Phase = 'unlock-collect' }) 'step 22 of 38 (checking the first unlock)'
 Expect 'an unknown phase still gives a sentence' (Get-StepText @{ Phase = 'zzz' }) 'the next step'
 foreach ($ph in $script:PhaseOrder) { if (-not $script:PhaseNames.Contains($ph)) { Expect "phase $ph has a plain name" $false $true } }
 Expect 'every phase has a plain name' $script:PhaseNames.Count $script:PhaseOrder.Count

 # ---------- the consent question and the restart ----------
 $s = [ordered]@{ Version = 1; Phase = 'diag-collect' }
 Set-Answers @('Y', 'Y')
 $ok = Request-RestartWithResume $s 'reason' $scriptPath
 ExpectTrue 'consent Y and restart Y: restart started' ($ok -and $script:Restarts -eq 1)
 ExpectTrue 'the entry is set and stays (the restart is happening)' (Test-ResumeEntry)
 ExpectTrue 'the consent is kept in the state file' ((Read-InstallerState).AutoResume.Consent -eq $true)
 ExpectTrue 'the question explained what is added and that nothing changes without a click' (((OutText) -like '*changes nothing until you click Continue*') -and ((OutText) -like '*runs once at your next login*'))
 Expect 'the question was asked' ($script:Asked[0]) 'Continue automatically when you log back in? (Y/N)'
 Remove-ResumeEntry
 Set-Answers @('Y')
 [void](Request-RestartWithResume $s 'reason' $scriptPath)
 ExpectTrue 'the consent is asked only once: the second restart asks only about the restart' ($script:Asked.Count -eq 1 -and $script:Asked[0] -like 'Restart now?*' -and (Test-ResumeEntry))
 Remove-ResumeEntry

 $s = [ordered]@{ Version = 1; Phase = 'diag-collect' }
 Set-Answers @('N', 'Y'); $script:Restarts = 0
 [void](Request-RestartWithResume $s 'reason' $scriptPath)
 ExpectTrue 'consent N: nothing is registered, the restart still happens when asked' ((-not (Test-ResumeEntry)) -and $script:Restarts -eq 1 -and ((Read-InstallerState).AutoResume.Consent -eq $false))
 Set-Answers @('Y')
 [void](Request-RestartWithResume $s 'reason' $scriptPath)
 ExpectTrue 'consent N is remembered: not asked again, still nothing registered' ((-not (Test-ResumeEntry)) -and $script:Asked.Count -eq 1)

 $s = [ordered]@{ Version = 1; Phase = 'x' }
 Set-Answers @('Y', 'N')
 $ok = Request-RestartWithResume $s 'reason' $scriptPath
 ExpectTrue 'restart declined after consent: the entry is removed again (nothing relaunches by itself)' ((-not $ok) -and (-not (Test-ResumeEntry)))
 $s = [ordered]@{ Version = 1; Phase = 'x' }
 $script:RestartCode = 1; Set-Answers @('Y', 'Y')
 $ok = Request-RestartWithResume $s 'reason' $scriptPath
 ExpectTrue 'a restart that Windows refused also removes the entry' ((-not $ok) -and (-not (Test-ResumeEntry)))
 $script:RestartCode = 0

 # ---------- the dialog ----------
 $state = [ordered]@{ Version = 1; Phase = 'unlock-collect' }
 function Show-SysChoiceDialog([string]$Title, [string]$Text, [string[]]$Buttons) { $script:DialogText = $Text; $script:DialogButtons = $Buttons; $script:DialogPick }
 foreach ($pair in @(@('Continue', 'Continue'), @('Not now', 'NotNow'), @('Roll back', 'Rollback'))) {
  $script:DialogPick = $pair[0]
  Expect "window button '$($pair[0])' maps to $($pair[1])" (Show-ResumeDialog $state) $pair[1]
 }
 Expect 'the window has exactly Continue, Not now and Roll back' ($script:DialogButtons -join '|') 'Continue|Not now|Roll back'
 ExpectTrue 'it names the step and says nothing changes before Continue' (($script:DialogText -like '*step 22 of 38*') -and ($script:DialogText -like '*Nothing changes until you click Continue*') -and ($script:DialogText -like '*administrator*'))
 function Show-SysChoiceDialog([string]$Title, [string]$Text, [string[]]$Buttons) { $null }
 foreach ($pair in @(@('c', 'Continue'), @('n', 'NotNow'), @('r', 'Rollback'))) {
  Set-Answers @('x', $pair[0])
  Expect "console fallback: '$($pair[0])' maps to $($pair[1]) (and a wrong key asks again)" (Show-ResumeDialog $state) $pair[1]
 }
 ExpectTrue 'the console fallback also names the step' ((OutText) -like '*step 22 of 38*')

 # ---------- -Resume at start ----------
 function Show-SysChoiceDialog([string]$Title, [string]$Text, [string[]]$Buttons) { $script:DialogPick }
 Save-InstallerState $state
 foreach ($pair in @(@('Continue', 'Continue'), @('Roll back', 'Rollback'), @('Not now', 'Stop'))) {
  Set-ResumeEntry $scriptPath
  $script:DialogPick = $pair[0]
  Expect "-Resume, $($pair[0]): result" (Invoke-ResumeStart) $pair[1]
  ExpectTrue "-Resume, $($pair[0]): the entry is removed in every case" (-not (Test-ResumeEntry))
 }
 ExpectTrue '-Resume, Not now: says how to carry on and that nothing was changed' (((OutText) -like '*Nothing was changed*') -and ((OutText) -like '*Install-GpuUnlock.cmd*') -and ((OutText) -like '*Roll back*'))
 Remove-Item (Get-StatePath) -Force
 Set-ResumeEntry $scriptPath
 Expect '-Resume with no install: nothing to resume' (Invoke-ResumeStart) 'Stop'
 ExpectTrue 'and the entry is removed' (-not (Test-ResumeEntry))

 # ---------- the start menu ----------
 Save-InstallerState $state
 foreach ($pair in @(@('1', 'Continue'), @('2', 'Rollback'), @('3', 'Exit'), @('EXIT', 'Exit'))) {
  Set-Answers @('9', $pair[0])
  Expect "start menu: $($pair[0]) is $($pair[1])" (Select-StartAction $state) $pair[1]
 }
 ExpectTrue 'the start menu says where the install stands and offers Continue, Roll back and Exit' (((OutText) -like '*step 22 of 38*') -and ((OutText) -like '*1. Continue*') -and ((OutText) -like '*2. Roll back*') -and ((OutText) -like '*3. Exit*'))

 # ---------- a leftover entry at the start of a run ----------
 $script:Cleared = 0
 Set-ResumeEntry $scriptPath
 Set-Answers @()
 function Invoke-Phase-zzz($State, $Opt) { @{ Stop = 'for the test' } }
 $st = Read-InstallerState; $st.Phase = 'zzz'; Save-InstallerState $st
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'rep')
 ExpectTrue 'a leftover entry is reported and removed at the start of a run' (((OutText) -like '*leftover automatic-resume entry*') -and (-not (Test-ResumeEntry)))
 Set-ResumeEntry $scriptPath
 $r = Invoke-Installer -DryRun -ReportFolder (Join-Path $t 'rep')
 ExpectTrue 'a dry run reports it but removes nothing' (((OutText) -like '*leftover automatic-resume entry*') -and (Test-ResumeEntry))
 Remove-ResumeEntry

 # a run that stops without having started a restart never leaves an entry
 function Invoke-Phase-zzz($State, $Opt) { Set-ResumeEntry $scriptPath; @{ Stop = 'for the test' } }
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'rep')
 ExpectTrue 'a run that ends without a restart removes the entry it (or anything) left' (-not (Test-ResumeEntry))
 function Invoke-Phase-zzz($State, $Opt) { throw 'boom' }
 try { [void](Invoke-Installer -ReportFolder (Join-Path $t 'rep')) } catch { }
 function Invoke-Phase-zzz($State, $Opt) { Set-ResumeEntry $scriptPath; throw 'boom' }
 try { [void](Invoke-Installer -ReportFolder (Join-Path $t 'rep')) } catch { }
 ExpectTrue 'an error removes the entry too, so a broken install never relaunches itself' (-not (Test-ResumeEntry))
 function Invoke-Phase-zzz($State, $Opt) { @{ Next = 'done' } }
 Set-ResumeEntry $scriptPath
 $r = Invoke-Installer -ReportFolder (Join-Path $t 'rep')
 ExpectTrue 'finishing removes any remaining entry' ($r.Done -and -not (Test-ResumeEntry))
 Remove-Item Function:\Invoke-Phase-zzz
} finally { Remove-TestRoot $t }

# ---------- the real scheduled task (admin only; its own dedicated task name, never the real one) ----------
# Restores the real system calls the harness replaced above. Uses a test-only task name throughout, specifically
# so this can never touch - or be confused with - a real resume task an in-progress install might actually have
# pending right now.
. (Join-Path $base 'Resume.ps1')
if (Get-SysIsAdmin) {
 $savedTaskName = $script:ResumeTaskName
 $script:ResumeTaskName = 'WindowsGPUUnlockResumeTest'
 try {
  ExpectThrows 'the real registration refuses a test-folder path' { Set-SysResumeTask 'C:\x\gpuunlock-test-resume.ps1' } '*test folder*'
  Expect 'nothing was registered by the refused attempt' (Get-SysResumeTask) $null
  $realScriptPath = 'C:\fake\Install-GpuUnlock.ps1'
  Set-SysResumeTask $realScriptPath
  $task = Get-SysResumeTask
  ExpectTrue 'the real task is registered' ($null -ne $task)
  ExpectTrue 'it runs the installer with -Resume' ($task.Actions[0].Arguments -like "*-File `"$realScriptPath`" -Resume")
  ExpectTrue 'it is not elevated by itself' ($task.Principal.RunLevel -eq 'Limited')
  ExpectTrue 'it runs in the interactive session, not hidden' ($task.Principal.LogonType -eq 'Interactive')
  ExpectTrue 'it is triggered at log on' ($task.Triggers[0].CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger')
  Remove-SysResumeTask
  Expect 'removing it leaves nothing behind' (Get-SysResumeTask) $null
  Remove-SysResumeTask   # idempotent
 } finally {
  $script:ResumeTaskName = $savedTaskName
  try { Unregister-ScheduledTask -TaskName 'WindowsGPUUnlockResumeTest' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
 }
} else { Write-Host 'skip the real scheduled-task test (needs an administrator session)' }

# ---------- the real window code is built (never shown) ----------
$canForm = $true
try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing } catch { $canForm = $false }
if ($canForm) {
 $form = New-ChoiceForm 'Title' 'Some text' @('Continue', 'Not now', 'Roll back')
 $btns = @($form.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] })
 Expect 'the window has three buttons' $btns.Count 3
 Expect 'with the right captions' (($btns | ForEach-Object Text) -join '|') 'Continue|Not now|Roll back'
 ExpectTrue 'they sit inside the window and do not overlap' ((@($btns | Where-Object { $_.Right -gt $form.ClientSize.Width }).Count -eq 0) -and ($btns[0].Right -lt $btns[1].Left) -and ($btns[1].Right -lt $btns[2].Left))
 Expect 'a window with no click returns nothing yet' ([string]$form.Tag) ''
 [void][System.Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'NonPublic,Instance').Invoke($btns[2], @([EventArgs]::Empty))   # a click without showing the window
 Expect 'clicking a button records its caption' ([string]$form.Tag) 'Roll back'
 $form.Dispose()
} else { Write-Host 'skip: Windows Forms is not available here' }

Complete-Tests
