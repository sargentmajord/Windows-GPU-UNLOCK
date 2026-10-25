# Compare performance under the same conditions


The benchmark uses the upstream 4096×4096 cuBLAS GEMM: FP32 pedantic, FP16/BF16 inputs with FP32 accumulation/output, two seconds of warmup per precision and 30 samples. Local changes select the RTX 3090 and add metadata inspection. Result checking remains limited to the first and last output elements, as in upstream.

The setup script downloads CUDA 12.6 redistributables from NVIDIA's official server, verifies sizes/hashes and prepares them within the project. It does not change the driver, ComfyUI or system PATH. Downloads and disk space are required.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\benchmark\setup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\benchmark\build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\benchmark\run-benchmark.ps1 -PreflightOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\benchmark\run-benchmark.ps1
```

The measured build used VS2019 BuildTools MSVC 14.29. For a different installation path, pass `build.ps1 -VcVars <vcvars64.bat>`. Use MSVC compatible with CUDA 12.6. Setup refuses to overwrite an existing packages directory; run it once in a fresh checkout.

Save and close ComfyUI, video, recording and other GPU workloads before measuring. Start limits are GPU utilization at most 5%, VRAM at most 2048 MiB and temperature at most 65°C. The runner records three runs in a new timestamped `benchmark/results/` directory. It does not forcibly terminate other processes.

Use the same executable, driver, power limit, overclock and temperature conditions before and after. This tool does not change GPU settings. FP16/BF16 Tensor throughput gains do not imply the same speedup in complete games, video tasks or ComfyUI workflows. See [the measured case and its limits](PROFILE-Z790-3060.en.md).
