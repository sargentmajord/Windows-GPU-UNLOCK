# Universal installer: design notes and requirements

Goal: one script a stranger runs on their own PC. It checks the PC first (read-only), detects the hardware,
runs the read-only diagnostic once, fills in that PC's profile automatically from what the diagnostic recorded,
builds a version for that PC and tests it against its own capture before anything else happens. No maintainer
support should be needed: the script follows general safety rules, not a list of machines.

## Requirements collected so far

1. **Compatibility check before anything changes.** Windows 11 x64 in UEFI mode, Secure Boot state, BitLocker state,
   administrator rights, a GPT disk with room for a dedicated 1 to 2 GiB EFI partition, a supported target card
   (RTX 30 series, PCI IDs from the upstream accepted list), and a second display adapter. Each failure is reported
   in plain words with what to try.
2. **A display must be attached to the target card.** On the reference machine the firmware created a display
   output (GOP) for the second graphics card only when a display (a monitor, a wireless HDMI adapter or an
   HDMI/DisplayPort dummy plug) was connected to it; without one the card had no display output at all. This may differ
   between motherboards, graphics cards, firmware versions and operating systems. The script must:
   - say so in the README and in the first screen of the script;
   - look in the capture for a display output on the target card;
   - if there is none, tell the user to attach a display or dummy plug to the target card and capture again, instead of
     assuming either way.
3. **Mixed graphics cards.** The console adapter (the one that keeps the screen working while the target card is released)
   may be another NVIDIA card (reference machine), an AMD or Intel integrated GPU (the original author's machine used an AMD
   integrated GPU), or an AMD or Intel discrete card. The profile therefore stores the console adapter's PCI ID, bus, root port
   and display path as data read from the capture, never as a vendor assumption. The safety rule is vendor-neutral: the
   console adapter's text and graphics outputs must be served by the same two firmware console drivers as the target's,
   and the console adapter must stay untouched (its edges before and after must match). Only the target card must be an
   NVIDIA RTX 30 series card. If the rule fails the script stops and says which part differed.
4. **EDID driver is detected, not assumed.** EDID is the monitor's identity data. The original author's firmware had a driver
   bound to it; the reference machine's firmware does not. The profile generator sets "no EDID driver" when the capture shows
   nothing but passive readers of the EDID protocol.
5. **No override switch.** There is no "ignore the checks and continue" option.
6. **Recovery without a maintainer.** Windows stays first in the boot order, each test boots once, there is a rollback (requirement 12), and every
   refusal writes a report file that can be posted in a public issue.
7. **Records of other machines are not rewritten.** Anything that came from another person's PC is either removed or kept
   clearly labelled as theirs.
8. **One command, resumable.** The user always runs the same script (`Install-GpuUnlock.ps1`). It keeps a small state file, works out
   the next phase itself (check, capture, build and test, back up and stage, first unlock, verify, optional automatic mode) and
   prints "restart now, then run this same command again" where a restart is unavoidable. Running it twice or out of order cannot
   break anything. The existing scripts become its internal phases.
9. **The boot partition is always the user's choice.** If the PC has no suitable dedicated FAT32/ESP-type partition (1 to 2 GiB), the
   script lists the options it found and **asks which one to use**: (a) shrink the C: drive to make room, or (b) use an existing
   alternate drive or partition, if one is available. It never picks for the user, never defaults to either option, never uses an
   alternate drive without asking even when one is available, and never shrinks C: without an explicit, separate confirmation that shows the
   exact sizes and changes beforehand. Declining both stops the script with nothing changed. An existing, correctly typed dedicated
   partition is the only case where nothing needs to be asked, and the script still shows which partition it will use.

