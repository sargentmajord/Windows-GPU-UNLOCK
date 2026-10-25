# Modified 2026-10-19/20 for Windows GPU UNLOCK; changes documented in CHANGES.md.
param([string]$VcVars='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$nvcc = Join-Path $root 'packages\cuda_nvcc\cuda_nvcc-windows-x86_64-12.6.20-archive'
$runtime = Join-Path $root 'packages\cuda_cudart\cuda_cudart-windows-x86_64-12.6.37-archive'
$cccl = Join-Path $root 'packages\cuda_cccl\cuda_cccl-windows-x86_64-12.6.37-archive'
$blas = Join-Path $root 'packages\libcublas\libcublas-windows-x86_64-12.6.0.22-archive'
$vcvars = $VcVars
if (-not (Test-Path -LiteralPath $vcvars)) { throw 'Required VS2022 build tools missing' }
$bin = Join-Path $root 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
# Import vcvars only into this child PowerShell process, never the user/machine environment.
$vcLines = & $env:ComSpec /d /c "`"$vcvars`" >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'vcvars64 failed' }
foreach ($line in $vcLines) {
    if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
}
& (Join-Path $nvcc 'bin\nvcc.exe') -std=c++17 -O3 -arch=sm_86 -Xcompiler /utf-8 `
    "-I$runtime\include" "-I$cccl\include" "-I$blas\include" `
    "-L$runtime\lib\x64" "-L$blas\lib\x64" `
    (Join-Path $root 'compute-benchmark-3060.cu') -lcublas -o (Join-Path $bin 'compute-benchmark-3060.exe')
if ($LASTEXITCODE -ne 0) { throw "nvcc failed: $LASTEXITCODE" }
Get-ChildItem -LiteralPath (Join-Path $blas 'bin') -Filter '*.dll' | Copy-Item -Destination $bin
$inspect = & (Join-Path $bin 'compute-benchmark-3060.exe') --inspect-only
if ($LASTEXITCODE -ne 0) { throw 'Metadata-only binary check failed' }
$versions = $inspect | ConvertFrom-Json
if ($versions.cuda_runtime -ne 12060 -or $versions.cublas_major -ne 12 -or $versions.cublas_minor -ne 6 -or $versions.cublas_patch -ne 0) { throw 'Unexpected CUDA/cuBLAS version' }
$inspect | Set-Content -LiteralPath (Join-Path $root 'runtime-verification.json') -Encoding utf8
$artifactPaths = @((Join-Path $root 'compute-benchmark-3060.cu'),(Join-Path $root 'upstream-compute-benchmark.cu')) + @(Get-ChildItem -LiteralPath $bin -File | Select-Object -ExpandProperty FullName)
$artifactPaths | ForEach-Object { $f = Get-Item -LiteralPath $_; [pscustomobject]@{Path=$f.FullName.Substring($root.Length+1);Bytes=$f.Length;SHA256=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash} } |
    ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $root 'build-manifest.json') -Encoding utf8
Write-Output $inspect
Write-Output 'Build and metadata-only check passed. No GEMM workload was run.'
