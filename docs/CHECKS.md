# Pre-flight checks (what the script verifies before it changes anything)

Every check is read-only. Each has an ID, the same ID is printed by the script and used in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md). A failed check stops the script with a plain-words message; there is no way to
skip a check. "Verified here" means the command was run on the reference machine (MSI MEG Z790 GODLIKE, Windows 11).

| ID | What is checked | How (PowerShell) | Passes when | If it fails the script says |
|---|---|---|---|---|
| C01 | Administrator | `([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')` | True | Open PowerShell with "Run as administrator". |
| C02 | Windows 11 x64, UEFI mode | `bcdedit /enum '{bootmgr}'` shows `path \EFI\Microsoft\Boot\bootmgfw.efi` (verified here); `Confirm-SecureBootUEFI` throws "Cmdlet not supported on this platform" on legacy BIOS. (The registry value `PEFirmwareType` and `$env:firmware_type` are not reliable: the first was empty on the reference PC.) | `.efi` path | The PC boots in legacy (CSM/BIOS) mode. Switch the boot mode to UEFI. Changing this can stop Windows booting; read your board manual first. |
| C03 | **Secure Boot is OFF** | `Confirm-SecureBootUEFI` (needs admin) -> `False`. Also `msinfo32` -> "Secure Boot State: Off" | False | Secure Boot is on. The unlock program is not signed, so the firmware refuses to run it. Turn Secure Boot off in the BIOS (see TROUBLESHOOTING T03). Note: games with kernel anti-cheat (Battlefield 6, Call of Duty, Valorant, FACEIT) need Secure Boot ON. |
| C04 | **BitLocker / device encryption is OFF and the drive fully decrypted** | `manage-bde -status C:` -> "Conversion Status: Fully Decrypted", "Protection Status: Protection Off" (verified here) | both | The drive is encrypted. Turn off BitLocker / Device encryption in Windows, wait until decryption finishes, then run again. Changing boot settings with BitLocker on can trigger the recovery-key screen. |
| C05 | GPT system disk with an existing Windows EFI partition | `Get-Disk`, `Get-Partition` (partition type System, GPT type `{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}`) | GPT + ESP present | The disk is MBR, or Windows is not booted from a GPT/UEFI disk. Not supported. |
| C06 | Room for a dedicated EFI partition (2 GiB) | `Get-PartitionSupportedSize -DriveLetter C` (SizeMin below current size by at least 2 GiB) | yes | Free up space on C: (the script shrinks C: by 2 GiB; it never moves or deletes files). |
| C07 | Target card is a supported RTX 30 series | `Get-PnpDevice -Class Display` -> `PCI\VEN_10DE&DEV_xxxx` in the accepted list below | yes | The card is not on the supported list. |
| C08 | Not a laptop / virtual machine | `Win32_SystemEnclosure.ChassisTypes` (3 = desktop on the reference PC; laptops report 8, 9, 10 or 14), and `Win32_ComputerSystem` manufacturer/model not VMware, VirtualBox, QEMU or Microsoft Virtual Machine. Do not use `HypervisorPresent`: it reads True on the reference PC (real hardware) because of Windows security features. | desktop | Laptop and hybrid-graphics PCs and virtual machines are not supported (upstream reports unlocks with no speedup on laptops). |
| C09 | A second display adapter exists | `Get-PnpDevice -Class Display` count >= 2 (any vendor: iGPU or another card) | yes | The target card would be the only display adapter. Not supported yet. Enable the motherboard's integrated graphics or add another card. |
| C10 | Target card is in its default state | `nvidia-smi` shows one GPU per card, no overclock tools holding it | yes | Close GPU tuning tools and run again. |
| C11 | Windows Fast Startup / hibernate is off | `powercfg /a` lists "Fast Startup" as available; registry `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled` (it was 1 on the reference PC) | 0 (or hibernate off) | Fast Startup makes "Shut down" a hibernate, not a cold boot. The script offers `powercfg /h off`. |
| C12 | Prerequisites present or installable | LLVM 20.1.8 (`clang --version`), Python (`py -0p`), Windows SDK + MSVC build tools (`vswhere`) | yes | The script offers to install each (with the download size) and waits for your OK. |
| C13 | No pending reboot / queued one-shot boot | `bcdedit /enum {fwbootmgr}` (no `bootsequence`), Windows first in `displayorder` | yes | Restart Windows once and run again. |
| C14 | Internet reachable for the NVIDIA inputs | HTTPS to the pinned download URLs | yes | The firmware inputs are downloaded and checked by SHA-256; no internet, no assets. |

## Checks made after the diagnostic has run once (from the capture)

| ID | What | Passes when | If it fails |
|---|---|---|---|
| K01 | Capture is complete and targets the chosen card | `capture-complete=1`, target found exactly once, PCI config read succeeded | Run the capture again. |
| K02 | **The target card has a display output at boot** | the capture lists a GOP whose device path is behind the target's root port | Attach a monitor, a wireless HDMI adapter or an HDMI/DisplayPort dummy plug to the target card and capture again. This differs between boards and cards: on the reference machine the card had no display output at all until something was plugged into it. |
| K03 | Target PCI configuration is well-formed | `GuCheckConfig` accepts the 256-byte config (capability list walk) | Unfamiliar card layout; stop. |
| K04 | Cold-state registers look like an untouched card | chip register family, memory size register, the fixed values at offsets 0x118128 / 0x118234 / 0x110100 / 0x1fa828 / 0x823804 | The card is not in its default state (already unlocked, overclocked, or an unsupported variant). Power the PC off completely and capture again. |
| K05 | The console adapter exists and its outputs are served by the same two firmware console drivers as the target's | handle graph rule | Unfamiliar firmware layout; the script prints which rule failed. |
| K06 | No unexpected driver holds the target's handles | handle graph rule | Same. |
| K07 | The target's NVIDIA display driver is the `nvgop-ga1xx` image and its fingerprint is recorded | image name + code hash | A different VBIOS/firmware; the profile is generated from this capture. |
| K08 | EDID driver present or absent | an active (BY_DRIVER) holder of the EDID protocol on the display handles | Not a failure: sets the profile option automatically. |
| K09 | Host replay test passes on the capture | the console and display-path tests pass against the PC's own capture | A rule failed; the script prints which scenario. |

## Supported target cards (from the upstream accepted-ID list)

GA102: 0x2200, 0x2203, 0x2204, 0x2205, 0x2206, 0x2207, 0x2208, 0x220a, 0x220d, 0x2216, 0x222b, 0x222f.
GA104: 0x2480, 0x2482, 0x2483, 0x2484, 0x2486, 0x2487, 0x2488, 0x2489, 0x248a, 0x248c, 0x248d, 0x248e, 0x249c, 0x249d, 0x249f, 0x24a0, 0x24a4, 0x24ac, 0x24ad, 0x24af, 0x24bf, 0x24c0, 0x24c7, 0x24c8, 0x24c9, 0x24dc, 0x24dd, 0x24df, 0x24e0.
GA103 (untested): 0x2414. GA106: 0x2501, 0x2503, 0x2504, 0x2505, 0x2507, 0x2508, 0x2509, 0x252f, 0x2544.
Source: `kernel/gpu_unlock/main.c` on the `main` branch of Zagitta/gpu-unlock (checked 2026-10-25; the older commit this fork is based on matches only the RTX 3090). Being on the list does not mean it works: for example RTX 3060 `10de:2544` needs an
upstream fix that is not merged yet (pull request #115), and some laptop and OEM variants unlock with no speedup (issues #124, #28).
