# Downloads NVIDIA's CUDA 12.6.0 redistributable components (compiler, runtime, headers, cuBLAS) into -Root, checking every file
# against the size and SHA-256 in NVIDIA's own published manifest. Nothing is installed system-wide and no driver, PATH or
# GPU setting is touched. Refuses to overwrite an existing packages folder.
# -ListOnly prints the components and the total download size without downloading anything.
param([string]$Root = $PSScriptRoot, [switch]$ListOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$manifestUrl = 'https://developer.download.nvidia.com/compute/cuda/redist/redistrib_12.6.0.json'
$manifest = Invoke-RestMethod $manifestUrl
$components = @('cuda_nvcc', 'cuda_cudart', 'cuda_cccl', 'libcublas')
if ($ListOnly) {
    $total = 0
    foreach ($component in $components) { $a = $manifest.$component.'windows-x86_64'; $total += [long]$a.size; Write-Output ('{0} {1}: {2} bytes' -f $component, $manifest.$component.version, $a.size) }
    Write-Output ('Total download: {0} bytes' -f $total)
    return
}
$downloads = Join-Path $Root 'downloads'
$packages = Join-Path $Root 'packages'
New-Item -ItemType Directory -Force -Path $downloads, $packages | Out-Null
$records = @()
foreach ($component in $components) {
    $item = $manifest.$component
    $archive = $item.'windows-x86_64'
    $url = 'https://developer.download.nvidia.com/compute/cuda/redist/' + $archive.relative_path
    $zip = Join-Path $downloads ([IO.Path]::GetFileName($archive.relative_path))
    if (-not (Test-Path -LiteralPath $zip)) {
        Write-Output "Downloading $component $($item.version)"
        Invoke-WebRequest -Uri $url -OutFile $zip
    }
    if ((Get-Item -LiteralPath $zip).Length -ne [long]$archive.size -or
        (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archive.sha256) {
        throw "NVIDIA archive verification failed: $component"
    }
    $destination = Join-Path $packages $component
    if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite package directory: $destination" }
    Expand-Archive -LiteralPath $zip -DestinationPath $destination
    $records += [pscustomobject]@{Component=$component;Version=$item.version;Url=$url;SHA256=$archive.sha256;Bytes=[long]$archive.size}
    Write-Output "Verified and extracted $component"
}
$records | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Root 'packages-manifest.json') -Encoding utf8
Write-Output 'Isolated CUDA components prepared; no installer or GPU workload was run.'
