param([string]$Clang='clang',[string]$LldLink='lld-link')
$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
 $child='../unlock/build/experimental/entryLatchedSs1Full/internal/automatic/RTX3060-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL-AUTO.EFI'
 $m=Get-Content ../unlock/build/experimental/entryLatchedSs1Full/internal/automatic/build-manifest.json -Raw | ConvertFrom-Json
 $hash=(Get-FileHash -LiteralPath $child).Hash
 if($m.Mode -ne 'automatic-internal-exact-card-unlock' -or $m.EfiSha256 -ne $hash -or $m.StockProfile -ne 'entryLatchedSs1Full'){throw 'Automatic child contract mismatch'}
 [void][IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'build/automatic'))
 @("/* Generated automatic-child contract; GPL-2.0-only. */",('#define GU_UNLOCK_SHA256 "'+$hash.ToLowerInvariant()+'"'),('#define GU_UNLOCK_BYTES '+(Get-Item $child).Length)) | Set-Content build/automatic/child-contract.h -Encoding ascii
 $sources=@('handoff.c','full-release.c','full-flow.c','diagnostic.c','../unlock/checks.c','../unlock/sha256.c','../efi_runtime.c')
 $objects=@()
 foreach($source in $sources) {
  $obj='build/automatic/'+[IO.Path]::GetFileNameWithoutExtension($source)+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror -DGU_FULL_UNLOCK -DGU_AUTOMATIC_BOOT -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 -c $source -o $obj
  if($LASTEXITCODE -ne 0){throw "Compile failed: $source"};$objects+=$obj
 }
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf /map:build/automatic/AUTO.map /out:build/automatic/AUTO.EFI @objects
 if($LASTEXITCODE -ne 0){throw 'Automatic wrapper link failed'}
 python ../unlock/verify_pe.py build/automatic/AUTO.EFI build/automatic/AUTO.map --output build/automatic/pe-verification.json
 if($LASTEXITCODE -ne 0){throw 'PE verification failed'}
 [ordered]@{Mode='guarded-automatic-internal-unlock-then-windows';HardwareTested=$false;ChildSha256=$hash;ChildBytes=(Get-Item $child).Length;EfiSha256=(Get-FileHash build/automatic/AUTO.EFI).Hash;BuiltUtc=[DateTime]::UtcNow.ToString('o');Sources=@($sources+@('prepare-console.c','prepare-console.h','full-release.h','full-flow.h','decode-policy.h','media.h','build/automatic/child-contract.h') | ForEach-Object {[ordered]@{Path=$_;Sha256=(Get-FileHash $_).Hash}})} | ConvertTo-Json -Depth 5 | Set-Content build/automatic/manifest.json -Encoding utf8
}finally {Pop-Location}
