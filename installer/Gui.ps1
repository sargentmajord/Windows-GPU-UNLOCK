# The graphical front end (plan requirement 32): one window made with Windows Forms (ships with Windows PowerShell 5.1, no download).
# It shows exactly what the console shows, in a scrolling transcript, and replaces the typed questions with buttons:
#   Yes / No (no default, nothing focused), one button per numbered option, and a real confirmation (check box + Confirm) where the console wants a typed word.
# The installer itself runs in a worker (a separate runspace) so the window never freezes; the worker's prompt functions (GuiPrompts.ps1) talk to
# this window through a queue. The phases, state, journal and tests are the shared modules; no safety rule lives only here.

$script:UiColors = @{ Red = 'Firebrick'; Green = 'SeaGreen'; Yellow = 'DarkGoldenrod'; Cyan = 'SteelBlue'; DarkRed = 'Firebrick'; DarkGreen = 'SeaGreen'; DarkYellow = 'DarkGoldenrod'; Magenta = 'Purple' }

# Needed here at dot-source time, not only later inside New-InstallerWindow: $script:UiDarkTheme below builds
# real System.Drawing.Color values the moment this file loads, so the type must already be resolvable by then.
Add-Type -AssemblyName System.Drawing

# Two Windows-11 touches, both left to the OS rather than a fixed skin of our own: the window's own corners
# follow the current Windows version (DwmSetWindowAttribute is simply ignored, harmlessly, on anything older
# than Windows 11), and the whole window's colors follow whatever light/dark mode the person already has
# Windows set to - the same thing Settings and every other first-party app does - instead of defaulting to
# a plain white window regardless of what the rest of the person's desktop looks like.
if (-not ('GpuUnlockDwm.NativeMethods' -as [type])) {
 Add-Type -Namespace GpuUnlockDwm -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
'@
}
function Get-SystemPrefersDarkMode {
 try { (Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop) -eq 0 }
 catch { $false }     # can't tell: match what a fresh Windows install itself defaults to (light), not a guess
}
# Set once per window, not once per control, so every button and every log line can just read it.
$script:UiIsDark = $false
$script:UiDarkTheme = @{
 Background   = [System.Drawing.Color]::FromArgb(0x20, 0x20, 0x20)
 Surface      = [System.Drawing.Color]::FromArgb(0x1E, 0x1E, 0x1E)
 Text         = [System.Drawing.Color]::FromArgb(0xE4, 0xE4, 0xE4)
 ButtonBack   = [System.Drawing.Color]::FromArgb(0x33, 0x33, 0x33)
 ButtonBorder = [System.Drawing.Color]::FromArgb(0x55, 0x55, 0x55)
}
# Close to the real default Windows 11 light-mode button face/border, so a rounded button still reads as a
# native control rather than a custom skin - only the corners are different, not the colors.
$script:UiLightButton = @{
 Back   = [System.Drawing.Color]::FromArgb(0xE1, 0xE1, 0xE1)
 Border = [System.Drawing.Color]::FromArgb(0xAD, 0xAD, 0xAD)
 Text   = [System.Drawing.Color]::Black
}

