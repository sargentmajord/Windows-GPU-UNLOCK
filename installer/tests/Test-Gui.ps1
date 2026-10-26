# The graphical front end (requirement 32), without showing a window: the worker's prompt functions are run in a real second runspace and
# answered from here; the window's controls are built and "clicked" with reflection. Also checks that the console and the window offer the
# same questions (every question goes through the five Ui functions) and that the launcher falls back to the console.
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main', 'Session', 'Gui') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$repo = Split-Path -Parent $base
Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing

function New-Bridge { [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Answer = $null; AnswerReady = (New-Object System.Threading.ManualResetEventSlim($false)); Closed = $false }) }

# Runs code in a second runspace with the real prompt functions; $Answer is called for every question and returns the answer.
function Invoke-InWorker([string]$Code, [scriptblock]$Answer, [scriptblock]$BeforeAnswer = $null, [int]$CloseAfterAsks = 0) {
 $bridge = New-Bridge
 $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
 $ps = [powershell]::Create(); $ps.Runspace = $rs
 [void]$ps.AddScript({
  param($Base, $Bridge, $Code)
  $ErrorActionPreference = 'Stop'
  foreach ($m in 'Ui', 'State', 'Resume', 'Main', 'GuiPrompts') { . (Join-Path $Base "$m.ps1") }
  $script:Bridge = $Bridge
  try { $r = & ([scriptblock]::Create($Code)); [pscustomobject]@{ Result = $r; Error = $null } } catch { [pscustomobject]@{ Result = $null; Error = $_.Exception.Message } }
 }).AddArgument($base).AddArgument($bridge).AddArgument($Code)
 $h = $ps.BeginInvoke()
 $seen = New-Object System.Collections.ArrayList; $asks = 0
 $deadline = (Get-Date).AddSeconds(30)
 while (-not $h.IsCompleted -and (Get-Date) -lt $deadline) {
  $m = $null
  while ($bridge.Queue.TryDequeue([ref]$m)) {
   [void]$seen.Add($m)
   if ($m.Kind -eq 'ask') {
    $asks++
    if ($CloseAfterAsks -gt 0 -and $asks -ge $CloseAfterAsks) { $bridge.Closed = $true; $bridge.AnswerReady.Set() }
    else { $bridge.Answer = (& $Answer $m); $bridge.AnswerReady.Set() }
   }
  }
  Start-Sleep -Milliseconds 20
 }
 $out = if ($h.IsCompleted) { $ps.EndInvoke($h) | Select-Object -Last 1 } else { [pscustomobject]@{ Result = $null; Error = 'worker did not finish' } }
 $m = $null; while ($bridge.Queue.TryDequeue([ref]$m)) { [void]$seen.Add($m) }
 $ps.Dispose(); $rs.Dispose()
 [pscustomobject]@{ Result = $out.Result; Error = $out.Error; Messages = @($seen) }
}

# ---------- the worker's prompt functions ----------
$r = Invoke-InWorker 'Write-Plain "one"; Write-Host "two" -ForegroundColor Green; Write-Host "a" "b" -Separator "-"; Write-Host ""; 7' { $null }
Expect 'a worker returns its value' $r.Result 7
$t = @($r.Messages | Where-Object Kind -eq 'text')
Expect 'Write-Plain reaches the window' $t[0].Text 'one'
ExpectTrue 'Write-Host reaches the window with its colour' (($t[1].Text -eq 'two') -and ($t[1].Color -eq 'Green'))
Expect 'Write-Host joins its parts' $t[2].Text 'a-b'
Expect 'an empty Write-Host is an empty line' $t[3].Text ''

