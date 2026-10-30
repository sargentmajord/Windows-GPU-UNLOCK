# Build tool detection and install offers, with mocked system queries and a mocked winget.
$base = Split-Path -Parent $PSScriptRoot
. (Join-Path $base 'Ui.ps1'); . (Join-Path $base 'State.ps1'); . (Join-Path $base 'Tools.ps1')
. (Join-Path $PSScriptRoot 'Harness.ps1')

# ---------- detection ----------
$script:Files = @{}      # path -> $true
$script:Outputs = @{}    # "exe|args" -> text
$script:Paths = @{}      # command name -> @(paths)
$script:PF = @('C:\Program Files', 'C:\Program Files (x86)')
function Get-SysFileExists([string]$Path) { [bool]$script:Files[$Path] }
function Get-SysCommandPaths([string]$Name) { @($script:Paths[$Name]) | Where-Object { $_ } }
function Get-SysCommandPath([string]$Name) { Get-SysCommandPaths $Name | Select-Object -First 1 }
function Get-SysToolOutput([string]$Exe, [string[]]$ToolArgs) { $script:Outputs["$Exe|$($ToolArgs -join ' ')"] }
function Get-SysProgramFiles { $script:PF }
function Reset-World { $script:Files = @{}; $script:Outputs = @{}; $script:Paths = @{} }

# clang
Reset-World
ExpectTrue 'nothing installed: no clang' ($null -eq (Find-Clang))
$script:Files['C:\Program Files\LLVM\bin\clang.exe'] = $true
$script:Outputs['C:\Program Files\LLVM\bin\clang.exe|--version'] = 'clang version 20.1.8 (https://github.com/llvm/llvm-project ...)'
$c = Find-Clang
Expect 'clang found in the default folder' $c.Version '20.1.8'
Expect 'lld-link sits next to clang' $c.Lld 'C:\Program Files\LLVM\bin\lld-link.exe'
$script:Paths['clang.exe'] = @('D:\tools\clang.exe')
$script:Files['D:\tools\clang.exe'] = $true
$script:Outputs['D:\tools\clang.exe|--version'] = 'clang version 19.1.0'
Expect 'PATH clang is tried first' (Find-Clang).Version '19.1.0'
$rows = Get-ToolStatus
$llvm = $rows | Where-Object Id -eq 'llvm'
ExpectTrue 'wrong clang version is not ok' (-not $llvm.Ok)
ExpectTrue 'detail names the needed version' ($llvm.Detail -like '*20.1.8 is needed*')
Reset-World
$script:Files['C:\Program Files\LLVM\bin\clang.exe'] = $true
$script:Outputs['C:\Program Files\LLVM\bin\clang.exe|--version'] = 'clang version 20.1.8'
ExpectTrue 'clang without lld-link is not ok' (-not (Get-ToolStatus | Where-Object Id -eq 'llvm').Ok)
$script:Files['C:\Program Files\LLVM\bin\lld-link.exe'] = $true
ExpectTrue 'clang with lld-link is ok' (Get-ToolStatus | Where-Object Id -eq 'llvm').Ok
$script:Outputs['C:\Program Files\LLVM\bin\clang.exe|--version'] = $null
ExpectTrue 'clang that cannot run is not found' ($null -eq (Find-Clang))

# python
Reset-World
$show = "import sys;print('.'.join(map(str,sys.version_info[:3])))"
ExpectTrue 'no python' ($null -eq (Find-PythonExe))
$script:Paths['python.exe'] = @('C:\Users\x\AppData\Local\Microsoft\WindowsApps\python.exe', 'C:\Python312\python.exe')
$script:Outputs['C:\Python312\python.exe|-c ' + $show] = '3.12.9'
$p = Find-PythonExe
Expect 'the Store stub is skipped, real python found' $p.Path 'C:\Python312\python.exe'
Expect 'python version' $p.Version '3.12.9'
Reset-World
$script:Paths['python.exe'] = @('C:\Python38\python.exe')
$script:Outputs['C:\Python38\python.exe|-c ' + $show] = '3.11.9'
ExpectTrue 'python 3.11 is too old' ($null -eq (Find-PythonExe))
$script:Outputs['C:\Python38\python.exe|-c ' + $show] = '3.12.0'
ExpectTrue 'python 3.12 is enough' ($null -ne (Find-PythonExe))
Reset-World
$script:Paths['py.exe'] = @('C:\Windows\py.exe')
$script:Outputs['C:\Windows\py.exe|-3 -c ' + $show] = '3.13.1'
$script:Outputs['C:\Windows\py.exe|-3 -c import sys;print(sys.executable)'] = 'C:\Python313\python.exe'
Expect 'the py launcher is resolved to the real interpreter' (Find-PythonExe).Path 'C:\Python313\python.exe'