function New-InstallerWindow($Bridge) {
 Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
 $script:UiIsDark = Get-SystemPrefersDarkMode
 $form = New-Object System.Windows.Forms.Form
 $form.Text = 'Windows GPU UNLOCK installer'; $form.StartPosition = 'CenterScreen'; $form.ClientSize = New-Object System.Drawing.Size(820, 640); $form.MinimumSize = New-Object System.Drawing.Size(640, 480)
 $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
 try {
  $round = 2; [void][GpuUnlockDwm.NativeMethods]::DwmSetWindowAttribute($form.Handle, 33, [ref]$round, 4)     # DWMWCP_ROUND
  $darkVal = [int]$script:UiIsDark; [void][GpuUnlockDwm.NativeMethods]::DwmSetWindowAttribute($form.Handle, 20, [ref]$darkVal, 4)     # DWMWA_USE_IMMERSIVE_DARK_MODE
 } catch {}
 if ($script:UiIsDark) { $form.BackColor = $script:UiDarkTheme.Background }
 $table = New-Object System.Windows.Forms.TableLayoutPanel
 $table.Dock = 'Fill'; $table.ColumnCount = 1; $table.RowCount = 4
 [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
 [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 10)))
 [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
 [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
 $header = New-Object System.Windows.Forms.Label
 $header.Text = 'Starting...'; $header.AutoSize = $true; $header.Margin = New-Object System.Windows.Forms.Padding(12, 10, 12, 4); $header.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
 $bar = New-Object System.Windows.Forms.ProgressBar
 $bar.Style = 'Marquee'; $bar.MarqueeAnimationSpeed = 30; $bar.Dock = 'Fill'; $bar.Margin = New-Object System.Windows.Forms.Padding(12, 0, 12, 4)
 $log = New-Object System.Windows.Forms.RichTextBox
 $log.ReadOnly = $true; $log.Dock = 'Fill'; $log.Font = New-Object System.Drawing.Font('Consolas', 10); $log.BackColor = [System.Drawing.Color]::White; $log.BorderStyle = 'FixedSingle'
 $log.Margin = New-Object System.Windows.Forms.Padding(12, 4, 12, 4); $log.WordWrap = $true; $log.DetectUrls = $false; $log.TabStop = $false
 $answer = New-Object System.Windows.Forms.TableLayoutPanel
 $answer.AutoSize = $true; $answer.Dock = 'Fill'; $answer.ColumnCount = 1; $answer.Margin = New-Object System.Windows.Forms.Padding(12, 4, 12, 12); $answer.Visible = $false
 $prompt = New-Object System.Windows.Forms.Label
 $prompt.AutoSize = $true; $prompt.MaximumSize = New-Object System.Drawing.Size(760, 0); $prompt.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5); $prompt.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
 if ($script:UiIsDark) {
  $header.ForeColor = $script:UiDarkTheme.Text; $prompt.ForeColor = $script:UiDarkTheme.Text
  $log.BackColor = $script:UiDarkTheme.Surface; $log.ForeColor = $script:UiDarkTheme.Text
 }
 $extra = New-Object System.Windows.Forms.FlowLayoutPanel
 $extra.AutoSize = $true; $extra.FlowDirection = 'LeftToRight'; $extra.WrapContents = $true; $extra.Margin = New-Object System.Windows.Forms.Padding(0)
 $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
 $buttons.AutoSize = $true; $buttons.FlowDirection = 'LeftToRight'; $buttons.WrapContents = $true; $buttons.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
 $answer.Controls.Add($prompt); $answer.Controls.Add($extra); $answer.Controls.Add($buttons)
 $table.Controls.Add($header, 0, 0); $table.Controls.Add($bar, 0, 1); $table.Controls.Add($log, 0, 2); $table.Controls.Add($answer, 0, 3)
 $form.Controls.Add($table)
 $ui = @{ Form = $form; Header = $header; Bar = $bar; Log = $log; Answer = $answer; Prompt = $prompt; Extra = $extra; Buttons = $buttons; Bridge = $Bridge; Asking = $false; Finished = $false; Phrase = ''; Check = $null; Text = $null; ConfirmButton = $null }
 $form.Tag = $ui
 $form.Add_FormClosing({
  param($s, $e)
  $u = $s.Tag
  if ($u.Finished) { return }
  if ($u.Asking) { $u.Bridge.Closed = $true; $u.Bridge.AnswerReady.Set(); return }     # nobody is waiting for a step: the worker stops at the question
  [void][System.Windows.Forms.MessageBox]::Show('A step is running. Please wait until it finishes or asks you something; stopping it in the middle could leave it unfinished.', 'Windows GPU UNLOCK installer', 'OK', 'Information')
  $e.Cancel = $true
 })
 $ui
}

function Add-UiText($Ui, [string]$Text, [string]$Color = '') {
 $log = $Ui.Log
 $log.SelectionStart = $log.TextLength; $log.SelectionLength = 0
 $default = if ($script:UiIsDark) { $script:UiDarkTheme.Text } else { [System.Drawing.Color]::Black }
 $name = if ($Color -and $script:UiColors.ContainsKey($Color)) { $script:UiColors[$Color] } elseif ($Color) { $Color } else { '' }
 if ($name) { try { $log.SelectionColor = [System.Drawing.Color]::FromName($name) } catch { $log.SelectionColor = $default } } else { $log.SelectionColor = $default }
 $log.AppendText($Text + "`r`n")
 $log.SelectionColor = $default
 $log.ScrollToCaret()
}