$r = Invoke-InWorker '$a = Ask-YesNo "Go on?"; $b = Ask-YesNo "Again?"; "$a $b"' { param($m) if ($m.Prompt -eq 'Go on?') { $true } else { $false } }
Expect 'Ask-YesNo gives True for Yes and False for No' $r.Result 'True False'
ExpectTrue 'the question carries its text and type' ((@($r.Messages | Where-Object Kind -eq 'ask')[0].Type -eq 'yesno') -and (@($r.Messages | Where-Object Kind -eq 'ask')[0].Prompt -eq 'Go on?'))
$r = Invoke-InWorker '(Ask-YesNo "x") -eq $true' { 'maybe' }
Expect 'anything but True is not a yes' $r.Result $false

$r = Invoke-InWorker '$a = Ask-Number "Which?" 3; $b = Ask-Number "Which again?" 3 "EXIT"; "$a|$b|" + ($null -eq $b)' { param($m) if ($m.Prompt -eq 'Which?') { 2 } else { '' } }
Expect 'Ask-Number gives the number, and null for the none button' $r.Result '2||True'
$ask = @($r.Messages | Where-Object Kind -eq 'ask')
ExpectTrue 'Ask-Number carries the maximum and the none word' (($ask[0].Max -eq 3) -and ($ask[1].NoneWord -eq 'EXIT'))

$r = Invoke-InWorker '$a = Ask-Phrase "Delete it?" "DELETE"; $b = Ask-Phrase "Again?" "DELETE"; "$a $b"' { param($m) $m.Prompt -eq 'Delete it?' }
Expect 'Ask-Phrase is a confirmation: true only when confirmed' $r.Result 'True False'
Expect 'it carries the word to confirm' (@($r.Messages | Where-Object Kind -eq 'ask')[0].Phrase) 'DELETE'
$r = Invoke-InWorker 'Read-Answer "Name?"' { 'abc' }
Expect 'Read-Answer returns text' $r.Result 'abc'

$r = Invoke-InWorker 'Set-UiPhase "build"; Set-UiPhase "rollback"; Set-UiPhase "zzz"' { $null }
$ph = @($r.Messages | Where-Object Kind -eq 'phase')
Expect 'the phase message says which step of how many' $ph[0].Text 'step 15 of 38 (building the boot programs)'
ExpectTrue 'rollback and unknown phases still read as words' (($ph[1].Text -eq 'rolling back') -and ($ph[2].Text -eq 'zzz'))

$r = Invoke-InWorker 'Ask-YesNo "Will you answer?"' { $true } -CloseAfterAsks 1
ExpectTrue 'closing the window while a question is open stops the worker with a plain message' ($r.Error -eq 'The window was closed.')

# ---------- the same module code runs against these prompts ----------
$r = Invoke-InWorker '$s = [ordered]@{ Version = 1; Phase = "unlock-collect" }; Select-StartAction $s' { param($m) 2 }
Expect 'the start menu works through the window' $r.Result 'Rollback'
ExpectTrue 'and its options were printed above the question' ((@($r.Messages | Where-Object { $_.Kind -eq 'text' -and $_.Text -like '*2. Roll back*' }).Count) -eq 1)

# ---------- the window ----------
$bridge = New-Bridge
$ui = New-InstallerWindow $bridge
function Click($Control) { [void][System.Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'NonPublic,Instance').Invoke($Control, @([EventArgs]::Empty)) }
function ButtonsOf($u) { @($u.Buttons.Controls | ForEach-Object Text) -join '|' }
function ButtonNamed($u, [string]$Text) { @($u.Buttons.Controls | Where-Object Text -eq $Text)[0] }
function Answered { $bridge.AnswerReady.IsSet }

Expect 'the window starts without a question' $ui.Asking $false
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'text'; Text = 'hello'; Color = 'Red' })
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'text'; Text = 'second line'; Color = '' })
ExpectTrue 'text lines are added to the transcript in order' ($ui.Log.Text -match 'hello\s+second line')
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'phase'; Text = 'step 3 of 38 (tools)' })
Expect 'the step is shown at the top' $ui.Header.Text 'step 3 of 38 (tools)'
Expect 'and the busy bar runs while a step works' ([string]$ui.Bar.Style) 'Marquee'

