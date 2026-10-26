# NVIDIA firmware files, generated locally on the user's own PC (plan requirements 1, 4, 13; docs/ASSETS.en.md).
# Nothing from NVIDIA is shipped with this project. With the user's Y, the installer downloads two pinned inputs from their
# official hosts, checks each against its published SHA-256, runs upstream's own generators (vendored unchanged in
# firmware-tools/, each checked against a pinned hash before it runs), and verifies the five resulting files against
# internal-boot/unlock/assets.json. Everything stays in the installer's own folder; nothing is installed system-wide.
# Needs Ui.ps1, State.ps1, Tools.ps1, Capture.ps1 (Invoke-SysPython, Get-WorkRoot, Get-RepoRoot, Get-SysFileHash).

# Pinned inputs (sizes from the hosts' Content-Length, hashes from firmware-tools/artifacts-610.43.03.json and the zstd release manifest).
$script:ZstdUrl = 'https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-v1.5.7-win64.zip'
$script:ZstdSha256 = 'acb4e8111511749dc7a3ebedca9b04190e37a17afeb73f55d4425dbf0b90fad9'   # SHA-256 of the official zstd-v1.5.7-win64.zip (matches the winget manifest and the file downloaded in testing)
$script:FirmwareDownloads = @(
 [pscustomobject]@{ Name = 'NVIDIA open kernel module source 610.43.03'; Host = 'download.nvidia.com'; Bytes = 26172192 }
 [pscustomobject]@{ Name = 'nvidia-utils 610.43.03 driver package (CachyOS archive)'; Host = 'archive.cachyos.org'; Bytes = 314789539 }
 [pscustomobject]@{ Name = 'zstd 1.5.7 (decompressor, portable)'; Host = 'github.com'; Bytes = 1747181 }
)
# The vendored upstream scripts must be byte-identical to Zagitta/gpu-unlock at commit 0ebdb1c (see firmware-tools/SOURCE.txt).
$script:VendoredScripts = [ordered]@{
 'fetch_artifacts.py'         = '5655e3e497b16e17e3a9c307cf733ef2207cd7a3d0be5a9d0b2c532d66abe76b'
 'generate_v67.py'            = '4b41e5199c6b9968d134c43a5a42d8127d094eebfe9dca78204be4d7c8237fd0'
 'extract_boot_assets.py'     = '7acc5f488cd35700c499bc942a07e7d0d9b0822b1e2ad040cd34bacf99fa5986'
 'artifacts-610.43.03.json'   = '766be4acb90a9ce2448adc3eb4cead81ea142e96b614f30bde1600b74fe5a4bc'
}

# --- system calls (replaceable in tests) ---
function Invoke-SysDownload([string]$Url, [string]$OutFile) {
 if ($Url -notlike 'https://*') { throw 'Downloads must use HTTPS.' }
 Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}
function Invoke-SysExpandZip([string]$Zip, [string]$Dest) { Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force }
function Get-SysFreeBytes([string]$Path) {
 $root = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path).Path)
 (Get-Volume -DriveLetter $root.Substring(0, 1)).SizeRemaining
}

# --- the five expected files ---
# Windows PowerShell 5.1 returns a JSON array as one object; unroll it so callers get one object per file.
function Get-ExpectedAssets {
 $all = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'internal-boot\unlock\assets.json') -Raw | ConvertFrom-Json
 foreach ($a in $all) { $a }
}

# Compares a folder with assets.json (size and SHA-256 of all five files).
function Test-AssetsFolder([string]$Dir) {
 $missing = @(); $wrong = @()
 foreach ($a in (Get-ExpectedAssets)) {
  $f = Join-Path $Dir $a.Name
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $missing += $a.Name; continue }
  if ((Get-Item -LiteralPath $f).Length -ne $a.Bytes -or (Get-SysFileHash $f) -ne $a.Sha256) { $wrong += $a.Name }
 }
 [pscustomobject]@{ Ok = (-not $missing.Count -and -not $wrong.Count); Missing = $missing; Wrong = $wrong }
}

