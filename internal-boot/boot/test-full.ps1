param([Parameter(Mandatory)][string]$DiagnosticCapture,[Parameter(Mandatory)][string]$PciCapture,[string]$AmiPe,[Parameter(Mandatory)][string]$NvPe,[Parameter(Mandatory)][string]$Prom,[string[]]$FixtureArgs=@(),[string]$Clang='clang',[string]$VcVars='C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat')
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 New-Item -ItemType Directory -Path build/full -Force | Out-Null
 python make-console-fixture.py $DiagnosticCapture @FixtureArgs
 if($LASTEXITCODE -ne 0){throw 'Ownership fixture failed'}
 @'
from pathlib import Path
import re,struct,sys
t=Path(sys.argv[1]).read_text()
cfg={int(m[1],16):[int(x,16) for x in m[2].split()] for m in re.finditer(r'config\[([0-9a-f]+)\]=([^\n]+)',t)}
values=[]
for at in range(0,256,16):
 if len(cfg.get(at,[]))!=4: raise ValueError('Incomplete config')
 values.extend(cfg[at])
Path('build/full/config.bin').write_bytes(struct.pack('<64I',*values))
'@ | python - $PciCapture
 if($LASTEXITCODE -ne 0){throw 'Full config fixture failed'}
 $vsi=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer';if((Test-Path -LiteralPath $vsi) -and ($env:PATH -notlike "*$vsi*")){$env:PATH="$vsi;$env:PATH"}   # vcvars64.bat calls vswhere.exe
 $lines=& cmd.exe /d /c "call `"$VcVars`" >nul && set"
 if($LASTEXITCODE -ne 0){throw 'MSVC environment failed'}
 foreach($line in $lines){if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process')}}
 & $Clang -std=c11 -O1 -Wall -Wextra -Werror -D_CRT_SECURE_NO_WARNINGS -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 test_full.c console-flow.c ../unlock/checks.c ../unlock/sha256.c -o build/full/test-full.exe
 if($LASTEXITCODE -ne 0){throw 'Full release tests compile failed'}
 # the AMI mouse/EDID driver image is only an input for firmware that binds one (profiles without GU_NO_EDID_DRIVER)
 $inputs=@();if($AmiPe){$inputs+=$AmiPe};$inputs+=@($NvPe,$Prom,'build/full/config.bin')
 & ./build/full/test-full.exe @inputs
 if($LASTEXITCODE -ne 0){throw 'Full release tests failed'}
 & $Clang -std=c11 -O1 -Wall -Wextra -Werror -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 test_full_flow.c full-flow.c -o build/full/test-full-flow.exe
 if($LASTEXITCODE -ne 0){throw 'Full flow tests compile failed'}
 & ./build/full/test-full-flow.exe
 if($LASTEXITCODE -ne 0){throw 'Full flow tests failed'}
} finally {Pop-Location}
