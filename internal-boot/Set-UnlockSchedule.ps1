# Chooses WHEN the unlock runs, using only the one-time boot queue (BootNext), which the firmware honors on cold boots.
# It never changes the permanent firmware boot order (some boards rebuild it at power-up), never touches the Windows boot
# entry, and needs no BIOS or boot-menu step.
#   Once      : queue one unlock for the next boot only.
#   EveryBoot : a Windows startup task queues one unlock for the next boot, every time Windows starts.
#   Off       : remove the startup task and any queued boot; restore the Fast Startup value saved earlier.
#   Status    : show what is set.
# Run in an administrator PowerShell. -DryRun prints the actions and changes nothing.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Once','EveryBoot','Off','Status')][string]$Mode,[string]$EntryId,[switch]$DryRun)
$ErrorActionPreference='Stop'
$root=Join-Path $env:ProgramData 'WindowsGPUUnlock'
$taskName='WindowsGPUUnlock-ArmNextBoot'
$armScript=Join-Path $root 'Arm-NextBoot.ps1'
$stateFile=Join-Path $root 'unlock-schedule-state.json'
$power='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$label='GPUUNLOCK'
$logFolder='RTX3060-UNLOCK'   # per-machine profile value; the profile generator will supply it

function Bcd([string[]]$a){$o=& bcdedit.exe @a 2>&1;if($LASTEXITCODE -ne 0){throw "bcdedit $($a -join ' ') failed: $($o|Out-String)"};return ($o|Out-String)}
function Act([string]$what,[scriptblock]$do){if($DryRun){Write-Output "DRYRUN: $what"}else{& $do}}
function ReadHiber{$k=Get-Item -LiteralPath $power;$e=$k.GetValueNames() -contains 'HiberbootEnabled';@{Exists=$e;Value=$(if($e){[int]$k.GetValue('HiberbootEnabled')}else{$null})}}
function ReadState{if(Test-Path -LiteralPath $stateFile){Get-Content -LiteralPath $stateFile -Raw|ConvertFrom-Json}else{$null}}

$who=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if(-not $who.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run this in an administrator PowerShell.'}

# One source for the firmware-entry lookup (UnlockEntryLookup.ps1): used here and pasted into the generated startup script,
# so the entry is found again at every start.
$findEntryCode=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'UnlockEntryLookup.ps1') -Raw
Invoke-Expression $findEntryCode

# The startup script runs as SYSTEM and the state files are trusted, so the data folder must be a real folder that only the administrators
# and SYSTEM can change (SecureFolder.ps1). The security check is also pasted into the generated script, which re-checks itself at every start.
. (Join-Path $PSScriptRoot 'SecureFolder.ps1')
$securityCheckCode=$script:SecurityCheckCode
if($Mode -ne 'Status' -and (Test-Path -LiteralPath $root -ErrorAction SilentlyContinue)){Act "make the data folder $root a real folder that only administrators and SYSTEM can change" {Protect-DataFolder $root}}

if($Mode -eq 'Status'){
 $s=ReadState;$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
 $notifyTask=Get-ScheduledTask -TaskName 'WindowsGPUUnlock-NotifyStuck' -ErrorAction SilentlyContinue
 Write-Output ("Mode recorded: {0}" -f $(if($s){$s.Mode}else{'never set'}))
 Write-Output ("Startup task: {0}" -f $(if($task){'present'}else{'absent'}))
 Write-Output ("Stuck-notification task: {0}" -f $(if($notifyTask){'present'}else{'absent'}))
 Write-Output ("Fast Startup (HiberbootEnabled): {0}" -f (ReadHiber).Value)
 Write-Output ((Bcd @('/enum','{fwbootmgr}')) -split "`r?`n" | Select-String 'bootsequence|displayorder' | ForEach-Object Line)
 $log=Join-Path $root 'arm.log';if(Test-Path -LiteralPath $log){Write-Output 'Last arm.log lines:';Get-Content -LiteralPath $log -Tail 5}
 return
}

