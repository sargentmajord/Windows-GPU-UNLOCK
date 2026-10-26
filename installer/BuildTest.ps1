# Building the boot programs for this PC and testing them against its own capture (plan: "builds a version for that PC and tests
# it against its own capture before anything else happens"). No hardware access: the tests replay the capture in host memory.
# Needs State.ps1, Ui.ps1, Tools.ps1, Capture.ps1 (Invoke-SysPython, Get-WorkRoot, Get-RepoRoot, Get-SysFileHash), BootPartition.ps1,
# Firmware.ps1.

# --- system calls (replaceable in tests) ---
function Invoke-SysScriptProcess([string]$CommandText) {
 $ErrorActionPreference = 'Continue'   # a tool's stderr text must not become a terminating error
 $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $CommandText 2>&1
 [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($o | Out-String) }
}

function ConvertTo-PsLiteral($Value) {
 if ($Value -is [System.Array]) { return '@(' + (($Value | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ',') + ')' }
 if ($Value -is [bool] -or $Value -is [System.Management.Automation.SwitchParameter]) { return $(if ($Value) { '$true' } else { '$false' }) }
 "'" + ([string]$Value).Replace("'", "''") + "'"
}
function New-ScriptCall([string]$File, $Params) {
 $parts = @("& " + (ConvertTo-PsLiteral $File))
 foreach ($k in $Params.Keys) {
  $v = $Params[$k]
  if ($v -is [System.Management.Automation.SwitchParameter] -or $v -is [bool]) { if ($v) { $parts += "-$k" } }
  else { $parts += "-$k " + (ConvertTo-PsLiteral $v) }
 }
 ($parts -join ' ') + '; if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { exit $LASTEXITCODE }'
}

# --- platform config: the partition identities the boot programs pin ---
function ConvertTo-GuidInitializer([guid]$Value) {
 $b = $Value.ToByteArray(); $tail = ($b[8..15] | ForEach-Object { '0x{0:x2}' -f $_ }) -join ','
 '{{0x{0:x8},0x{1:x4},0x{2:x4},{{{3}}}}}' -f [BitConverter]::ToUInt32($b, 0), [BitConverter]::ToUInt16($b, 4), [BitConverter]::ToUInt16($b, 6), $tail
}

function Get-PlatformConfigText([guid]$UnlockGuid, [guid]$WindowsEspGuid) {
 "/* Local partition configuration; never distribute this file. */`r`n#define GU_INTERNAL_PARTITION_INITIALIZER $(ConvertTo-GuidInitializer $UnlockGuid)`r`n#define GU_WINDOWS_PARTITION_INITIALIZER $(ConvertTo-GuidInitializer $WindowsEspGuid)`r`n"
}

# Writes boot\platform-config.h and local-config.json (both git-ignored local files).
function New-PlatformConfig($State, [switch]$DryRun) {
 $layout = Get-SysDiskLayout
 $esp = @($layout.Partitions | Where-Object IsWindowsEsp)
 if ($esp.Count -ne 1) { throw 'Could not identify the Windows system partition (expected exactly one).' }
 $unlock = [string]$State.BootPartition.Guid
 if (-not $unlock) { throw 'The boot partition has no identity recorded.' }
 $text = Get-PlatformConfigText ([guid]$unlock) ([guid]$esp[0].Guid)
 if ($DryRun) { Write-Plain 'DRYRUN: write the local partition configuration (platform-config.h, local-config.json)'; return $null }
 $repo = Get-RepoRoot
 $h = Join-Path $repo 'internal-boot\boot\platform-config.h'
 [void](Invoke-JournaledChange -Phase 'build' -Action 'write local partition configuration' -Target $h -Undo 'delete it (it is a local generated file)' -Do {
  [IO.File]::WriteAllText($h, $text, [Text.Encoding]::ASCII)
  $cfg = [ordered]@{ UnlockDriveLetter = [string]$State.BootPartition.DriveLetter; UnlockPartitionGuid = $unlock; WindowsPartitionGuid = [string]$esp[0].Guid
   GeneratedHeaderSha256 = (Get-SysFileHash $h).ToUpper(); ConfiguredUtc = [DateTime]::UtcNow.ToString('o') }
  $cfg | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'internal-boot\local-config.json') -Encoding utf8
 })
 (Get-SysFileHash $h)
}

