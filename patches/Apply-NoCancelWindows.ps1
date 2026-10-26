param([string]$Clang='clang',[string]$LldLink='lld-link',[string]$Python='python',[switch]$Undo,[string]$Accept)
# Applies (or removes) patches/no-cancel-windows.patch and builds the private automatic pair without the Esc cancel windows.
# See patches/README-no-cancel-windows.md. Installs nothing and changes no boot setting.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$patch=Join-Path $PSScriptRoot 'no-cancel-windows.patch'
Push-Location $repo
try {
 if($Undo){
  git apply -R --check $patch
  if($LASTEXITCODE -ne 0){throw 'The patch is not applied (or the files changed since); nothing was removed.'}
  git apply -R $patch; if($LASTEXITCODE -ne 0){throw 'Removing the patch failed'}
  Write-Output 'Patch removed. Rebuild with internal-boot\Build.ps1 for the default build (with the Esc windows).'; return
 }
 Write-Output @'
==================== DISCLAIMER ====================
This patch REMOVES the two Esc cancel windows (5 s and 3 s) from the automatic unlock boot.
 - Experimental third-party software, provided "as is", with NO WARRANTY, under GPL-2.0-only. Use at your own risk.
 - You will NOT be able to cancel from the keyboard during boot. To abort you must power off.
 - If any hardware check fails, the boot stops on a frozen screen. You must hold the power button, power on again and
   Windows then starts normally; no BIOS or boot menu is needed.
 - Do not use it if you cannot be at the PC to do that. Keep Windows Boot Manager first in the firmware boot order.
 - All hardware checks stay in place; this patch adds no switch to skip a check.
 - Verified only on the reference machine in CHANGES.md. The video BIOS is not modified; the unlock is lost at power-off.
====================================================
'@
 $answer=if($Accept){$Accept}else{Read-Host 'Type I ACCEPT to continue'}
 if($answer -cne 'I ACCEPT'){throw 'Not accepted. Nothing was changed.'}
 git apply --check $patch
 if($LASTEXITCODE -ne 0){throw 'The patch does not apply cleanly to this source tree (already applied or the code changed). Nothing was changed.'}
 git apply $patch; if($LASTEXITCODE -ne 0){throw 'Applying the patch failed'}
 try {
  $common=@{Clang=$Clang;LldLink=$LldLink;Python=$Python;ExperimentalUnlock=$true;InternalBoot=$true;StockProfile='entryLatchedSs1Full';AutomaticBoot=$true;NoEscWindows=$true}
  & (Join-Path $repo 'internal-boot\unlock\build.ps1') @common
  if(!$?){throw 'Private child build failed'}
  & (Join-Path $repo 'internal-boot\boot\build-automatic.ps1') -Clang $Clang -LldLink $LldLink -Python $Python -NoEscWindows
  if(!$?){throw 'Private wrapper build failed'}
 } catch {
  Write-Warning "Build failed: $($_.Exception.Message) - removing the patch again."
  git apply -R $patch; throw
 }
 $m=Get-Content (Join-Path $repo 'internal-boot\boot\build\automatic-noesc\manifest.json') -Raw | ConvertFrom-Json
 Write-Output "Built (patch stays applied until you run -Undo):"
 Write-Output "  internal-boot\boot\build\automatic-noesc\AUTO.EFI  $($m.EfiSha256)"
 Write-Output "  internal-boot\unlock\build\experimental\entryLatchedSs1Full\internal\automatic-noesc\*-AUTO-NOESC.EFI  $($m.ChildSha256)"
 Write-Output 'Nothing was installed. Stage the two files yourself the same way as the default automatic pair.'
} finally {Pop-Location}
