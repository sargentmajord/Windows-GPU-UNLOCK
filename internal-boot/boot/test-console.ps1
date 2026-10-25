param([string]$Clang='clang',[string]$VcVars='C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat',[Parameter(Mandatory)][string]$Capture)
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 python make-console-fixture.py $Capture
 if($LASTEXITCODE -ne 0){throw 'Capture fixture generation failed'}
 $lines=& cmd.exe /d /c "call `"$VcVars`" >nul && set"
 if($LASTEXITCODE -ne 0){throw 'MSVC environment failed'}
 foreach($line in $lines){if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process')}}
 & $Clang -std=c11 -O1 -Wall -Wextra -Werror -D_CRT_SECURE_NO_WARNINGS -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 test_console.c console-flow.c -o build/console/test-console.exe
 if($LASTEXITCODE -ne 0){throw 'Console prepare tests compile failed'}
 & ./build/console/test-console.exe
 if($LASTEXITCODE -ne 0){throw 'Console prepare tests failed'}
} finally {Pop-Location}