# yes / no
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'ask'; Type = 'yesno'; Prompt = 'Restart now?' })
Expect 'a yes/no question offers exactly Yes and No' (ButtonsOf $ui) 'Yes|No'
ExpectTrue 'the question is visible and the bar stops' ($ui.Asking -and [string]$ui.Bar.Style -eq 'Continuous' -and $ui.Prompt.Text -eq 'Restart now?')
ExpectTrue 'there is no default: no accept button and nothing focused' (($null -eq $ui.Form.AcceptButton) -and ($null -eq $ui.Form.ActiveControl) -and (-not (@($ui.Buttons.Controls | Where-Object { $_.Focused }).Count)))
Click (ButtonNamed $ui 'No')
ExpectTrue 'No gives False and wakes the worker' (($bridge.Answer -eq $false) -and (Answered) -and -not $ui.Asking)
Expect 'the busy bar runs again' ([string]$ui.Bar.Style) 'Marquee'
$bridge.AnswerReady.Reset()
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'ask'; Type = 'yesno'; Prompt = 'Again?' })
Click (ButtonNamed $ui 'Yes')
Expect 'Yes gives True' $bridge.Answer $true
Click (ButtonNamed $ui 'Yes')
ExpectTrue 'a second click after answering does nothing' ($bridge.Answer -eq $true)

# numbered options
$bridge.AnswerReady.Reset()
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'ask'; Type = 'number'; Prompt = 'Which option do you want?'; Max = 3; NoneWord = 'NONE' })
Expect 'a numbered question offers one button per option and None' (ButtonsOf $ui) '1|2|3|None'
Click (ButtonNamed $ui '3')
Expect 'a number button gives that number' ([int]$bridge.Answer) 3
$bridge.AnswerReady.Reset()
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'ask'; Type = 'number'; Prompt = 'What now?'; Max = 4; NoneWord = 'EXIT' })
Expect 'the none button carries the question''s own word' (ButtonsOf $ui) '1|2|3|4|Exit'
Click (ButtonNamed $ui 'Exit')
Expect 'the none button gives an empty answer (no choice)' $bridge.Answer ''

# confirmation with a check box
$bridge.AnswerReady.Reset()
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'ask'; Type = 'confirm'; Prompt = 'Shrink C: by 2.02 GiB (C: now 500.00 GiB, after 497.98 GiB). Confirm?'; Phrase = 'SHRINK' })
Expect 'a confirmation offers Confirm and Cancel' (ButtonsOf $ui) 'Confirm|Cancel'
ExpectTrue 'its question shows the exact sizes' ($ui.Prompt.Text -like '*2.02 GiB*497.98 GiB*')
ExpectTrue 'the check box starts unticked and names the word' ((-not $ui.Check.Checked) -and ($ui.Check.Text -like '*SHRINK*'))
ExpectTrue 'Confirm is disabled until the box is ticked' (-not (ButtonNamed $ui 'Confirm').Enabled)
$ui.Check.Checked = $true
ExpectTrue 'ticking enables Confirm' ((ButtonNamed $ui 'Confirm').Enabled)
$ui.Check.Checked = $false
ExpectTrue 'unticking disables it again' (-not (ButtonNamed $ui 'Confirm').Enabled)
$ui.Check.Checked = $true
Click (ButtonNamed $ui 'Cancel')
Expect 'Cancel gives False even with the box ticked' $bridge.Answer $false
$bridge.AnswerReady.Reset()
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'ask'; Type = 'confirm'; Prompt = 'Accept?'; Phrase = 'I ACCEPT' })
ExpectTrue 'a new confirmation starts unticked again' (-not $ui.Check.Checked)
$ui.Check.Checked = $true; Click (ButtonNamed $ui 'Confirm')
Expect 'ticked + Confirm gives True' $bridge.Answer $true

