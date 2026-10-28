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
#
# $Do must reference only plain variable names (no $using: prefix) - $using: is valid only inside
# Invoke-Command, Start-Job or workflow InlineScript, never for a plain Start-Process to a new
# process, which cannot see this process's variables at all. Found 2026-10-28: every call site here
# used $using: anyway, so Repair and "No, turn it off" silently did nothing in every case - not just
# when not elevated, but even already elevated, since $using: is invalid either way. Values the
# scriptblock needs must be passed explicitly via -With; they are re-declared as literal, single-
# quoted assignments before the body runs in the new process. The already-elevated path runs $Do
# directly, where plain variable names resolve normally through ordinary lexical scoping.
function Invoke-Elevated([scriptblock]$Do, [hashtable]$With = @{}) {
 $id = [Security.Principal.WindowsIdentity]::GetCurrent()
 $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
 if ($isAdmin) { & $Do; return $true }
 $assigns = foreach ($k in $With.Keys) { "`$$k = '" + ([string]$With[$k] -replace "'", "''") + "'" }
 $full = ($assigns -join "`n") + "`n" + $Do.ToString()
 $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
 $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
 if ($p.ExitCode -ne 0) { throw "elevated action failed with exit code $($p.ExitCode)" }
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
  Invoke-Elevated { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue } -With @{ stateFile = $stateFile } | Out-Null
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
   if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
   try { & bcdedit.exe /deletevalue '{fwbootmgr}' bootsequence 2>&1 | Out-Null } catch {}
   $notifyTask = 'WindowsGPUUnlock-NotifyStuck'
   if (Get-ScheduledTask -TaskName $notifyTask -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $notifyTask -Confirm:$false }
   if (Test-Path -LiteralPath $stateFile) {
    $s = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if ($s.HiberbootBefore -and $s.HiberbootBefore.Exists) {
     Set-ItemProperty -LiteralPath $power -Name HiberbootEnabled -Value $s.HiberbootBefore.Value -Type DWord
    }
   }
  } -With @{ taskName = $taskName; stateFile = $stateFile; power = $power } | Out-Null
  Log 'no: turned off every-boot mode from the notification (startup task removed, Fast Startup restored). Run the installer again to turn it back on.'
 }
 default { Log "unrecognized action in notification URI: $Uri" }
}
