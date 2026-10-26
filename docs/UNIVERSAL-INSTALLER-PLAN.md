# Universal installer: design notes and requirements

Goal: one script a stranger runs on their own PC. It checks the PC first (read-only), detects the hardware,
runs the read-only diagnostic once, fills in that PC's profile automatically from what the diagnostic recorded,
builds a version for that PC and tests it against its own capture before anything else happens. No maintainer
support should be needed: the script follows general safety rules, not a list of machines.

## Requirements collected so far

1. **Compatibility check before anything changes.** Windows 11 x64 in UEFI mode, Secure Boot state, BitLocker state,
   administrator rights, BitLocker and Windows "device encryption" both off (an unsigned program in the boot chain changes the TPM measurements and can trigger a recovery-key prompt; Windows 11 Home can enable device encryption by itself), a GPT disk with room for a dedicated 1 to 2 GiB EFI partition, a supported target card
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
    - the Windows startup task and its generated files (every-boot mode); the firmware boot order and the Windows boot entry are never changed, so there is
      nothing to restore there (the backup is kept, and rollback checks that Windows is still first);
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
    - **Disclosed download.** The benchmark needs NVIDIA's CUDA compiler and libraries (about 489 MB: 488,838,722 bytes in four files, downloaded from NVIDIA's download site,
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
    > entry and any queued one-time boot; deletes the files the installer added to its boot partition (only if they are
    > unchanged); checks that the boot order still has Windows first (the installer never changes it); removes the startup task; puts the Fast Startup setting back to what it was; stops the unlock from
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
    The profile is tied to the BIOS version, so a changed BIOS version requires a new capture. The unlock uses the entry the firmware itself makes for the fallback file,
    and that entry's identifier can change after such a reset, so the startup step must look the entry up again at every start instead of storing it once (see requirement 27).
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

22. **What is and is not persistent must be stated in the README and on the screen:**
    - the unlock itself is not persistent: it lives in volatile registers and is lost at every power-off and on sleep; nothing is written to the card's stored firmware;
    - the standard install queues a one-time boot, which is used up when it starts; the firmware boot order and the Windows boot entry are never changed;
    - **"every boot" adds one persistent item: a Windows startup task** (requirement 24) that queues the next one-time boot, and turns Windows Fast Startup off until it is
      rolled back. It is opt-in with the default answer **No**, offered only after an unlock has been verified, and the question says in plain words: what runs at every
      boot; that a failed check freezes the screen and the user must hold the power button and power on again (Windows then starts normally; no BIOS or boot menu is
      needed); that Fast Startup is turned off and its old value saved; and how to undo it (Roll back, requirement 12). A backup of the boot configuration is made first.
23. **The installer must never require the BIOS or the firmware boot menu, and must not assume recovery through them.** On dual-card PCs the firmware may show its own
    screens on only one of the cards, and a user with a monitor on the other card can see neither the BIOS nor the F11 menu (seen on the reference machine). So:
    - the installer finds out which card the firmware displays on (from the diagnostic capture) and states recovery steps that work for that layout;
    - recovery never relies on a menu: a freeze is recovered by holding the power button and powering on, because a queued one-time boot is used up when it starts
      (this must be proven on hardware with a deliberately hanging test image before release, requirement 29);
    - the firmware boot list may be rebuilt by the firmware at power-on (seen on the reference machine: an order set from Windows did not survive a cold boot; a
      read-only logger showed the list was already reverted before Windows started), so the installer never relies on the permanent boot order.

24. **When the unlock runs is chosen in the installer, using only the one-time boot queue.** Measured on the reference machine (2026-10-25): the firmware boot order does
    not survive a cold boot, but a one-time boot queued from Windows does, and ran the unlock from a cold boot (FP16 48.24, BF16 49.88). So the installer offers:
    - **Once**: queue one unlock for the next boot only;
    - **Every boot**: a Windows startup task queues one unlock for the next boot each time Windows starts (`internal-boot/Set-UnlockSchedule.ps1`);
    - **Off**: removes the task and any queued boot and restores the Fast Startup value saved earlier.
    The installer performs all of this itself (it elevates itself; the user does nothing outside it). The permanent firmware boot order and the Windows boot entry
    are never changed. Safety: a boot-configuration backup is made first; if a queued run leaves no report, or the latest attempt did not end clean, the startup task
    stops re-arming and says so (a freeze is recovered by holding the power button and powering on: the queue is already used up, so Windows starts normally).

25. **Three parts: the safe installer, then two optional extras offered only at the very end.**
    - **The installer (default, all safeties on):** every check, a backup, the unlock needs a deliberate keypress (U) and can be cancelled with Esc, and the benchmark
      confirms it worked. This is all a user gets unless they choose more.
    - **Extra 1, remove the keypress:** the unlock runs by itself on a boot (automatic mode; the U press is no longer needed). Offered only after the installer has
      confirmed that the unlock worked and the benchmark shows it.
    - **Extra 2, remove the countdown:** removes the two short Esc cancel windows of automatic mode, so the boot goes straight through (about 8 seconds faster).
      Offered only after Extra 1 is active and has been confirmed to work, because the countdowns exist only in automatic mode.
    - Each extra is shown on its own screen with a plain description of what it changes and what it does not change (the hardware checks stay), its warnings and a
      disclaimer (as is, no warranty, what happens on a failed check, how to recover with the power button, no cancel from the keyboard for Extra 2), and the user must
      tick an explicit accept box. Declining either leaves the installer's safe setup untouched.
    - Each extra can be switched off again later with the installer's Roll back option; the previous files are kept (the `with-esc` folder pattern).

