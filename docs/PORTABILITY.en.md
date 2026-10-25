# Portability design and validation gates

[README](../README.md)

This is a staged design, **not a declaration of expanded EFI support**. The present implementation and successful-case binary remain exact-machine experiments. Universal execution across all GPUs or firmware cannot be promised from the available evidence.

## Separate host portability from GPU support

An ASUS motherboard or AMD CPU is not inherently the unlock algorithm. They currently appear in hardcoded platform and display assumptions. Intel hosts, other motherboard vendors and additional display topologies can be investigated independently of the GPU transaction. AMD Radeon and Intel discrete targets would need separate unlock implementations; this repository only contains the NVIDIA GA102 transaction used for the RTX 3090 case.

| Layer | Current binding | Proposed direction | Required evidence |
|---|---|---|---|
| Device discovery | GPU BDF `01:00.0` in `GuCheckConfig` and `GuTargetConfig` | Enumerate PCI candidates and require one explicit, unambiguous match | Different segments/BDFs, duplicate candidates and read failures |
| BAR access | `GU_BAR0_BASE`, `BarCheck` descriptor/base checks | Validate descriptor type, size, bounds and alignment; latch the discovered resource | 32/64-bit descriptors, overflow, truncation, relocation and identity rechecks |
| Display isolation | `GuDisplayPath`, `AmdGopParent`, `DisplayCheck` pin one AMD path | Resolve GOP ancestry to the actual PCI device; prove it is separate from the target | Intel/AMD GOPs, console forwarding, malformed paths and target-owned display rejection |
| GPU policy | PCI/subsystem/revision, chip/VRAM/PROM and firmware identities | Reviewed device profiles with fixed provenance and state/selector rules | Identity, PROM, firmware, memory/WPR layout and cold-state mismatch rejection |
| Transaction containment | Ownership, decode restoration, BME, DMA, FLR and cleanup | Preserve guards and bind every phase to the same latched device/profile | Fault injection, timeouts, cleanup failure, retained resources and no retry in the same boot |
| Windows handoff | Return to ASUS firmware, manual no-reset Boot Override | Document verified firmware routes; investigate direct chainload separately | No-reset behavior, failure handling and Windows driver recovery on each platform |

The executable sources are [`port.h`](../internal-boot/unlock/port.h), [`port.c`](../internal-boot/unlock/port.c), [`checks.c`](../internal-boot/unlock/checks.c), [`app.c`](../internal-boot/unlock/app.c), [`ownership.c`](../internal-boot/unlock/ownership.c) and [`vendor/unlock_610.c`](../internal-boot/unlock/vendor/unlock_610.c). In particular, `ConfigCheck` pins additional PCI dwords, while `ColdCheck` and `PromCheck` impose independent state and identity requirements. Removing AMD IDs or changing BDF/PROM constants would leave these other assumptions unresolved.

## Stages

1. **Inventory and international documentation — implemented here.** English/Korean entry points, public Windows inventory, a manual compatibility issue form and explicit evidence limits. The inventory never authorizes unlock.
2. **Generic pre-boot diagnostic discovery — planned.** Add a separate non-arming diagnostic path. Report candidates, GOP ancestry and resource descriptions without releasing a driver, changing PCI/MMIO, enabling bus mastering, allocating DMA or resetting a device. Existing default preflight is still machine-specific and does not satisfy this stage.
3. **Reviewed platform and GPU profiles — planned.** Separate resource discovery from GPU identity/layout/firmware policy. Unknown or ambiguous profiles remain non-arming. Latch device/resource identity for the transaction and recheck it after ownership changes. A user-edited configuration file must not grant write eligibility.
4. **One new hardware configuration at a time — hardware evidence required.** Prefer host/display portability for the existing GPU family before adding different GPU models. Preserve the old verified case and review positive/negative host tests before any separately authorized hardware experiment.
5. **Broader distribution — evidence required.** Publish a compatibility matrix keyed by EFI/source hashes, GPU/subsystem/PROM/firmware profile, motherboard/BIOS, display route and Windows driver/build. Record reports, mock-tested profiles and hardware-verified profiles as distinct statuses.

## Acceptance criteria before expanding a write-enabled EFI

- Unknown device, invalid read, malformed path, unsupported layout or multiple candidates must not arm, write PCI/MMIO, enable BME, release ownership, allocate DMA or trigger FLR.
- Discovery may vary BDF/BAR location, but identity, descriptor bounds and snapshot consistency remain enforced. Changes during the transaction fail closed.
- Display verification must establish independence from the target GPU. Merely finding another GOP or matching a vendor name is insufficient. No-iGPU, multi-GPU and hybrid laptop paths need explicit designs.
- Profile tests cover wrong subsystem/revision, PROM/firmware digest mismatch, invalid cold state, selector changes and memory/WPR bounds. Default and unknown profiles remain non-writing.
- Preserve one-shot confirmation, phase guards, timeout/retry containment, driver ownership, decode restoration, DMA lifetime, FLR cleanup and `STOP / POWER OFF` on unsafe return.
- Preserve the existing negative cases in `test_checks.c`, `test_port.c`, `test_preflight.c` and related transaction/ownership tests. Change expectations only when a replacement invariant is implemented and independently verified.
- A mock pass is software evidence. Hardware support needs exact build/profile provenance, complete cleanup, Windows driver recovery and controlled before/after measurements. Stability and real-application performance require their own evidence.

No hardware support is added by a model-name match, an inventory submission or a successful build. Firmware redistribution rules and existing licenses still apply.
