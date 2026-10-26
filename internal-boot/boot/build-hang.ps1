# Recovery drill image: prints a line and hangs forever. Writes nothing.
param([string]$Clang='clang',[string]$LldLink='lld-link',[string]$Python='python')
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 New-Item -ItemType Directory -Path build/hang -Force | Out-Null
 $sources=@('hang.c')
 $objects=@()
 foreach($source in $sources) {
  $obj='build/hang/'+[IO.Path]::GetFileNameWithoutExtension($source)+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 -c $source -o $obj
  if($LASTEXITCODE -ne 0){throw "Compile failed: $source"};$objects+=$obj
 }
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf /map:build/hang/HANG.map /out:build/hang/HANG.EFI @objects
 if($LASTEXITCODE -ne 0){throw 'Hang image link failed'}
 & $Python ../unlock/verify_pe.py build/hang/HANG.EFI build/hang/HANG.map --output build/hang/pe-verification.json
 if($LASTEXITCODE -ne 0){throw 'Hang image PE verification failed'}
 (Get-FileHash -LiteralPath build/hang/HANG.EFI -Algorithm SHA256).Hash
} finally {Pop-Location}
