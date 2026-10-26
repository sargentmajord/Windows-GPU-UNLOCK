# Windows GPU UNLOCK - RTX 3060 fork (work in progress)

An experimental, **unreleased** fork of [impacifist/Windows-GPU-UNLOCK](https://github.com/impacifist/Windows-GPU-UNLOCK), the Windows UEFI
port of [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock). It runs a short program before Windows starts that sets the tensor-math
speed selectors of one RTX 30 series card, then hands over to Windows without a reset. This fork converts the project to one documented
machine and works toward a single guided installer for other PCs.

**Status: nothing here is a release.** A guided installer exists and is covered by automated tests (`Install-GpuUnlock.cmd`; how to use it: [docs/INSTALLER-GUIDE.en.md](docs/INSTALLER-GUIDE.en.md)), but only one machine is known to get all the way through it. Everything below describes that machine.

## What has been verified (one machine, 2026-10-25)

Reference machine: MSI MEG Z790 GODLIKE (BIOS 1.I0), Core i9-14900KF (no integrated GPU), RTX 3060 12 GB as the target, RTX 5070 keeping the
screen working, Windows 11, UEFI, Secure Boot off. Details: [docs/PROFILE-Z790-3060.en.md](docs/PROFILE-Z790-3060.en.md).

- The read-only diagnostic, a console-detach test, a release-only test and the manual unlock (twice, on separate boots) all completed and
  returned to Windows.
- Matrix-multiply benchmark (4096x4096, median of three, driver 617.42): FP16 tensor 26.51 -> 48.13 TFLOPS (+81.6%), BF16 tensor
  26.40 -> 50.34 TFLOPS (+90.7%), FP32 unchanged (8.20 -> 8.18). A five-minute sustained run stayed within about 3% of those values.
- **Not verified:** other cards, boards, firmware versions or operating systems; sleep and normal Windows restart; the automatic (no keypress) mode beyond one boot; the guided installer on any other PC; the no-cancel extra on hardware; a real run of the optional automatic mode through the installer (requirements: [docs/UNIVERSAL-INSTALLER-PLAN.md](docs/UNIVERSAL-INSTALLER-PLAN.md)).
- **Other cards and PCs are refused, not guessed.** The installer builds its boot programs from a read-only capture of your own PC, runs every check again at boot, and runs host tests
  against your own capture before anything is put on the boot partition. Some of those tests still contain the reference card's own expectations (the size and offsets of its video BIOS
  firmware part). They pass for the reference RTX 3060; on a different card they may fail, and then the installer stops and writes a report instead of continuing. That is the safe direction,
  but it means only the reference machine is known to get all the way through; reports from other PCs are how this gets generalized.
- Only matrix-heavy GPU work speeds up (for example AI prefill, training, image generation). Games, FP32 work and memory-bound work do not.

## Read this before trying anything

- **No warranty.** This writes to GPU registers before Windows starts. It is unofficial, unsupported by NVIDIA and may void a warranty.
  Use a card you can afford to lose, and know the recovery: if a start freezes, hold the power button and power on again (Windows then starts normally). Nothing here flashes the video BIOS; the unlock is lost at every
  power-off and applied again each boot.
- **Requirements:** Windows 11 x64 in UEFI mode, Secure Boot **off**, BitLocker off, Windows Fast Startup off (for automatic mode), a second
  graphics adapter that keeps the screen working, and a display attached to the target card. Games with anti-cheat that requires Secure Boot
  will not run with it off. See [docs/CHECKS.md](docs/CHECKS.md) and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
- **Not included:** NVIDIA firmware, video BIOS images and drivers are never redistributed. Firmware files are generated locally
  ([docs/ASSETS.en.md](docs/ASSETS.en.md)).
- **The scripts are not digitally signed.** Check the download first (`SHA256SUMS`, and `gh attestation verify` if you use the GitHub CLI — see
  the release page). Windows may mark a downloaded zip and what you extract from it as coming from the internet and show a warning when you
  open `Install-GpuUnlock.cmd`; read the scripts if you want to, then choose to run it. `Install-GpuUnlock.cmd` starts the installer with the
  PowerShell execution policy bypassed for that one run only and changes no system setting. If you prefer, right-click the extracted `.ps1`
  and `.cmd` files, open Properties and tick Unblock, or run `Unblock-File` on them. Only do that after you have checked the file and where
  it came from. A checksum file and an attestation are not the same thing as code signing: they show the archive is the one this project
  built, not that Windows trusts the publisher.

## Where things are

| Path | Purpose |
|---|---|
| [docs/INSTALLER-GUIDE.en.md](docs/INSTALLER-GUIDE.en.md) | how to use the installer, step by step, and how Roll back works |
| [docs/PROFILE-Z790-3060.en.md](docs/PROFILE-Z790-3060.en.md) | the reference machine and its measured results |
| [docs/CHECKS.md](docs/CHECKS.md), [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | pre-flight checks and fixes |
| [docs/UNIVERSAL-INSTALLER-PLAN.md](docs/UNIVERSAL-INSTALLER-PLAN.md) | requirements the installer is built to |
| [docs/AUDIT-2026-10-25.md](docs/AUDIT-2026-10-25.md) | what was checked before the first hardware step |
| `internal-boot/` | the boot programs, build and staging scripts, host tests |
| `patches/` | optional patches, including one that removes the automatic mode's Esc cancel windows (with disclaimer) |
| `benchmark/` | the before/after benchmark |

## Changes in this fork

Fixed the RTX 3060 `10de:2544` firmware-load alignment bug (upstream [pull request #115](https://github.com/Zagitta/gpu-unlock/pull/115), applied
here with regression tests), made the release path work on firmware without an EDID driver, replaced the author's machine profiles with one
for the reference machine, and added tests, documentation and a benchmark for it. Full list: [CHANGES.md](CHANGES.md).

## License and attribution

GPL-2.0-only; EDK2 and separately attributed components keep their licenses. Based on
[rough2515-hub/rtx3080-unlock-public](https://github.com/rough2515-hub/rtx3080-unlock-public/tree/a08254d269af30ace9e57237abd3d8e6c261e8f5)
and [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock/tree/0ebdb1c6308b6a2072be5bf04513472942541956), through impacifist's port.
The original author's own documents and measurements for his machines are in the [upstream repository](https://github.com/impacifist/Windows-GPU-UNLOCK) and are not repeated here. Keep [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [CHANGES.md](CHANGES.md). Changes in this fork were made by Sargentmajord with
assistance from Claude, an AI coding assistant. Not affiliated with or endorsed by NVIDIA.