if($Mode -eq 'Off'){
 $s=ReadState
 Act "unregister task $taskName" {if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}}
 Act 'unregister the stuck-notification task and protocol, if set up' {
  $notifyTaskName='WindowsGPUUnlock-NotifyStuck'
  if(Get-ScheduledTask -TaskName $notifyTaskName -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $notifyTaskName -Confirm:$false}
  $key='HKCU:\Software\Classes\gpuunlock-action'
  if(Test-Path -LiteralPath $key){Remove-Item -LiteralPath $key -Recurse -Force}
 }
 Act 'delete any queued one-time boot' {try{[void](Bcd @('/deletevalue','{fwbootmgr}','bootsequence'))}catch{Write-Output 'No queued boot to remove.'}}
 if($s -and $s.HiberbootBefore){
  $h=$s.HiberbootBefore
  Act "restore Fast Startup (exists=$($h.Exists) value=$($h.Value))" {
   if($h.Exists){[void](New-ItemProperty -LiteralPath $power -Name HiberbootEnabled -PropertyType DWord -Value ([int]$h.Value) -Force)}
   elseif((Get-Item -LiteralPath $power).GetValueNames() -contains 'HiberbootEnabled'){Remove-ItemProperty -LiteralPath $power -Name HiberbootEnabled}
  }
 }
 if(-not $DryRun -and $s){$s.Mode='Off';Write-SecureFile $stateFile ($s|ConvertTo-Json -Depth 5) ([Text.UTF8Encoding]::new($true))}
 Write-Output 'Off: no startup task, no queued boot. The permanent boot order was never changed.'
 return
}

# Once / EveryBoot
if(-not $EntryId){$EntryId=Find-UnlockEntry}
if($EntryId -notmatch '^\{[0-9a-fA-F-]{36}\}$'){throw 'EntryId must look like {guid}'}
if(-not (Test-Path -LiteralPath $root)){Act "create $root as a real folder that only administrators and SYSTEM can change" {Protect-DataFolder $root}}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backup=Join-Path $root "Backups\schedule-$stamp"
Act "back up the boot configuration to $backup" {
 [void](New-Item -ItemType Directory -Path $backup -Force)
 [void](Bcd @('/export',(Join-Path $backup 'bcd-store')))
 (Bcd @('/enum','firmware'))|Set-Content -LiteralPath (Join-Path $backup 'firmware-entries.txt') -Encoding utf8
 (Bcd @('/enum','{fwbootmgr}'))|Set-Content -LiteralPath (Join-Path $backup 'fwbootmgr.txt') -Encoding utf8
}
$prev=ReadState
$hiberBefore=if($prev -and $prev.HiberbootBefore){$prev.HiberbootBefore}else{ReadHiber}
Act 'turn Windows Fast Startup off (old value saved)' {[void](New-ItemProperty -LiteralPath $power -Name HiberbootEnabled -PropertyType DWord -Value 0 -Force)}

