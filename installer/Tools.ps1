# Build tools: detect them, and offer to install what is missing (plan requirement 1 / checks C12).
# The boot programs are built on the user's own PC with clang + lld-link 20.1.8 (the version the reference build was made
# with); host tests need Python and the MSVC C++ build tools with the Windows SDK. Nothing is installed without a Y.
# System queries and the winget call sit in Get-Sys* / Invoke-Sys* so tests can replace them.

$script:LlvmVersion = '20.1.8'

# --- system queries (replaceable in tests) ---
function Get-SysFileExists([string]$Path) { Test-Path -LiteralPath $Path -PathType Leaf }
function Get-SysCommandPaths([string]$Name) { @(Get-Command $Name -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }) }
function Get-SysCommandPath([string]$Name) { Get-SysCommandPaths $Name | Select-Object -First 1 }
function Get-SysToolOutput([string]$Exe, [string[]]$ToolArgs) {
 try { $ErrorActionPreference = 'Continue'; $o = & $Exe @ToolArgs 2>&1; if ($LASTEXITCODE -ne 0) { return $null }; ($o | Out-String).Trim() } catch { $null }
}
function Get-SysProgramFiles { @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } }
function Get-SysWingetPath { Get-SysCommandPath 'winget.exe' }
# Runs an external program and returns only its exit code - never any output it printed. An unassigned
# native-command statement's own stdout would otherwise become part of THIS function's return value too,
# bundled into an array together with the real exit code (seen live, 2026-10-30: "winget install ... failed
# with code System.Object[]" on an install that had actually succeeded - $code was that array, not the int).
function Invoke-SysExeForExitCode([string]$Exe, [string[]]$ExeArgs) {
 $o = & $Exe @ExeArgs
 $LASTEXITCODE
}
function Invoke-SysWinget([string[]]$WingetArgs) { Invoke-SysExeForExitCode 'winget.exe' $WingetArgs }

# --- detection ---
function Find-Clang {
 $cands = @()
 $p = Get-SysCommandPath 'clang.exe'; if ($p) { $cands += $p }
 foreach ($pf in (Get-SysProgramFiles)) { $cands += (Join-Path $pf 'LLVM\bin\clang.exe') }
 $cands += 'C:\TOOLS\LLVM20\bin\clang.exe'
 foreach ($c in ($cands | Select-Object -Unique)) {
  if (-not (Get-SysFileExists $c)) { continue }
  $v = Get-SysToolOutput $c @('--version')
  if ($v -match 'clang version (\d+\.\d+\.\d+)') {
   $dir = Split-Path -Parent $c
   return [pscustomobject]@{ Path = $c; Version = $Matches[1]; Dir = $dir; Lld = [IO.Path]::Combine($dir, 'lld-link.exe') }
  }
 }
 $null
}
function Find-PythonExe {
 $cands = @()
 $cands += @(Get-SysCommandPaths 'python.exe')
 $cands += @(Get-SysCommandPaths 'py.exe')
 foreach ($c in $cands) {
  # the Microsoft Store "python.exe" stub exits non-zero and prints nothing useful, so it is skipped by this probe
  $show = "import sys;print('.'.join(map(str,sys.version_info[:3])))"
  $args2 = if ($c -like '*\py.exe') { @('-3', '-c', $show) } else { @('-c', $show) }
  $v = Get-SysToolOutput $c $args2
  if ($v -match '^(\d+)\.(\d+)\.(\d+)$' -and ([int]$Matches[1] -gt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 12))) {
   $exe = $c
   if ($c -like '*\py.exe') {   # the launcher cannot be passed to the build scripts; use the interpreter it starts
    $exe = Get-SysToolOutput $c @('-3', '-c', 'import sys;print(sys.executable)')
    if (-not $exe) { continue }
   }
   return [pscustomobject]@{ Path = $exe; Version = $v }
  }
 }
 $null
}
function Find-VcVars {
 foreach ($pf in (Get-SysProgramFiles)) {
  $vswhere = Join-Path $pf 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Get-SysFileExists $vswhere)) { continue }
  $root = Get-SysToolOutput $vswhere @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath')
  if ($root) {
   $vc = Join-Path ($root -split "`r?`n" | Select-Object -First 1) 'VC\Auxiliary\Build\vcvars64.bat'
   if (Get-SysFileExists $vc) { return [pscustomobject]@{ VcVars = $vc; VswhereDir = (Split-Path -Parent $vswhere) } }
  }
 }
 $null
}