10. **The installer can restart the PC, only with the user's confirmation.** The script needs administrator rights and checks for them at
    the start; if it is not elevated it says so and offers to relaunch itself elevated (the user still approves Windows' own prompt).
    Where a restart is needed it first tells the user to save and close their work, then asks "Restart now? (Y/N)". Only an explicit
    Y starts it: `shutdown /r /t 30 /c "<reason>"`, with the countdown shown and the abort command (`shutdown /a`) printed, so the user can
    cancel during the countdown. N prints "restart when you are ready, then run this same command again". There is no silent or
    unattended restart option. Syntax per
    [Microsoft's shutdown reference](https://learn.microsoft.com/windows-server/administration/windows-commands/shutdown).
11. **Optional automatic resume after the restart, only with the user's consent.** At the first restart the script asks "Continue
    automatically when you log back in? (Y/N)". Y writes one value under `HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce` that
    starts the same command with its saved state. Windows runs a RunOnce entry once at the next log-on and removes it
    ([Microsoft: Run and RunOnce keys](https://learn.microsoft.com/en-us/windows/desktop/SetupApi/run-and-runonce-registry-keys)); the script
    uses the `!` prefix so the entry is kept until the command finishes successfully. It is a current-user registry value, not a scheduled
    task, service or startup file, and it is not elevated by itself: the resumed script asks for administrator approval again through
    Windows' own prompt. Rules: (a) it is created only after a Y, never silently; (b) every phase that needs another restart registers a
    fresh one, and the final phase deletes any remaining entry, prints "All done", waits for Enter and exits; (c) a failure or refusal
    deletes it too and leaves the report file, so a broken install never relaunches itself on every log-in; (d) `Rollback` (requirement 12) and the state-file
    cleanup remove it, and the script checks for and reports a leftover entry at the start of every run; (e) N means nothing is
    registered and the user runs the same command by hand.
    **The resumed script always opens a visible window and asks first.** After log-in it shows a dialog ("Windows GPU Unlock installer: step 3
    of 6 is ready. Continue?" with Yes and No), using the .NET message box that ships with Windows PowerShell, with a console prompt as the
    fallback. It changes nothing until the user clicks Yes (Windows then shows its administrator prompt). No closes it, deletes the
    RunOnce entry and prints how to continue by hand later. It never continues in a hidden window. The dialog also has a **Roll back** button (requirement 12).

12. **Rollback at any point.** Every run offers "Continue", "Roll back" and "Exit" (the resume dialog has the same three choices), and
    `Install-GpuUnlock.ps1 -Rollback` does it directly. The installer keeps a journal of every change it makes, written before each change
    (what, where, and the hash or previous value), so rollback removes exactly what the installer made and nothing else. It undoes, in
    reverse order and only for the phases that actually ran:
    - the resume entry (RunOnce) and any pending one-time boot (BootNext);
    - firmware boot entries it created, and the boot order, restored from the saved backup so Windows is first;
    - the Fast Startup setting, restored to its saved value;
    - the files it copied to the boot partition (a file is deleted only if its hash still matches what the installer wrote; a changed
      file is left and reported), and the empty folders it created;
    - automatic mode (the unlock stops being applied at the next boot);
    - its working files and state file, keeping the report/log files unless the user chooses to delete them too.

    Items that need a decision are asked, never assumed: the locally generated NVIDIA firmware files (keep or delete), and a partition
    the installer created or a C: shrink it performed (re-extending C: is offered with the exact sizes shown and a separate confirmation;
    an alternate drive it only wrote files to needs nothing). Nothing the user owned before the install is deleted. The graphics card needs
    no rollback: nothing is written to its stored firmware, and a power-off clears the unlock. When it finishes, rollback re-reads the boot
    order, Fast Startup value and boot partition, compares them with the backup, prints a plain checklist ("removed / already gone / left
    because it changed") and offers a restart only if one is needed.

13. **A before-and-after benchmark is part of every install by default; the user may opt out, and is strongly advised not to.** The user is told about it before anything starts, in the
    first screen and in the README: it runs three matrix-multiply trials on the target card (about a minute of full load), once before any
    change and once after the unlock, then prints a plain comparison and a verdict. Rules:
    - **Disclosed download.** The benchmark needs NVIDIA's CUDA compiler and libraries (about 470 MB, downloaded from NVIDIA's download site,
      checked against NVIDIA's published hashes, kept inside the installer's own folder, nothing installed system-wide). The script states the
      size and source and asks "Download and run the benchmark? (Y/N)". The screen says: "We highly recommend you do not skip this. The benchmark is the only way to find out whether the unlock is worth the effort of installing it on your PC." N skips the benchmark and the install continues; the final report then says "improvement not measured" and prints no verdict. The skip is recorded in the state file and the report, and the user is offered the benchmark again at the end ("run it now? Y/N") with the same size notice.
    - **Target found from the capture,** never hard-coded: the benchmark selects the target card by its PCI bus address and refuses to
      run on any other card. The console adapter and every other GPU are untouched.
    - **Fair baseline.** It requires the target to be idle (no other process using it, temperature below a limit) and tells the user which
      programs are using the card if not. It records driver version, clocks, power and temperature next to the results, and runs the
      identical program for the "after" measurement.
    - **Verdict in plain words,** from the median of three trials for FP16 and BF16 tensor math, with FP32 shown as a control that should
      not change: at least +20% "clear improvement", +5% to +20% "small improvement", under +5% "no meaningful improvement: consider rolling
      back". These cut-offs are the installer's rule of thumb, not an upstream figure. The result screen also says what the number means:
      only matrix-heavy GPU work (for example AI model prefill, training and image generation) speeds up; games, FP32 work and memory-bound
      work such as single-token LLM decode do not.
    - **Not-worth-it path.** If the verdict is "no meaningful improvement" the installer recommends rolling back (requirement 12) and offers it
      with one keypress. If the card shows no gain at all, the script also saves the benchmark and capture reports for a public issue.
    - **Local only.** Results are saved as a JSON and a text report in the installer's folder. Nothing is uploaded.
    - **Rollback hint when skipped.** Without a benchmark the installer cannot say whether the unlock helped, so its closing screen says so and reminds the user that Roll back (requirement 12) is available.

14. **Rollback is explained to the user before and after, in plain words.** The README, the first screen and the Roll back button's own
    confirmation show the same text, which must stay accurate:

    > **What Roll back does.** It undoes only what this installer changed on your PC, and nothing else. It removes the automatic-resume
    > entry and any queued one-time boot; deletes the boot entries and the files the installer added to its boot partition (only if they are
    > unchanged); puts the boot order back so Windows is first; puts the Fast Startup setting back to what it was; stops the unlock from
    > being applied at boot; and deletes the installer's working files. It keeps the report and log files unless you tell it to delete them.
    > It asks you before it deletes the NVIDIA firmware files it generated, and before it gives disk space back to C: if it had shrunk it.
    > It never touches your Windows files, your own data, BIOS/UEFI settings or the graphics card's stored firmware. Settings you changed yourself as a prerequisite, such as turning Secure Boot off in the BIOS, are not reversed: turn them back on yourself if you want them (some games' anti-cheat needs Secure Boot). After you restart,
    > the card behaves as if the installer had never run. At the end it prints a checklist of what was removed, what was already gone and
    > what it left because you had changed it.

15. **The user chooses the target card.** The installer never assumes which GPU to modify. It lists every graphics adapter it can see
    (from the PCI device list and, where present, NVIDIA's `nvidia-smi`), one line each: number, name, PCI ID and subsystem, PCI bus
    address, video memory, whether it is currently driving a display, and a verdict from the supported-card check: "supported (RTX 30
    series, ID on the accepted list)", "not supported" with the reason (other vendor, other series, laptop part, ID not on the list), or
    "cannot tell". The user picks one **supported** card by number. Rules:
    - Not even a single eligible card is picked silently: with one candidate the installer still shows it and asks "Use this card? (Y/N)".
    - Cards are told apart by PCI bus address, so two identical cards cannot be confused; the chosen bus address, ID and name are written to
      the state file, repeated on every confirmation screen and report, and re-checked at every phase. If the address, ID or the set of
      installed cards changes (a card moved or added), the installer stops and asks again instead of continuing with a stale choice.
    - Unsupported cards cannot be selected, and there is no override.
    - The target must be a different adapter from the one that keeps the screen working during the unlock (the console adapter). The
      installer lists the console-adapter candidates the same way and asks the user to confirm which one stays untouched, then checks the
      capture against that choice.
    - The benchmark (requirement 13) and every later phase act only on the chosen card; every other GPU is read-only.
    - Nothing is written to any card until the first-unlock phase, and only to the chosen one.

16. **Detect lost boot entries after a BIOS update or CMOS clear.** Firmware updates and CMOS resets often wipe the entries stored in firmware
    memory (NVRAM); the fallback file `\EFI\BOOT\BOOTX64.EFI` still boots
    ([forum reports](https://thomas-krenn.com/en/wiki/Restoring_UEFI_boot_entry_via_motherboard_replacement_or_BIOS_update)), and a BIOS update
    may re-enable Secure Boot. The status screen checks the entries, the fallback file and the Secure Boot state on every run and offers a repair.
    The profile is tied to the BIOS version, so a changed BIOS version requires a new capture.
17. **Integrity of the download itself.** Publish a `SHA256SUMS` file with each release and show the PowerShell command to compare it; also publish
    GitHub artifact attestations, checked with `gh attestation verify`
    ([GitHub CLI manual](https://cli.github.com/manual/gh_attestation_verify)). Neither replaces code signing. The scripts are unsigned, so the
    README should say what Windows may show when running them and how to check the file first.
18. **Say that power draw and heat go up.** Measured on the reference machine: the unlocked card ran about 148 W and 68 C in a five-minute
    matrix-multiply run. Upstream notes that the power limit changes the gain a lot ([Zagitta README](https://github.com/Zagitta/gpu-unlock)). The
    installer should record power and temperature in the benchmark report and tell the user.
19. **Cards that complete the unlock but gain nothing.** Upstream issue [#28](https://github.com/Zagitta/gpu-unlock/issues/28) reports an OEM RTX 3080 Ti
    that unlocks without any BF16 gain. The mandatory-by-default benchmark (requirement 13) is what catches this; the verdict screen should name
    the possibility and point to rollback.
20. **Privacy in reports.** The report file meant for public issues must not contain the Windows user name, serial numbers, MAC addresses, drive
    serials or paths under the user profile, and never the video BIOS image or firmware files.
21. **Sleep and restart limits stated plainly.** The unlock is lost on sleep and on power-off; automatic mode re-applies it only on a boot that goes
    through the firmware. Both limits go in the README and the final screen.

## Layout shapes seen so far (for the profile generator's rule checks)

| Machine | Console adapter | EDID driver | Console layer |
|---|---|---|---|
| Original author, RTX 3090 | AMD integrated GPU | yes | one console driver pair per GPU |
| Original author, RTX 3070 Ti | none (target only) | yes | aggregate splitter |
| Reference machine, RTX 3060 | RTX 5070 | no | one console driver pair owns both GPUs |