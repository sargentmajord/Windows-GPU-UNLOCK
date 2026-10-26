# One installer session after administrator rights are in place: the opening text, the start menu for an earlier install, then the phases or
# Roll back. The same function runs in the console and, inside the graphical window's worker, with the prompts swapped (GuiPrompts.ps1).
# Needs every module, loaded.

function Wait-Close { Write-Plain ''; [void](Read-Answer 'Press Enter to close this window') }

function Write-OpeningText([switch]$Rollback) {
 Write-Host ''
 Write-Host 'Windows GPU UNLOCK installer' -ForegroundColor Cyan
 Write-Host 'Before it changes anything it shows you a plan and asks you to confirm. You can roll back at any time.'
 Write-Host ''
 if ($Rollback) { Write-Host 'You asked to roll back.' }
 else {
  Write-Host 'You need:'
  Write-Host ' - a display (monitor, wireless HDMI adapter or HDMI/DisplayPort dummy plug) attached to the card that will be unlocked;'
  Write-Host '   on some boards the firmware creates no screen output for that card without one.'
  Write-Host ' - another graphics adapter that keeps your screen working.'
  Write-Host ' - to know how to recover from a frozen start: hold the power button until the PC turns off, then power on.'
  Write-Host '   No BIOS screen or boot menu is needed.'
  Write-Host ''
  foreach ($l in (Get-RollbackExplanation)) { Write-Host $l }
 }
 Write-Host ''
}

# Returns a short word describing how the session ended: Finished | RolledBack | Stopped | Exited | SwitchedOff | Error
function Invoke-InstallerSession([string]$Here, [switch]$DryRun, [string]$CaptureFolder, [switch]$Rollback, [switch]$Confirmed) {
 Write-OpeningText -Rollback:$Rollback
 try {
  Set-RepoRoot $Here
  if (-not $Rollback -and -not $Confirmed) {
   $existing = Read-InstallerState
   if ($existing.Phase -ne 'new') {
    if ($existing.Phase -eq 'done') { $statusItems = Get-InstallStatus $existing; Show-InstallStatus $statusItems }
    $act = Select-StartAction $existing
    if ($act -eq 'Exit') { Write-Host 'Nothing was changed.'; Wait-Close; return 'Exited' }
    if ($act -eq 'Rollback') { $Rollback = $true }
    if ($act -eq 'SwitchOff') {
     Disable-Extras $existing -DryRun:$DryRun
     if (-not $DryRun) { Save-InstallerState $existing }
     Write-Host 'The optional extras are switched off.' -ForegroundColor Green
     Wait-Close; return 'SwitchedOff'
    }
    if ($act -eq 'Continue' -and $existing.Phase -eq 'done') {
     $dirty = Invoke-StatusRepairs $existing $statusItems -DryRun:$DryRun
     $envChange = Invoke-EnvironmentChange $existing @{ DryRun = [bool]$DryRun; ReportFolder = (Join-Path $Here 'reports'); CaptureFolder = $CaptureFolder }
     if ($envChange -and $envChange.Stop) { if (-not $DryRun) { Save-InstallerState $existing }; Write-Host ('The installer stopped: ' + $envChange.Stop + '.') -ForegroundColor Yellow; Wait-Close; return 'Stopped' }
     if (-not $envChange -and (Offer-BootProgramUpdate $existing -DryRun:$DryRun)) { $dirty = $true }
     if ($envChange -and $envChange.Next) { $dirty = $true }
     if ($dirty -and -not $DryRun) { Save-InstallerState $existing }
    }
   }
  }
  $r = Invoke-Installer -DryRun:$DryRun -ReportFolder (Join-Path $Here 'reports') -CaptureFolder $CaptureFolder -Rollback:$Rollback
  if ($r.RolledBack) { Write-Host 'Roll back is finished.' -ForegroundColor Green; $end = 'RolledBack' }
  elseif ($r.Done) { Write-Host 'This part of the installer is finished.' -ForegroundColor Green; $end = 'Finished' }
  else { Write-Host ('The installer stopped at "{0}": {1}. Run it again to continue.' -f $r.Phase, $r.Reason) -ForegroundColor Yellow; $end = 'Stopped' }
 } catch {
  try { Remove-ResumeEntry } catch { }     # a broken install must never relaunch itself at the next login
  Write-Host ('The installer stopped because of an error: ' + $_.Exception.Message) -ForegroundColor Red
  $end = 'Error'
 }
 Wait-Close
 $end
}
