# Installer state file and change journal (plan requirements 8 and 12).
# State: small JSON file, rewritten atomically. Journal: one JSON line per change, written BEFORE the change
# (status 'planned') and marked 'done' afterwards, so Roll back knows exactly what was made and what it replaced.
# Nothing here touches the PC outside the installer's own folder.

$script:InstallerRoot = $null

function Get-InstallerRoot {
 if ($script:InstallerRoot) { return $script:InstallerRoot }
 Join-Path $env:ProgramData 'WindowsGPUUnlock\installer'
}
function Set-InstallerRoot([string]$Path) { $script:InstallerRoot = $Path }   # tests only

# The state and the journal decide what Roll back deletes, and the scripts next to them run elevated or as SYSTEM, so the data folder
# (C:\ProgramData\WindowsGPUUnlock) must be a real folder that only the administrators and SYSTEM can change (internal-boot\SecureFolder.ps1).
# It is checked and fixed once per run, before anything is read from it. A dry run only reports a problem; it never changes permissions.
$script:ReadOnlyMode = $false
$script:DataRootChecked = $false
function Set-ReadOnlyMode([bool]$On) { $script:ReadOnlyMode = $On }
function Get-DataRoot { Split-Path -Parent (Get-InstallerRoot) }
function Confirm-DataRootProtected {
 if ($script:InstallerRoot) { return }       # tests use a temporary folder of their own
 if ($script:DataRootChecked) { return }
 $dataRoot = Get-DataRoot
 if ($script:ReadOnlyMode) {
  if (Test-Path -LiteralPath $dataRoot) {
   $p = @(Get-TreeSecurityProblems $dataRoot)
   if ($p.Count) { Write-Plain ('DRY RUN: the data folder is not safe yet and the real run will fix it: ' + (($p | Select-Object -First 2) -join '; ')) }
  }
  $script:DataRootChecked = $true
  return
 }
 Protect-DataFolder $dataRoot
 $script:DataRootChecked = $true
}
function Initialize-InstallerRoot {
 Confirm-DataRootProtected
 $r = Get-InstallerRoot
 if (-not (Test-Path -LiteralPath $r)) { [void](New-Item -ItemType Directory -Path $r -Force) }
 $r
}

function Get-StatePath { Join-Path (Get-InstallerRoot) 'state.json' }
function Get-JournalPath { Join-Path (Get-InstallerRoot) 'journal.jsonl' }

function ConvertTo-PlainObject($o) {
 # PowerShell 5.1 ConvertFrom-Json gives PSCustomObject; keep state as an ordered hashtable for easy updates.
 if ($null -eq $o) { return $null }
 if ($o -is [System.Management.Automation.PSCustomObject]) {
  $h = [ordered]@{}
  foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-PlainObject $p.Value }
  return $h
 }
 if ($o -is [System.Array]) { return @(, @($o | ForEach-Object { ConvertTo-PlainObject $_ })) }
 $o
}

function Read-InstallerState {
 Confirm-DataRootProtected
 $p = Get-StatePath
 if (-not (Test-Path -LiteralPath $p)) { return [ordered]@{ Version = 1; Phase = 'new' } }
 $s = ConvertTo-PlainObject (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
 if (-not $s.Contains('Version')) { throw 'The installer state file is not valid.' }
 $s
}
function Save-InstallerState($State) {
 [void](Initialize-InstallerRoot)
 $p = Get-StatePath
 $tmp = $p + '.tmp'
 ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding utf8
 Move-Item -LiteralPath $tmp -Destination $p -Force
}

# Journal -------------------------------------------------------------------
function Add-JournalEntry([string]$Phase, [string]$Action, [string]$Target, $Previous = $null, [string]$Undo = '') {
 [void](Initialize-InstallerRoot)
 $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
 $e = [ordered]@{ Id = $id; Time = (Get-Date).ToString('o'); Phase = $Phase; Action = $Action; Target = $Target; Previous = $Previous; Undo = $Undo; Status = 'planned' }
 ($e | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath (Get-JournalPath) -Encoding utf8
 $id
}
function Set-JournalStatus([string]$Id, [string]$Status) {
 # Append a status line instead of rewriting history; readers take the last line per Id.
 $e = [ordered]@{ Id = $Id; Time = (Get-Date).ToString('o'); StatusUpdate = $Status }
 ($e | ConvertTo-Json -Compress) | Add-Content -LiteralPath (Get-JournalPath) -Encoding utf8
}
function Read-Journal {
 Confirm-DataRootProtected
 $p = Get-JournalPath
 if (-not (Test-Path -LiteralPath $p)) { return @() }
 $byId = [ordered]@{}
 foreach ($line in (Get-Content -LiteralPath $p)) {
  if (-not $line.Trim()) { continue }
  $o = ConvertTo-PlainObject ($line | ConvertFrom-Json)
  if ($o.Contains('StatusUpdate')) { if ($byId.Contains($o.Id)) { $byId[$o.Id].Status = $o.StatusUpdate } }
  else { $byId[$o.Id] = $o }
 }
 @($byId.Values)
}

# Runs a change with the journal around it. -DryRun prints the line and changes nothing.
# The -Do block runs inside this function, so PowerShell's dynamic scoping would let this function's own variables hide the
# caller's variables of the same name. Every local here therefore has a jc_ prefix that callers never use.
function Invoke-JournaledChange {
 param([string]$Phase, [string]$Action, [string]$Target, $Previous = $null, [string]$Undo = '', [Parameter(Mandatory)][scriptblock]$Do, [switch]$DryRun)
 if ($DryRun) { Write-Host ("DRYRUN: {0} -> {1}" -f $Action, $Target); return $null }
 $jc_id = Add-JournalEntry -Phase $Phase -Action $Action -Target $Target -Previous $Previous -Undo $Undo
 try { & $Do; Set-JournalStatus $jc_id 'done' }
 catch { Set-JournalStatus $jc_id 'failed'; throw }
 $jc_id
}
