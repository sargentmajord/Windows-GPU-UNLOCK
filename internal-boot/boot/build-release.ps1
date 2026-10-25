# Release test image: the full driver release and verification, then Windows. Loads no unlock program.
param([string]$Clang='clang',[string]$LldLink='lld-link',[string]$Python='python')
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 New-Item -ItemType Directory -Path build/release -Force | Out-Null
 $sources=@('handoff.c','full-release.c','full-flow.c','diagnostic.c','../unlock/checks.c','../unlock/sha256.c','../efi_runtime.c')
 $objects=@()
 foreach($source in $sources) {
  $obj='build/release/'+[IO.Path]::GetFileNameWithoutExtension($source)+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror -DGU_FULL_UNLOCK -DGU_RELEASE_ONLY -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 -c $source -o $obj
  if($LASTEXITCODE -ne 0){throw "Compile failed: $source"};$objects+=$obj
 }
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf /map:build/release/RELEASE.map /out:build/release/RELEASE.EFI @objects
 if($LASTEXITCODE -ne 0){throw 'Release test link failed'}
 & $Python ../unlock/verify_pe.py build/release/RELEASE.EFI build/release/RELEASE.map --output build/release/pe-verification.json
 if($LASTEXITCODE -ne 0){throw 'Release test PE verification failed'}
 $tracked=@($sources+@('prepare-console.c','prepare-console.h','full-release.h','full-flow.h','decode-policy.h','media.h','generated.h'))
 $sourceManifest=@($tracked | ForEach-Object {[ordered]@{Path=$_;Sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}})
 [ordered]@{HardwareTested=$false;Mode='guarded-gop-release-decode-restore-then-windows';CanUnlock=$false;LoadsUnlockApplication=$false;RestoreMask='missing original IO/MEM only; never BME';Input='none; Esc in the first five seconds skips';EfiSha256=(Get-FileHash -LiteralPath build/release/RELEASE.EFI -Algorithm SHA256).Hash;BuiltUtc=[DateTime]::UtcNow.ToString('o');Sources=$sourceManifest} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath build/release/manifest.json -Encoding utf8
} finally {Pop-Location}
