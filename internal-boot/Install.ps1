# GPL-2.0-only. Existing dedicated ESP only; never create/format/delete partitions.
param([string]$Assets,[switch]$RegisterManual,[switch]$EnableAutomaticBoot,[switch]$ConfirmedManualSuccess,[switch]$RestoreWindowsFirst)
$ErrorActionPreference='Stop'
if(@($RegisterManual,$EnableAutomaticBoot,$RestoreWindowsFirst | Where-Object {$_}).Count -gt 1){throw 'Choose one action'}
. (Join-Path $PSScriptRoot 'install/automatic-policy.ps1')
$stateFile=Join-Path $PSScriptRoot 'install/state.json'
$power='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
function Bcd([string[]]$Arguments){$lines=@(& bcdedit @Arguments);if($LASTEXITCODE -ne 0){throw ('BCDEdit failed: '+($Arguments -join ' '))};return ($lines -join "`r`n")}
function Order([string]$Text){
 $m=[regex]::Match($Text,'(?ms)^displayorder\s+(.*?)(?=\r?\n\S|\z)');if(!$m.Success){throw 'No firmware order'}
 $v=@([regex]::Matches($m.Groups[1].Value,'\{(?:bootmgr|[0-9a-f-]{36})\}') | ForEach-Object {$_.Value})
 if($v -notcontains '{bootmgr}' -or @($v | Select-Object -Unique).Count -ne $v.Count){throw 'Invalid firmware order'};return $v
}
function SetOrder([string[]]$Values){[void](Bcd (@('/set','{fwbootmgr}','displayorder')+$Values))}
function ReadHiber { $k=Get-Item -LiteralPath $power;$e=$k.GetValueNames() -contains 'HiberbootEnabled';if($e -and $k.GetValueKind('HiberbootEnabled') -ne 'DWord'){throw 'Unexpected Hiberboot value type'};return @{Exists=$e;Value=$(if($e){[int]$k.GetValue('HiberbootEnabled')}else{$null})} }
function SetHiber($Plan){
 if($Plan.Exists){[void](New-ItemProperty -LiteralPath $power -Name HiberbootEnabled -PropertyType DWord -Value ([int]$Plan.Value) -Force)}
 elseif((Get-Item -LiteralPath $power).GetValueNames() -contains 'HiberbootEnabled'){Remove-ItemProperty -LiteralPath $power -Name HiberbootEnabled -ErrorAction Stop}
 $read=ReadHiber;if($read.Exists -ne [bool]$Plan.Exists -or ($read.Exists -and $read.Value -ne [int]$Plan.Value)){throw 'Hiberboot restoration failed'}
}
function SaveState($State){$State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding utf8}
function ExistsBcd([string]$Id){$null=& bcdedit /enum $Id;return $LASTEXITCODE -eq 0}
function Ids([string]$Text){return @([regex]::Matches($Text,'(?mi)^identifier\s+(\{[0-9a-f-]{36}\})') | ForEach-Object {$_.Groups[1].Value})}
function CheckEntry([string]$Text,[string]$Name,[string]$Path){
 if($Text -notmatch ('(?m)^description\s+'+[regex]::Escape($Name)+'\s*$') -or $Text -notmatch ('(?mi)^path\s+'+[regex]::Escape($Path)+'\s*$') -or $Text -notmatch ('(?mi)^device\s+partition='+[regex]::Escape($config.UnlockDriveLetter)+':\s*$')){throw 'Registered entry does not match expected device, path and name'}
}
if($RestoreWindowsFirst){
 $s=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
 if([string]$s.EntryId -notmatch '^\{[0-9a-f-]{36}\}$'){throw 'Invalid saved entry'}
 $current=Order (Bcd @('/enum','{fwbootmgr}'))
 Invoke-RecoveryActions -Actions @(
  {SetOrder (@('{bootmgr}')+@($current | Where-Object {$_ -ne '{bootmgr}'}))},
  {if($s.HiberbootBefore){SetHiber $s.HiberbootBefore}},
  {try{[void](Bcd @('/set',$s.EntryId,'path','\EFI\WindowsGPUUnlock\MANUAL.EFI'));[void](Bcd @('/set',$s.EntryId,'description','Windows GPU UNLOCK Manual'))}catch{Write-Warning 'Windows-first recovery is independent; manual entry was not restored'}}
 )
 if((Order (Bcd @('/enum','{fwbootmgr}')))[0] -ne '{bootmgr}'){throw 'Windows-first verification failed'}
 Write-Output 'Windows first restored. No files deleted and no reboot.';return
}
if($EnableAutomaticBoot -and !$ConfirmedManualSuccess){throw 'Test manual unlock, direct Windows entry and Tensor performance first; then explicitly pass -ConfirmedManualSuccess'}
$config=Get-Content (Join-Path $PSScriptRoot 'local-config.json') -Raw | ConvertFrom-Json
function Target {
 $p=Get-Partition -DriveLetter $config.UnlockDriveLetter;$d=Get-Disk -Number $p.DiskNumber;$v=$p | Get-Volume
 if($p.Guid -ne $config.UnlockPartitionGuid -or $p.IsSystem -or $p.Offset -ne $config.UnlockOffset -or $p.Size -ne $config.UnlockSize -or $d.UniqueId -ne $config.UnlockDiskUniqueId -or $p.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or $v.FileSystem -ne 'FAT32' -or !$v.Path){throw 'Configured unlock ESP identity changed'};return $v.Path
}
$root=Target
$windows=@(Get-Partition | Where-Object {$_.Guid -eq $config.WindowsPartitionGuid})
if($windows.Count -ne 1 -or !$windows[0].IsSystem -or $config.WindowsPartitionGuid -eq $config.UnlockPartitionGuid){throw 'Windows ESP identity changed'}
if(Confirm-SecureBootUEFI){throw 'Disable Secure Boot in firmware before using unsigned EFI'}
$enc=Get-BitLockerVolume -MountPoint C:
if([int]$enc.VolumeStatus -ne 0 -or [int]$enc.ProtectionStatus -ne 0){throw 'This experimental installer requires C: fully decrypted and protection off; it never changes encryption settings'}
$manual=Get-Content (Join-Path $PSScriptRoot 'boot/build/full/manifest.json') -Raw | ConvertFrom-Json
$auto=Get-Content (Join-Path $PSScriptRoot 'boot/build/automatic/manifest.json') -Raw | ConvertFrom-Json
$artifacts=@(
 @('unlock/build/experimental/entryLatchedSs1Full/internal/RTX3060-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL.EFI','EFI\WindowsGPUUnlock\UNLOCK.EFI',$manual.UnlockSha256),
 @('boot/build/full/FULL.EFI','EFI\WindowsGPUUnlock\MANUAL.EFI',$manual.EfiSha256),
 @('unlock/build/experimental/entryLatchedSs1Full/internal/automatic/RTX3060-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL-AUTO.EFI','EFI\WindowsGPUUnlock\UNLOCK-AUTO.EFI',$auto.ChildSha256),
 @('boot/build/automatic/AUTO.EFI','EFI\WindowsGPUUnlock\AUTO.EFI',$auto.EfiSha256)
)
if($manual.Mode -ne 'guarded-gop-release-decode-restore-original-unlock' -or $auto.Mode -ne 'guarded-automatic-internal-unlock-then-windows'){throw 'Unexpected build modes'}
function StageFile([string]$Source,[string]$Relative,[string]$Hash){
 if((Get-FileHash -LiteralPath $Source).Hash -ne $Hash){throw 'Build or asset hash mismatch'}
 $dest=Join-Path $root $Relative
 if(Test-Path -LiteralPath $dest){if((Get-FileHash -LiteralPath $dest).Hash -ne $Hash){throw ('Refusing to overwrite different file: '+$Relative)}}
 else{[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));[IO.File]::Copy($Source,$dest,$false)}
 if((Get-FileHash -LiteralPath $dest).Hash -ne $Hash){throw 'Staged hash mismatch'}
}
if(!$Assets){throw 'Specify the local directory containing the five required assets'}
foreach($a in $artifacts){StageFile (Join-Path $PSScriptRoot $a[0]) $a[1] $a[2]}
foreach($a in (Get-Content (Join-Path $PSScriptRoot 'unlock/assets.json') -Raw | ConvertFrom-Json)){
 $source=Join-Path $Assets $a.Name;if((Get-Item -LiteralPath $source).Length -ne $a.Bytes){throw 'Wrong asset size'}
 StageFile $source ('RTX3060-UNLOCK\ASSETS\'+$a.Name) $a.Sha256
}
function CheckStaged {
 if((Target) -ne $root){throw 'Target changed'}
 foreach($a in $artifacts){if((Get-FileHash -LiteralPath (Join-Path $root $a[1])).Hash -ne $a[2]){throw 'Installed EFI changed'}}
 foreach($a in (Get-Content (Join-Path $PSScriptRoot 'unlock/assets.json') -Raw | ConvertFrom-Json)){if((Get-FileHash -LiteralPath (Join-Path $root ('RTX3060-UNLOCK\ASSETS\'+$a.Name))).Hash -ne $a.Sha256){throw 'Installed asset changed'}}
}
if(!$RegisterManual -and !$EnableAutomaticBoot){Write-Output 'Files staged only. Boot order unchanged.';return}
$fw=Bcd @('/enum','{fwbootmgr}');$order=Order $fw;$manager=Bcd @('/enum','{bootmgr}')
if($order[0] -ne '{bootmgr}' -or $fw -match '(?mi)^bootsequence\s+'){throw 'Start with Windows first and no BootNext'}
$backup=Join-Path $env:ProgramData ('WindowsGPUUnlock\Backups\'+(Get-Date -Format 'yyyyMMdd-HHmmssfff'))
[void][IO.Directory]::CreateDirectory($backup);[void](Bcd @('/export',(Join-Path $backup 'BCD-export')))
[IO.File]::WriteAllText((Join-Path $backup 'firmware-before.txt'),(Bcd @('/enum','firmware')))
if($RegisterManual){
 if(Test-Path -LiteralPath $stateFile){throw 'An install state already exists; use its recovery procedure'}
 $beforeIds=Ids (Bcd @('/enum','all'));$reg=@{Id=$null;Mode='registering'}
 $s=[ordered]@{EntryId=$null;BackupRoot=$backup;BootOrderBefore=$order;HiberbootBefore=$null;Mode='registering';HardwareTested=$false}
 CheckStaged
 if((Bcd @('/enum','{fwbootmgr}')) -cne $fw -or (Bcd @('/enum','{bootmgr}')) -cne $manager){throw 'Boot state changed before registration'}
 Invoke-AutomaticTransition -Steps @(
  {
   try{[void](Bcd @('/copy','{bootmgr}','/d','Windows GPU UNLOCK Manual'))}
   finally{
    $afterIds=Ids (Bcd @('/enum','all'));$entries=@{}
    foreach($candidate in $afterIds){if($beforeIds -notcontains $candidate){$entries[$candidate]=Bcd @('/enum',$candidate)}}
    $reg.Id=Resolve-NewBootCopy -BeforeIds $beforeIds -AfterEntries $entries -Source $manager -Name 'Windows GPU UNLOCK Manual'
   }
   $s.EntryId=$reg.Id;SaveState $s
  },
  {[void](Bcd @('/set',$reg.Id,'device',('partition='+$config.UnlockDriveLetter+':')))},
  {[void](Bcd @('/set',$reg.Id,'path','\EFI\WindowsGPUUnlock\MANUAL.EFI'))},
  {SetOrder (@($order)+@($reg.Id))}
 ) -Verify {
  $after=Bcd @('/enum','{fwbootmgr}')
  CheckEntry (Bcd @('/enum',$reg.Id)) 'Windows GPU UNLOCK Manual' '\EFI\WindowsGPUUnlock\MANUAL.EFI'
  if(((Order $after) -join ',') -cne ((@($order)+@($reg.Id)) -join ',') -or $after -match '(?mi)^bootsequence\s+' -or (Bcd @('/enum','{bootmgr}')) -cne $manager){throw 'Manual registration verification failed'}
  CheckStaged;$s.Mode='manual';SaveState $s
 } -Rollback {
  Invoke-RecoveryActions -Actions @({SetOrder $order},{if($reg.Id -and (ExistsBcd $reg.Id)){[void](Bcd @('/delete',$reg.Id))}})
  if(!$reg.Id -or (Bcd @('/enum','{fwbootmgr}')) -cne $fw -or (Bcd @('/enum','{bootmgr}')) -cne $manager -or (ExistsBcd $reg.Id)){throw ('Registration recovery incomplete; inspect backup: '+$backup)}
  if(Test-Path -LiteralPath $stateFile){$owned=Get-Content $stateFile -Raw | ConvertFrom-Json;if($owned.EntryId -ne $reg.Id){throw 'State changed; refusing to remove it'};Remove-Item -LiteralPath $stateFile -ErrorAction Stop}
 }
 Write-Output 'Manual entry registered; Windows stays first. Test using F8 before enabling automatic mode.';return
}
$s=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json;$id=[string]$s.EntryId
if($id -notmatch '^\{[0-9a-f-]{36}\}$' -or $order -notcontains $id){throw 'Saved manual entry missing'}
$entry=Bcd @('/enum',$id)
if($entry -notmatch '(?mi)^path\s+\\EFI\\WindowsGPUUnlock\\MANUAL\.EFI\s*$' -or $entry -notmatch ('(?mi)^device\s+partition='+[regex]::Escape($config.UnlockDriveLetter)+':\s*$')){throw 'Manual entry changed'}
$s.HiberbootBefore=ReadHiber;$s.BackupRoot=$backup
$s | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $backup 'recovery-plan.json') -Encoding utf8
SaveState $s
if((Bcd @('/enum','{fwbootmgr}')) -cne $fw -or (Bcd @('/enum',$id)) -cne $entry -or (Target) -ne $root){throw 'Boot state changed before promotion'}
CheckStaged
$now=ReadHiber;if($now.Exists -ne $s.HiberbootBefore.Exists -or $now.Value -ne $s.HiberbootBefore.Value){throw 'Hiberboot changed before promotion'}
$newOrder=@($id)+@($order | Where-Object {$_ -ne $id})
Invoke-AutomaticTransition -Steps @(
 {[void](Bcd @('/set',$id,'path','\EFI\WindowsGPUUnlock\AUTO.EFI'))},
 {[void](Bcd @('/set',$id,'description','Windows GPU UNLOCK Auto'))},
 {[void](New-ItemProperty -LiteralPath $power -Name HiberbootEnabled -PropertyType DWord -Value 0 -Force)},
 {SetOrder $newOrder}
) -Verify {
 $after=Bcd @('/enum','{fwbootmgr}')
 if(((Order $after) -join ',') -cne ($newOrder -join ',') -or $after -match '(?mi)^bootsequence\s+' -or (Bcd @('/enum','{bootmgr}')) -cne $manager -or (ReadHiber).Value -ne 0){throw 'Automatic promotion verification failed'}
 CheckEntry (Bcd @('/enum',$id)) 'Windows GPU UNLOCK Auto' '\EFI\WindowsGPUUnlock\AUTO.EFI'
 CheckStaged;$s.Mode='automatic';SaveState $s
} -Rollback {
 Invoke-RecoveryActions -Actions @({SetOrder $order},{[void](Bcd @('/set',$id,'path','\EFI\WindowsGPUUnlock\MANUAL.EFI'))},{[void](Bcd @('/set',$id,'description','Windows GPU UNLOCK Manual'))},{SetHiber $s.HiberbootBefore})
 if((Bcd @('/enum','{fwbootmgr}')) -cne $fw -or (Bcd @('/enum',$id)) -cne $entry -or (Bcd @('/enum','{bootmgr}')) -cne $manager){throw ('Automatic recovery incomplete; inspect backup: '+$backup)}
}
Write-Output 'Automatic unlock first, Windows second. Fast Startup disabled. No reboot; first automatic firmware test still required.'