26. **A way to unlock again after every power-off, without extras.** The unlock is lost at power-off, and the default install does not run by itself. So the installer
    creates a shortcut ("Unlock my GPU on next boot") that asks for administrator approval, queues one unlock and offers the restart (requirement 10). Without it a user
    who declined "every boot" would have to re-run the whole installer after each power-off.
27. **Look up the firmware entry at every start; never store it once.** The startup step finds the firmware's entry for the boot partition at each run (as
    `Set-UnlockSchedule.ps1` does at install time) and writes a clear line to its log if it is missing or ambiguous, instead of silently failing. The status screen
    shows the last result. (`Arm-NextBoot.ps1` currently embeds the identifier; this must change before release.)
28. **Check the startup task's own prerequisites at every start:** Fast Startup is still off (Windows feature updates can change it), Secure Boot is still off (a BIOS
    update can turn it on), and the boot partition is present. Anything wrong is logged and shown by the status screen, and the task stops queuing instead of looping.
29. **A recovery drill on hardware before any release.** Stage a test image that deliberately hangs (the same behavior as a failed check), queue it, and prove that holding
    the power button and powering on gives a normal Windows start, with no BIOS and no menu, and that the startup task then stays quiet (the circuit breaker). The on-screen
    failure text of the boot programs still says to use the Windows Boot Manager menu; change it to the power-button instruction and rebuild and retest those images.
30. **One plan screen, dry run everywhere, and tests.** Before any change the installer shows one screen listing every change it will make (files, partitions, startup
    task, settings), and the user confirms once; every phase also runs with `-DryRun`, which prints the same list and changes nothing. The installer's decision logic
    is covered by automated tests with mocked system queries, run before each release.
31. **Updates keep the user's choices.** Running a newer installer keeps the state file, journal and installed extras, shows what changed and asks before replacing the
    boot programs. A changed BIOS, card or driver triggers a new capture rather than reuse of the old profile. The old `Install.ps1` (boot-order approach) is retired.

32. **A graphical front end (requested 2026-10-25; to be built after the text installer, its tests and the user README are done and verified).** A window-based
    wizard for people who do not want a console, using only what ships with Windows PowerShell 5.1 (WinForms or WPF; no extra download). Pages: the system checks;
    choosing the target card and the screen adapter; choosing the boot partition (the typed `SHRINK` becomes a real confirmation box that shows the exact sizes); the one
    plan screen; progress bars for the long steps (downloads, the benchmark, the build and tests); the result and verdict; a Roll back button; the two extras, each on its
    own page with an accept check box; and the resume-after-login Yes / No / Roll back dialog. Rules:
    - The decision logic stays in the shared modules. The prompt functions in `installer/Ui.ps1` (`Read-Answer`, `Ask-YesNo`, `Ask-Number`, `Ask-Phrase`, `Write-Plain`)
      are the swap point: the same phases, state, journal and tests serve both front ends, and no safety rule may exist in only one of them.
    - Console mode stays available as a fallback (`-Console`) and is what the automated tests use. The launcher stays `Install-GpuUnlock.cmd`; when no desktop session is
      available (for example a remote console) it falls back to console mode by itself.
    - Same rules as the console version: every question is explicit with no default, nothing changes before the plan is confirmed, the user can always cancel or roll back,
      and the window never hides what a long step is doing.

## Status of the requirements (2026-10-26)

All 32 are implemented in the installer and covered by the automated tests, except the items below, which are deliberately not code:

- **Release-time tasks (not done, nothing is released yet):** requirement 17 (publish `SHA256SUMS` and artifact attestations with each release, and say in the README what Windows may show for unsigned scripts) and the hardware half of requirement 29 (repeat the recovery drill with the release build before each release; it was done once on the reference machine).
- **Draft for both release-time tasks:** [RELEASE-CHECKLIST.en.md](RELEASE-CHECKLIST.en.md).
- **Optional polish, not a gap:** requirement 23's first bullet (state recovery steps tailored to which card the firmware displays on). Recovery is the same everywhere and never needs a menu: hold the power button, then power on.
- **Interpretations worth knowing:** in requirement 31 "driver" is read as the firmware's display driver, which the capture records and the boot programs re-check at every start; the Windows graphics driver does not affect the profile. Requirement 16's repair for a lost firmware entry is a restart (the firmware recreates its entry from the fallback file) and putting the boot programs back; a changed BIOS or board forces a new capture.
- **Not testable on the reference machine:** other boards' firmware behaviour, a second GPU model, real winget installs and a real run of the optional extras through the installer. These are limits of the evidence, not unmet requirements.

## Layout shapes seen so far (for the profile generator's rule checks)

| Machine | Console adapter | EDID driver | Console layer |
|---|---|---|---|
| Original author, RTX 3090 | AMD integrated GPU | yes | one console driver pair per GPU |
| Original author, RTX 3070 Ti | none (target only) | yes | aggregate splitter |
| Reference machine, RTX 3060 | RTX 5070 | no | one console driver pair owns both GPUs |