# One row per tool: Name, Ok, Found, Detail, Install (what we would run) and the disclosed size/source.
function Get-ToolStatus {
 $clang = Find-Clang; $py = Find-PythonExe; $vc = Find-VcVars
 $rows = @()
 $clangOk = $clang -and $clang.Version -eq $script:LlvmVersion -and (Get-SysFileExists $clang.Lld)
 $rows += [pscustomobject]@{ Id = 'llvm'; Name = "LLVM clang and lld-link $($script:LlvmVersion)"; Ok = [bool]$clangOk
  Detail = $(if (-not $clang) { 'not found' } elseif ($clang.Version -ne $script:LlvmVersion) { "found version $($clang.Version); $($script:LlvmVersion) is needed (the version the boot programs were verified with)" } elseif (-not (Get-SysFileExists $clang.Lld)) { 'clang found but lld-link is missing' } else { "found $($clang.Version)" })
  WingetId = 'LLVM.LLVM'; WingetArgs = @('--version', $script:LlvmVersion); Size = 'about 300 MB'; Source = 'the official LLVM release on GitHub (winget package LLVM.LLVM)'; Info = $clang }
 $rows += [pscustomobject]@{ Id = 'python'; Name = 'Python 3.12 or newer'; Ok = [bool]$py
  Detail = $(if ($py) { "found $($py.Version)" } else { 'not found' })
  WingetId = 'Python.Python.3.12'; WingetArgs = @(); Size = 'about 30 MB'; Source = 'python.org (winget package Python.Python.3.12)'; Info = $py }
 $rows += [pscustomobject]@{ Id = 'msvc'; Name = 'Microsoft C++ Build Tools with the Windows SDK (for the host tests)'; Ok = [bool]$vc
  Detail = $(if ($vc) { 'found' } else { 'not found' })
  # Found live, 2026-10-30: "--includeRecommended" pulls in everything Microsoft marks Recommended (not
  # Required) for this workload - ARM64/ARM64EC cross-compilation toolsets, CMake tools, a second,
  # Clang-based compiler for Windows (redundant: this project already brings its own LLVM separately, for
  # the main build), test adapters, extra SDK versions. None of it is needed just to run cl.exe, link.exe
  # and one Windows SDK - which is the whole of what this project's own builds (nvcc's host compiler, and
  # vcvars64.bat for lld-link) actually use. Dropped it; only the Required set installs now.
  WingetId = 'Microsoft.VisualStudio.2022.BuildTools'; WingetArgs = @('--override', '--passive --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools'); Size = 'roughly 1 to 2 GB and a few minutes'; Source = 'Microsoft (winget package Microsoft.VisualStudio.2022.BuildTools)'; Info = $vc }
 $rows
}

