# Changes

## 2026-10-25 - automatic mode verified once on the reference machine

- AUTO.EFI + UNLOCK-AUTO.EFI (with the issue-42 hardening, Esc windows kept, no keypress) ran from a one-time boot: release, one unlock (transaction result 0, selectors 0x88888888 / 0x8, FLR completed), Windows started. Benchmark afterwards: FP16 48.61, BF16 50.17, FP32 8.21 TFLOPS (4096 matrix multiply, median of 3); no Windows GPU or hardware-error events.
- Not yet verified: more than one automatic boot, a normal Windows restart with automatic mode permanent, Fast Startup off, the no-wait private build.
- The manual pair on the boot partition was refreshed to the hardened build; the pair that ran on hardware earlier is kept under EFI\WindowsGPUUnlock\previous.

## 2026-10-25 - pruning to what is needed (credit, build, tests, documents we use)

- Removed after checking that nothing used them: the duplicate root efi_runtime.c; the original author's headless research scripts (research/), headless installer and its tests (internal-boot/Headless.ps1, install/headless-package.ps1 and tests; Configure.ps1 now holds the one identity value it needed); the unrunnable v0.6 write-sequence comparison harness (tests/check_fwsec_sequence.py, test_fwsec_trace.c, tests/reference/); the original author's guides and records for his own machines (GUIDE, HEADLESS, INTERNAL-BOOT, docs/original-author/) and all Korean translations (they stay in the upstream repository).
- THIRD_PARTY_NOTICES.md is now an English notice that names every upstream project and contributor and what this fork changed; the original Korean notice is kept as THIRD_PARTY_NOTICES.ko.md.
- Kept on purpose: LICENSE, LICENSES/, the notices, the vendored upstream source files with their headers, the benchmark's upstream source and licence, the EDK2 headers, and the C-level headless code that shared sources still contain (blocked for this profile).
- After the pruning: all host tests pass and the boot images rebuild to the same hashes as the ones on the boot partition.

## 2026-10-25 - final regression check

- Removed this machine's absolute paths (and stale, non-existent capture folder names) from tracked scripts: the capture/PROM arguments of test-all.ps1, test-console.ps1 and research/headless/test-full.ps1 are now required parameters, and the build manifest no longer records a local path. The optional patch's context line was kept identical.
- Checked: history has no firmware, video BIOS or capture files from this work; no secrets; no scheduled task or run-key was added; Windows boot order, Fast Startup, Secure Boot and BitLocker are as before; the Rocky repositories are untouched by this work.
- The automatic pair on the boot partition was rebuilt and restaged to include the issue-42 hardening (AUTO.EFI 8C43211B8674, UNLOCK-AUTO.EFI C1E4103D493D); the previous pair is kept under EFI\WindowsGPUUnlock\previous. The manual FULL.EFI/UNLOCK.EFI that ran on hardware twice are unchanged.

## 2026-10-25 - firmware-boot assessment rejects register-error values (upstream issue 42)

- internal-boot/unlock/vendor/gfw_eval.c: values in the 0xbadfxxxx register-error family no longer count as a finished firmware boot (the old check only rejected 0xffffffff). New tests/test_gfw_eval.c (also in test-all.ps1) covers it; against the old code the new test fails 4 checks. Healthy cold values (this machine: 0x8b8f / 0x3ff / 0x10) are unaffected.
- The boot images staged on the reference machine's boot partition were built before this change (commit fb5b5c5); the next build, which will be run on hardware again, includes it.

## 2026-10-25 - second consistency check of this copy

- The top-level README and several guides still presented the original author's RTX 3090 / ASUS system as this project's result. The old README now lives in docs/original-author/ (with a banner), the old guides carry a 'not for this machine' banner, and the new README states what was and was not verified here. Links repaired.
- internal-boot/Build.ps1 builds both pairs again (opt-out switch -ManualOnly); an earlier edit had made it manual-only while Install.ps1 needs both.
- docs/PROFILE-Z790-3060.en.md, docs/AUDIT-2026-10-25.md and docs/UNIVERSAL-INSTALLER-PLAN.md brought up to date (plan: 15 requirements, edit damage repaired, rollback wording, Secure Boot note).
- Re-verified: all host tests, and the six boot images rebuild to the same hashes as the staged ones (CONSOLE.EFI differs only by its clearer on-screen message).

