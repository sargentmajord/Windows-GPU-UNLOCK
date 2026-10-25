# Third-party notices

English notice for this fork, written 2026-10-25. The original Korean notice from the upstream port is kept unchanged as
[THIRD_PARTY_NOTICES.ko.md](THIRD_PARTY_NOTICES.ko.md); where the two differ, this file describes what is in this repository.

## This fork

A single-machine conversion (RTX 3060 12 GB target, RTX 5070 console adapter, MSI MEG Z790 GODLIKE) of the projects below, with a different
hardware profile, new tests and documentation, a benchmark, and the fixes listed in [CHANGES.md](CHANGES.md). Changes in this fork were made by
Sargentmajord with assistance from Claude, an AI coding assistant. It is licensed **GPL-2.0-only**, like the work it builds on ([LICENSE](LICENSE)).
It is not affiliated with or endorsed by NVIDIA. No NVIDIA firmware, video BIOS (PROM) image, driver or CUDA library is included; users generate
or download those locally.

## Windows GPU UNLOCK (UEFI port) - impacifist

- Source: [impacifist/Windows-GPU-UNLOCK](https://github.com/impacifist/Windows-GPU-UNLOCK), GPL-2.0-only.
- The part of this repository under `internal-boot/` descends from that port. Per the upstream notice, its direct base is
  [rough2515-hub/rtx3080-unlock-public](https://github.com/rough2515-hub/rtx3080-unlock-public/tree/a08254d269af30ace9e57237abd3d8e6c261e8f5)
  (GPL-2.0-only). The port added checks, memory layout and the `entryLatchedSs1Full` profile for an RTX 3090 24 GiB with an AMD integrated GPU, and
  matching tests. The dates, hardware and descriptions for the earlier RTX 3080 work in the upstream history belong to that history.
- 2026-10-23 extension, translated from the upstream notice: `internal-boot/` is a separate experimental extension of the existing GPL-2.0-only
  port. It adds new console and driver hand-over, limited PCI restore and compare, automatic arming, install and recovery code, and matching checks.
  The same EDK2 headers are used from `deps/` with their license notices kept. Binary NVIDIA firmware, PROM and BIOS images are not included;
  partition-specific EFI files are built locally from the public source.
- The upstream notice also says its inclusion of a notice does not mean permission to redistribute separate firmware binaries has been confirmed.
- Removed from this fork: the original author's legacy USB implementation (`unlock/`, `release/`), his measurement records, release notes and
  guides for his own machines. They remain in the upstream repository and its history.

## GPU unlock core - Zagitta/gpu-unlock, GPL-2.0-only

- Source: [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock/tree/0ebdb1c6308b6a2072be5bf04513472942541956), pinned commit
  `0ebdb1c6308b6a2072be5bf04513472942541956`. Licence text: [LICENSE](LICENSE).
- Used in: `internal-boot/unlock/vendor/` (`unlock_610`, `prep_610`, `layout_610`, `vbios_610`, `gfw_eval`, `diagnostic.h`).
- Local changes made by the upstream port (translated from its notice): selection of the MSI RTX 3080 target, checked I/O and execution/cleanup
  state for UEFI, FWSEC diagnostics, a UEFI port with host/mock tests, Bus Master handled through PCI I/O Attributes with protocol state and the real
  PCI Command register checked together, and later public tooling and documentation clean-up (local USB package generation, a public test runner,
  relative-path build metadata). GPU execution conditions and the transaction order were kept.
- Local changes made in this fork: the FWSEC DMEM alignment fix for RTX 3060 `10de:2544`, which is the change proposed by **lerpongn** in
  [upstream pull request #115](https://github.com/Zagitta/gpu-unlock/pull/115), re-implemented here with regression tests; and the rejection of
  register-error values in the firmware-boot assessment, following the report by **odcpw** in
  [upstream issue #42](https://github.com/Zagitta/gpu-unlock/issues/42). Details are in [CHANGES.md](CHANGES.md).

## Benchmark

`benchmark/upstream-compute-benchmark.cu` and `benchmark/LICENSE` are the public benchmark source and licence from
[rough2515-hub/rtx3080-unlock-public](https://github.com/rough2515-hub/rtx3080-unlock-public/tree/a08254d269af30ace9e57237abd3d8e6c261e8f5)
(`analysis/compute-benchmark.cu`). `benchmark/compute-benchmark-3060.cu` is a modified copy for this machine.

## EDK2 headers - BSD-2-Clause-Patent

- Source: [TianoCore EDK2](https://github.com/tianocore/edk2/tree/c1415771ac592ad8509351c46cd3cda4f38d7d52), pinned commit
  `c1415771ac592ad8509351c46cd3cda4f38d7d52`.
- Used in: `deps/edk2/MdePkg/Include/`. Licence and copyright notices: [LICENSES/EDK2-BSD-2-Clause-Patent.txt](LICENSES/EDK2-BSD-2-Clause-Patent.txt)
  and the header of each file.
- The programs use the header declarations; no EDK2 library binary is linked.

## Related notices kept from the upstream project

NVIDIA source and EFI reference notices preserved by the upstream project:

- [NVIDIA MIT notice](LICENSES/NVIDIA-MIT.txt)
- [CMP40HX MIT notice](LICENSES/CMP40HX-MIT.txt)
- [NVIDIA Driver License Agreement](LICENSES/NVIDIA-Driver.txt)

When you copy the source, keep these licences and copyright notices with it.