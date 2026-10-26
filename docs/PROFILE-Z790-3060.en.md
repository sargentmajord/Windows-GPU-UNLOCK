# Profile: MSI MEG Z790 GODLIKE + RTX 3060 12 GB (the only profile in this copy)

**Status: experimental. On this one machine (2026-10-25) the full ladder has run: read-only diagnostic, console-detach test, release-only test, then the manual unlock (twice, on separate boots). Automatic mode (no keypress, Esc windows kept) ran once on hardware afterwards with the same result. Headless builds stay blocked at compile time for this profile.**
All names, folders and constants in this copy refer to this machine (RTX 3060 target, RTX 5070 console adapter, MSI MEG Z790 GODLIKE). The original author's profiles were removed from this copy; the project history and credits remain in CHANGES.md and THIRD_PARTY_NOTICES.md.

## Target machine

| Item | Value (read from Windows) |
|---|---|
| Card | NVIDIA GeForce RTX 3060 12 GB (GA106), PCI `10de:2544`, subsystem `1462:397d` |
| Location / BAR0 | `0000:01:00.0` / `0x85000000` |
| Board / BIOS | MSI MEG Z790 GODLIKE (MS-7D85) / 1.I0 |
| CPU | Intel Core i9-14900KF (no iGPU) |
| Other GPU | RTX 5070 at `02:00.0` drives the main display; it is not touched |

The chip register, PROM hash, display path and driver fingerprints in the profile were read from this machine's own diagnostic captures (captures/profile-constants-z790-3060.md, kept outside the repository).

## What is and is not known

- The upstream Linux module (Zagitta/gpu-unlock) lists PCI ID `0x2544` in its accepted list. Its README validates GA106 only on the RTX 3060 12 GB `10de:2504`.
- The original Windows UEFI port was documented on an RTX 3090 FE and an RTX 3070 Ti. The five firmware files it requires are named `ga102` (one `ga10x`). They worked on this GA106 card (see Results). Upstream's Linux module runs one code path for GA102/GA103/GA104/GA106, and [pull request #115](https://github.com/Zagitta/gpu-unlock/pull/115) reports a Zotac RTX 3060 with this exact PCI ID (`10de:2544`) unlocking with the same fix that is applied in this copy.
- Established by the diagnostic runs below: the firmware creates a display output (GOP) for the 3060 only when a display is attached to it; the 5070 keeps its own output either way. Established by the later runs: a non-iGPU Intel host with a second GPU as the display adapter completed the release and unlock (below).

## Reproduce the read-only diagnostic

Requires Windows 11 UEFI, Secure Boot **off**, BitLocker off, a separate FAT32 EFI System Partition of at least 1 GiB, LLVM/clang 20.1.8 and the five locally generated assets (see [ASSETS](ASSETS.en.md)). Then:

```powershell
.\internal-boot\Configure.ps1 -UnlockDriveLetter U -WindowsEspGuid '<your Windows ESP GUID>' -HardwareProfile z790-3060
.\internal-boot\boot\build-diagnostic.ps1 -Clang C:\TOOLS\LLVM20\bin\clang.exe -LldLink C:\TOOLS\LLVM20\bin\lld-link.exe -HardwareProfile z790-3060
```

`internal-boot/boot/generated.h` is only included to satisfy the compiler; under `GU_DIAGNOSTIC_ONLY` no unlock program is ever loaded. Use a clearly labelled placeholder (all-zero hash) for it.

## Results

Three read-only diagnostic runs on 2026-10-25 (each wrote its log, returned status 0 and booted Windows normally):