function Set-UiBusy($Ui, [bool]$Busy) { $Ui.Bar.Style = $(if ($Busy) { 'Marquee' } else { 'Continuous' }); $Ui.Bar.Value = 0 }

# Hands the answer to the worker and puts the window back into its "working" look.
function Submit-UiAnswer($Ui, $Value) {
 if (-not $Ui.Asking) { return }
 $Ui.Asking = $false
 $Ui.Answer.Visible = $false
 Set-UiBusy $Ui $true
 $Ui.Bridge.Answer = $Value
 $Ui.Bridge.AnswerReady.Set()
}

# A Region clip would be the cheap way to round a button's corners, but Region clipping has no anti-
# aliasing - the curve comes out as a visible pixel staircase, which reads as "blocky" rather than smooth.
# Instead this draws the button itself: erase the square face the base control already painted, refill it
# with an anti-aliased rounded path, and draw the label over that - the only way to get an actually smooth
# curve in classic WinForms.
function New-UiButton([string]$Text, [int]$Width = 110) {
 $b = New-Object System.Windows.Forms.Button
 $b.Text = $Text; $b.Size = New-Object System.Drawing.Size($Width, 34); $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 6)
 $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.UseVisualStyleBackColor = $false
 if ($script:UiIsDark) {
  $b.BackColor = $script:UiDarkTheme.ButtonBack; $b.ForeColor = $script:UiDarkTheme.Text; $border = $script:UiDarkTheme.ButtonBorder
 } else {
  $b.BackColor = $script:UiLightButton.Back; $b.ForeColor = $script:UiLightButton.Text; $border = $script:UiLightButton.Border
 }
 # The real Text property stays set (tests and the click-by-text lookups in this file depend on it, and so
 # would a screen reader) - this just repaints over whatever the base control already drew with its own,
 # square, un-rounded version of the same text, so there's no visible double-draw.
 $b.Add_Paint({
  param($s, $e)
  $g = $e.Graphics
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $w = $s.Width; $h = $s.Height; $r = 8
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
  $path.AddArc($w - $r * 2 - 1, 0, $r * 2, $r * 2, 270, 90)
  $path.AddArc($w - $r * 2 - 1, $h - $r * 2 - 1, $r * 2, $r * 2, 0, 90)
  $path.AddArc(0, $h - $r * 2 - 1, $r * 2, $r * 2, 90, 90)
  $path.CloseFigure()
  $parentBack = if ($s.Parent) { $s.Parent.BackColor } else { $s.BackColor }
  $eraseBrush = New-Object System.Drawing.SolidBrush($parentBack)
  $g.FillRectangle($eraseBrush, 0, 0, $w, $h)
  $fillBrush = New-Object System.Drawing.SolidBrush($s.BackColor)
  $g.FillPath($fillBrush, $path)
  $pen = New-Object System.Drawing.Pen($border, 1)
  $g.DrawPath($pen, $path)
  $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
  [System.Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)), $s.ForeColor, $flags)
  $eraseBrush.Dispose(); $fillBrush.Dispose(); $pen.Dispose(); $path.Dispose()
 }.GetNewClosure())
 $b
}