# msvc
Reset-World
ExpectTrue 'no vswhere: no msvc' ($null -eq (Find-VcVars))
$vsw = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$script:Files[$vsw] = $true
$args1 = '-latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath'
$script:Outputs["$vsw|$args1"] = 'C:\VS\BuildTools'
ExpectTrue 'vswhere but no vcvars: not found' ($null -eq (Find-VcVars))
$script:Files['C:\VS\BuildTools\VC\Auxiliary\Build\vcvars64.bat'] = $true
$v = Find-VcVars
Expect 'vcvars found' $v.VcVars 'C:\VS\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
Expect 'vswhere folder is returned for PATH' $v.VswhereDir 'C:\Program Files (x86)\Microsoft Visual Studio\Installer'

# ---------- install offers ----------
function Row($Id, $Ok, $Name = $Id) { [pscustomobject]@{ Id = $Id; Name = $Name; Ok = $Ok; Detail = $(if ($Ok) { 'found' } else { 'not found' }); WingetId = "Pkg.$Id"; WingetArgs = @('--extra'); Size = 'about 1 MB'; Source = 'a test source'; Info = $null } }
$script:State = @{ python = $false; msvc = $true; llvm = $true }
function Get-ToolStatus { @('llvm', 'python', 'msvc' | ForEach-Object { Row $_ $script:State[$_] }) }
$script:WingetCalls = New-Object System.Collections.ArrayList
$script:WingetCode = 0
$script:HaveWinget = $true
function Get-SysWingetPath { if ($script:HaveWinget) { 'C:\winget.exe' } else { $null } }
function Invoke-SysWinget([string[]]$WingetArgs) {
 [void]$script:WingetCalls.Add($WingetArgs -join ' ')
 if ($script:WingetCode -eq 0) { $script:State['python'] = $true }
 $script:WingetCode
}

$t = New-TestRoot
try {
 Set-Answers @()
 $script:State = @{ python = $true; msvc = $true; llvm = $true }
 ExpectTrue 'everything present: true without questions' (Resolve-Tools)
 Expect 'no winget call' $script:WingetCalls.Count 0

 $script:State = @{ python = $false; msvc = $true; llvm = $true }
 Set-Answers @('N')
 ExpectTrue 'declining the install returns false' (-not (Resolve-Tools))
 Expect 'declined: no winget call' $script:WingetCalls.Count 0
 ExpectTrue 'the offer names size and source' (((OutText) -like '*about 1 MB*') -and ((OutText) -like '*a test source*'))

 Set-Answers @('Y')
 ExpectTrue 'accepting installs and re-checks' (Resolve-Tools)
 Expect 'one winget call' $script:WingetCalls.Count 1
 ExpectTrue 'winget is exact-id, from the winget source, with agreements and the package args' ($script:WingetCalls[0] -eq 'install --id Pkg.python --exact --source winget --accept-package-agreements --accept-source-agreements --extra')
 $j = @(Read-Journal)
 Expect 'the install was journaled and done' ($j | Where-Object Action -like 'install*').Status 'done'

 # failing install is reported and journaled as failed
 $script:WingetCalls.Clear(); $script:State = @{ python = $false; msvc = $true; llvm = $true }; $script:WingetCode = 1603
 Set-Answers @('Y')
 ExpectThrows 'winget failure is an error' { Resolve-Tools } '*failed with code 1603*'
 Expect 'failed install is marked failed' @(Read-Journal)[-1].Status 'failed'

 # install succeeded but the tool still is not found
 $script:WingetCode = 0; $script:WingetCalls.Clear()
 function Invoke-SysWinget([string[]]$WingetArgs) { [void]$script:WingetCalls.Add('x'); 0 }
 $script:State = @{ python = $false; msvc = $true; llvm = $true }
 Set-Answers @('Y')
 ExpectTrue 'still missing after install returns false' (-not (Resolve-Tools))
 ExpectTrue 'says to run again' ((OutText) -like '*run the installer again*')

 # no winget
 $script:HaveWinget = $false; $script:WingetCalls.Clear()
 Set-Answers @()
 ExpectTrue 'no winget: false without questions' (-not (Resolve-Tools))
 ExpectTrue 'says nothing was changed' ((OutText) -like '*Nothing was changed*')
 $script:HaveWinget = $true

 # two missing tools are offered one by one; declining the second stops
 $script:State = @{ python = $false; msvc = $false; llvm = $true }
 function Invoke-SysWinget([string[]]$WingetArgs) { [void]$script:WingetCalls.Add($WingetArgs -join ' '); 0 }
 Set-Answers @('Y', 'N')
 ExpectTrue 'declining the second tool stops' (-not (Resolve-Tools))
 Expect 'only the first was installed' $script:WingetCalls.Count 1

 # dry run: questions are asked, nothing runs, nothing is journaled
 $script:WingetCalls.Clear(); $before = @(Read-Journal).Count
 $script:State = @{ python = $false; msvc = $true; llvm = $true }
 Set-Answers @('Y')
 ExpectTrue 'dry run returns true' (Resolve-Tools -DryRun)
 Expect 'dry run: no winget' $script:WingetCalls.Count 0
 Expect 'dry run: no journal' @(Read-Journal).Count $before
} finally { Remove-TestRoot $t }

