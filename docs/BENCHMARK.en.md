# Compare performance under the same conditions


The benchmark uses the upstream 4096x4096 cuBLAS GEMM: FP32 pedantic, FP16/BF16 inputs with FP32 accumulation/output, two seconds of warmup per precision and 30 samples. Local changes select the card by its PCI bus address (`--pci 0000:BB:DD.F`; the name is reported, never assumed) and add metadata inspection. Result checking remains limited to the first and last output elements, as in upstream.

`setup.ps1` downloads NVIDIA's CUDA 12.6.0 redistributables (compiler, runtime, headers, cuBLAS: 488,838,722 bytes in four files) from NVIDIA's official server and checks each file's size and SHA-256 against NVIDIA's own published manifest (`setup.ps1 -ListOnly` prints the list and total without downloading). It does not change the driver, ComfyUI or system PATH. Downloads and disk space are required. All three scripts take `-Root <folder>`; the installer uses a folder of its own, so nothing lands in this repository.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\benchmark\setup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\benchmark\build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\benchmark\run-benchmark.ps1 -Bus 01:00.0 -PreflightOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\benchmark\run-benchmark.ps1 -Bus 01:00.0 -Label before
```

`-Bus` is the card's `bus:device.function` as `nvidia-smi` shows it. Save and close ComfyUI, video, recording and other GPU workloads before measuring. Start limits are GPU utilization at most 5%, VRAM at most 2048 MiB and temperature at most 65 C; if the card is busy the script names the programs using it (file names only) and stops. It does not forcibly terminate other processes. Each run writes a result folder with the three raw trials and `summary.json` (medians, highest power, temperature and clock, driver).

The installer also looks at the FP16-to-FP32 speed ratio of the "before" run (about 3.2 on the reference RTX 3060 when locked, about 5.9 when unlocked) to warn about a baseline taken on a card that is already unlocked. That ratio is only a hint, calibrated on one card (an unlocked RTX 3090 is about 4.0 and would not trigger it); the authoritative check is the card's register state in the capture, which the profile generator and the boot programs check and refuse on.

Use the same executable, driver, power limit, overclock and temperature conditions before and after. This tool does not change GPU settings. FP16/BF16 Tensor throughput gains do not imply the same speedup in complete games, video tasks or ComfyUI workflows. See [the measured case and its limits](PROFILE-Z790-3060.en.md).
