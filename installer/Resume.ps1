# Restart with optional automatic resume after login, and the start menu (plan requirements 10, 11, 12).
#  - The resume entry is ONE current-user RunOnce value, created only after an explicit Y, never silently. It only starts
#    "Install-GpuUnlock.ps1 -Resume", which opens a visible window and asks first (Continue / Not now / Roll back). Nothing changes until
#    the user clicks Continue; Windows then shows its own administrator prompt.
#  - The entry is removed when the resumed run starts, when a run ends without a restart, on an error, on Roll back and when the install finishes.
#    A leftover entry is reported and removed at the start of every run, so a broken install never relaunches itself at every login.
# Needs Ui.ps1, State.ps1, BootEntry.ps1, Main.ps1 ($script:PhaseOrder).

$script:ResumeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$script:ResumeValueName = 'WindowsGPUUnlockResume'
$script:RestartStarted = $false

$script:PhaseNames = [ordered]@{
 'checks' = 'checking your PC'; 'cards' = 'choosing the graphics card'; 'tools' = 'build tools'; 'partition' = 'choosing the boot partition'
 'plan' = 'the plan'; 'backup' = 'backing up your settings'; 'make-partition' = 'preparing the boot partition'
 'diag-build' = 'building the read-only diagnostic'; 'diag-stage' = 'putting the diagnostic on the boot partition'; 'diag-entry' = 'finding the boot entry'
 'diag-queue' = 'running the diagnostic'; 'diag-collect' = 'collecting the diagnostic''s log'; 'profile' = 'making the profile for your PC'
 'firmware' = 'NVIDIA firmware files'; 'build' = 'building the boot programs'; 'hosttests' = 'testing the boot programs'
 'benchmark-offer' = 'the benchmark'; 'benchmark-prepare' = 'preparing the benchmark'; 'benchmark-before' = 'measuring before the unlock'
 'stage' = 'putting the boot programs on the boot partition'; 'unlock-queue' = 'the first unlock'; 'unlock-collect' = 'checking the first unlock'
 'benchmark-after' = 'measuring after the unlock'; 'verdict' = 'the result'; 'schedule' = 'unlocking again later'
 'update-stage' = 'update: putting the new boot programs on the boot partition'; 'update-queue' = 'update: checking the new programs'; 'update-collect' = 'update: reading the result'
 'extra1-offer' = 'optional extra 1'; 'extra1-stage' = 'extra 1: putting the automatic programs on the boot partition'; 'extra1-queue' = 'extra 1: the first automatic run'
 'extra1-collect' = 'extra 1: checking the automatic run'; 'extra1-shortcut' = 'extra 1: the shortcut and starting at every start'
 'extra2-offer' = 'optional extra 2'; 'extra2-build' = 'extra 2: building and testing'; 'extra2-stage' = 'extra 2: putting the programs on the boot partition'
 'extra2-queue' = 'extra 2: the first run'; 'extra2-collect' = 'extra 2: checking the run'
}

# --- system calls (replaceable in tests) ---
function Get-SysRunOnceValue { $v = Get-ItemProperty -LiteralPath $script:ResumeKey -Name $script:ResumeValueName -ErrorAction SilentlyContinue; if ($v) { [string]$v.($script:ResumeValueName) } else { $null } }
function Set-SysRunOnceValue([string]$Command) {
 if ($Command -like '*gpuunlock-test-*') { throw 'Refusing to write a real resume entry that points into a test folder (a test forgot to replace this function).' }
 if (-not (Test-Path -LiteralPath $script:ResumeKey)) { [void](New-Item -Path $script:ResumeKey -Force) }
 [void](New-ItemProperty -LiteralPath $script:ResumeKey -Name $script:ResumeValueName -Value $Command -PropertyType String -Force)
}
function Remove-SysRunOnceValue { Remove-ItemProperty -LiteralPath $script:ResumeKey -Name $script:ResumeValueName -ErrorAction SilentlyContinue }

# Shows a window with the buttons and returns the label of the one clicked, or $null when no window could be made (then the console is used).
function Show-SysChoiceDialog([string]$Title, [string]$Text, [string[]]$Buttons) {
 try {
  Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
  $form = New-ChoiceForm $Title $Text $Buttons
  [void]$form.ShowDialog()
  $r = [string]$form.Tag
  $form.Dispose()
  if ($r) { $r } else { $Buttons[1] }       # closing the window with the X is "Not now"
 } catch { $null }
}
function New-ChoiceForm([string]$Title, [string]$Text, [string[]]$Buttons) {
 $form = New-Object System.Windows.Forms.Form
 $form.Text = $Title; $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
 $form.TopMost = $true; $form.ClientSize = New-Object System.Drawing.Size(520, 170); $form.Tag = ''
 $lab = New-Object System.Windows.Forms.Label
 $lab.Text = $Text; $lab.AutoSize = $false; $lab.Location = New-Object System.Drawing.Point(16, 14); $lab.Size = New-Object System.Drawing.Size(488, 100)
 $form.Controls.Add($lab)
 $x = 16
 foreach ($b in $Buttons) {
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = $b; $btn.Size = New-Object System.Drawing.Size(150, 32); $btn.Location = New-Object System.Drawing.Point($x, 124); $btn.Name = 'btn-' + $b
  $btn.Add_Click({ param($s, $e) $s.FindForm().Tag = $s.Text; $s.FindForm().Close() })
  $form.Controls.Add($btn)
  $x += 160
 }
 $form
}

