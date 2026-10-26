param([string]$Clang='clang',[string]$VcVars='C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat')
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 $vsi=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer';if((Test-Path -LiteralPath $vsi) -and ($env:PATH -notlike "*$vsi*")){$env:PATH="$vsi;$env:PATH"}   # vcvars64.bat calls vswhere.exe
 $lines=& cmd.exe /d /c "call `"$VcVars`" >nul && set"
 if($LASTEXITCODE -ne 0){throw 'MSVC environment failed'}
 foreach($line in $lines){if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process')}}
 New-Item -ItemType Directory -Path build -Force | Out-Null
 & $Clang -std=c11 -O1 -Wall -Wextra -Werror -D_CRT_SECURE_NO_WARNINGS -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 test_handoff.c flow.c ../unlock/sha256.c -o build/test-handoff.exe
 if($LASTEXITCODE -ne 0){throw 'Handoff test compile failed'}
 & ./build/test-handoff.exe ../unlock/build/experimental/entryLatchedSs1Full/internal/RTX3060-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL.EFI
 if($LASTEXITCODE -ne 0){throw 'Handoff tests failed'}
} finally {Pop-Location}
