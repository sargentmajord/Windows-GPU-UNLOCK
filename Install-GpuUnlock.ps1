# Windows GPU UNLOCK installer. Run it by double-clicking Install-GpuUnlock.cmd; run it again to continue.
# It opens a window. -Console uses the text version instead (it is also used automatically when there is no desktop to show a window on).
# -DryRun shows what would happen and changes nothing (questions are still asked, nothing is saved).
# -Rollback undoes everything the installer did (it asks before it starts). -Resume is used only by the automatic-resume entry you
# can allow at a restart: it opens a window that asks first.
param([switch]$Elevated, [switch]$DryRun, [string]$CaptureFolder, [switch]$Resume, [switch]$Rollback, [switch]$Confirmed, [switch]$Console)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'internal-boot\SecureFolder.ps1')
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main', 'Session', 'Gui') { . (Join-Path $here "installer\$m.ps1") }

$useWindow = (-not $Console) -and (Test-DesktopAvailable)

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
  $choice = Invoke-ResumeStart
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
