# Runs the REAL profile generation, firmware check, platform config, build and all host tests on the reference machine's saved
# capture (private; $env:GPU_UNLOCK_CAPTURES or ..\..\captures). Needs LLVM 20.1.8, Python 3.12+, MSVC build tools and the
# five firmware files in assets\. Touches only git-ignored build output and local config files inside the repo; the journal
# and work folder go to a temporary folder. Takes several minutes. Not part of the quick test run (Run-AllTests.ps1 -Integration).
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$repo = Split-Path -Parent $base
$capDir = if ($env:GPU_UNLOCK_CAPTURES) { $env:GPU_UNLOCK_CAPTURES } else { Join-Path (Split-Path -Parent $repo) 'captures' }
$run03 = Join-Path $capDir 'run03-restart-adapter-on-3060'; $run04 = Join-Path $capDir 'run04'
if (-not ((Test-Path "$run03\DIAG02.TXT") -and (Test-Path "$run04\PROM.BIN"))) { Write-Host 'skip: the private reference capture is not available'; exit 0 }

$t = New-TestRoot
try {
 Set-RepoRoot $repo
 $tools = @(Get-ToolStatus)
 ExpectTrue 'all build tools are present' (@($tools | Where-Object { -not $_.Ok }).Count -eq 0)
 $cap = Join-Path $t 'capture'; [void](New-Item -ItemType Directory $cap)
 Copy-Item "$run03\DIAG02.TXT" "$cap\DIAG.TXT"; Get-ChildItem $run03 -Filter 'IMG*.BIN' | Copy-Item -Destination $cap; Copy-Item "$run04\PROM.BIN" $cap

 $cards = Get-CardTable
 $t1 = $cards | Where-Object Id -eq '10de:2544'; $c1 = $cards | Where-Object Id -eq '10de:2f04'
 ExpectTrue 'the reference cards are installed' ($t1 -and $c1)
 $layout = Get-SysDiskLayout
 $u = @(Find-DedicatedPartitions $layout)[0]
 $state = [ordered]@{ Version = 1; Phase = 'profile'; CaptureDir = $cap
  Cards = [ordered]@{ Target = (ConvertTo-CardRecord $t1); Console = (ConvertTo-CardRecord $c1) }
  BootPartition = [ordered]@{ Kind = 'Existing'; Disk = $u.Disk; Number = $u.Number; Guid = $u.Guid; DriveLetter = $u.DriveLetter } }

 # profile
 $prof = New-Profile $state $tools $cap
 ExpectTrue 'profile generated from the capture' $prof.Ok
 $state.Profile = [ordered]@{ Dir = $prof.Dir; Summary = $prof.Summary }

 # firmware: the verified set already in the repo is recognised
 $assets = Find-ExistingAssets
 ExpectTrue 'the verified firmware set is found' ([bool]$assets)

 # platform config: identical to what the reference build already uses
 $hBefore = (Get-FileHash (Join-Path $repo 'internal-boot\boot\platform-config.h')).Hash
 [void](New-PlatformConfig $state)
 Expect 'platform-config.h is byte-identical to the existing one' (Get-FileHash (Join-Path $repo 'internal-boot\boot\platform-config.h')).Hash $hBefore

 # build
 $files = Build-BootPrograms $state $tools $prof.Dir
 $short = @{}; foreach ($f in $files) { $short[$f.Role] = $f.Sha256.Substring(0, 12) }
 Expect 'manual wrapper hash' $short['manual-wrapper'] '78aeb10ab783'
 Expect 'manual unlock hash' $short['manual-unlock'] '663383920a33'
 Expect 'automatic wrapper hash' $short['automatic-wrapper'] '111af4aa1236'
 Expect 'automatic unlock hash' $short['automatic-unlock'] 'c1e4103d493d'

 # host tests
 $outcome = Invoke-HostTests $state $tools $assets
 Show-HostTestResults $outcome
 foreach ($r in $outcome.Results) { ExpectTrue ("host test: " + $r.Name) $r.Passed }
} finally { Remove-TestRoot $t }
Complete-Tests
