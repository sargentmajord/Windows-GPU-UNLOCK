# Registered as the handler for the gpuunlock-action: URI protocol. Windows invokes this with the clicked
# toast button's URI as the first argument when the user picks Repair, Ignore or "No, turn it off" on the
# every-boot-stuck notification (Notify-EveryBootStuck.ps1 shows it). Self-contained: does not depend on the
# original installer download still being present, since it may be clicked long after that was deleted.
param([Parameter(Mandatory)][string]$Uri, [string]$DataRoot = (Join-Path $env:ProgramData 'WindowsGPUUnlock'))
$ErrorActionPreference = 'Stop'
$log = Join-Path $DataRoot 'arm.log'
function Log($m) { Add-Content -LiteralPath $log -Value ("{0:s} [notify-action] {1}" -f (Get-Date), $m) }

# Elevates and re-runs a scriptblock as administrator if the current process is not already elevated.
# Returns $true if it ran directly, $false if it had to hand off to an elevated child process.
function Invoke-Elevated([scriptblock]$Do) {
 $id = [Security.Principal.WindowsIdentity]::GetCurrent()
 $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
 if ($isAdmin) { & $Do; return $true }
 $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Do.ToString()))
 Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
 return $false
}

function Get-Action([string]$RawUri) {
 if ($RawUri -match '^gpuunlock-action:(?<a>\w+)') { return $Matches.a.ToLowerInvariant() }
 return $null
}

$action = Get-Action $Uri
switch ($action) {
 'repair' {
  $stateFile = Join-Path $DataRoot 'arm-state.json'
  Invoke-Elevated { Remove-Item -LiteralPath $using:stateFile -Force -ErrorAction SilentlyContinue } | Out-Null
  Log 'repair: cleared the stuck state from the notification; it will queue normally again from the next start'
 }
 'ignore' {
  Log 'ignore: no change from the notification; it will ask again if still stuck at the next logon'
 }
 'no' {
  $taskName = 'WindowsGPUUnlock-ArmNextBoot'
  $stateFile = Join-Path $DataRoot 'unlock-schedule-state.json'
  $power = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
  Invoke-Elevated {
   if (Get-ScheduledTask -TaskName $using:taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $using:taskName -Confirm:$false }
   try { & bcdedit.exe /deletevalue '{fwbootmgr}' bootsequence 2>&1 | Out-Null } catch {}
   $notifyTask = 'WindowsGPUUnlock-NotifyStuck'
   if (Get-ScheduledTask -TaskName $notifyTask -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $notifyTask -Confirm:$false }
   if (Test-Path -LiteralPath $using:stateFile) {
    $s = Get-Content -LiteralPath $using:stateFile -Raw | ConvertFrom-Json
    if ($s.HiberbootBefore -and $s.HiberbootBefore.Exists) {
     Set-ItemProperty -LiteralPath $using:power -Name HiberbootEnabled -Value $s.HiberbootBefore.Value -Type DWord
    }
   }
  } | Out-Null
  Log 'no: turned off every-boot mode from the notification (startup task removed, Fast Startup restored). Run the installer again to turn it back on.'
 }
 default { Log "unrecognized action in notification URI: $Uri" }
}
