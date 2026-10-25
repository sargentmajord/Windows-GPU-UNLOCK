# Optional patch: remove the two Esc cancel windows (automatic mode)

**This patch is optional, unsupported and not part of the default build.**

## What it changes

The automatic boot image normally waits twice so you can abort with Esc:

1. 5 seconds at the start (Esc boots Windows with nothing changed);
2. 3 seconds after the drivers are released (Esc stops safely).

That is about 8 seconds on every boot. This patch removes both waits, so a boot goes straight through
release → unlock → Windows. It adds a build option, `-NoEscWindows`, and changes nothing else.

## What it does NOT change

Every hardware check stays: card ID, subsystem, video BIOS hash, PCI layout, the card's clean power-on state, display
topology, driver ownership, the one-attempt rule and the stop-on-any-failure rule. A mismatch still stops the boot
before anything is written. The patch does not add any switch that skips a check.

## Disclaimer — read before applying

- This is third-party experimental software, provided **"as is", with no warranty of any kind**, under GPL-2.0-only.
  You use it at your own risk. The authors are not liable for damage, data loss, instability or a PC that does not boot.
- With the waits removed, **you can no longer cancel from the keyboard during boot.** The only ways to abort are to power
  the PC off, or to boot from another entry in your firmware's boot menu.
- If a check fails, the boot **stops on a frozen screen** (by design; it never retries or resets). You must hold the power
  button, power on again, and pick Windows Boot Manager from the firmware boot menu. If you cannot do that, do not use
  this patch.
- Do not apply it to a PC you cannot reach, to a PC you cannot recover without a keyboard, or to a machine whose only
  boot entry is the unlock image.
- Keep your own recovery path: a working Windows Boot Manager entry, and the key for your firmware's boot menu.
- It was verified only on the reference machine described in CHANGES.md. Other hardware may behave differently.
- It does not flash or modify the video BIOS. The unlock is lost at every power-off and is applied again each boot.

## Turn off Windows Fast Startup first (required for automatic mode)

Automatic mode only works on boots that run through the firmware. With **Fast Startup** on, "Shut down" is a hibernate, so
the card may not reset and the unlock may not run (see T06 in docs/TROUBLESHOOTING.md). This is Windows' Fast Startup,
not a setting in your BIOS. Turn it off before relying on automatic mode:

- **Control Panel:** Power Options → "Choose what the power buttons do" → "Change settings that are currently
  unavailable" → clear **Turn on fast startup** → Save changes
  ([steps](https://pureinfotech.com/disable-fast-startup-windows-11-10/)).
- **Or, administrator PowerShell:** `powercfg /h off` (this also turns hibernation off; undo with `powercfg /h on`).
- **Check:** `powercfg /a` should no longer list Fast Startup, or read
  `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled` (0 = off).

Windows starts a little slower with it off. The project's `Install.ps1 -EnableAutomaticBoot` also sets it to 0 and saves the
old value; this patch does not install anything, so you must do it yourself.

## Apply, build, undo

From the repository root, in an administrator PowerShell:

```powershell
.\patches\Apply-NoCancelWindows.ps1 -Clang 'C:\TOOLS\LLVM20\bin\clang.exe' -LldLink 'C:\TOOLS\LLVM20\bin\lld-link.exe' -Python 'python'
```

The script shows the disclaimer, asks you to type `I ACCEPT`, applies the patch, builds the private automatic pair and
prints the output file hashes. Nothing is installed or registered. To remove the patch again:

```powershell
.\patches\Apply-NoCancelWindows.ps1 -Undo
```