# ---------- end-of-run cleanup offer ----------
$t2 = New-TestRoot
try {
 # nothing this run installed (the pre-existing-tool case: it never got an 'install *' journal entry at all,
 # so there is nothing here to offer) -> zero questions, zero winget calls
 $script:WingetCalls.Clear()
 Set-Answers @()
 Invoke-ToolCleanupOffer
 Expect 'no journal entries: no question asked' $script:Asked.Count 0
 Expect 'no journal entries: no winget call' $script:WingetCalls.Count 0
 Expect 'no journal entries: nothing printed' (OutText) ''

 # this run installed python -> it is the only one offered, and accepting it uninstalls with the exact id
 $script:State = @{ python = $false; msvc = $true; llvm = $true }
 function Invoke-SysWinget([string[]]$WingetArgs) { [void]$script:WingetCalls.Add($WingetArgs -join ' '); $script:State['python'] = $true; 0 }
 Set-Answers @('Y')
 ExpectTrue 'tool install succeeds' (Resolve-Tools)
 $script:WingetCalls.Clear()

 Set-Answers @('Y')
 function Invoke-SysWinget([string[]]$WingetArgs) { [void]$script:WingetCalls.Add($WingetArgs -join ' '); 0 }
 Invoke-ToolCleanupOffer
 Expect 'exactly one tool is offered' $script:Asked.Count 1
 ExpectTrue 'the offer names the installed tool' ($script:Asked[0] -like '*python*')
 Expect 'one uninstall call' $script:WingetCalls.Count 1
 ExpectTrue 'uninstall is exact-id, from the winget source' ($script:WingetCalls[0] -eq 'uninstall --id Pkg.python --exact --source winget --accept-source-agreements')
 ExpectTrue 'says it was uninstalled' ((OutText) -like '*was uninstalled*')

 # declining leaves it installed and never calls winget
 $script:WingetCalls.Clear()
 Set-Answers @('N')
 Invoke-ToolCleanupOffer
 Expect 'declined: no winget call' $script:WingetCalls.Count 0
 ExpectTrue 'says it was left installed' ((OutText) -like '*was left installed*')
} finally { Remove-TestRoot $t2 }

# ---------- build environment ----------
$tools = @(
 [pscustomobject]@{ Id = 'llvm'; Info = [pscustomobject]@{ Path = 'C:\LLVM\bin\clang.exe'; Dir = 'C:\LLVM\bin'; Lld = 'C:\LLVM\bin\lld-link.exe' } },
 [pscustomobject]@{ Id = 'python'; Info = [pscustomobject]@{ Path = 'C:\Py\python.exe' } },
 [pscustomobject]@{ Id = 'msvc'; Info = [pscustomobject]@{ VcVars = 'C:\VS\vcvars64.bat'; VswhereDir = 'C:\VSI' } })
$be = Get-BuildEnvironment $tools 'C:\work\profile'
Expect 'build env clang' $be.Clang 'C:\LLVM\bin\clang.exe'
Expect 'build env python' $be.Python 'C:\Py\python.exe'
ExpectTrue 'PATH starts with the tool folders' ($be.Path.StartsWith('C:\LLVM\bin;C:\VSI;C:\Py;'))
$before = $env:PATH; $beforeC = $env:CPATH
$seen = @{}
Invoke-WithBuildEnvironment $be { $script:seen.Cpath = $env:CPATH; $script:seen.PathHead = $env:PATH.Substring(0, 12) }
Expect 'CPATH is the profile folder inside the block' $seen.Cpath 'C:\work\profile'
Expect 'PATH has the tool folder inside the block' $seen.PathHead 'C:\LLVM\bin;'
Expect 'PATH restored afterwards' $env:PATH $before
Expect 'CPATH restored afterwards' $env:CPATH $beforeC
try { Invoke-WithBuildEnvironment $be { throw 'inside' } } catch { }
Expect 'PATH restored after an error' $env:PATH $before

Complete-Tests
