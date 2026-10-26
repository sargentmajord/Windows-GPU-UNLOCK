# Firmware generation, platform config, boot program build and host test runner, with every system call mocked.
# (The real build and real host tests on the reference machine's capture are in Integration-RealPipeline.ps1.)
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$realRepo = Split-Path -Parent $base

# ---------------- vendored scripts (real files) ----------------
Set-RepoRoot $realRepo
Expect 'the vendored firmware scripts match their pinned hashes' (@(Test-VendoredScripts)).Count 0
Expect 'assets.json lists the five files' (@(Get-ExpectedAssets)).Count 5

# ---------------- a small fake repo for the rest ----------------
function New-FakeRepo([string]$Root) {
 foreach ($d in 'internal-boot\unlock', 'firmware-tools', 'tools', 'internal-boot\boot\build\full', 'internal-boot\boot\build\automatic') { [void](New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force) }
 $u = Join-Path $Root 'internal-boot\unlock\build\experimental\entryLatchedSs1Full\internal'; [void](New-Item -ItemType Directory -Path "$u\automatic" -Force)
 $files = [ordered]@{ 'a.bin' = 'AAAA'; 'b.bin' = 'BBBBBB' }
 $list = foreach ($k in $files.Keys) { $p = Join-Path $Root "tmp-$k"; Set-Content -LiteralPath $p -Value $files[$k] -NoNewline -Encoding ascii; [ordered]@{ Name = $k; Bytes = (Get-Item $p).Length; Sha256 = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower() }; Remove-Item $p }
 (@($list) | ConvertTo-Json) | Set-Content (Join-Path $Root 'internal-boot\unlock\assets.json') -Encoding utf8
 foreach ($k in $script:VendoredScripts.Keys) { Set-Content (Join-Path $Root "firmware-tools\$k") 'x' -Encoding ascii }
}

