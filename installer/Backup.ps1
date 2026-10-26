# Backups taken before the installer changes anything (plan requirements 6 and 12). Local only, never published.
# Needs State.ps1. System calls sit in Invoke-Sys* so tests can replace them.

function Invoke-SysBcdExport([string]$Path) { $ErrorActionPreference = 'Continue'; $o = & bcdedit.exe /export $Path 2>&1; if ($LASTEXITCODE -ne 0) { throw "bcdedit /export failed: $($o | Out-String)" } }
function Get-SysBcdText([string[]]$BcdArgs) { $ErrorActionPreference = 'Continue'; $o = & bcdedit.exe @BcdArgs 2>&1; if ($LASTEXITCODE -ne 0) { throw "bcdedit $($BcdArgs -join ' ') failed" }; ($o | Out-String) }
function Get-SysPartitionTable { Get-Partition | Select-Object DiskNumber, PartitionNumber, DriveLetter, GptType, Offset, Size, IsSystem, IsBoot }

# Writes the backup folder and returns its path. -DryRun only names it.
function Backup-SystemState([string]$Stamp = (Get-Date -Format 'yyyyMMdd-HHmmss'), [switch]$DryRun) {
 $dir = Join-Path (Get-InstallerRoot) "Backups\install-$Stamp"
 if ($DryRun) { Write-Host "DRYRUN: back up the boot configuration, firmware boot entries, partition table and Fast Startup value to $dir"; return $dir }
 [void](Invoke-JournaledChange -Phase 'backup' -Action 'create backup folder' -Target $dir -Undo 'keep (backups are never deleted by Roll back)' -Do {
  [void](New-Item -ItemType Directory -Path $dir -Force)
  Invoke-SysBcdExport (Join-Path $dir 'bcd-store')
  (Get-SysBcdText @('/enum', 'firmware')) | Set-Content -LiteralPath (Join-Path $dir 'firmware-entries.txt') -Encoding utf8
  (Get-SysBcdText @('/enum', '{fwbootmgr}')) | Set-Content -LiteralPath (Join-Path $dir 'fwbootmgr.txt') -Encoding utf8
  (Get-SysPartitionTable | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath (Join-Path $dir 'partition-table.json') -Encoding utf8
  [ordered]@{ HiberbootEnabled = (Get-SysFastStartup); Saved = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'fast-startup.json') -Encoding utf8
 })
 $dir
}

# Re-reads the live state and compares it with a backup. Used by Roll back's closing checklist.
function Compare-WithBackup([string]$Dir) {
 $r = [ordered]@{}
 $saved = Get-Content -LiteralPath (Join-Path $Dir 'fast-startup.json') -Raw | ConvertFrom-Json
 $r.FastStartup = ($saved.HiberbootEnabled -eq (Get-SysFastStartup))
 $now = Get-SysBcdText @('/enum', '{fwbootmgr}')
 $then = Get-Content -LiteralPath (Join-Path $Dir 'fwbootmgr.txt') -Raw
 $order = { param($t) ([regex]::Match($t, '(?ms)^displayorder\s+(.*?)(?=^\S|\z)').Groups[1].Value -replace '\s+', ' ').Trim() }
 $r.DisplayOrder = ((& $order $now) -ceq (& $order $then))
 [pscustomobject]$r
}