if($Mode -eq 'EveryBoot'){
 $arm=@'
# Generated by Set-UnlockSchedule.ps1. Queues one unlock for the next boot unless the previous queued run did not finish cleanly.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSCommandPath
$log=Join-Path $root 'arm.log'
$stateFile=Join-Path $root 'arm-state.json'
function Log($m){Add-Content -LiteralPath $log -Value ("{0:s} {1}" -f (Get-Date),$m)}
$label='__LABEL__'
__SECURITY__
# This script runs as SYSTEM: refuse to do anything if it or its folder can be changed by anyone but the administrators or SYSTEM.
$problems=@(Get-SecurityProblems $PSCommandPath)+@(Get-SecurityProblems $root)
if($problems.Count){Log ('refusing to run: '+($problems -join '; '));exit 1}
__LOOKUP__
try{
 # Prerequisites, checked at every start (a Windows or BIOS update can change them). Anything wrong: log it and do not queue.
 $hv=(Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
 if($hv -ne 0){Log "not armed: Fast Startup is on (HiberbootEnabled=$hv), so a shutdown is not a cold boot";exit 0}
 $sb=$null;try{$sb=Confirm-SecureBootUEFI}catch{}
 if($sb -ne $false){Log "not armed: Secure Boot is not confirmed off (state: $sb); the unlock program is not signed";exit 0}
 $vol=Get-Volume -FileSystemLabel $label -ErrorAction SilentlyContinue|Select-Object -First 1
 if(-not $vol){Log "not armed: the boot partition labelled $label is not present";exit 0}
 $entry=$null
 try{$entry=Find-UnlockEntry}catch{Log "not armed: firmware entry lookup failed: $($_.Exception.Message)";exit 0}
 $dir=$vol.Path+'__FOLDER__'
 $runs=@(Get-ChildItem -LiteralPath $dir -Directory -Filter 'AUTO*' -ErrorAction SilentlyContinue|Sort-Object Name)
 $st=if(Test-Path -LiteralPath $stateFile){Get-Content -LiteralPath $stateFile -Raw|ConvertFrom-Json}else{$null}
 if($st -and $st.Armed -and $runs.Count -eq [int]$st.RunsWhenArmed){Log 'not armed: the previously queued unlock left no report (it did not run or did not finish)';exit 0}
 if($runs.Count){
  $final=Select-String -LiteralPath (Join-Path $runs[-1].FullName 'REPORT.TXT') -Pattern '^FINAL '|Select-Object -Last 1
  if(-not $final){Log 'not armed: the latest report has no FINAL line';exit 0}
  if($final.Line -match 'attempted=1' -and $final.Line -notmatch 'clean=1'){Log "not armed: the latest attempt did not end clean: $($final.Line)";exit 0}
 }
 & bcdedit.exe /set '{fwbootmgr}' bootsequence $entry|Out-Null
 if($LASTEXITCODE -ne 0){Log "bcdedit failed with $LASTEXITCODE";exit 1}
 [ordered]@{Armed=$true;RunsWhenArmed=$runs.Count}|ConvertTo-Json|Set-Content -LiteralPath $stateFile -Encoding utf8
 Log "armed one unlock for the next boot (entry $entry, runs on record: $($runs.Count))"
}catch{Log "error: $($_.Exception.Message)";exit 1}
'@
 foreach($anchor in '__LABEL__','__FOLDER__','__LOOKUP__','__SECURITY__'){if(-not $arm.Contains($anchor)){throw "Arm script template lacks $anchor"}}
 $arm=$arm.Replace('__SECURITY__',$securityCheckCode).Replace('__LOOKUP__',$findEntryCode).Replace('__LABEL__',$label).Replace('__FOLDER__',$logFolder)
 if($arm -match '__[A-Z]+__'){throw 'Arm script placeholder was not replaced'}
 Act "write $armScript (checked afterwards: only administrators and SYSTEM may change it)" {Write-SecureFile $armScript $arm ([Text.UTF8Encoding]::new($true))}
 Act "register startup task $taskName (runs as SYSTEM at every Windows start)" {
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$armScript`""
  $trigger=New-ScheduledTaskTrigger -AtStartup
  $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  [void](Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force)
 }
 Act 'run the arm step once now (same code the startup task runs)' {& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $armScript;if($LASTEXITCODE -ne 0){throw 'Arm step failed; see arm.log'}}
 # If the startup task's circuit breaker ever stops queuing (a real freeze, a power loss, or a test can all
 # cause this), nothing would otherwise tell the signed-in user - they would just find it had silently stopped.
 # This deploys a second, LOGON-triggered task that runs as the current interactive user (not SYSTEM, which
 # cannot show UI to a desktop session) and shows a notification with a self-service repair. Self-contained:
 # both deployed scripts only ever touch $root and the registry, never the original install location.
 $notifyTaskName='WindowsGPUUnlock-NotifyStuck'
 $notifyScript=Join-Path $root 'Notify-EveryBootStuck.ps1'
 $handlerScript=Join-Path $root 'Handle-NotifyAction.ps1'
 Act "write $notifyScript and $handlerScript (checked afterwards: only administrators and SYSTEM may change them)" {
  Write-SecureFile $notifyScript (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Notify-EveryBootStuck.ps1') -Raw) ([Text.UTF8Encoding]::new($true))
  Write-SecureFile $handlerScript (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Handle-NotifyAction.ps1') -Raw) ([Text.UTF8Encoding]::new($true))
 }
 Act "register the gpuunlock-action protocol (so clicking a notification button runs $handlerScript)" {
  $key='HKCU:\Software\Classes\gpuunlock-action'
  [void](New-Item -Path $key -Force)
  Set-ItemProperty -LiteralPath $key -Name '(default)' -Value 'URL:GPU Unlock Notification Action'
  Set-ItemProperty -LiteralPath $key -Name 'URL Protocol' -Value ''
  [void](New-Item -Path "$key\shell\open\command" -Force)
  Set-ItemProperty -LiteralPath "$key\shell\open\command" -Name '(default)' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$handlerScript`" -Uri `"%1`""
 }
 Act "register notification task $notifyTaskName (runs as $env:USERNAME at logon, so it can show you a notification)" {
  $naction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$notifyScript`""
  $ntrigger=New-ScheduledTaskTrigger -AtLogOn
  $nprincipal=New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
  $nsettings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
  [void](Register-ScheduledTask -TaskName $notifyTaskName -Action $naction -Trigger $ntrigger -Principal $nprincipal -Settings $nsettings -Force)
 }
}else{
 Act "queue one unlock for the next boot ($EntryId)" {[void](Bcd @('/set','{fwbootmgr}','bootsequence',$EntryId))}
}
Act 'save state' {
 Write-SecureFile $stateFile ([ordered]@{Mode=$Mode;EntryId=$EntryId;HiberbootBefore=$hiberBefore;Backup=$backup;Changed=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 5) ([Text.UTF8Encoding]::new($true))
}
Write-Output "$Mode set. Backup: $backup"
Write-Output "Undo any time:  .\Set-UnlockSchedule.ps1 -Mode Off"
