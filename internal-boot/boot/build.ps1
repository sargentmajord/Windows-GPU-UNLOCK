param(
 [string]$Clang='clang',
 [string]$LldLink='lld-link'
)
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 $unlock=Join-Path $PSScriptRoot '../unlock/build/experimental/entryLatchedSs1Full/internal/RTX3060-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL.EFI'
 if(!(Test-Path -LiteralPath $unlock)){throw 'Build the internal unlock profile first'}
 $hash=(Get-FileHash -LiteralPath $unlock -Algorithm SHA256).Hash.ToLowerInvariant()
 $bytes=(Get-Item -LiteralPath $unlock).Length
 $header="/* Generated local exact-image contract. GPL-2.0-only. */`n#define GU_UNLOCK_SHA256 `"$hash`"`n#define GU_UNLOCK_BYTES $bytes`n"
 [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'generated.h'),$header,[Text.UTF8Encoding]::new($false))
 New-Item -ItemType Directory -Path build -Force | Out-Null
 $sources=@('handoff.c','flow.c','../unlock/sha256.c','../efi_runtime.c')
 $objects=@()
 foreach($source in $sources) {
  $obj='build/'+[IO.Path]::GetFileNameWithoutExtension($source)+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 -c $source -o $obj
  if($LASTEXITCODE -ne 0){throw "Compile failed: $source"};$objects+=$obj
 }
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf /map:build/HANDOFF.map /out:build/HANDOFF.EFI @objects
 if($LASTEXITCODE -ne 0){throw 'Handoff link failed'}
 python ../unlock/verify_pe.py build/HANDOFF.EFI build/HANDOFF.map --output build/pe-verification.json
 if($LASTEXITCODE -ne 0){throw 'Handoff PE verification failed'}
 [ordered]@{HardwareTested=$false;UnlockSha256=$hash;UnlockBytes=$bytes;HandoffSha256=(Get-FileHash -LiteralPath build/HANDOFF.EFI -Algorithm SHA256).Hash;Configuration='boot/platform-config.h (local, not distributed)';BuiltUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath build/manifest.json -Encoding utf8
} finally {Pop-Location}
