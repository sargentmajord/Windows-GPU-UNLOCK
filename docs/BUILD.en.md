# Build and validation


Python 3.9+, LLVM/clang and lld-link are required. The successful-case EFI was built with **clang 20.1.8**. The default build is a read-only preflight and cannot run the unlock. It still contains exact-machine checks; it is not a generic hardware probe.

To build the experimental profile for the verified system:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\unlock\build.ps1 `
  -Clang C:\TOOLS\LLVM20\bin\clang.exe `
  -LldLink C:\TOOLS\LLVM20\bin\lld-link.exe `
  -ExperimentalUnlock -StockProfile entryLatchedSs1Full
```

Output:

```text
unlock/build/experimental/entryLatchedSs1Full/RTX3060-EXPERIMENTAL-entryLatchedSs1Full.EFI
```

The build checks PE/COFF structure. During original public preparation, a rebuild with clang 20.1.8 matched the successful USB EFI SHA-256. Compare a new build using `Get-FileHash`. `HardwareTested=false` in a new build manifest means the automated build did not test real hardware. Historical successful-case evidence is kept separately in `evidence/`.

## Host mock checks

These tests do not access a GPU. MSVC/Windows SDK are required; use `-VcVars` if your Visual Studio path differs. The full command below requires local fixtures from the owning PC. PROM, raw captures and firmware are not published.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\unlock\test-all.ps1 `
  -Clang C:\TOOLS\LLVM20\bin\clang.exe `
  -VcVars 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat' `
  -WithLocalFixtures -ExperimentalUnlock -StockProfile entryLatchedSs1Full `
  -Assets C:\LOCAL-FIXTURES\assets `
  -Prom C:\LOCAL-FIXTURES\probe\PROM.BIN `
  -Capture C:\LOCAL-FIXTURES\probe\REPORT.TXT `
  -ColdCapture C:\LOCAL-FIXTURES\cold\REPORT.TXT
```

Do not report missing-fixture or partial validation as a complete pass. Historical `test-*.cmd` files and some old tests assume the original development environment; `test-all.ps1` is the current port entry point. Mock success does not prove GPU success or long-term stability.

## Historical release checks

During public preparation on October 20, 2026, **10 host mock groups and malformed-PE rejection checks** passed for this profile. The [recorded result](https://github.com/impacifist/Windows-GPU-UNLOCK/blob/main/evidence/host-tests.json) explicitly states `HardwareAccess=false`. The packaging tool's five tests also passed: successful packaging and rejection of bad assets, modified source, an existing output and path traversal. These are historical results, not a claim that this documentation update reran the hardware or full host suite.

To run the public Python tool tests without firmware or GPU access:

```powershell
python -m unittest discover -s tools -p "test_*.py" -v
```