# Shows a question. Nothing is selected or focused, and Enter does nothing, so no answer can be given by accident.
function Show-UiAsk($Ui, $Msg) {
 $Ui.Extra.Controls.Clear(); $Ui.Buttons.Controls.Clear()
 $Ui.Check = $null; $Ui.Text = $null; $Ui.ConfirmButton = $null
 $Ui.Form.AcceptButton = $null
 $Ui.Prompt.Text = [string]$Msg.Prompt
 switch ($Msg.Type) {
  'yesno' {
   $y = New-UiButton 'Yes'; $n = New-UiButton 'No'
   $y.Add_Click({ param($s, $e) Submit-UiAnswer $s.FindForm().Tag $true }); $n.Add_Click({ param($s, $e) Submit-UiAnswer $s.FindForm().Tag $false })
   $Ui.Buttons.Controls.Add($y); $Ui.Buttons.Controls.Add($n)
  }
  'number' {
   for ($i = 1; $i -le [int]$Msg.Max; $i++) {
    $b = New-UiButton ([string]$i) 56; $b.Tag = $i
    $b.Add_Click({ param($s, $e) Submit-UiAnswer $s.FindForm().Tag $s.Tag })
    $Ui.Buttons.Controls.Add($b)
   }
   $none = New-UiButton ((Get-Culture).TextInfo.ToTitleCase(([string]$Msg.NoneWord).ToLower())) 110
   $none.Tag = ''
   $none.Add_Click({ param($s, $e) Submit-UiAnswer $s.FindForm().Tag '' })
   $Ui.Buttons.Controls.Add($none)
  }
  'confirm' {
   $Ui.Phrase = [string]$Msg.Phrase
   $c = New-Object System.Windows.Forms.CheckBox
   $c.Text = 'Yes, I understand and I confirm this (' + $Msg.Phrase + ')'; $c.AutoSize = $true; $c.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
   if ($script:UiIsDark) { $c.ForeColor = $script:UiDarkTheme.Text }
   $ok = New-UiButton 'Confirm'; $ok.Enabled = $false; $cancel = New-UiButton 'Cancel'
   $c.Add_CheckedChanged({ param($s, $e) $u = $s.FindForm().Tag; $u.ConfirmButton.Enabled = $s.Checked })
   $ok.Add_Click({ param($s, $e) $u = $s.FindForm().Tag; Submit-UiAnswer $u ([bool]$u.Check.Checked) })
   $cancel.Add_Click({ param($s, $e) Submit-UiAnswer $s.FindForm().Tag $false })
   $Ui.Check = $c; $Ui.ConfirmButton = $ok
   $Ui.Extra.Controls.Add($c); $Ui.Buttons.Controls.Add($ok); $Ui.Buttons.Controls.Add($cancel)
  }
  default {
   if (([string]$Msg.Prompt) -like 'Press Enter to close*') {
    $Ui.Prompt.Text = 'The installer has finished.'
    $b = New-UiButton 'Close'; $b.Add_Click({ param($s, $e) $u = $s.FindForm().Tag; $u.Finished = $true; Submit-UiAnswer $u '' }); $Ui.Buttons.Controls.Add($b)
   } else {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Width = 420; $Ui.Text = $t; $Ui.Extra.Controls.Add($t)
    if ($script:UiIsDark) { $t.BackColor = $script:UiDarkTheme.Surface; $t.ForeColor = $script:UiDarkTheme.Text }
    $b = New-UiButton 'OK'; $b.Add_Click({ param($s, $e) $u = $s.FindForm().Tag; Submit-UiAnswer $u $u.Text.Text }); $Ui.Buttons.Controls.Add($b)
   }
  }
 }
 $Ui.Asking = $true
 Set-UiBusy $Ui $false
 $Ui.Answer.Visible = $true
 $Ui.Form.ActiveControl = $null
}

# One message from the worker.
function Invoke-UiMessage($Ui, $Msg) {
 switch ($Msg.Kind) {
  'text' { Add-UiText $Ui ([string]$Msg.Text) ([string]$Msg.Color) }
  'phase' { $Ui.Header.Text = [string]$Msg.Text; Add-UiText $Ui ('--- ' + [string]$Msg.Text + ' ---') 'Cyan' }
  'ask' { Add-UiText $Ui ''; Show-UiAsk $Ui $Msg }
  'done' { $Ui.Finished = $true; Set-UiBusy $Ui $false; $Ui.Header.Text = 'Finished'; $Ui.Form.Close() }
 }
}

