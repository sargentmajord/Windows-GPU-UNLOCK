# Read-only boot list logger: copies the firmware boot variables to a text file, then restarts. Loads nothing, writes no variables.
param([string]$Clang='clang',[string]$LldLink='lld-link',[string]$Python='python')
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 New-Item -ItemType Directory -Path build/bootlist -Force | Out-Null
 $sources=@('bootlist.c','../efi_runtime.c')
 $objects=@()
 foreach($source in $sources) {
  $obj='build/bootlist/'+[IO.Path]::GetFileNameWithoutExtension($source)+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 -c $source -o $obj
  if($LASTEXITCODE -ne 0){throw "Compile failed: $source"};$objects+=$obj
 }
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf /map:build/bootlist/BOOTLIST.map /out:build/bootlist/BOOTLIST.EFI @objects
 if($LASTEXITCODE -ne 0){throw 'Boot list link failed'}
 & $Python ../unlock/verify_pe.py build/bootlist/BOOTLIST.EFI build/bootlist/BOOTLIST.map --output build/bootlist/pe-verification.json
 if($LASTEXITCODE -ne 0){throw 'Boot list PE verification failed'}
 (Get-FileHash -LiteralPath build/bootlist/BOOTLIST.EFI -Algorithm SHA256).Hash
} finally {Pop-Location}