# Offers to install each missing tool; returns $true when everything needed is present afterwards.
function Resolve-Tools([switch]$DryRun) {
 $rows = @(Get-ToolStatus)
 foreach ($r in $rows) { Write-Plain ('  [{0}] {1}: {2}' -f $(if ($r.Ok) { 'ok     ' } else { 'MISSING' }), $r.Name, $r.Detail) }
 $missing = @($rows | Where-Object { -not $_.Ok })
 if (-not $missing.Count) { return $true }
 Write-Plain ''
 if (-not (Get-SysWingetPath)) {
  Write-Plain 'The Windows package manager (winget) is not available here, so the installer cannot install these for you.'
  Write-Plain 'Install the missing tools yourself from the sources named above, then run the installer again. Nothing was changed.'
  return $false
 }
 foreach ($r in $missing) {
  Write-Plain ('{0} is needed. Download size {1}, from {2}.' -f $r.Name, $r.Size, $r.Source)
  if (-not (Ask-YesNo ('Install {0} now?' -f $r.Name))) { Write-Plain 'Nothing more was changed. The installer cannot go on without it.'; return $false }
  if (-not $DryRun) { Write-Plain 'Installing - this can take a few minutes depending on your connection. Nothing more is printed here until it finishes.' }
  $wingetArgs = @('install', '--id', $r.WingetId, '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements') + $r.WingetArgs
  $id = Invoke-JournaledChange -Phase 'tools' -Action ('install ' + $r.WingetId) -Target $r.Name -Previous $null -Undo 'left installed (Roll back lists it; uninstall from Settings > Apps if you want it gone)' -DryRun:$DryRun -Do {
   $code = Invoke-SysWinget $wingetArgs
   if ($code -ne 0) { throw ('winget install of {0} failed with code {1}' -f $r.WingetId, $code) }
  }
 }
 if ($DryRun) { return $true }
 # a fresh install can need a new PATH; re-detect from the usual folders
 $again = @(Get-ToolStatus | Where-Object { -not $_.Ok })
 if ($again.Count) {
  Write-Plain ('Still missing after the install: ' + (($again | ForEach-Object { $_.Name }) -join '; ') + '. Close this window, run the installer again, and it will pick them up.')
  return $false
 }
 $true
}

# Offers to uninstall, one at a time, each build tool THIS install actually installed (never one that was
# already there - only a tool Get-ToolStatus found missing, and Resolve-Tools then installed, ever gets an
# 'install *' journal entry to offer here at all). Asked once, right when a run finishes successfully, so
# it is not missed by whoever never runs Roll back. Roll back still offers the same thing as a safety net.
function Invoke-ToolCleanupOffer {
 $installed = @(Read-Journal | Where-Object { $_.Action -like 'install *' -and $_.Status -eq 'done' })
 if (-not $installed.Count) { return }
 Write-Plain ''
 Write-Plain 'This install downloaded and installed the following build tools because they were missing:'
 foreach ($e in $installed) { Write-Plain ('  - ' + $e.Target) }
 Write-Plain 'If you do not already use them for anything else, they can be removed now; otherwise they are left as they are.'
 foreach ($e in $installed) {
  $wingetId = $e.Action -replace '^install ', ''
  if (Ask-YesNo ('Uninstall {0} now?' -f $e.Target)) {
   $code = Invoke-SysWinget @('uninstall', '--id', $wingetId, '--exact', '--source', 'winget', '--accept-source-agreements')
   if ($code -eq 0) { Write-Plain ('  ' + $e.Target + ' was uninstalled.') }
   else { Write-Plain ('  Uninstalling ' + $e.Target + ' failed (code ' + $code + '); remove it yourself in Settings > Apps if you still want it gone.') }
  } else { Write-Plain ('  ' + $e.Target + ' was left installed.') }
 }
}

# The settings every build and host test needs: tool folders on PATH, the profile folder on CPATH.
function Get-BuildEnvironment($Tools, [string]$ProfileDir) {
 $clang = ($Tools | Where-Object Id -eq 'llvm').Info; $vc = ($Tools | Where-Object Id -eq 'msvc').Info
 $py = ($Tools | Where-Object Id -eq 'python').Info
 $dirs = @($clang.Dir, $vc.VswhereDir, (Split-Path -Parent $py.Path))
 @{ Path = (($dirs | Where-Object { $_ }) -join ';') + ';' + $env:PATH; Cpath = $ProfileDir; Clang = $clang.Path; LldLink = $clang.Lld; Python = $py.Path; VcVars = $vc.VcVars }
}
function Invoke-WithBuildEnvironment($BuildEnv, [scriptblock]$Do) {
 $savedPath = $env:PATH; $savedCpath = $env:CPATH
 try { $env:PATH = $BuildEnv.Path; if ($BuildEnv.Cpath) { $env:CPATH = $BuildEnv.Cpath } else { Remove-Item Env:CPATH -ErrorAction SilentlyContinue }; & $Do }
 finally { $env:PATH = $savedPath; if ($null -ne $savedCpath) { $env:CPATH = $savedCpath } else { Remove-Item Env:CPATH -ErrorAction SilentlyContinue } }
}
