# Capture phase and profile generation (plan requirements 2, 4, 8, 15, 23; checks K01-K09).
# Builds the READ-ONLY diagnostic for the chosen card, puts it on the boot partition, queues one boot of it, collects what it
# logged, and turns the log into this PC's profile with tools/profile_gen.py. The diagnostic cannot unlock, detach or write
# to the card (its build manifest says so). Needs State.ps1, Ui.ps1, Tools.ps1, BootEntry.ps1.

$script:RepoRoot = $null
function Set-RepoRoot([string]$Path) { $script:RepoRoot = $Path }
function Get-RepoRoot { if ($script:RepoRoot) { $script:RepoRoot } else { Split-Path -Parent $PSScriptRoot } }
function Get-WorkRoot { Join-Path (Get-InstallerRoot) 'work' }

# --- system calls (replaceable in tests) ---
function Get-SysBoard {
 $b = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue; $f = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
 [pscustomobject]@{ Board = [string]$b.Product; Bios = [string]$f.SMBIOSBIOSVersion }
}
function Invoke-SysPowerShellFile([string]$File, [string[]]$FileArgs) { $ErrorActionPreference = 'Continue'; $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $File @FileArgs 2>&1; [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($o | Out-String) } }
function Invoke-SysPython([string]$Python, [string[]]$PyArgs) { $ErrorActionPreference = 'Continue'; $o = & $Python -X utf8 -I @PyArgs 2>&1; [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($o | Out-String) } }
function Get-SysFileHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower() }

function Get-BootRoot($State) {
 $l = [string]$State.BootPartition.DriveLetter
 if (-not $l) { throw 'The boot partition has no drive letter yet.' }
 "$($l.TrimEnd(':')):\"
}