## 2026-10-25 - optional patch: no cancel windows (automatic mode)

- patches/no-cancel-windows.patch, patches/Apply-NoCancelWindows.ps1, patches/README-no-cancel-windows.md: a standalone, opt-in patch that adds a `-NoEscWindows` build option removing the 5 s and 3 s Esc windows from the automatic boot. All hardware checks stay. The script shows a disclaimer, requires typing `I ACCEPT`, applies the patch, builds the private pair into `automatic-noesc` folders, installs nothing, and has `-Undo`. The default build is unchanged (byte-identical AUTO.EFI before and after).

## 2026-10-25 - first hardware result on the reference machine (RTX 3060 12 GB, MSI MEG Z790 GODLIKE, RTX 5070 as console adapter)

- Ladder run in order: read-only diagnostic, console-detach test, release-only test, then the manual unlock (FULL.EFI + UNLOCK.EFI, one U press). Unlock transaction result 0, selectors 0x88888888 / 0x8, FLR completed, Windows started without a reset.
- Matrix-multiply benchmark (4096, median of three): FP16 26.51 -> 48.13 TFLOPS (+81.6%), BF16 26.40 -> 50.34 (+90.7%), FP32 unchanged (8.20 -> 8.18). A 5-minute sustained run (43 runs) stayed within 47.1-48.1 (FP16) and 49.2-49.7 (BF16) with a peak of 68 C; no Windows GPU or WHEA errors logged.
- Not yet verified: repeating the unlock on a second boot, behavior after a normal restart or sleep (the unlock is re-applied every boot by design).

## 2026-10-25 - release-only test image (RELEASE.EFI)

- internal-boot/boot/handoff.c, build-release.ps1, unlock/machine-profile.h: new `GU_RELEASE_ONLY` build (with `GU_FULL_UNLOCK`). It runs the full driver release and verification and then starts Windows. It does not load or contain the unlock application and writes nothing to the card (the only register-level change is restoring the original PCI decode bits). The compile guard still refuses every other write-capable build, and refuses the release-only flag combined with any unlock mode.
- Console-detach message now names the RTX 3060.

## 2026-10-25 - benchmark made card-agnostic for the RTX 3060

- benchmark/: the compute benchmark now selects the RTX 3060 (bus 1) instead of a 3090; the runner no longer requires exactly one NVIDIA GPU (the console adapter is ignored) and the build uses VS2022 build tools. The 3070 Ti variant was removed. CUDA 12.6 components are downloaded hash-verified into benchmark/packages (git-ignored).

## 2026-10-25 - the unlock program's own host tests now run against this machine's real data

- tests/test_checks.c, test_preflight.c, test_efi_transaction.c, test_experimental.c, test_sha256.c: stale values from the original author's machines replaced by the profile (console adapter path, bus and BAR end, 12 GB layout, this card's FWSEC image size 0xed00 and DMEM 0x980 loaded as 0xa00). New tools/make_capture_report.py converts a diagnostic capture into the report these tests read.
- Result with the real PROM, PCI config and firmware files: all five suites pass (46 + 244 + 17 + 112 scenarios + the entry-latched integration). Write-enabled firmware builds stay blocked at compile time.

## 2026-10-25 — real video BIOS replay on the reference machine

- Diagnostic (probe.c) saves the 1 MiB PROM window next to its log; test_full.c passes 9,032 checks with the real PROM, config, handle graph and nvgop image;
  new tests/test_real_prom.c parses a captured PROM with the project's FWSEC parser and checks the DMEM alignment rule (this card: DMEM 0x980 -> 0xa00).

## 2026-10-25 — fix for RTX 3060 10de:2544 (non-LHR GA106) FWSEC DMEM alignment, from upstream pull request #115