# --- the resume entry ---
function Test-ResumeEntry { [bool](Get-SysRunOnceValue) }

function Get-ResumeCommand([string]$ScriptPath) {
 $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 '!"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Resume' -f $ps, $ScriptPath    # "!" keeps the value until the command has finished
}

function Set-ResumeEntry([string]$ScriptPath) {
 $cmd = Get-ResumeCommand $ScriptPath
 [void](Invoke-JournaledChange -Phase 'restart' -Action 'register automatic resume after login' -Target ($script:ResumeKey + '\' + $script:ResumeValueName) `
  -Previous ([ordered]@{ Existed = (Test-ResumeEntry) }) -Undo 'remove the value' -Do { Set-SysRunOnceValue $cmd })
}
function Remove-ResumeEntry { if (Test-ResumeEntry) { Remove-SysRunOnceValue } }

# What the user sees: "step 3 of 25 (building the boot programs)".
function Get-StepText($State) {
 $names = @($script:PhaseOrder)
 $i = [array]::IndexOf($names, [string]$State.Phase)
 if ($i -lt 0) { return 'the next step' }
 'step {0} of {1} ({2})' -f ($i + 1), $names.Count, $script:PhaseNames[[string]$State.Phase]
}

# The resumed run asks first. Returns 'Continue', 'NotNow' or 'Rollback'. A window is tried first, the console is the fallback.
function Show-ResumeDialog($State) {
 $step = Get-StepText $State
 $text = "Windows GPU Unlock installer: $step is ready.`r`n`r`nContinue now? Windows will ask you to approve administrator rights. Nothing changes until you click Continue."
 $buttons = @('Continue', 'Not now', 'Roll back')
 $pick = Show-SysChoiceDialog 'Windows GPU Unlock installer' $text $buttons
 if (-not $pick) {
  Write-Plain "Windows GPU Unlock installer: $step is ready."
  while ($true) {
   $a = (Read-Answer 'Continue now (C), not now (N), or roll back (R)').Trim().ToUpper()
   if ($a -eq 'C') { $pick = 'Continue'; break }
   if ($a -eq 'N') { $pick = 'Not now'; break }
   if ($a -eq 'R') { $pick = 'Roll back'; break }
  }
 }
 switch ($pick) { 'Continue' { 'Continue' } 'Roll back' { 'Rollback' } default { 'NotNow' } }
}

# Handles -Resume before anything else runs. Returns 'Continue', 'Rollback' or 'Stop'. The entry is removed in every case.
function Invoke-ResumeStart {
 $state = Read-InstallerState
 $choice = if ($state.Phase -eq 'new') { 'Stop' } else { Show-ResumeDialog $state }
 Remove-ResumeEntry
 if ($choice -eq 'NotNow') {
  Write-Plain 'Nothing was changed, and the automatic resume is off now. To carry on later, double-click Install-GpuUnlock.cmd; to undo everything, run it and choose Roll back.'
  return 'Stop'
 }
 if ($state.Phase -eq 'new') { Write-Plain 'There is no install to resume.'; return 'Stop' }
 $choice
}

# A restart that offers automatic resume. The question is asked once; the answer is kept in the state file.
function Request-RestartWithResume($State, [string]$Reason, [string]$ScriptPath) {
 if (-not $State.Contains('AutoResume')) {
  Write-Plain ''
  Write-Plain 'After the restart the installer can open a window when you log in and ask whether to continue. It changes nothing until you click Continue.'
  Write-Plain 'This adds one entry that runs once at your next login and removes itself; Roll back removes it too.'
  $State.AutoResume = [ordered]@{ Consent = (Ask-YesNo 'Continue automatically when you log back in?'); Asked = (Get-Date).ToString('o') }
  Save-InstallerState $State
 }
 if ($State.AutoResume.Consent) { Set-ResumeEntry $ScriptPath }
 $ok = Request-Restart $Reason
 $script:RestartStarted = $ok
 if (-not $ok) { Remove-ResumeEntry }   # no restart was started: nothing should relaunch at the next login
 $ok
}

# The start menu of a run that finds an earlier install: Continue, Roll back or Exit.
function Select-StartAction($State) {
 Write-Plain ''
 Write-Plain ('An earlier install is in progress at {0}.' -f (Get-StepText $State))
 Write-Plain '  1. Continue'
 Write-Plain '  2. Roll back (undo everything the installer did)'
 $extras = ($State.Contains('Automatic') -and $State.Automatic -and $State.Automatic.Active)
 if ($extras) { Write-Plain '  3. Switch the optional extras off (back to the safe manual setup; nothing else is undone)' }
 Write-Plain ('  {0}. Exit (nothing is changed)' -f $(if ($extras) { 4 } else { 3 }))
 $max = if ($extras) { 4 } else { 3 }
 $n = Ask-Number 'What do you want to do?' $max 'EXIT'
 if ($extras -and $n -eq 3) { return 'SwitchOff' }
 switch ($n) { 1 { 'Continue' } 2 { 'Rollback' } default { 'Exit' } }
}
