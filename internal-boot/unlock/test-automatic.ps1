param([Parameter(Mandatory)][string]$Prom,[Parameter(Mandatory)][string]$ColdCapture,[Parameter(Mandatory)][string]$Assets,[string]$Clang='clang',[switch]$ManualRegression,[switch]$HeadlessResearch)
$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
 $lines=& cmd.exe /d /c 'call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul && set'
 if($LASTEXITCODE -ne 0){throw 'VS environment failed'}
 foreach($line in $lines){if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process')}}
 [void][IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'build/automatic-tests'))
 $flags=@('-std=c11','-O1','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-unused-function','-D_CRT_SECURE_NO_WARNINGS','-D__KERNEL__','-DGU_UEFI_PORT','-DGU_TARGET_PCI_ID=0x254410deU','-DGU_EXPERIMENTAL_UNLOCK','-DGU_ENTRY_LATCHED_SS1_FULL','-DGU_INTERNAL_BOOT','-DGU_AUTOMATIC_BOOT','-Icompat','-I../../deps/edk2/MdePkg/Include','-I../../deps/edk2/MdePkg/Include/X64')
 $test='tests/test_automatic.c';$exe='build/automatic-tests/test-automatic.exe'
 if($HeadlessResearch -and $ManualRegression){throw 'Headless and manual regression are separate tests'}
 if($HeadlessResearch){$flags+='-DGU_HEADLESS_RESEARCH';$test='tests/test_headless.c';$exe='build/automatic-tests/test-headless.exe'}
 if($ManualRegression){$flags=@($flags | Where-Object {$_ -ne '-DGU_AUTOMATIC_BOOT'});$test='tests/test_entry_latched.c';$exe='build/automatic-tests/test-manual.exe'}
 $sources=@($test,'app_io.c','ownership.c','format.c','sha256.c','checks.c','port.c','compat.c','vendor/unlock_610.c','vendor/prep_610.c','vendor/layout_610.c','vendor/vbios_610.c','vendor/gfw_eval.c')
 & $Clang @flags @sources -o $exe
 if($LASTEXITCODE -ne 0){throw 'Automatic test compile failed'}
 & $exe $Prom $ColdCapture $Assets
 if($LASTEXITCODE -ne 0){throw 'Automatic app test failed'}
} finally {Pop-Location}