- internal-boot/unlock/vendor/unlock_610.c, `unlock_transaction_fwsec()`: this card's FWSEC image has a DMEM size of 0x980, which
  is not a multiple of 256. Falcon DMA moves 256-byte blocks, so the unmodified code rejected the load with -EINVAL after the
  firmware-started barrier was set, which upstream reports leaves the card stuck until a power cycle. The fix (written upstream by
  lerpongn in Zagitta/gpu-unlock pull request #115, not yet merged there) rounds the DMEM transfer up to 256 bytes, zero-pads and
  enlarges the buffer when needed, and validates the IMEM/DMEM DMA geometry before bus mastering and before the started barrier, so an
  unloadable layout fails cleanly. Adapted to this tree: the validation sits before the entry-selector check, and sizes are logged with
  %#x. The fwsec buffer size recorded for freeing is now the allocated size.
- New regression cases in internal-boot/unlock/tests/test_transaction.c (modes 10 and 11, synthetic fixture): an unaligned DMEM size must
  start the firmware with the rounded size; a misaligned IMEM target must fail with -EINVAL before bus mastering or firmware start.
  Control run: the same test fails (exit 1) against the unpatched code and passes (exit 0) with the fix.

## 2026-10-25 — converted to a single-machine copy for the RTX 3060 / MSI MEG Z790 GODLIKE PC

- machine-profile.h now holds only this machine (target RTX 3060 10de:2544, console adapter RTX 5070 10de:2f04, MSI firmware
  console drivers, nvgop-ga1xx). The profiles of the original author's machines were removed from this copy.
  Freestanding builds that can write to the card are blocked with a compile-time error until the release path is complete.
- Renamed to this machine: GU_EXPERIMENTAL_3090 -> GU_EXPERIMENTAL_UNLOCK, folder/output names RTX3090-* -> RTX3060-*
  (boot-partition log folder is now \RTX3060-UNLOCK), GU_AMD_* / Amd* identifiers -> GU_OTHER_GPU_* / Other*,
  test files test_3090_preflight.c / test_3090_experimental.c / test_transaction_3080.c -> test_preflight.c /
  test_experimental.c / test_transaction.c, build and installer scripts reduced to the single profile z790-3060,
  messages that named an AMD display or an RTX 3090 now name the RTX 5070 / RTX 3060.
- Not renamed on purpose: copyright and credit lines, THIRD_PARTY_NOTICES.md, the history in CHANGES.md, NVIDIA's firmware
  file names (gsp_ga10x.bin, *_ga102.bin; the code opens them by name), the frozen v0.6 reference snapshot under
  tests/reference, and the original author's own records (evidence/, release/, docs describing his machine).
- Verification: console prepare test 291 checks pass against the captured graph of this machine; display-path test passes;
  research analyzer tests pass; read-only diagnostic rebuilt and redeployed.

## 2026-10-25 — diagnostic-only profile for RTX 3060 / MSI MEG Z790 GODLIKE (NOT hardware-verified)

- Added `-DGU_PROFILE_Z790_3060_DIAG` to internal-boot/unlock/machine-profile.h and a
  `z790-3060-diag` option to internal-boot/Configure.ps1,
  internal-boot/boot/build-diagnostic.ps1 and the identity table in
  internal-boot/install/headless-package.ps1. It defines only identity values read
  from Windows (PCI 10de:2544 at 01:00.0, subsystem 1462:397d, BAR0 0x85000000,
  board MS-7D85, BIOS 1.I0). Every other constant is deliberately undefined, and
  any unlock build flag against this profile is a compile error.
- Console-adapter parametrization (all profiles): the "other" display adapter that keeps the
  console while the target RTX is released was hard-coded to the original machine's AMD iGPU
  (bus 12, ID 1002:164e, subsystem 1043:8877, root port 00:08.1, ADR 0x80010300). It is now
  read from `GU_OTHER_GPU_*` in machine-profile.h, with those AMD values as the default.
  Changed: internal-boot/unlock/machine-profile.h, port.h (GU_AMD_ID/GU_AMD_SUBSYSTEM now alias
  the profile values), checks.c (GuDisplayPath route 1), app.c (AmdGopParent bus) and
  internal-boot/boot/prepare-console.c (AmdPath, PciFor). Verified with llvm-objdump that the
  compiled code and data of port.c, checks.c, app.c and prepare-console.c are identical for
  the default and the b660m-3070ti profiles. New host test
  internal-boot/unlock/tests/test_other_gpu_path.c (44 cases) covers the z790-3060-diag profile,
  where the console adapter is an RTX 5070 (10de:2f04, bus 2, root port 00:01.1, ADR 0x80010390).
- Status: builds as a read-only diagnostic. It has NOT been booted on hardware yet.
  No unlock path exists for this profile. Do not treat it as support for the RTX 3060.
- Contributors: changes by Sargentmajord (with assistance from Claude, an AI coding
  assistant). Upstream work: Zagitta/gpu-unlock, impacifist/Windows-GPU-UNLOCK and
  its upstream rough2515-hub/rtx3080-unlock-public; see THIRD_PARTY_NOTICES.md.

## 2026-10-24 — v0.3.1 variable headless display-child discovery

- Fixed preflight rejection when ASUS firmware exposes three RTX display
  children instead of exactly two. The wrapper now discovers and validates up
  to four unique RTX display children, then releases each guarded EDID
  connection before the NVIDIA GOP.
- The rebuilt wrapper completed automatic unlock and Windows handoff on the
  same system. The user observed the RTX display go dark during release and
  return after Windows started. No new performance benchmark was run for this
  build.
- Release remains source-only. Do not publish local EFI binaries, firmware,
  PROM captures, raw boot logs, partition identifiers or machine-local config.

## 2026-10-24 — GA104 RTX 3070 Ti machine profile (second verified machine)

- Added compile-time machine profiles in internal-boot/unlock/machine-profile.h:
  -DGU_PROFILE_B650M_3090FE (default, original verified machine) and
  -DGU_PROFILE_B660M_3070TI. PCI/subsystem, BAR0, chip/VRAM, PROM, root-port,
  display-path and all EFI driver fingerprints are profile constants; a build
  remains exact-machine and a user-editable file never selects them.
- New aggregate-console headless topology (GU_CONSOLE_AGGREGATE) for hosts
  without a second display GPU: nvgop owns the target PCI function, the AMI
  GOP combo splitter serves the console through an aggregate GOP, and the
  wrapper releases the nvgop/EDID/combo/text chain instead of the two-child
  nvgop console used on the B650M profile.
- Hardware verified on TUF GAMING B660M-E D4 BIOS 4003, i7-12700F, MSI
  RTX 3070 Ti: one headless unlock transaction, direct Windows start with
  display recovery, cuBLAS GEMM n=4096 medians FP16 88.7 / BF16 88.6 TFLOPS.
  S3 sleep still invalidates the unlock; no resume path exists.
- internal-boot/unlock/build.ps1, research/headless/build-unlock.ps1,
  Configure.ps1 and Headless.ps1 take -HardwareProfile (default b650m-3090fe);
  installer board/BIOS gates follow the built package profile. The B650M
  profile keeps its original code paths and constants behind the same checks.
- Added a read-only diagnostic probe (probe.c, -DGU_DIAGNOSTIC_PROBE) used to
  fingerprint new platforms; it performs no writes and is compiled into
  diagnostic/headless wrapper builds.

## 2026-10-24 — v0.3.0 headless internal handoff, public setup and recovery

- Verified one internal headless boot on the exact ASUS BIOS 3057 / RTX 3090 FE
  system: RTX GOP 1 → 0, one successful unlock transaction, direct Windows
  return and three Tensor benchmark trials. FP16/BF16 medians were
  124.969948/128.931534 TFLOPS. No active AMD display was required; the CPU
  still has an iGPU, and other boards/CPUs/headless USB are not validated.
- Added a separate headless compile profile: two reviewed EDID children, exact
  NVIDIA ownership release, zero-physical-GOP policy, file-only child logging,
  TPL-protected observations and original PROM/cold/containment/cleanup gates.
- Added public configuration/build provenance, stage/register/confirmed automatic
  promotion and Windows-first recovery. Registration preserves default priority;
  promotion explicitly orders Headless then Windows and saves Fast Startup
  recovery data before mutation. Source/include/config/asset contracts are rechecked.
- Rewrote English/Korean README and setup guides, retained distinct legacy USB
  and AMD-display paths, and published sanitized headless evidence. Firmware,
  PROM/BIOS, private partition configuration and generated EFI images stay local.
- Original manual child, automatic child and automatic wrapper EFI hashes remain
  identical. Public installer mutation paths are mock-tested; cross-machine
  registration, repeated cold-boot reliability and sleep/resume remain unverified.

## 2026-10-23 — v0.2.0 internal handoff and experimental automatic boot

- Added a separate `internal-boot/` source tree; original USB release source and EFI remain unchanged.
- Reviewed RTX console/EDID/GOP release, original IO/MEM restoration without BME, and direct Windows handoff. Original unlock transaction and card guards retained.
- Discovered display ADR per boot while pinning PCI ancestry, GPU identity and subsequent whole-path checks. Allowed only old CED/URD status clearing after successful unlock; other config changes still fail.
- Added precise handoff failure stages and config differences. Internal manual handoff and Tensor performance were verified on one BIOS 3057 system.
- Added a separate compile-time automatic child with two Esc windows, strict input failures, fresh hardware gates and rejection of unexpected owners. Automatic firmware boot remains unverified.
- Added local partition configuration, builds, stage/manual/automatic/recovery scripts and bilingual walkthroughs. Private partition GUIDs, firmware/PROM and raw boot graphs are excluded.
- Public-source builds reproduced all four locally installed EFI hashes. Public installer registration/promotion remains experimental; host and policy tests are not hardware evidence.

## 2026-10-23 — International documentation and compatibility inventory

- English default README and complete English USB, assets, build, compatibility, benchmark and results guides; Korean README and guides remain available through language links.
- Added a local read-only Windows model/version inventory and manual compatibility issue form. Private identifier fields and PnP instance suffixes are excluded; reports never authorize unlock.
- Added a staged portability design distinguishing host discovery, GPU policy, software tests and hardware evidence. This update adds no new write-enabled EFI profile or hardware support.
- USB package readme links both languages. Refreshed the public source inventory for these documentation/tool additions; successful EFI and its corresponding C/header hashes are unchanged.

## 2026-10-20 — Windows GPU UNLOCK public case study

- Base: rough2515-hub/rtx3080-unlock-public at a08254d269af30ace9e57237abd3d8e6c261e8f5; original core and licenses retained.
- Local changes made 2026-10-19/20: exact RTX3090 24GiB and AMD iGPU identity checks, memory layout, firmware ownership/PCI access checks, default read-only mode, explicit experimental profiles, immutable entry-selector latch and one SS1 write for entryLatchedSs1Full, phase guards, corresponding host mock tests.
- Modified upstream files: unlock/app.c, app_io.c, build.ps1, checks.c, checks.h, port.c, port.h, test-all.ps1, tests/test_app.c, test_checks.c, test_efi_transaction.c, test_master_attributes.c, test_pe.py, test_port.c, test_sha256.c, vendor/unlock_610.c. Additional RTX3090 tests are under unlock/tests/.
- Public packaging only: portable LLVM defaults, configurable MSVC environment and PE negative tests that inspect the selected profile rather than requiring a separate preflight build; no further GPU transaction changes. Success EFI is tied to hashes of the corresponding C sources and headers. Changed source files carry dated notices; C notices share an existing line to preserve diagnostic __LINE__ values and reproduce the successful EFI byte for byte.
- Added Korean USB/ASUS boot handoff guide, measured results and benchmark sources. Changed benchmark device selection to RTX3090, added inspect-only mode, and kept the original GEMM helper/measure path.
- The release deliberately excludes NVIDIA firmware, drivers, CUDA DLLs, original PROM dumps, private paths, credentials and unrelated repositories.
- Direct Windows chainload and internal disk automatic boot are not implemented.