$t = New-TestRoot
try {
 $fake = Join-Path $t 'repo'; New-FakeRepo $fake; Set-RepoRoot $fake
 ExpectTrue 'changed vendored scripts are noticed' ((@(Test-VendoredScripts)).Count -eq 4)

 # ---- Test-AssetsFolder / Find-ExistingAssets ----
 $a1 = Join-Path $t 'assets1'; [void](New-Item -ItemType Directory $a1)
 $r = Test-AssetsFolder $a1
 ExpectTrue 'empty folder: both missing' (-not $r.Ok -and $r.Missing.Count -eq 2)
 Set-Content (Join-Path $a1 'a.bin') 'AAAA' -NoNewline -Encoding ascii; Set-Content (Join-Path $a1 'b.bin') 'WRONG!' -NoNewline -Encoding ascii
 $r = Test-AssetsFolder $a1
 ExpectTrue 'a different file is reported as wrong' ($r.Wrong -contains 'b.bin' -and $r.Missing.Count -eq 0)
 Set-Content (Join-Path $a1 'b.bin') 'BBBBBB' -NoNewline -Encoding ascii
 ExpectTrue 'right files pass' (Test-AssetsFolder $a1).Ok
 Set-Content (Join-Path $a1 'b.bin') 'BBBBBb' -NoNewline -Encoding ascii
 ExpectTrue 'one changed byte is noticed' (-not (Test-AssetsFolder $a1).Ok)
 Set-Content (Join-Path $a1 'b.bin') 'BBBBBB' -NoNewline -Encoding ascii
 ExpectTrue 'no existing assets yet' ($null -eq (Find-ExistingAssets))
 Copy-Item $a1 (Join-Path $fake 'assets') -Recurse
 Expect 'the repo assets folder is found' (Find-ExistingAssets) (Join-Path $fake 'assets')
 Set-Answers @()
 Expect 'verified existing assets need no question and no download' (Resolve-Assets @{} @() ) (Join-Path $fake 'assets')
 Remove-Item (Join-Path $fake 'assets') -Recurse -Force

 # ---- Resolve-Assets with mocked downloads and generators ----
 Set-Content (Join-Path $fake 'zstdfile.zip') 'ZIPDATA' -Encoding ascii
 $script:ZstdSha256 = (Get-FileHash (Join-Path $fake 'zstdfile.zip') -Algorithm SHA256).Hash.ToLower()
 $script:Calls = New-Object System.Collections.ArrayList; $script:GenPath = $null; $script:Corrupt = $false; $script:Free = 100GB
 $script:VendoredScripts = [ordered]@{}   # the fake repo has placeholder scripts
 function Invoke-SysDownload([string]$Url, [string]$OutFile) { [void]$script:Calls.Add("download $Url"); Copy-Item (Join-Path $fake 'zstdfile.zip') $OutFile }
 function Invoke-SysExpandZip([string]$Zip, [string]$Dest) { [void]$script:Calls.Add('unzip'); [void](New-Item -ItemType Directory -Path "$Dest\zstd-v1.5.7-win64" -Force); Set-Content "$Dest\zstd-v1.5.7-win64\zstd.exe" 'EXE' }
 function Get-SysFreeBytes([string]$Path) { $script:Free }
 function Invoke-SysPython([string]$Python, [string[]]$PyArgs) {
  $first = [IO.Path]::GetFileName($PyArgs[0])
  [void]$script:Calls.Add("python $first")
  switch ($first) {
   'fetch_artifacts.py' { [void](New-Item -ItemType Directory -Path $PyArgs[1] -Force); Set-Content (Join-Path $PyArgs[1] 'nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst') 'PKG'; Set-Content (Join-Path $PyArgs[1] 'NVIDIA-kernel-module-source-610.43.03.tar.xz') 'SRC' }
   'generate_v67.py' { $script:GenPath = $env:PATH; Set-Content (Join-Path $PyArgs[2] 'a.bin') 'AAAA' -NoNewline -Encoding ascii }
   '-c' { [void](New-Item -ItemType Directory -Path $PyArgs[3] -Force) }
   'extract_boot_assets.py' { Set-Content (Join-Path $PyArgs[2] 'b.bin') $(if ($script:Corrupt) { 'CORRUPT' } else { 'BBBBBB' }) -NoNewline -Encoding ascii }
  }
  [pscustomobject]@{ Code = 0; Output = '' }
 }
 $tools = @([pscustomobject]@{ Id = 'python'; Info = [pscustomobject]@{ Path = 'C:\Py\python.exe' } })
 Set-Answers @('N')
 ExpectTrue 'declining downloads nothing' ($null -eq (Resolve-Assets @{} $tools))
 Expect 'declined: no network call' $script:Calls.Count 0
 $text = OutText
 ExpectTrue 'the offer names every host and the total' (($text -like '*download.nvidia.com*') -and ($text -like '*archive.cachyos.org*') -and ($text -like '*github.com*') -and ($text -like '*343 MB*'))
 ExpectTrue 'the offer says nothing is installed and the files must not be shared' (($text -like '*nothing is installed*') -and ($text -like '*must not be shared*'))
 Set-Answers @('Y')
 $dir = Resolve-Assets @{} $tools
 Expect 'accepted: the assets folder is returned' $dir (Join-Path (Get-WorkRoot) 'assets')
 ExpectTrue 'the set is verified' (Test-AssetsFolder $dir).Ok
 Expect 'steps ran in order' ($script:Calls -join '|') 'download https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-v1.5.7-win64.zip|unzip|python fetch_artifacts.py|python generate_v67.py|python -c|python extract_boot_assets.py'
 ExpectTrue 'zstd was on PATH for the generator only' (($script:GenPath -like '*zstd-v1.5.7-win64*') -and ($env:PATH -notlike '*zstd-v1.5.7-win64*'))
 ExpectTrue 'the large inputs were removed afterwards' (-not (Test-Path (Join-Path (Get-WorkRoot) 'firmware\inputs')))
 Expect 'journaled and done' (@(Read-Journal) | Where-Object Action -like 'generate NVIDIA*').Status 'done'
 # a corrupt result leaves nothing behind
 Remove-Item (Get-WorkRoot) -Recurse -Force
 $script:Corrupt = $true; Set-Answers @('Y')
 ExpectThrows 'wrong generated files are refused' { Resolve-Assets @{} $tools } '*do not match the expected hashes*b.bin*'
 ExpectTrue 'and no half-made folder is kept' (-not (Test-Path (Join-Path (Get-WorkRoot) 'assets')))
 $script:Corrupt = $false
 # a wrong zstd download
 $realSha = $script:ZstdSha256; $script:ZstdSha256 = '0' * 64; Set-Answers @('Y')
 ExpectThrows 'a download that does not match its hash is refused' { Resolve-Assets @{} $tools } '*zstd download does not match*'
 $script:ZstdSha256 = $realSha
 # not enough space
 $script:Free = 100MB; Set-Answers @('Y')
 ExpectThrows 'too little free space is reported before downloading' { Resolve-Assets @{} $tools } '*Not enough free space*'
 $script:Free = 100GB
 # a download over plain http is refused by the real wrapper
 Remove-Item Function:\Invoke-SysDownload; . (Join-Path $base 'Firmware.ps1')
 $script:VendoredScripts = [ordered]@{}; $script:ZstdSha256 = $realSha   # re-sourcing reset the test setup
 ExpectThrows 'only HTTPS downloads are allowed' { Invoke-SysDownload 'http://example.com/x' 'C:\x' } '*HTTPS*'
 # dry run
 function Invoke-SysDownload([string]$Url, [string]$OutFile) { [void]$script:Calls.Add('download') }
 $script:Calls.Clear(); Set-Answers @('Y')
 [void](Resolve-Assets @{} $tools -DryRun)
 Expect 'dry run downloads nothing' $script:Calls.Count 0
 # changed vendored scripts stop everything before any question
 $script:VendoredScripts = [ordered]@{ 'fetch_artifacts.py' = ('0' * 64) }; Set-Answers @()
 ExpectThrows 'tampered bundled scripts are refused' { Resolve-Assets @{} $tools } '*bundled firmware scripts were changed*'
} finally { Remove-TestRoot $t }