# Copies one file onto the boot partition. A file that is already there with other content is first copied to the backup folder
# (so Roll back can restore it); an identical file is left alone. Every change is journaled before it happens.
function Copy-ToBootPartition($State, [string]$Source, [string]$RelativeDest, [string]$BackupFolder, [switch]$DryRun) {
 $dest = Join-Path (Get-BootRoot $State) $RelativeDest
 $hash = Get-SysFileHash $Source
 $existed = Test-Path -LiteralPath $dest -PathType Leaf
 $prevHash = if ($existed) { Get-SysFileHash $dest } else { $null }
 if ($existed -and $prevHash -eq $hash) { return [pscustomobject]@{ Dest = $dest; Sha256 = $hash; Changed = $false } }
 $backup = $null
 # the name carries the replaced file's hash, so replacing the same file twice keeps BOTH earlier versions (Roll back needs the first one)
 if ($existed) { $backup = Join-Path $BackupFolder ('staged\' + ($RelativeDest -replace '[\\/:]', '_') + '.' + $prevHash.Substring(0, 12)) }
 [void](Invoke-JournaledChange -Phase 'stage' -Action 'copy file to boot partition' -Target $dest `
  -Previous ([ordered]@{ Existed = $existed; Sha256 = $prevHash; Backup = $backup; WrittenSha256 = $hash }) -Undo ('delete it if its hash is still ' + $hash + ($(if ($existed) { ' and put the previous file back' } else { '' }))) -DryRun:$DryRun -Do {
   if ($existed) { [void](New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force); Copy-Item -LiteralPath $dest -Destination $backup -Force }
   [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force)
   Copy-Item -LiteralPath $Source -Destination $dest -Force
   if ((Get-SysFileHash $dest) -ne $hash) { throw "The copy of $RelativeDest on the boot partition does not match the source." }
  })
 [pscustomobject]@{ Dest = $dest; Sha256 = $hash; Changed = $true }
}

function New-BootFolder($State, [string]$Relative, [switch]$DryRun) {
 $p = Join-Path (Get-BootRoot $State) $Relative
 if (Test-Path -LiteralPath $p) { return }
 [void](Invoke-JournaledChange -Phase 'stage' -Action 'create folder on boot partition' -Target $p -Undo 'remove it if empty' -DryRun:$DryRun -Do { [void](New-Item -ItemType Directory -Path $p -Force) })
}

# --- diagnostic build ---
function Get-DiscoveryProfileDir($State) { Join-Path (Get-WorkRoot) 'discovery' }

function Build-Diagnostic($State, $Tools, [switch]$DryRun) {
 $dir = Get-DiscoveryProfileDir $State
 if ($DryRun) { Write-Plain "DRYRUN: build the read-only diagnostic for card $($State.Cards.Target.Id) in $dir"; return [pscustomobject]@{ Path = $null; Sha256 = $null } }
 [void](New-Item -ItemType Directory -Path $dir -Force)
 $env2 = Get-BuildEnvironment $Tools $dir
 $gen = Invoke-SysPython $env2.Python @((Join-Path (Get-RepoRoot) 'tools\profile_gen.py'), '--discovery', '--target-id', $State.Cards.Target.Id, '--out', (Join-Path $dir 'profile.h'))
 if ($gen.Code -ne 0) { throw ('Could not write the discovery profile: ' + $gen.Output) }
 $r = $null
 Invoke-WithBuildEnvironment $env2 { $script:__r = Invoke-SysPowerShellFile (Join-Path (Get-RepoRoot) 'internal-boot\boot\build-diagnostic.ps1') @('-Clang', $env2.Clang, '-LldLink', $env2.LldLink, '-Python', $env2.Python) }
 $r = $script:__r
 if ($r.Code -ne 0) { throw ('The diagnostic did not build: ' + $r.Output) }
 $efi = Join-Path (Get-RepoRoot) 'internal-boot\boot\build\diagnostic\DIAGNOSTIC.EFI'
 $man = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'internal-boot\boot\build\diagnostic\manifest.json') -Raw | ConvertFrom-Json
 if ($man.CanUnlock -or $man.CanDetach -or $man.WritesFirmwareVariables) { throw 'The diagnostic build says it can change things; refusing to use it.' }
 [pscustomobject]@{ Path = $efi; Sha256 = (Get-SysFileHash $efi) }
}

function Stage-Diagnostic($State, $Built, [switch]$DryRun) {
 $backup = $State.BackupFolder
 New-BootFolder $State 'RTX3060-UNLOCK' -DryRun:$DryRun
 New-BootFolder $State 'EFI\WindowsGPUUnlock' -DryRun:$DryRun
 if ($DryRun) { Write-Plain 'DRYRUN: copy the diagnostic to EFI\BOOT\BOOTX64.EFI and EFI\WindowsGPUUnlock\DIAGNOSTIC.EFI on the boot partition'; return }
 [void](Copy-ToBootPartition $State $Built.Path 'EFI\WindowsGPUUnlock\DIAGNOSTIC.EFI' $backup)
 [void](Copy-ToBootPartition $State $Built.Path 'EFI\BOOT\BOOTX64.EFI' $backup)
}

# Old outputs of an earlier diagnostic run would be mistaken for new ones; this clears only the files the diagnostic itself writes.
function Clear-OldCaptureOutput($State, [switch]$DryRun) {
 $dir = Join-Path (Get-BootRoot $State) 'RTX3060-UNLOCK'
 if (-not (Test-Path -LiteralPath $dir)) { return }
 $old = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -match '^(IMG\d+\.BIN|PROM\.BIN)$' })
 if ($DryRun) { if ($old.Count) { Write-Plain "DRYRUN: remove $($old.Count) old capture output file(s) the diagnostic wrote earlier" }; return }
 foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force }
}

# --- collecting the capture ---
function Get-DiagFileNames($State) {
 $dir = Join-Path (Get-BootRoot $State) 'RTX3060-UNLOCK'
 if (-not (Test-Path -LiteralPath $dir)) { return @() }
 @(Get-ChildItem -LiteralPath $dir -File -Filter 'DIAG*.TXT' | ForEach-Object { $_.Name })
}

# The log of the diagnostic run that happened after it was queued: the DIAGnn.TXT that was not there before (file times on the boot
# partition come from the firmware's clock and can be hours off, so time is only the fallback when no earlier list exists).
function Get-LatestCapture($State, $Before, [datetime]$Since) {
 $dir = Join-Path (Get-BootRoot $State) 'RTX3060-UNLOCK'
 if (-not (Test-Path -LiteralPath $dir)) { return $null }
 $all = @(Get-ChildItem -LiteralPath $dir -File -Filter 'DIAG*.TXT')
 $log = if ($null -ne $Before) { $known = @($Before); $all | Where-Object { $known -cnotcontains $_.Name } | Sort-Object Name | Select-Object -Last 1 }
  else { $all | Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime | Select-Object -Last 1 }
 if ($log) { [pscustomobject]@{ Log = $log.FullName; Dir = $dir } } else { $null }
}

function Copy-CaptureLocal($Found, [string]$Stamp) {
 $dest = Join-Path (Get-WorkRoot) ("capture-$Stamp-" + [guid]::NewGuid().ToString('N').Substring(0, 4))   # never reuse a folder, so a new capture cannot mix with an old one
 [void](New-Item -ItemType Directory -Path $dest -Force)
 Copy-Item -LiteralPath $Found.Log -Destination (Join-Path $dest 'DIAG.TXT')
 # PROM.BIN is the card's own video BIOS image: it stays in this local work folder for the host tests and is never published or reported
 foreach ($f in @(Get-ChildItem -LiteralPath $Found.Dir -File | Where-Object { $_.Name -match '^(IMG\d+|PROM)\.BIN$' })) { Copy-Item -LiteralPath $f.FullName -Destination $dest }
 $dest
}

# --- profile generation ---
function New-Profile($State, $Tools, [string]$CaptureDir, [switch]$DryRun) {
 $outDir = Join-Path (Get-WorkRoot) 'profile'
 $t = $State.Cards.Target; $c = $State.Cards.Console
 $busNum = { param($b) [int]($b -split '[:.]')[0] }
 $board = Get-SysBoard
 $name = ('{0}-{1}-{2}' -f $board.Board, $board.Bios, ($t.Name -replace '^NVIDIA GeForce ', '')) -replace '[^A-Za-z0-9._-]+', '-'
 if ($DryRun) { Write-Plain "DRYRUN: generate the profile for bus $($t.Bus) from $CaptureDir"; return [pscustomobject]@{ Ok = $true; Dir = $outDir; Summary = $null; Findings = @() } }
 [void](New-Item -ItemType Directory -Path $outDir -Force)
 $a = @((Join-Path (Get-RepoRoot) 'tools\profile_gen.py'), '--capture', (Join-Path $CaptureDir 'DIAG.TXT'), '--images', $CaptureDir,
  '--target-bus', (& $busNum $t.Bus), '--target-id', $t.Id, '--target-subsystem', $t.Subsystem, '--target-name', $t.Name,
  '--console-bus', (& $busNum $c.Bus), '--console-id', $c.Id, '--console-subsystem', $c.Subsystem, '--console-name', $c.Name,
  '--profile-name', $name, '--out', (Join-Path $outDir 'profile.h'), '--summary', (Join-Path $outDir 'summary.json'))
 if ($t.VramMiB) { $a += @('--target-vram-mib', [string]$t.VramMiB) }
 $py = ($Tools | Where-Object Id -eq 'python').Info.Path
 if (Test-Path -LiteralPath (Join-Path $outDir 'profile.h')) { Remove-Item -LiteralPath (Join-Path $outDir 'profile.h') -Force }
 $r = Invoke-SysPython $py $a
 $json = $null
 try { $json = $r.Output | ConvertFrom-Json } catch { }
 if ($r.Code -eq 0 -and $json -and $json.ok) { return [pscustomobject]@{ Ok = $true; Dir = $outDir; Summary = $json.summary; Findings = @() } }
 if ($r.Code -eq 2 -and $json) { return [pscustomobject]@{ Ok = $false; Dir = $outDir; Summary = $null; Findings = @($json.findings) } }
 throw ('The profile generator failed: ' + $r.Output)
}

function Show-ProfileSummary($Summary) {
 Write-Plain ''
 Write-Plain 'What the capture shows about your PC:'
 Write-Plain ('  Card to unlock: {0}, subsystem {1}, on PCI bus {2}' -f $Summary.target.id, $Summary.target.subsystem, $Summary.target.bus)
 Write-Plain ('  The firmware created a display output for it: {0}' -f $(if ($Summary.target.display_output_found) { 'yes' } else { 'no' }))
 Write-Plain ('  Screen adapter: {0}, on PCI bus {1} (it is never touched)' -f $Summary.screen_adapter.id, $Summary.screen_adapter.bus)
 Write-Plain ('  Both cards use the same two firmware console drivers: {0}' -f $(if ($Summary.console_drivers.shared_by_both_cards) { 'yes' } else { 'no' }))
 Write-Plain ('  The card''s own firmware driver: {0}' -f $Summary.card_gop_driver.name)
 Write-Plain '  The card is in its untouched startup state.'
}

function Show-Refusal($Findings) {
 Write-Plain ''
 Write-Plain 'The installer cannot make a safe profile for this PC:'
 foreach ($f in $Findings) {
  Write-Plain ('  - ' + $f.message)
  if ($f.fix) { Write-Plain ('    What to do: ' + $f.fix) }
 }
 Write-Plain 'There is no way to skip this. Nothing on your PC was changed beyond the steps already shown.'
}
