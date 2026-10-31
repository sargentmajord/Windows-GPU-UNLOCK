# One-time boot queue and restart prompt (plan requirements 10, 23, 24, 27).
# The unlock only ever uses the firmware's one-time boot queue (BootNext, "bootsequence"); the permanent boot order and the
# Windows boot entry are never changed, and no BIOS screen or boot menu is ever needed. System calls sit in Get-Sys* / Invoke-Sys*.

$script:UnlockLabel = 'GPUUNLOCK'
$script:FallbackPath = '\EFI\BOOT\BOOTX64.EFI'

function Get-SysFirmwareEntriesText { $ErrorActionPreference = 'Continue'; $o = & bcdedit.exe /enum firmware 2>&1; if ($LASTEXITCODE -ne 0) { throw "bcdedit /enum firmware failed: $($o | Out-String)" }; ($o | Out-String) }
function Get-SysFwBootMgrText { $ErrorActionPreference = 'Continue'; $o = & bcdedit.exe /enum '{fwbootmgr}' 2>&1; if ($LASTEXITCODE -ne 0) { throw "bcdedit /enum {fwbootmgr} failed" }; ($o | Out-String) }
function Get-SysVolumeLabel([string]$Letter) { $v = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue; if ($v) { [string]$v.FileSystemLabel } else { $null } }
function Invoke-SysQueueBoot([string]$EntryId) { $ErrorActionPreference = 'Continue'; $o = & bcdedit.exe /set '{fwbootmgr}' bootsequence $EntryId 2>&1; if ($LASTEXITCODE -ne 0) { throw "bcdedit could not queue the boot: $($o | Out-String)" } }
function Invoke-SysClearQueue { $ErrorActionPreference = 'Continue'; $o = & bcdedit.exe /deletevalue '{fwbootmgr}' bootsequence 2>&1; $LASTEXITCODE -eq 0 }
function Invoke-SysRestart([int]$Seconds, [string]$Reason) { $o = & shutdown.exe /r /t $Seconds /c $Reason; $LASTEXITCODE }

# Firmware entries that boot \EFI\BOOT\BOOTX64.EFI from the volume labelled GPUUNLOCK. Looked up every time, never stored.
function Find-UnlockEntries([string]$Label = $script:UnlockLabel) {
 $t = Get-SysFirmwareEntriesText
 $hits = @()
 foreach ($b in ($t -split '(?:\r?\n){2,}')) {
  $id = $null; $dev = $null
  if ($b -match '(?mi)^identifier\s+(\{[0-9a-f-]{36}\})') { $id = $Matches[1] }
  if ($b -match '(?mi)^device\s+partition=(\S+)') { $dev = $Matches[1] }
  if ($id -and $dev -and $b -match '(?mi)^path\s+\\EFI\\BOOT\\BOOTX64\.EFI\s*$') {
   if ($dev -match '^([A-Za-z]):$' -and (Get-SysVolumeLabel $Matches[1]) -ceq $Label) { $hits += $id }
  }
 }
 , @($hits)
}

function Test-QueuedBoot {
 (Get-SysFwBootMgrText) -match '(?mi)^bootsequence\s'
}

# Queues one boot of the unlock partition's entry. Returns the entry id, or $null with a plain message when it is not
# possible (no entry yet: the firmware makes it after seeing the file, which can take one restart).
function Queue-OneTimeBoot([switch]$DryRun) {
 $hits = Find-UnlockEntries
 if ($hits.Count -eq 0) { return $null }
 if ($hits.Count -gt 1) { throw "The firmware lists $($hits.Count) boot entries for the $($script:UnlockLabel) partition; expected exactly one." }
 $id = $hits[0]
 [void](Invoke-JournaledChange -Phase 'queue' -Action 'queue one-time boot' -Target $id -Previous ([ordered]@{ Queued = (Test-QueuedBoot) }) `
  -Undo 'delete the queued one-time boot' -DryRun:$DryRun -Do { Invoke-SysQueueBoot $id })
 $id
}

# Restart only after the user's explicit Y. Shows the countdown and how to cancel. Returns $true when a restart was started.
function Request-Restart([string]$Reason, [switch]$DryRun) {
 Write-Plain ''
 Write-Plain 'A restart is needed. Save and close your work first.'
 if (-not (Ask-YesNo 'Restart now?')) {
  Write-Plain 'Restart when you are ready, then run this same command again.'
  return $false
 }
 if ($DryRun) { Write-Plain 'DRY RUN: the PC would restart here (30 second countdown).'; return $false }
 $code = Invoke-SysRestart 30 $Reason
 if ($code -ne 0) { Write-Plain 'Windows could not start the restart. Restart by hand, then run this same command again.'; return $false }
 Write-Plain 'The PC restarts in 30 seconds. To cancel, open a command prompt and type:  shutdown /a'
 $true
}