# ---------------- a failed download tells the user exactly what to do (review item E) ----------------
$artifacts = Get-Content (Join-Path $realRepo 'firmware-tools\artifacts-610.43.03.json') -Raw | ConvertFrom-Json
$pkg = $artifacts.source_artifacts | Where-Object { $_.filename -like 'NVIDIA-kernel*' }
$nvu = $artifacts.source_artifacts | Where-Object { $_.name -like 'nvidia-utils*' }
Expect 'the NVIDIA source hash in the help equals the published one' ($script:FirmwareInputs | Where-Object File -like 'NVIDIA-kernel*').Sha256 $pkg.sha256
Expect 'the driver package hash in the help equals the published one' ($script:FirmwareInputs | Where-Object File -like 'nvidia-utils*').Sha256 $nvu.sha256
Expect 'the driver package source in the help equals the published one' ($script:FirmwareInputs | Where-Object File -like 'nvidia-utils*').Url $nvu.url
$help = Format-DownloadHelp 'C:\work\inputs' "fetch failed: HTTP 404`r`nsecond line"
ExpectTrue 'the help names both files, their SHA-256 and where to put them' (($help -like '*nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst*') -and ($help -like '*e17e7c92eeff*') -and ($help -like '*NVIDIA-kernel-module-source-610.43.03.tar.xz*') -and ($help -like '*C:\work\inputs*'))
ExpectTrue 'it says a copy from anywhere works if the hash matches, and to run the installer again' (($help -like '*from anywhere as long as its SHA-256 matches exactly*') -and ($help -like '*run the installer again*'))
ExpectTrue 'it says nothing else was changed and includes the reason' (($help -like '*Nothing else was changed*') -and ($help -like '*HTTP 404*'))

# ---------------- platform config ----------------
Set-RepoRoot $realRepo
$g = [guid]'7188d005-9794-47ba-9c9b-f144488bdc1e'
Expect 'guid initializer layout' (ConvertTo-GuidInitializer $g) '{0x7188d005,0x9794,0x47ba,{0x9c,0x9b,0xf1,0x44,0x48,0x8b,0xdc,0x1e}}'
$localCfg = Join-Path $realRepo 'internal-boot\local-config.json'; $localH = Join-Path $realRepo 'internal-boot\boot\platform-config.h'
if ((Test-Path $localCfg) -and (Test-Path $localH)) {
 $c = Get-Content $localCfg -Raw | ConvertFrom-Json
 $mine = Get-PlatformConfigText ([guid]$c.UnlockPartitionGuid) ([guid]$c.WindowsPartitionGuid)
 $theirs = [IO.File]::ReadAllText($localH)
 Expect 'the generated platform config equals the one the reference build uses' ($mine -replace "`r`n", "`n") ($theirs -replace "`r`n", "`n")
} else { Write-Host 'skip platform-config golden (no local config on this PC)' }

