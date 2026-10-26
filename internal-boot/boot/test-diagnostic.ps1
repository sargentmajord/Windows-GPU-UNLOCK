param([string]$Clang='clang',[string]$VcVars='C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat')
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 $vsi=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer';if((Test-Path -LiteralPath $vsi) -and ($env:PATH -notlike "*$vsi*")){$env:PATH="$vsi;$env:PATH"}   # vcvars64.bat calls vswhere.exe
 $lines=& cmd.exe /d /c "call `"$VcVars`" >nul && set"
 if($LASTEXITCODE -ne 0){throw 'MSVC environment failed'}
 foreach($line in $lines){if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process')}}
 New-Item -ItemType Directory -Path build/diagnostic -Force | Out-Null
 & $Clang -std=c11 -O1 -Wall -Wextra -Werror -D_CRT_SECURE_NO_WARNINGS -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 test_diagnostic.c -o build/diagnostic/test-diagnostic.exe
 if($LASTEXITCODE -ne 0){throw 'Diagnostic tests compile failed'}
 & ./build/diagnostic/test-diagnostic.exe
 if($LASTEXITCODE -ne 0){throw 'Diagnostic tests failed'}
} finally {Pop-Location}
