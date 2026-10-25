# Internal boot implementation

Read [the top-level README](../README.md), [docs/CHECKS.md](../docs/CHECKS.md) and [docs/PROFILE-Z790-3060.en.md](../docs/PROFILE-Z790-3060.en.md) before building or installing.

This tree is separate from the legacy USB source. Scope: reviewed
single-machine profiles only (internal-boot/unlock/machine-profile.h): the
RTX 3060 / MSI MEG Z790 GODLIKE BIOS 1.I0 build. Manual direct
handoff is hardware verified; automatic firmware boot and the public
registration/promotion adapter remain experimental.

1. `Configure.ps1`: inspect existing dedicated ESP; generate ignored local partition config.
2. `Build.ps1`: build separate manual and automatic child/wrapper pairs.
3. `Install.ps1 -Assets <directory>`: stage only, never format or overwrite different files.
4. `Install.ps1 -Assets <directory> -RegisterManual`: register a manual test, Windows first.
5. After actual manual/performance success, optionally use `-EnableAutomaticBoot -ConfirmedManualSuccess`.
6. `Install.ps1 -RestoreWindowsFirst`: recovery independent of EFI/build files.

Keep local config, install state and backups private. No firmware is distributed.
GPL-2.0-only; root LICENSE and THIRD_PARTY_NOTICES.md apply.
