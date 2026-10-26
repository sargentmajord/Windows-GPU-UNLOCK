# Modified 2026-10-19/20 for Windows GPU UNLOCK; changes documented in CHANGES.md.
param(
 [string]$Clang='clang',
 [string]$LldLink='lld-link',
 [string]$Python='python',
 [switch]$ExperimentalUnlock,
 [switch]$InternalBoot,
 [switch]$AutomaticBoot,
 [switch]$HeadlessResearch,
 [ValidateSet('original03100062','observed03000062','entryLatchedSs1Preserve','entryLatchedSs1Full')][string]$StockProfile,
 [string]$HardwareProfile='z790-3060'
)
# The profile is the single source of per-machine constants: unlock/profiles/<name>/profile.h for the reference
# machine, or a generated profile.h in a folder the installer puts on CPATH (see machine-profile.h).
function Get-ProfileValue([string]$Text,[string]$Name){
 $m=[regex]::Match($Text,'(?m)^#define\s+'+$Name+'\s+("[^"]*"|\S+)');if(!$m.Success){throw "Profile has no $Name"};$m.Groups[1].Value.Trim('"')
}
$profileDir=if($env:CPATH){($env:CPATH -split ';' | Where-Object {$_ -and (Test-Path -LiteralPath (Join-Path $_ 'profile.h'))} | Select-Object -First 1)}else{$null}
$profileFile=if($profileDir){Join-Path $profileDir 'profile.h'}else{Join-Path $PSScriptRoot 'profiles/z790-3060/profile.h'}
$profileText=Get-Content -LiteralPath $profileFile -Raw
$hw=[ordered]@{Name=(Get-ProfileValue $profileText 'GU_PROFILE_NAME');
 TargetPci=((Get-ProfileValue $profileText 'GU_BOARD_ID') -replace '^0x','' -replace 'U$','');
 Subsystem=((Get-ProfileValue $profileText 'GU_BOARD_SUBSYSTEM') -replace '^0x','' -replace 'U$','');
 Chip=((Get-ProfileValue $profileText 'GU_CHIP_ID') -replace 'U$','');
 Prom=(Get-ProfileValue $profileText 'GU_PROM_SHA256');
 Memory=((Get-ProfileValue $profileText 'GU_DEVICE_MEMORY_SIZE') -replace 'U$','');HeadlessOnly=$false}
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 if(!(Test-Path -LiteralPath $PSScriptRoot)){throw 'Missing output parent'}
 if($ExperimentalUnlock -and !$PSBoundParameters.ContainsKey('StockProfile')){throw '-StockProfile is required with -ExperimentalUnlock'}
 if(!$ExperimentalUnlock -and $PSBoundParameters.ContainsKey('StockProfile')){throw '-StockProfile is only valid with -ExperimentalUnlock'}
 $out=if($ExperimentalUnlock){"build/experimental/$StockProfile"}else{'build'}
 $name=if($ExperimentalUnlock){"RTX3060-EXPERIMENTAL-$StockProfile"}else{'RTX3060-PREFLIGHT'}
 $defines=@()
 if($HeadlessResearch -and (!$AutomaticBoot -or !$InternalBoot -or !$ExperimentalUnlock -or $StockProfile -ne 'entryLatchedSs1Full')){throw 'Headless research requires automatic internal exact full profile'}
 if($hw.HeadlessOnly -and $ExperimentalUnlock -and !$HeadlessResearch){throw ('Profile '+$HardwareProfile+' only ships a headless write path; non-headless builds are diagnostic-only')}
 if($AutomaticBoot -and (!$InternalBoot -or !$ExperimentalUnlock -or $StockProfile -ne 'entryLatchedSs1Full')){throw 'Automatic boot requires internal full experimental profile'}
 if($InternalBoot) {
  if(!$ExperimentalUnlock -or $StockProfile -ne 'entryLatchedSs1Full'){throw 'Internal boot requires the validated full experimental profile'}
  $out+='/internal';$name+='-INTERNAL';$defines+='-DGU_INTERNAL_BOOT'
 }
 if($AutomaticBoot){$out+='/automatic';$name+='-AUTO';$defines+='-DGU_AUTOMATIC_BOOT'}
 if($HeadlessResearch){$out+='/headless-research';$name+='-HEADLESS-RESEARCH';$defines+='-DGU_HEADLESS_RESEARCH'}
  if($ExperimentalUnlock){$defines+= '-DGU_EXPERIMENTAL_UNLOCK';$defines+=$(switch($StockProfile){'original03100062'{'-DGU_STOCK_PROFILE_ORIGINAL_03100062'} 'observed03000062'{'-DGU_STOCK_PROFILE_OBSERVED_03000062'} 'entryLatchedSs1Preserve'{'-DGU_ENTRY_LATCHED_SS1_PRESERVE'} 'entryLatchedSs1Full'{'-DGU_ENTRY_LATCHED_SS1_FULL'}})}
 New-Item -ItemType Directory -Path $out -Force | Out-Null
 $sources=@('app','app_io','ownership','format','runtime','sha256','checks','port','compat',
  'vendor/unlock_610','vendor/prep_610','vendor/layout_610','vendor/vbios_610','vendor/gfw_eval')
 $objects=@()
 foreach($source in $sources) {
  $object="$out/"+($source -replace '/','_')+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror -Wno-unused-parameter -D__KERNEL__ -DGU_UEFI_PORT @defines -I compat -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 -c "$source.c" -o $object
  if($LASTEXITCODE -ne 0){throw "Compile failed: $source"};$objects+=$object
 }
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf "/map:$out/$name.map" "/out:$out/$name.EFI" @objects
 if($LASTEXITCODE -ne 0){throw 'EFI link failed'}
 & $Python verify_pe.py "$out/$name.EFI" "$out/$name.map" --output "$out/pe-verification.json"
 if($LASTEXITCODE -ne 0){throw 'PE verification failed'}
 [ordered]@{BuiltUtc=[DateTime]::UtcNow.ToString('o');HardwareProfile=$hw.Name;TargetPci=$hw.TargetPci;Subsystem=$hw.Subsystem;
  Mode=$(if($HeadlessResearch){'headless-research-automatic-internal-exact-card-unlock'}elseif($AutomaticBoot){'automatic-internal-exact-card-unlock'}elseif($ExperimentalUnlock){'experimental-exact-card-manual-unlock'}else{'diagnostic-preflight-only'});
  CanArm=[bool]$ExperimentalUnlock;Defines=$defines;ManualConfirmation=$(if($AutomaticBoot){'none; Esc within 3 seconds cancels'}else{'U once; Esc or 30-second timeout cancels'});
  StockProfile=$(if($ExperimentalUnlock){$StockProfile}else{$null});ColdChipExpected=$hw.Chip;ColdSS0Expected=$(if($StockProfile -like 'entryLatchedSs1*'){'first fully validated cold entry; immutable'}elseif($ExperimentalUnlock){if($StockProfile -eq 'original03100062'){'0x03100062'}else{'0x03000062'}}else{'unknown'});ColdSS1Expected=$(if($StockProfile -like 'entryLatchedSs1*'){'first fully validated cold entry <= 0xf; immutable'}else{'0x6'});
  SS0Target='0x88888888';SS1Target=$(if($StockProfile -eq 'entryLatchedSs1Preserve'){'preserve entry; no SS1 writes'}elseif($StockProfile -eq 'entryLatchedSs1Full'){'0x8; one guarded write'}elseif($ExperimentalUnlock){'0x8'}else{'no writes'});
  OriginalBaselineCapture='local read-only diagnostic capture of the target machine (not published)';
  StockProfileSource=$(if($StockProfile -like 'entryLatchedSs1*'){'Explicit immutable validated entry latch; no fixed stock selector assumption'}elseif($StockProfile -eq 'observed03000062'){'Explicit observed03000062 experiment selection; original baseline capture does not evidence this SS0'}elseif($ExperimentalUnlock){'OriginalBaselineCapture'}else{'preflight has no selected stock profile'});
  PromSha256=$hw.Prom;
  DeviceMemorySize=$hw.Memory;HardwareTested=$false;
  EfiSha256=(Get-FileHash -LiteralPath "$out/$name.EFI" -Algorithm SHA256).Hash;
  Headers=@(Get-ChildItem -LiteralPath . -Recurse -File -Filter '*.h' | Where-Object {$_.FullName.Substring($PSScriptRoot.Length+1) -notmatch '(^|[\\/])build([\\/]|$)'} | Sort-Object FullName | ForEach-Object {[ordered]@{Path=$_.FullName.Substring($PSScriptRoot.Length+1);Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}});
  Sources=@($sources | ForEach-Object {[ordered]@{Path="$_.c";Sha256=(Get-FileHash -LiteralPath "$_.c" -Algorithm SHA256).Hash}})
  } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath "$out/build-manifest.json"
 "Built $name.EFI; ExperimentalUnlock=$([bool]$ExperimentalUnlock); hardware untested."
} finally {Pop-Location}
