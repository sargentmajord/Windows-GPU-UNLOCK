# Runs every installer test file in its own PowerShell process and prints one summary line per file.
# -Integration also runs the real build and host tests on the reference machine's private capture (several minutes).
param([switch]$Integration)
$here = $PSScriptRoot
$total = 0; $bad = 0
$files = @(Get-ChildItem -LiteralPath $here -Filter 'Test-*.ps1' | Sort-Object Name)
if ($Integration) { $files += Get-Item (Join-Path $here 'Integration-RealPipeline.ps1') }
foreach ($f in $files) {
 $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f.FullName 2>&1 | Out-String
 $m = [regex]::Match($out, '(\d+) passed, (\d+) failed')
 if ($m.Success) { $p = [int]$m.Groups[1].Value; $x = [int]$m.Groups[2].Value }
 elseif ($out -match 'all tests passed') { $p = ([regex]::Matches($out, '(?m)^ok ')).Count; $x = 0 }
 else { $p = 0; $x = 1 }
 $total += $p; $bad += $x
 Write-Host ('{0,-26} {1,4} passed, {2} failed' -f $f.Name, $p, $x)
 if ($x) { ($out -split "`n" | Where-Object { $_ -match '^FAIL|UNEXPECTED|Exception|rror' } | Select-Object -First 8) | ForEach-Object { Write-Host "   $_" } }
}
Write-Host ('TOTAL {0} passed, {1} failed' -f $total, $bad)
if ($bad) { exit 1 }
