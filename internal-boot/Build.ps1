param([string]$Clang='clang',[string]$LldLink='lld-link',[string]$Python='python',[switch]$ManualOnly)
$ErrorActionPreference='Stop'
if(!(Test-Path (Join-Path $PSScriptRoot 'local-config.json'))){throw 'Run Configure.ps1 first'}
$common=@{Clang=$Clang;LldLink=$LldLink;Python=$Python;ExperimentalUnlock=$true;InternalBoot=$true;StockProfile='entryLatchedSs1Full'}
& (Join-Path $PSScriptRoot 'unlock/build.ps1') @common
if(!$?){throw 'Manual child build failed'}
$child=Join-Path $PSScriptRoot 'unlock/build/experimental/entryLatchedSs1Full/internal/RTX3060-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL.EFI'
$hash=(Get-FileHash -LiteralPath $child).Hash.ToLowerInvariant()
@('/* Generated local manual child contract. GPL-2.0-only. */',('#define GU_UNLOCK_SHA256 "'+$hash+'"'),('#define GU_UNLOCK_BYTES '+(Get-Item $child).Length)) | Set-Content (Join-Path $PSScriptRoot 'boot/generated.h') -Encoding ascii
& (Join-Path $PSScriptRoot 'boot/build-full.ps1') -Clang $Clang -LldLink $LldLink -Python $Python
if(!$?){throw 'Manual wrapper build failed'}
if($ManualOnly){Write-Output 'Manual EFI pair built (-ManualOnly). Note: Install.ps1 stages both pairs, so build the automatic pair too before staging. Nothing installed.';return}
& (Join-Path $PSScriptRoot 'unlock/build.ps1') @common -AutomaticBoot
if(!$?){throw 'Automatic child build failed'}
& (Join-Path $PSScriptRoot 'boot/build-automatic.ps1') -Clang $Clang -LldLink $LldLink
if(!$?){throw 'Automatic wrapper build failed'}
Write-Output 'Both manual and automatic EFI pairs built. Nothing installed; hardware not tested by this command.'