$t = New-TestRoot
try {
 $fake = Join-Path $t 'repo'; New-FakeRepo $fake; Set-RepoRoot $fake
 [void](New-Item -ItemType Directory -Path (Join-Path $fake 'internal-boot\boot') -Force)
 $ESP = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
 $script:Layout = [pscustomobject]@{ Partitions = @([pscustomobject]@{ Guid = '{4bd184d1-b7fa-4a50-8d89-e68cffd71b5d}'; IsWindowsEsp = $true }, [pscustomobject]@{ Guid = '{7188d005-9794-47ba-9c9b-f144488bdc1e}'; IsWindowsEsp = $false }) }
 function Get-SysDiskLayout { $script:Layout }
 $state = [ordered]@{ BootPartition = [ordered]@{ Guid = '{7188d005-9794-47ba-9c9b-f144488bdc1e}'; DriveLetter = 'U' } }
 $h = New-PlatformConfig $state
 ExpectTrue 'platform-config.h written' (Test-Path (Join-Path $fake 'internal-boot\boot\platform-config.h'))
 ExpectTrue 'local-config.json written with both ids' (((Get-Content (Join-Path $fake 'internal-boot\local-config.json') -Raw | ConvertFrom-Json).WindowsPartitionGuid) -eq '{4bd184d1-b7fa-4a50-8d89-e68cffd71b5d}')
 ExpectTrue 'the header names the partition ids' ((Get-Content (Join-Path $fake 'internal-boot\boot\platform-config.h') -Raw) -like '*0x7188d005*')
 Expect 'journaled' (@(Read-Journal) | Where-Object Action -like 'write local partition*').Status 'done'
 Remove-Item (Join-Path $fake 'internal-boot\boot\platform-config.h')
 [void](New-PlatformConfig $state -DryRun)
 ExpectTrue 'dry run writes nothing' (-not (Test-Path (Join-Path $fake 'internal-boot\boot\platform-config.h')))
 $script:Layout.Partitions = @($script:Layout.Partitions + [pscustomobject]@{ Guid = '{11111111-1111-1111-1111-111111111111}'; IsWindowsEsp = $true })
 ExpectThrows 'two system partitions are refused' { New-PlatformConfig $state } '*exactly one*'
 $script:Layout.Partitions = @($script:Layout.Partitions[0])
 ExpectThrows 'a missing partition identity is refused' { New-PlatformConfig ([ordered]@{ BootPartition = [ordered]@{ Guid = '' } }) } '*no identity*'

 # ---------------- command text for the test processes ----------------
 Expect 'strings are single-quoted and quotes doubled' (ConvertTo-PsLiteral "it's") "'it''s'"
 Expect 'arrays become @()' (ConvertTo-PsLiteral @('a', 'b c')) "@('a','b c')"
 $cmd = New-ScriptCall 'C:\x y\t.ps1' ([ordered]@{ Clang = 'C:\LLVM\clang.exe'; Flag = $true; Off = $false; List = @('--a', 'b') })
 Expect 'script call text' $cmd "& 'C:\x y\t.ps1' -Clang 'C:\LLVM\clang.exe' -Flag -List @('--a','b'); if (`$LASTEXITCODE -ne 0 -and `$null -ne `$LASTEXITCODE) { exit `$LASTEXITCODE }"

 # ---------------- build ----------------
 $tools = @(
  [pscustomobject]@{ Id = 'llvm'; Info = [pscustomobject]@{ Path = 'C:\LLVM\bin\clang.exe'; Dir = 'C:\LLVM\bin'; Lld = 'C:\LLVM\bin\lld-link.exe' } },
  [pscustomobject]@{ Id = 'python'; Info = [pscustomobject]@{ Path = 'C:\Py\python.exe' } },
  [pscustomobject]@{ Id = 'msvc'; Info = [pscustomobject]@{ VcVars = 'C:\VS\vcvars64.bat'; VswhereDir = 'C:\VSI' } })
 $script:Proc = New-Object System.Collections.ArrayList; $script:Cpath = $null; $script:BuildCode = 0; $script:Skip = $null
 function Invoke-SysScriptProcess([string]$CommandText) {
  [void]$script:Proc.Add($CommandText); $script:Cpath = $env:CPATH
  if ($CommandText -like '*Build.ps1*') {
   foreach ($f in (Get-BuiltFileList)) { if ($f.Role -ne $script:Skip) { [void](New-Item -ItemType Directory -Path (Split-Path -Parent $f.Path) -Force); Set-Content $f.Path $f.Role -Encoding ascii } }
  }
  [pscustomobject]@{ Code = $script:BuildCode; Output = 'build output' }
 }
 # stale images are removed before the build
 $stale = (Get-BuiltFileList)[0].Path; [void](New-Item -ItemType Directory -Path (Split-Path -Parent $stale) -Force); Set-Content $stale 'OLD'
 $script:Skip = 'manual-wrapper'; $script:BuildCode = 0
 ExpectThrows 'a build that leaves out an image is refused (no stale file is used)' { Build-BootPrograms $state $tools 'C:\work\profile' } '*manual-wrapper is missing*'
 $script:Skip = $null
 $files = Build-BootPrograms $state $tools 'C:\work\profile'
 Expect 'four images are reported' $files.Count 4
 ExpectTrue 'each has a SHA-256' (@($files | Where-Object { $_.Sha256 -match '^[0-9a-f]{64}$' }).Count -eq 4)
 Expect 'the profile folder was on CPATH during the build' $script:Cpath 'C:\work\profile'
 ExpectTrue 'Build.ps1 was run with the tool paths' ($script:Proc[-1] -like "*Build.ps1* -Clang 'C:\LLVM\bin\clang.exe' -LldLink 'C:\LLVM\bin\lld-link.exe' -Python 'C:\Py\python.exe'*")
 $script:BuildCode = 1
 ExpectThrows 'a failing build is an error with its output' { Build-BootPrograms $state $tools 'C:\work\profile' } '*did not build*build output*'
 $script:BuildCode = 0; $n = $script:Proc.Count
 Expect 'dry run builds nothing' @(Build-BootPrograms $state $tools 'C:\work\profile' -DryRun).Count 0
 Expect 'dry run runs no process' $script:Proc.Count $n

 # ---------------- host tests ----------------
 $cap = Join-Path $t 'cap'; [void](New-Item -ItemType Directory $cap)
 foreach ($f in 'DIAG.TXT', 'PROM.BIN', 'IMG34.BIN') { Set-Content (Join-Path $cap $f) 'x' }
 $summary = [pscustomobject]@{ fixture = [pscustomobject]@{ rtx_id = 'aaaa10de'; other_id = 'bbbb10de'; rtx_path_node = '010106000001'; other_path_node = '010106000101'; nvgop_image = 'IMG34.BIN' } }
 $state2 = [ordered]@{ CaptureDir = $cap; Profile = [ordered]@{ Dir = 'C:\work\profile'; Summary = $summary } }
 $plan = @(Get-HostTestPlan $state2 $tools 'C:\assets')
 Expect 'seven host tests are planned' $plan.Count 7
 $fx = @($plan[2].Params.FixtureArgs)
 Expect 'the console replay gets this PC''s card ids and path nodes' ($fx -join ' ') '--rtx-id aaaa10de --other-id bbbb10de --rtx-path-node 010106000001 --other-path-node 010106000101'
 Expect 'the full replay uses the card driver image' $plan[3].Params.NvPe (Join-Path $cap 'IMG34.BIN')
 Expect 'the unlock test gets the assets folder' $plan[4].Params.Assets 'C:\assets'
 ExpectTrue 'the unlock test runs with local fixtures and the full profile' ($plan[4].Params.WithLocalFixtures -and $plan[4].Params.StockProfile -eq 'entryLatchedSs1Full')
 ExpectTrue 'the manual regression is its own test' ($plan[6].Params.ManualRegression -eq $true)
 Expect 'every test script exists in the real repo' (@($plan | Where-Object { $_.File -notlike "$fake*" }).Count) 0
 Set-RepoRoot $realRepo
 $realPlan = @(Get-HostTestPlan $state2 $tools 'C:\assets')
 Expect 'every planned script exists in the real repo' (@($realPlan | Where-Object { -not (Test-Path $_.File) }).Count) 0
 Set-RepoRoot $fake

 function Invoke-SysPython([string]$Python, [string[]]$PyArgs) { Set-Content $PyArgs[-1] 'report' ; [pscustomobject]@{ Code = 0; Output = '' } }
 $script:Fail = $null
 function Invoke-SysScriptProcess([string]$CommandText) {
  if ($CommandText -like '*Build.ps1*') { foreach ($f in (Get-BuiltFileList)) { [void](New-Item -ItemType Directory -Path (Split-Path -Parent $f.Path) -Force); Set-Content $f.Path $f.Role -Encoding ascii } }
  $code = if ($script:Fail -and $CommandText -like "*$script:Fail*") { 1 } else { 0 }
  [pscustomobject]@{ Code = $code; Output = "line one`r`nPASS something: 12 checks`r`n" }
 }
 $outcome = Invoke-HostTests $state2 $tools 'C:\assets'
 ExpectTrue 'all pass' $outcome.Ok
 Expect 'seven results' $outcome.Results.Count 7
 Expect 'the last output line is the detail' $outcome.Results[0].Detail 'PASS something: 12 checks'
 ExpectTrue 'the report was made from the capture' (Test-Path (Join-Path $cap 'REPORT.TXT'))
 ExpectTrue 'logs were saved' (@(Get-ChildItem (Join-Path (Get-WorkRoot) 'tests')).Count -eq 7)
 $script:Fail = 'test-full.ps1'
 $outcome = Invoke-HostTests $state2 $tools 'C:\assets'
 ExpectTrue 'one failing test fails the whole run' (-not $outcome.Ok)
 Expect 'only that test is marked failed' @($outcome.Results | Where-Object { -not $_.Passed }).Count 1
 Set-Answers @(); Show-HostTestResults $outcome
 ExpectTrue 'the failure is shown in words' (((OutText) -like '*FAIL*full driver release*') -and ((OutText) -like '*[[]pass[]]*'))
 $script:Fail = $null

 # ---------------- phases ----------------
 $opt = @{ DryRun = $false; ReportFolder = (Join-Path $t 'reports'); CaptureFolder = $null }
 function Get-ToolStatus { $tools | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Ok = $true; Info = $_.Info } } }
 $st = [ordered]@{ CaptureDir = $cap; Profile = [ordered]@{ Dir = 'C:\work\profile'; Summary = $summary }; BootPartition = $state.BootPartition }
 function Resolve-Assets($State, $Tools, [switch]$DryRun) { $script:AssetsAnswer }
 $script:AssetsAnswer = $null
 Expect 'no firmware files: stop' (Invoke-Phase-firmware $st $opt).Stop 'the NVIDIA firmware files are not available'
 $script:AssetsAnswer = 'C:\work\assets'
 $r = Invoke-Phase-firmware $st $opt
 Expect 'firmware ok: go on to build' $r.Next 'build'
 Expect 'assets folder saved' $st.Assets 'C:\work\assets'
 $r = Invoke-Phase-build $st $opt
 Expect 'build: go on to the tests' $r.Next 'hosttests'
 Expect 'four built files recorded in the state' $st.Build.Files.Count 4
 ExpectTrue 'hashes are shown' ((OutText) -match '(?m)manual-wrapper: [0-9a-f]{12}')
 $r = Invoke-Phase-hosttests $st $opt
 Expect 'tests pass: on to the benchmark offer' $r.Next 'benchmark-offer'
 ExpectTrue 'passing time recorded' ([bool]$st.TestsPassed)
 $script:Fail = 'test-all.ps1'; $st.Remove('TestsPassed')
 Set-Answers @()
 $r = Invoke-Phase-hosttests $st $opt
 Expect 'a failing test stops the installer' $r.Stop 'a host test failed'
 ExpectTrue 'no pass time recorded' (-not $st.Contains('TestsPassed'))
 ExpectTrue 'the user is told there is no skip' ((OutText) -like '*no way to skip a test*')
 $rep = @(Get-ChildItem (Join-Path $t 'reports') -Filter 'host-tests-*')
 Expect 'a report was saved' $rep.Count 1
 ExpectTrue 'the report names the failed test' ((Get-Content $rep[0].FullName -Raw) -like '*unlock program, checks and transaction*')
 ExpectTrue 'the report holds no user name' ((Get-Content $rep[0].FullName -Raw) -notlike "*$env:USERNAME*")
} finally { Remove-TestRoot $t }

# ---------------- every script that calls vcvars64.bat can find vswhere.exe on its own ----------------
Set-RepoRoot $realRepo
$callers = @(Get-ChildItem (Join-Path $realRepo 'internal-boot'), (Join-Path $realRepo 'benchmark') -Recurse -Filter '*.ps1' | Where-Object { (Get-Content $_.FullName -Raw) -match 'vcvars' -and (Get-Content $_.FullName -Raw) -match 'cmd\.exe|ComSpec' })
ExpectTrue 'the scripts that import the Visual Studio environment were found' ($callers.Count -ge 7)
foreach ($c in $callers) { ExpectTrue ("$($c.Name) puts vswhere's folder on PATH before calling vcvars64.bat") ((Get-Content $c.FullName -Raw) -like '*Visual Studio\Installer*') }
Complete-Tests