| Run | Setup | Result |
|---|---|---|
| 1 | no display on the 3060 | 3060 found at 01:00.0; chip register `0xb76000a1`; PROM (1 MiB window) SHA-256 `5630f3a825e52a225fcead26663288fa6c2017ad46dde6335388a01e7f03a38d`; 1 GOP (the 5070's) |
| 2 | no display on the 3060 | identical to run 1 |
| 3 | wireless HDMI adapter on the 3060 | 2 GOPs: the 3060's (ADR `0x80010370`) and the 5070's (ADR `0x80010390`); same chip and PROM values |

The firmware's two console drivers (file IDs `43e7abdd-...` graphics and `628a497d-...` text out) own both outputs; no EDID/mouse driver is bound to them. Cold-state registers match the repository's expected values at 7 of 9 offsets; the speed-selector register reads `0x46425000` or `0x46421000` depending on the power-on (the program latches the first valid value and requires it to stay unchanged). Logs and driver dumps are not published (they contain device addresses and firmware images).

## Hardware results (reference machine only)

| Step | Result |
|---|---|
| Read-only diagnostic (4 runs) | passed; saved the card's 1 MiB video BIOS window (SHA-256 above) |
| Console-detach test | passed: released only the 3060's text and graphics console drivers; the 5070 console was retained |
| Release-only test (no unlock program in the image) | passed: full driver release, PCI decode restore, verification, Windows started |
| Manual unlock, boot 1 and boot 2 | transaction result 0 both times; speed selectors `0x88888888` / `0x8`; PCIe reset completed; Windows started |
| Benchmark, 4096x4096 matrix multiply, median of 3 | FP16 tensor 26.51 -> 48.13 TFLOPS (+81.6%); BF16 tensor 26.40 -> 50.34 (+90.7%); FP32 8.20 -> 8.18 (control, unchanged); boot 2 repeated 48.11 / 50.04 |
| Automatic mode, 1 boot (no keypress) | transaction result 0, same selectors; FP16 48.61, BF16 50.17 TFLOPS |
| 5-minute sustained run (43 runs) | FP16 47.1-48.1, BF16 49.2-49.7 TFLOPS; peak 68 C and 149 W; no Windows GPU or hardware-error events |

Measured with driver 617.42. The unlock is not permanent: it is applied again at each boot by the unlock program and is lost at power-off. This is one card on one machine; it is not a promise for other hardware. Sleep has not been tested. A normal Windows restart (not a full shutdown) has now been tested (see below) and does reset the card to locked - every-boot mode's whole design depends on this.

## Locked vs. unlocked, reproduced a day later (2026-10-26)

A second round, a day after the results above, specifically to settle whether a plain Windows **Restart** (as opposed to a full power-off) actually resets the card, and to measure how much of the raw tensor-math gain shows up in real local LLM inference rather than just in a synthetic benchmark.

**Confirming each state independently**, not just assuming it from whether the unlock was scheduled:

- **Locked**: every-boot mode turned off, no one-time boot entry queued, restart, confirmed nothing ran (no new boot report). Independently confirmed by the FP16/FP32 ratio reading 3.25, matching the ~3.2 locked reference above.
- **Unlocked**: every-boot mode turned back on, restart, confirmed via the unlock program's own post-reset register readout in its boot report (`SS0=0, SS1=0` before the transaction -> `SS0=0x88888888, SS1=0x8` after, the exact intended target values). Independently confirmed by the FP16/FP32 ratio reading 5.87, matching the ~5.9 unlocked reference above.

This also answers the open question above: a normal **Restart** does reset the card back to its locked default - the queued one-time boot entry is what reapplies the unlock on the next start, not anything about the restart itself being different from a cold boot.

| Measurement | Locked | Unlocked | Change |
|---|---|---|---|
| Raw GEMM, FP16 tensor (median of 3) | 26,338.7 GFLOPS | 47,938.4 GFLOPS | +82.0% |
| Raw GEMM, BF16 tensor (median of 3) | 26,296.6 GFLOPS | 50,071.9 GFLOPS | +90.4% |
| Raw GEMM, FP32 (control) | 8,110.4 GFLOPS | 8,174.3 GFLOPS | +0.8% (noise; confirms comparable thermal/clock conditions on both sides) |

Consistent with the 2026-10-25 run above within normal run-to-run variance.

### How much of that reaches a real local LLM

Same card, same locked/unlocked states (confirmed the same way), this time running actual local LLM inference through a llama.cpp-based server (Ollama), flash attention on, forced onto this one card alone (`CUDA_VISIBLE_DEVICES`) so the reading isn't diluted by a second GPU in the system. The chat model is a 7.6B-parameter Qwen2-architecture instruction-tuned model, Q4_K_M quantization. Prefill (processing the prompt, the matrix-multiply-heavy phase) and decode (generating each new token, memory-bandwidth-bound) were measured separately:

| Test | Locked | Unlocked | Change |
|---|---|---|---|
| Prefill, ~7,600-token prompt | 2,182.5 tok/s | 2,252.3 tok/s | +3.2% |
| Prefill, ~31,000-token prompt, larger batch (same model) | 1,573.6 tok/s | 1,693.4 tok/s | +7.6% |
| Decode (token generation) | no measurable change either way | | ~0% |

Decode speed was also checked on a much larger model (31.1B-parameter Qwen3-VL mixture-of-experts vision-language model, same quantization) and showed the same flat result; that model doesn't fit on one 12 GB card, so Ollama splits it across both GPUs, meaning only part of its compute happens on the unlocked card at all - it's reported here only to confirm the decode-is-flat finding holds at a different model size and architecture, not as a clean before/after number.

**Why +82% raw compute turns into only +3-8% in practice:** the GEMM benchmark is one large matrix multiply running back-to-back with nothing else happening, fully saturating the tensor cores. Real inference mixes matmuls with plenty of work the unlock does nothing for: reading and writing the KV cache (pure memory bandwidth, unchanged by the unlock), softmax/normalization/RoPE (elementwise, not tensor-core math), dequantizing compressed weights, and many smaller matmuls with overhead between them instead of one continuous saturating one. The longer the prompt, the more that fixed/memory-bound overhead gets diluted by actual matmul work, which is why the gain roughly doubled (+3.2% -> +7.6%) between the two prompt sizes - but it is still far from the raw ceiling, because attention cost over a long context is itself increasingly memory-bound, not compute-bound. Decode never benefits at all, at any prompt size, because generating one token at a time is memory-bandwidth-bound by nature, not compute-bound.

**Bottom line:** the unlock's effect on real local LLM inference is real, repeatable and hardware-verified on both sides of the comparison, but modest - a few percent faster prompt processing, nothing on generation speed. Treat the raw GEMM percentages as the ceiling for pure matrix math on this card, not as an estimate of real-world LLM speedup.

## Credits and license

GPL-2.0-only, same as the project this builds on. Original work: **Zagitta/gpu-unlock** (the unlock core), **impacifist/Windows-GPU-UNLOCK** (the Windows UEFI port and 3090 / 3070 Ti profiles), **rough2515-hub/rtx3080-unlock-public** (the earlier public base), and the NVIDIA, CMP40HX and EDK2 notices kept in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). NVIDIA firmware is not included and is not redistributed; users generate it locally from NVIDIA's pinned inputs.
Changes in this profile were made by Sargentmajord with assistance from Claude, an AI coding assistant. See [CHANGES.md](../CHANGES.md).

## Warning

This writes to GPU registers before Windows starts. It is unofficial, unsupported by NVIDIA and may void a warranty. Use a card you can afford to lose and keep Windows-first boot recovery available.