# Starts the installer session in its own runspace (the "worker") and returns @{ Ps; Rs; Handle }.
function Start-GuiWorker([string]$Here, $Bridge, [hashtable]$Options) {
 $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
 $ps = [powershell]::Create(); $ps.Runspace = $rs
 [void]$ps.AddScript({
  param($Here, $Bridge, $Opts)
  $ErrorActionPreference = 'Stop'
  . (Join-Path $Here 'internal-boot\SecureFolder.ps1')
  foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main', 'Session', 'GuiPrompts') { . (Join-Path $Here "installer\$m.ps1") }
  $script:Bridge = $Bridge
  $end = 'Error'
  try { $end = Invoke-InstallerSession -Here $Here -DryRun:([bool]$Opts.DryRun) -CaptureFolder ([string]$Opts.CaptureFolder) -Rollback:([bool]$Opts.Rollback) -Confirmed:([bool]$Opts.Confirmed) }
  catch { Send-Ui @{ Kind = 'text'; Text = ('The installer stopped because of an error: ' + $_.Exception.Message); Color = 'Red' } }
  Send-Ui @{ Kind = 'done'; End = $end }
 }).AddArgument($Here).AddArgument($Bridge).AddArgument($Options)
 $handle = $ps.BeginInvoke()
 @{ Ps = $ps; Rs = $rs; Handle = $handle }
}

# Runs the whole session in the window. -AutoAnswer (a script block that gets the ask message and returns the answer) is for rehearsals and tests.
function Start-GuiInstaller([string]$Here, [hashtable]$Options, [scriptblock]$AutoAnswer, [int]$MaxSeconds = 0) {
 $bridge = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Answer = $null; AnswerReady = (New-Object System.Threading.ManualResetEventSlim($false)); Closed = $false })
 $ui = New-InstallerWindow $bridge
 $worker = Start-GuiWorker $Here $bridge $Options
 $ps = $worker.Ps; $rs = $worker.Rs; $handle = $worker.Handle
 $timer = New-Object System.Windows.Forms.Timer
 $timer.Interval = 80
 # the timer's handler runs later on this thread; it reads these through script scope
 $script:GuiBridge = $bridge; $script:GuiUi = $ui; $script:GuiAuto = $AutoAnswer; $script:GuiMax = $MaxSeconds; $script:GuiStarted = Get-Date
 $timer.Add_Tick({
  $msg = $null
  $count = 0
  while ($count -lt 200 -and $script:GuiBridge.Queue.TryDequeue([ref]$msg)) {
   $count++
   Invoke-UiMessage $script:GuiUi $msg
   if ($script:GuiAuto -and $msg.Kind -eq 'ask' -and $script:GuiUi.Asking) { Submit-UiAnswer $script:GuiUi (& $script:GuiAuto $msg) }
  }
  if ($script:GuiMax -gt 0 -and ((Get-Date) - $script:GuiStarted).TotalSeconds -gt $script:GuiMax) { $script:GuiUi.Finished = $true; $script:GuiBridge.Closed = $true; $script:GuiBridge.AnswerReady.Set(); $script:GuiUi.Form.Close() }
 })
 $timer.Start()
 try { [void]$ui.Form.ShowDialog() } finally { $timer.Stop(); $bridge.Closed = $true; $bridge.AnswerReady.Set() }
 $deadline = (Get-Date).AddSeconds(5)
 while (-not $handle.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
 if ($handle.IsCompleted) { try { [void]$ps.EndInvoke($handle) } catch { Write-Host ('The installer window ended with an error: ' + $_.Exception.Message) -ForegroundColor Red } }
 $ps.Dispose(); $rs.Dispose()
 $ui.Form.Dispose()
}

# Is there a desktop to show a window on? (Not in a remote console without one, not in session 0.)
function Test-DesktopAvailable {
 try {
  if (-not [Environment]::UserInteractive) { return $false }
  if ((Get-Process -Id $PID).SessionId -eq 0) { return $false }
  Add-Type -AssemblyName System.Windows.Forms
  if ([System.Windows.Forms.SystemInformation]::MonitorCount -lt 1) { return $false }
  # build (and throw away) a window once, so a machine that cannot make one falls back to the text version before anything starts
  $probe = New-InstallerWindow ([hashtable]::Synchronized(@{ Queue = $null; AnswerReady = $null; Closed = $false }))
  $probe.Form.Dispose()
  return $true
 } catch { return $false }
}