# text and close
$bridge.AnswerReady.Reset()
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'ask'; Type = 'text'; Prompt = 'Name?' })
$ui.Text.Text = 'Zed'; Click (ButtonNamed $ui 'OK')
Expect 'a text question returns what was typed' $bridge.Answer 'Zed'
$bridge.AnswerReady.Reset()
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'ask'; Type = 'text'; Prompt = 'Press Enter to close this window' })
Expect 'the closing prompt is a Close button' (ButtonsOf $ui) 'Close'
Click (ButtonNamed $ui 'Close')
ExpectTrue 'Close marks the session finished so the window may close' ($ui.Finished -and $bridge.Answer -eq '')
$ui.Form.Dispose()

# a closing window: while a question is open it releases the worker
$bridge = New-Bridge; $ui = New-InstallerWindow $bridge
Invoke-UiMessage $ui ([pscustomobject]@{ Kind = 'ask'; Type = 'yesno'; Prompt = 'Q?' })
$ev = [System.Windows.Forms.FormClosingEventArgs]::new([System.Windows.Forms.CloseReason]::UserClosing, $false)
$m = [System.Windows.Forms.Form].GetMethod('OnFormClosing', [Reflection.BindingFlags]'NonPublic,Instance'); [void]$m.Invoke($ui.Form, [object[]]@($ev))
ExpectTrue 'closing while a question is open tells the worker to stop' ($bridge.Closed -and $bridge.AnswerReady.IsSet -and -not $ev.Cancel)
$ui.Form.Dispose()

# ---------- one set of questions for both front ends ----------
$files = Get-ChildItem (Join-Path $base '*.ps1') | Where-Object { $_.Name -notin 'Ui.ps1', 'GuiPrompts.ps1', 'Gui.ps1' }
$direct = @($files | Select-String -Pattern 'Read-Host|ShowDialog|MessageBox' | Where-Object { $_.Line -notmatch '^\s*#' -and $_.Path -notlike '*Resume.ps1' -and $_.Path -notlike '*Schedule.ps1' })
ExpectTrue 'no module asks a question except through Ui.ps1 (Read-Answer, Ask-YesNo, Ask-Number, Ask-Phrase), the resume window or the generated shortcut script' ($direct.Count -eq 0)
$ui1 = Get-Content (Join-Path $base 'Ui.ps1') -Raw; $gp = Get-Content (Join-Path $base 'GuiPrompts.ps1') -Raw
foreach ($f in 'Read-Answer', 'Ask-YesNo', 'Ask-Number', 'Ask-Phrase', 'Write-Plain') { ExpectTrue "the window replaces $f (and the console has it)" (($ui1 -match "function $f\b") -and ($gp -match "function $f\b")) }
$g = Get-Content (Join-Path $base 'Gui.ps1') -Raw
ExpectTrue 'the window never gives an answer to a question by itself: AcceptButton is only ever cleared, and the only auto answer is the opt-in rehearsal hook' (([regex]::Matches($g, 'AcceptButton\s*=')).Count -eq 1 -and $g -match 'AcceptButton = \$null')

# ---------- the launcher ----------
$entry = Get-Content (Join-Path $repo 'Install-GpuUnlock.ps1') -Raw
ExpectTrue 'the launcher has -Console and falls back by itself when there is no desktop' (($entry -match '\[switch\]\$Console') -and ($entry -match 'Test-DesktopAvailable') -and ($entry -match '\(-not \$Console\) -and'))
ExpectTrue 'the console path calls the same session function as the window' ($entry -match 'Invoke-InstallerSession' -and (Get-Content (Join-Path $base 'Gui.ps1') -Raw) -match 'Invoke-InstallerSession')
$parse = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($entry, [ref]$null, [ref]$parse)
Expect 'the launcher is valid PowerShell' $parse.Count 0

Complete-Tests
