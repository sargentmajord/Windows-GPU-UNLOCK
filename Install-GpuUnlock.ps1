# Windows GPU UNLOCK installer. Run it by double-clicking Install-GpuUnlock.cmd; run it again to continue.
# It opens a window. -Console uses the text version instead (it is also used automatically when there is no desktop to show a window on).
# -DryRun shows what would happen and changes nothing (questions are still asked, nothing is saved).
# -Rollback undoes everything the installer did (it asks before it starts). -Resume is used only by the automatic-resume entry you
# can allow at a restart: it opens a window that asks first.
param([switch]$Elevated, [switch]$DryRun, [string]$CaptureFolder, [switch]$Resume, [switch]$Rollback, [switch]$Confirmed, [switch]$Console)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath

# Found live, 2026-10-30: the automatic-resume RunOnce entry (-Resume) repeatedly consumed itself at login
# with nothing ever visibly appearing - no window, no console, no trace of any kind - while the exact same
# command line, run manually, worked every time. RunOnce has no console attached and nowhere to show a
# terminating error, so a failure this early (loading a module, or Test-DesktopAvailable itself) would look
# exactly like "nothing happened" and leave no evidence to tell that apart from the resume dialog silently
# hanging. This writes one line unconditionally before anything else can fail, and another once loading and
# the window/console decision succeed, so the next time this happens at login the log says which it was.
$traceLog = Join-Path $env:ProgramData 'WindowsGPUUnlock\installer\last-launch.log'
try {
 $traceDir = Split-Path -Parent $traceLog
 if (-not (Test-Path -LiteralPath $traceDir)) { [void](New-Item -ItemType Directory -Path $traceDir -Force) }
 ('[{0}] PID={1} SessionId={2} starting: Resume={3} Elevated={4} Console={5}' -f (Get-Date -Format 'o'), $PID, (Get-Process -Id $PID).SessionId, [bool]$Resume, [bool]$Elevated, [bool]$Console) |
  Out-File -FilePath $traceLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
} catch { }

try {
 . (Join-Path $here 'internal-boot\SecureFolder.ps1')
 foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main', 'Session', 'Gui') { . (Join-Path $here "installer\$m.ps1") }
} catch {
 ('[{0}] PID={1} FAILED loading a module: {2}' -f (Get-Date -Format 'o'), $PID, $_.Exception.Message) | Out-File -FilePath $traceLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
 throw
}

try {
 $useWindow = (-not $Console) -and (Test-DesktopAvailable)
 ('[{0}] PID={1} modules loaded; useWindow={2}' -f (Get-Date -Format 'o'), $PID, $useWindow) | Out-File -FilePath $traceLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
} catch {
 ('[{0}] PID={1} FAILED Test-DesktopAvailable: {2}' -f (Get-Date -Format 'o'), $PID, $_.Exception.Message) | Out-File -FilePath $traceLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
 throw
}

# Opens this script again as administrator (Windows shows its own approval prompt). Returns $false if that was declined or failed.
function Restart-AsAdministrator([string[]]$ExtraArguments) {
 try {
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Elevated') + $ExtraArguments
  if ($DryRun) { $a += '-DryRun' }
  if ($Console) { $a += '-Console' }
  if ($CaptureFolder) { $a += @('-CaptureFolder', ('"{0}"' -f $CaptureFolder)) }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $a
  $true
 } catch { $false }
}

function Show-Notice([string]$Text) {
 if ($useWindow) { [void][System.Windows.Forms.MessageBox]::Show($Text, 'Windows GPU UNLOCK installer', 'OK', 'Information') } else { Write-Host $Text }
}
function Ask-Outside([string]$Question) {
 if ($useWindow) { return ([System.Windows.Forms.MessageBox]::Show($Question, 'Windows GPU UNLOCK installer', 'YesNo', 'Question') -eq 'Yes') }
 Ask-YesNo $Question
}
function Wait-CloseOutside { if (-not $useWindow) { Write-Host ''; [void](Read-Host 'Press Enter to close this window') } }

# --- automatic resume after login: ask first, in a window; change nothing before Continue ---
if ($Resume) {
 try {
  Set-RepoRoot $here
  if (-not (Get-SysIsAdmin)) { Set-ReadOnlyMode $true }     # only the step number is read here; the elevated run checks the data folder
  ('[{0}] PID={1} about to show the resume dialog (Invoke-ResumeStart)' -f (Get-Date -Format 'o'), $PID) | Out-File -FilePath $traceLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
  $choice = Invoke-ResumeStart
  ('[{0}] PID={1} resume dialog answered: {2}' -f (Get-Date -Format 'o'), $PID, $choice) | Out-File -FilePath $traceLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
  Set-ReadOnlyMode $false
  if ($choice -eq 'Stop') { Wait-CloseOutside; return }
  if (-not (Get-SysIsAdmin)) {
   $extra = @('-Confirmed'); if ($choice -eq 'Rollback') { $extra += '-Rollback' }
   if (-not (Restart-AsAdministrator $extra)) { Show-Notice 'The administrator prompt was declined or could not open. Nothing was changed.'; Wait-CloseOutside }
   return
  }
  $Confirmed = $true
  if ($choice -eq 'Rollback') { $Rollback = $true }
 } catch {
  ('[{0}] PID={1} FAILED in the resume block: {2}' -f (Get-Date -Format 'o'), $PID, $_.Exception.Message) | Out-File -FilePath $traceLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
  try { Remove-ResumeEntry } catch { }
  Show-Notice ('The installer could not resume: ' + $_.Exception.Message)
  Wait-CloseOutside; return
 }
}

if (-not (Get-SysIsAdmin)) {
 if (-not $useWindow) {
  Write-Host ''
  Write-Host 'Windows GPU UNLOCK installer' -ForegroundColor Cyan
 }
 $q = 'Administrator rights are needed to read and change boot settings. Open this installer again as administrator? Windows will ask you to approve it.'
 if (-not (Ask-Outside $q)) {
  Show-Notice 'Nothing was changed. Run the installer again when you are ready.'
  Wait-CloseOutside; return
 }
 $extra = @(); if ($Rollback) { $extra += '-Rollback' }
 if (-not (Restart-AsAdministrator $extra)) {
  Show-Notice 'The administrator prompt was declined or could not open. Nothing was changed.'
  Wait-CloseOutside
 }
 return
}

if ($useWindow) {
 Start-GuiInstaller $here @{ DryRun = [bool]$DryRun; CaptureFolder = [string]$CaptureFolder; Rollback = [bool]$Rollback; Confirmed = [bool]$Confirmed }
} else {
 [void](Invoke-InstallerSession -Here $here -DryRun:$DryRun -CaptureFolder $CaptureFolder -Rollback:$Rollback -Confirmed:$Confirmed)
}
