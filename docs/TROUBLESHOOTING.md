# Troubleshooting

Find your symptom or the check ID the script printed. Everything here is either something that happened on the reference
machine (MSI MEG Z790 GODLIKE, RTX 3060 + RTX 5070, Windows 11) or something reported publicly by other users (sources linked).
Nothing here is a promise that your PC behaves the same: boards, graphics cards, firmware versions and Windows builds differ.

## Before you start: what changes on your PC

- The script shrinks your C: partition by 2 GiB and creates a small separate boot partition (letter U: on the reference PC).
  It does not touch files inside C:, the Windows boot partition, your BIOS or the card's firmware.
- It does not change the firmware boot order and adds no boot entry of its own: it uses the "UEFI OS" entry the firmware makes for the boot partition, and queues a one-time boot for it. With the "every boot" option it also adds one Windows startup task that queues the next one-time boot.
- Secure Boot has to be OFF while you use this (T03). That is a security setting; see T04 for games.
- Roll back removes the startup task, any queued boot, the files and (if you agree) the partition.

## Settings that must be right

**T03 / C03: Secure Boot must be off.** The unlock program is not signed. With Secure Boot on, the firmware refuses it.
Check: run PowerShell as administrator and type `Confirm-SecureBootUEFI` (False = off), or run `msinfo32` and read "Secure Boot State"
([how-to](https://geekrewind.com/how-to-check-a-devices-secure-boot-status-on-windows-11/)). To turn it off, restart, press the BIOS key
(often Delete or F2), and look for "Secure Boot" under Security or Boot. MSI boards may expose it as "Image Execution Policy" instead
([Guru3D report](https://www.guru3d.com/news-story/oops-secure-boot-disabled-on-290-msi-motherboards.html)); menu names differ by board and
BIOS version, so look through the menus. Save and exit (F10 on most boards). After the
change, re-run the check; the script will not continue until it reads False.

**T04: games with kernel anti-cheat need Secure Boot ON.** Battlefield 6, Call of Duty (Black Ops 7 / Warzone) and Valorant require
Secure Boot, and FACEIT announced the same ([TechPowerUp](https://www.techpowerup.com/339706/call-of-duty-black-ops-7-and-battlefield-6-confirmed-to-require-secure-boot-and-tpm-2-0),
[PC Gamer](https://www.pcgamer.com/hardware/battlefield-6-requires-secure-boot-to-run-and-its-coming-to-more-games-soon-including-call-of-duty-black-ops-7-heres-what-it-is-why-linux-gamers-are-mad-about-it-and-how-to-enable-it/)).
Because the unlock program runs at every start, Secure Boot has to stay off for as long as you want the unlock. To play those games,
use the undo script, turn Secure Boot back on, and expect to repeat the setup later.

**T05 / C04: BitLocker / device encryption must be off, and the drive fully decrypted.** Windows 11 Home uses "Device encryption"
(Settings > Privacy & security > Device encryption); Pro uses Manage BitLocker
([overview](https://www.ninjaone.com/blog/turn-on-or-off-device-encryption-in-windows-11)). Some new installs turn encryption on automatically.
Check with `manage-bde -status C:`: you need "Fully Decrypted" and "Protection Off". Decryption runs in the background and can take a while.
Why: changing boot entries and boot settings with BitLocker on can trigger the recovery-key screen at startup. Keep your recovery key
somewhere safe either way.

**T06 / C11: Fast Startup.** With Fast Startup on, "Shut down" is a hibernate, not a cold boot, so the card may not reset. Turn it off
(`powercfg /h off` also disables it; check `HiberbootEnabled` under `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power`)
([guide](https://www.elevenforum.com/t/turn-on-or-off-fast-startup-in-windows-11.1212/)). One user reported `HiberbootEnabled` still reading 1 after
`powercfg -h off`; if you see that, verify with `powercfg /a`.

**T07: Boot mode must be UEFI (not CSM/legacy).** The program is a UEFI application.

## Display problems

**T10 / K02: a display must be attached to the target card.** On the reference PC the firmware created a display output for the second
card only when something was plugged into it; with nothing attached the card had no display output at all, and the capture had nothing to
work with. This may differ between boards, graphics cards, firmware versions and operating systems, so the script checks the capture
instead of assuming. If it reports no display output on the target card: plug a monitor, a wireless HDMI adapter (it counts as a display
if it presents itself to the card) or a cheap HDMI/DisplayPort dummy plug into the target card, and capture again.

**T11: the BIOS or boot screen goes to the wrong screen.** The firmware chooses the boot display card. On the reference board there was no
setting to choose it; the screen followed the card with a display attached and, with both cards on CPU slots, the lane group the firmware
numbers first. If you cannot see the BIOS: unplug the display from the target card, enter the BIOS, then plug it back. Use a cold start
instead of a restart if that helps. Swapping the cards between slots may change it; check your board manual first.

**T12: black screen for up to a minute or two during a test.** Normal while the target card's display driver is released. If the screen is
still black after about 5 minutes, hold the power button until the PC turns off, wait 10 seconds, turn it on. Each queued boot runs once and is used up
when it starts, so Windows boots normally the next time. You do not need the BIOS or a boot menu for this (on a PC whose monitor is on the other card you may not be able to see them at all).

**T13: nothing happened (the test did not run).** A start that fails for any reason (for example an unexpected trip into the BIOS) can clear the queued one-time boot, so queue it again. On the reference MSI board the boot entry made with `bcdedit` was never listed in
the firmware's boot menu and was silently skipped. A copy of the program at `\EFI\BOOT\BOOTX64.EFI` on the boot partition made the firmware
list it as a normal "UEFI OS" entry, and that entry then ran. The script uses that fallback when needed and checks which entry the firmware
actually started (`BootCurrent`) instead of trusting that the entry ran.

**T14: you cannot see the BIOS or the boot menu.** The installer never needs them for the unlock or for recovery (see T11 for why the screen can be on the other card). The firmware's boot order is not reliable here: on the reference board an order set from Windows was back to "Windows first" after a cold boot, so the installer only uses the one-time boot queue, which did survive cold boots.

## Start-up and restart problems

**T21: the unlock does not last across power-off, sleep or hibernate.** The unlock is applied again at every start. Upstream reports that S3
sleep invalidates the unlock with no resume path on the Windows port ([the original project's compatibility notes (upstream)](https://github.com/impacifist/Windows-GPU-UNLOCK/blob/main/docs/COMPATIBILITY.en.md) and [issue #5](https://github.com/impacifist/Windows-GPU-UNLOCK/issues/5)); a
Windows restart resets the card ([#10](https://github.com/impacifist/Windows-GPU-UNLOCK/issues/10)). Treat sleep and hibernate as "unlock lost; restart".

**T22: the program froze at start-up (black screen, no Windows).** The program stops on purpose, without resetting, when one of its safety
checks fails after it has already let go of the card's display driver. Power off with the button, wait 10 seconds, power on. The queued boot was used up when it started, so Windows starts normally.
The "every boot" startup task then does not queue another one until a run has finished cleanly (it writes the reason to `C:\ProgramData\WindowsGPUUnlock\arm.log`). The installer never changes the firmware boot order.

## Card and driver problems

**T30: the card is on the list but gets no speedup.** Upstream reports laptop GPUs that "unlock" with no FP16/BF16 change
([#124](https://github.com/Zagitta/gpu-unlock/issues/124)) and an OEM card where the unlock completed but BF16 stayed at half rate
([README table](https://github.com/Zagitta/gpu-unlock)). Gains also depend on the power limit (the smallest reported gains came from
cards capped at 225 W) and on the workload: matrix-heavy work (image generation, long-prompt processing) speeds up, token-by-token LLM
generation does not.

**T31: RTX 3060 `10de:2544` (non-LHR GA106) fails to unlock.** Upstream pull request #115 reports that this card's firmware image has a size
that is not a multiple of 256 bytes, so the unlock fails with error -22 and leaves the card stuck until a power cycle; the fix pads
the size and is not merged yet ([PR #115](https://github.com/Zagitta/gpu-unlock/pull/115)). The version of the code that the Windows port
uses was published on 2026-09-28 and does not contain it. This copy of the project includes the same fix (see CHANGES.md) with a regression test
that fails without it.
Cards with a 256-aligned size, such as `10de:2504`, behave the old way.

**T32: the card reports a different memory size than its label.** One report shows a 3090 Ti reading 0x5ff4 instead of 0x6000 MiB. The
script reads the register instead of computing it from the card's capacity.

**T33: cross-flashed or modified video BIOS.** The card's identity (subsystem ID, BIOS fingerprint) no longer matches what the board
was sold with. The checks compare against the capture, so a changed BIOS needs a new capture; a BIOS update on any card or board does too.

**T34: the capture is not the same after changing slots, BIOS settings or cards.** The profile pins the card's memory address (BAR0), bus
numbers, display path and the firmware's driver sizes. Moving the card, changing PCIe or Above-4G settings, updating the BIOS or adding
a PCIe device can change them. Capture again after any such change; the script detects the mismatch and refuses.

**T35: more than one monitor on the target card.** The verified runs used a single monitor on the target card. Reports with three monitors on
one card exist; they were not verified. Start with one display attached to the target card.

## Tools and downloads

**T40: LLVM must be exactly 20.1.8.** The build is only reproducible with the version the project pins. `winget install --id LLVM.LLVM
--version 20.1.8 --location C:\TOOLS\LLVM20` (needs administrator rights; a permission prompt appears and the install is cancelled if nobody clicks it).

**T41: the Windows C++ build tools and SDK are needed for the host tests** (about several GB). `vswhere.exe` must be on the PATH when
`vcvars64.bat` runs: add `C:\Program Files (x86)\Microsoft Visual Studio\Installer` to the PATH for the session.

**T42: generating the NVIDIA firmware inputs.** The five firmware files are never included (NVIDIA's terms). The script downloads NVIDIA's pinned
inputs (about 330 MB) and checks them by SHA-256. It needs Python 3.14 or newer (3.14 can read `.zst` archives itself; with older Python the
pinned tool needs a `zstd` program) and a few hundred MB of free space. Upstream notes Python 3.11 or newer is needed for other parts
([#114](https://github.com/Zagitta/gpu-unlock/issues/114)).

**T43: shell quirks seen on the reference PC.** Piping binary data through PowerShell corrupts it (use files); Git Bash rewrites `/mnt/c/...` paths
when calling `wsl`; `Get-PartitionSupportedSize` and `Confirm-SecureBootUEFI` need an elevated session.

**T44: the program does not build with a different compiler version or on a different path.** Re-run the script from a short path without spaces.

## Remote use

**T50: you need to be at the PC.** Turning Secure Boot off in the BIOS and fixing a failed start (holding the power button) need someone at the PC.
Remote tools often cannot answer Windows' administrator permission prompt, and the remote session is lost whenever the PC restarts or hangs.

## Getting help

The script writes a report (`report.json`) containing the detected hardware, which checks passed or failed and the capture summary. It
contains no serial numbers or user names. Review it before posting it in a public issue. Never post firmware images, video BIOS dumps or
BitLocker keys.