function Test-VendoredScripts {
 $bad = @()
 foreach ($k in $script:VendoredScripts.Keys) {
  $p = Join-Path (Get-RepoRoot) "firmware-tools\$k"
  if (-not (Test-Path -LiteralPath $p) -or (Get-SysFileHash $p) -ne $script:VendoredScripts[$k]) { $bad += $k }
 }
 $bad
}

# The two inputs and their published SHA-256 (firmware-tools/artifacts-610.43.03.json). Used to tell the user exactly what to fetch by hand.
$script:FirmwareInputs = @(
 [pscustomobject]@{ File = 'nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst'; Sha256 = 'e17e7c92eeffa178b0fe1f40eb17a47095f8fc3ce4a77bf115cf5bd5a4df86e9'; Url = 'https://archive.cachyos.org/archive/cachyos-v3/nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst' }
 [pscustomobject]@{ File = 'NVIDIA-kernel-module-source-610.43.03.tar.xz'; Sha256 = '7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc'; Url = 'https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-610.43.03.tar.xz' }
)

# What to do when a download fails. The package is hosted by a third party that may drop old files, so the installer accepts a copy
# from anywhere as long as its SHA-256 matches exactly: put it in the inputs folder and run the installer again.
function Format-DownloadHelp([string]$InputsDir, [string]$Detail) {
 $lines = @('Downloading the NVIDIA firmware inputs failed.', ('  ' + (($Detail -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' ')), '',
  'You can fetch the file(s) yourself by any means (a browser, another PC, a copy a friend has). The installer accepts a file from anywhere as long as its SHA-256 matches exactly:')
 foreach ($i in $script:FirmwareInputs) { $lines += ('  {0}' -f $i.File); $lines += ('    SHA-256 {0}' -f $i.Sha256); $lines += ('    normal source {0}' -f $i.Url) }
 $lines += ''
 $lines += ('Put the file(s) in this folder:  ' + $InputsDir)
 $lines += 'then run the installer again; it checks the files and does not download them. If a file is already there but its hash is wrong, delete it first. Nothing else was changed.'
 $lines -join "`r`n"
}

function Format-Mb([double]$Bytes) { '{0:N0} MB' -f ($Bytes / 1000000) }   # decimal megabytes, the way download sizes are usually quoted

# Finds a folder that already holds all five verified files: the repo's own assets\ folder, or an earlier run's work folder.
function Find-ExistingAssets {
 foreach ($d in @((Join-Path (Get-WorkRoot) 'assets'), (Join-Path (Get-RepoRoot) 'assets'))) {
  if ((Test-Path -LiteralPath $d) -and (Test-AssetsFolder $d).Ok) { return $d }
 }
 $null
}

# Returns the verified assets folder, or $null when the user declined or something failed (nothing half-made is left behind).
function Resolve-Assets($State, $Tools, [switch]$DryRun) {
 $have = Find-ExistingAssets
 if ($have) { Write-Plain ("The five NVIDIA firmware files are already here and verified: {0}" -f $have); return $have }
 $bad = @(Test-VendoredScripts)
 if ($bad.Count) { throw ('The bundled firmware scripts were changed (' + ($bad -join ', ') + '). Restore them from the project download.') }
 $total = ($script:FirmwareDownloads | Measure-Object Bytes -Sum).Sum
 Write-Plain ''
 Write-Plain 'The boot programs need five NVIDIA firmware files. This project does not ship them; they are made on your PC from NVIDIA''s own download:'
 foreach ($d in $script:FirmwareDownloads) { Write-Plain ('  - {0}, {1}, from {2}' -f $d.Name, (Format-Mb $d.Bytes), $d.Host) }
 Write-Plain ('Total download about {0}. Every download is checked against its published SHA-256 before it is used, the generating scripts are upstream''s' -f (Format-Mb $total))
 Write-Plain 'own (Zagitta/gpu-unlock, checked against a pinned hash), and the five results are checked against known hashes. The files and NVIDIA''s license text stay in the'
 Write-Plain 'installer''s own folder; nothing is installed on your PC. NVIDIA''s license applies to these files: they must not be shared.'
 if (-not (Ask-YesNo ('Download about {0} and generate the firmware files?' -f (Format-Mb $total)))) { Write-Plain 'Nothing was downloaded. The installer cannot go on without these files.'; return $null }
 $work = Join-Path (Get-WorkRoot) 'firmware'
 if ($DryRun) { Write-Plain "DRYRUN: download, check and generate the firmware files in $work"; return (Join-Path (Get-WorkRoot) 'assets') }
 [void](New-Item -ItemType Directory -Path $work -Force)
 if ((Get-SysFreeBytes $work) -lt ($total * 3)) { throw ('Not enough free space on this drive: about {0} are needed for the downloads and the extracted files.' -f (Format-Mb ($total * 3))) }
 $py = ($Tools | Where-Object Id -eq 'python').Info.Path
 $repo = Get-RepoRoot
 $assets = Join-Path (Get-WorkRoot) 'assets'
 try {
 [void](Invoke-JournaledChange -Phase 'firmware' -Action 'generate NVIDIA firmware files' -Target $assets -Undo 'Roll back asks whether to keep or delete them' -Do {
  $zip = Join-Path $work 'zstd.zip'
  Invoke-SysDownload $script:ZstdUrl $zip
  if ((Get-SysFileHash $zip) -ne $script:ZstdSha256) { throw 'The zstd download does not match its published SHA-256.' }
  Invoke-SysExpandZip $zip (Join-Path $work 'zstd')
  $zstd = Get-ChildItem -LiteralPath (Join-Path $work 'zstd') -Recurse -Filter 'zstd.exe' | Select-Object -First 1
  if (-not $zstd) { throw 'zstd.exe was not in the zstd download.' }
  $inputs = Join-Path $work 'inputs'
  $r = Invoke-SysPython $py @((Join-Path $repo 'firmware-tools\fetch_artifacts.py'), $inputs)
  if ($r.Code -ne 0) { throw (Format-DownloadHelp $inputs $r.Output) }
  [void](New-Item -ItemType Directory -Path $assets -Force)
  $savedPath = $env:PATH
  try {
   $env:PATH = $zstd.DirectoryName + ';' + $env:PATH
   $r = Invoke-SysPython $py @((Join-Path $repo 'firmware-tools\generate_v67.py'), (Join-Path $inputs 'nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst'), $assets)
   if ($r.Code -ne 0) { throw ('Generating the GSP firmware failed: ' + $r.Output) }
  } finally { $env:PATH = $savedPath }
  $src = Join-Path $work 'src'
  $untar = "import tarfile,sys; t=tarfile.open(sys.argv[1]); t.extractall(sys.argv[2], filter='data')"
  $r = Invoke-SysPython $py @('-c', $untar, (Join-Path $inputs 'NVIDIA-kernel-module-source-610.43.03.tar.xz'), $src)
  if ($r.Code -ne 0) { throw ('Unpacking the NVIDIA source failed: ' + $r.Output) }
  $r = Invoke-SysPython $py @((Join-Path $repo 'firmware-tools\extract_boot_assets.py'), (Join-Path $src 'NVIDIA-kernel-module-source-610.43.03'), $assets)
  if ($r.Code -ne 0) { throw ('Extracting the boot images failed: ' + $r.Output) }
  $t = Test-AssetsFolder $assets
  if (-not $t.Ok) { throw ('The generated firmware files do not match the expected hashes (missing: {0}; different: {1}).' -f ($t.Missing -join ', '), ($t.Wrong -join ', ')) }
  })
 } catch {
  # never leave a half-made set behind: only a complete, verified set counts
  Remove-Item -LiteralPath $assets -Recurse -Force -ErrorAction SilentlyContinue
  throw
 }
 # large inputs are not needed any more
 foreach ($d in 'inputs', 'src') { Remove-Item -LiteralPath (Join-Path $work $d) -Recurse -Force -ErrorAction SilentlyContinue }
 $assets
}