# --- building ---
function Get-BuiltFileList {
 $r = Get-RepoRoot
 $u = Join-Path $r 'internal-boot\unlock\build\experimental\entryLatchedSs1Full\internal'
 $b = Join-Path $r 'internal-boot\boot\build'
 @(
  [pscustomobject]@{ Role = 'manual-wrapper'; Path = (Join-Path $b 'full\FULL.EFI') }
  [pscustomobject]@{ Role = 'manual-unlock'; Path = (Join-Path $u 'RTX3060-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL.EFI') }
  [pscustomobject]@{ Role = 'automatic-wrapper'; Path = (Join-Path $b 'automatic\AUTO.EFI') }
  [pscustomobject]@{ Role = 'automatic-unlock'; Path = (Join-Path $u 'automatic\RTX3060-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL-AUTO.EFI') }
 )
}

# Builds the manual and automatic boot programs against the generated profile (CPATH). Returns the list with hashes.
function Build-BootPrograms($State, $Tools, [string]$ProfileDir, [switch]$DryRun) {
 if ($DryRun) { Write-Plain "DRYRUN: build the boot programs with the profile made from your capture"; return @() }
 foreach ($f in (Get-BuiltFileList)) { if (Test-Path -LiteralPath $f.Path) { Remove-Item -LiteralPath $f.Path -Force } }   # never keep a stale image
 $be = Get-BuildEnvironment $Tools $ProfileDir
 $call = New-ScriptCall (Join-Path (Get-RepoRoot) 'internal-boot\Build.ps1') ([ordered]@{ Clang = $be.Clang; LldLink = $be.LldLink; Python = $be.Python })
 $res = $null
 Invoke-WithBuildEnvironment $be { $script:__res = Invoke-SysScriptProcess $call }
 $res = $script:__res
 if ($res.Code -ne 0) { throw ('The boot programs did not build: ' + $res.Output) }
 $files = @(Get-BuiltFileList)
 foreach ($f in $files) {
  if (-not (Test-Path -LiteralPath $f.Path)) { throw ("The build finished but $($f.Role) is missing.") }
  $f | Add-Member -NotePropertyName Sha256 -NotePropertyValue (Get-SysFileHash $f.Path) -Force
 }
 $files
}

# --- host tests ---
function Get-FixtureArgs($Summary) {
 $f = $Summary.fixture
 @('--rtx-id', $f.rtx_id, '--other-id', $f.other_id, '--rtx-path-node', $f.rtx_path_node, '--other-path-node', $f.other_path_node)
}

# The ordered list of host tests with their parameters. Inputs come from this PC's own capture folder.
function Get-HostTestPlan($State, $Tools, [string]$AssetsDir) {
 $repo = Get-RepoRoot; $cap = $State.CaptureDir; $be = Get-BuildEnvironment $Tools $State.Profile.Dir
 $report = Join-Path $cap 'REPORT.TXT'; $prom = Join-Path $cap 'PROM.BIN'; $diag = Join-Path $cap 'DIAG.TXT'
 $nv = Join-Path $cap $State.Profile.Summary.fixture.nvgop_image
 $boot = Join-Path $repo 'internal-boot\boot'; $unlock = Join-Path $repo 'internal-boot\unlock'
 $fx = @(Get-FixtureArgs $State.Profile.Summary)
 $common = [ordered]@{ Clang = $be.Clang; VcVars = $be.VcVars }
 @(
  [pscustomobject]@{ Name = 'boot programs: flow, media and image checks'; File = (Join-Path $boot 'test.ps1'); Params = $common }
  [pscustomobject]@{ Name = 'read-only diagnostic'; File = (Join-Path $boot 'test-diagnostic.ps1'); Params = $common }
  [pscustomobject]@{ Name = 'console release, replayed on your capture'; File = (Join-Path $boot 'test-console.ps1'); Params = ([ordered]@{ Clang = $be.Clang; VcVars = $be.VcVars; Capture = $diag; FixtureArgs = $fx }) }
  [pscustomobject]@{ Name = 'full driver release, replayed on your capture and your card''s driver'; File = (Join-Path $boot 'test-full.ps1'); Params = ([ordered]@{ Clang = $be.Clang; VcVars = $be.VcVars; DiagnosticCapture = $diag; PciCapture = $report; NvPe = $nv; Prom = $prom; FixtureArgs = $fx }) }
  [pscustomobject]@{ Name = 'unlock program, checks and transaction, on your card''s data'; File = (Join-Path $unlock 'test-all.ps1'); Params = ([ordered]@{ Clang = $be.Clang; VcVars = $be.VcVars; WithLocalFixtures = $true; Capture = $report; Prom = $prom; ColdCapture = $report; Assets = $AssetsDir; ExperimentalUnlock = $true; InternalBoot = $true; StockProfile = 'entryLatchedSs1Full' }) }
  [pscustomobject]@{ Name = 'automatic mode'; File = (Join-Path $unlock 'test-automatic.ps1'); Params = ([ordered]@{ Clang = $be.Clang; VcVars = $be.VcVars; Prom = $prom; ColdCapture = $report; Assets = $AssetsDir }) }
  [pscustomobject]@{ Name = 'manual mode'; File = (Join-Path $unlock 'test-automatic.ps1'); Params = ([ordered]@{ Clang = $be.Clang; VcVars = $be.VcVars; Prom = $prom; ColdCapture = $report; Assets = $AssetsDir; ManualRegression = $true }) }
 )
}

function Convert-CaptureToReport($Tools, [string]$CaptureDir) {
 $py = ($Tools | Where-Object Id -eq 'python').Info.Path
 $r = Invoke-SysPython $py @((Join-Path (Get-RepoRoot) 'tools\make_capture_report.py'), (Join-Path $CaptureDir 'DIAG.TXT'), (Join-Path $CaptureDir 'REPORT.TXT'))
 if ($r.Code -ne 0) { throw ('Could not turn the capture into the report the tests read: ' + $r.Output) }
}

# Runs every host test. Returns @{ Ok; Results = @(@{Name; Passed; Detail}) }. Every test must pass; there is no skipping.
function Invoke-HostTests($State, $Tools, [string]$AssetsDir, [switch]$DryRun) {
 if ($DryRun) { Write-Plain 'DRYRUN: run the host tests (no hardware access) on your capture'; return [pscustomobject]@{ Ok = $true; Results = @() } }
 Convert-CaptureToReport $Tools $State.CaptureDir
 $logs = Join-Path (Get-WorkRoot) 'tests'
 [void](New-Item -ItemType Directory -Path $logs -Force)
 $be = Get-BuildEnvironment $Tools $State.Profile.Dir
 $results = @()
 foreach ($t in (Get-HostTestPlan $State $Tools $AssetsDir)) {
  $call = New-ScriptCall $t.File $t.Params
  Invoke-WithBuildEnvironment $be { $script:__res = Invoke-SysScriptProcess $call }
  $r = $script:__res
  $log = Join-Path $logs (($t.Name -replace '[^A-Za-z0-9]+', '-').Trim('-') + '.log')
  $r.Output | Set-Content -LiteralPath $log -Encoding utf8
  $last = @($r.Output -split "`r?`n" | Where-Object { $_.Trim() })
  $detail = if ($last.Count) { $last[-1].Trim() } else { '' }
  $results += [pscustomobject]@{ Name = $t.Name; Passed = ($r.Code -eq 0); Detail = $detail; Log = $log }
 }
 [pscustomobject]@{ Ok = (@($results | Where-Object { -not $_.Passed }).Count -eq 0); Results = $results }
}

function Show-HostTestResults($Outcome) {
 Write-Plain ''
 Write-Plain 'Host tests on your own capture (no hardware is touched):'
 foreach ($r in $Outcome.Results) { Write-Plain ('  [{0}] {1}' -f $(if ($r.Passed) { 'pass' } else { 'FAIL' }), $r.Name); if (-not $r.Passed) { Write-Plain ('         ' + $r.Detail) } }
}
