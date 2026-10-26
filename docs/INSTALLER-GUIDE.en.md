# Using the installer

This guide is for someone who wants to try the guided installer on their own PC. It is written in plain words and it matches what the
installer does today. If anything on your screen disagrees with this page, trust the screen and tell us.

**Status.** The installer is finished enough to run end to end and is covered by automated tests, but only one PC (the reference machine
in [PROFILE-Z790-3060.en.md](PROFILE-Z790-3060.en.md)) is known to get all the way through. On any other card or board it may stop and write a
report. That is the safe direction: it refuses instead of guessing.

## What it does, in one paragraph

A small program runs for a moment **before Windows starts**, sets the tensor-math speed of one RTX 30 series card, and hands over to Windows. The
installer builds that program for your PC from a read-only capture of your own PC, tests it against that capture, puts it on a small dedicated boot
partition, runs it once, and (if you allow it) measures your card before and after so you can see whether it helped. The permanent boot order and the
Windows boot entry are **never changed**. Nothing is written to the card's stored firmware, and the unlock is lost at every power-off, so you apply it
again after each power-off (a shortcut does that for you).

## What you need first

- Windows 11, 64-bit, started in UEFI mode, on a desktop PC (not a laptop, not a virtual machine).
- **Secure Boot off**, **BitLocker / device encryption off** (fully decrypted), and **Windows Fast Startup off**. The installer checks all three and stops with
  a plain message if one is wrong; there is no way to skip a check. Games with anti-cheat that needs Secure Boot will not run while it is off.
- A second graphics adapter that keeps your screen working while the other card is being set up.
- A **display attached to the card that will be unlocked** (a monitor, a wireless HDMI adapter, or an HDMI / DisplayPort dummy plug). On some boards the
  firmware creates no screen output for a card with nothing plugged in, and the capture then cannot find it.
- Room for a 2 GiB partition (see "The boot partition" below), about 1 GB of free disk space for the downloads (several GB more if the Microsoft C++ Build Tools must be installed), and an internet connection.
- You must be able to recover from a frozen start: **hold the power button until the PC turns off, then power on.** Windows then starts normally.
  No BIOS screen or boot menu is needed, ever. If you cannot be at the PC to do that, do not run this.

## Starting it

Double-click `Install-GpuUnlock.cmd`. Windows asks you to approve administrator rights (its own prompt), then the installer opens a **window**: a scrolling log of what it is doing, the current step at the top, a bar that moves while a step works, and buttons for every question (Yes / No, numbered options, and a tick box plus Confirm where the text version asks you to type a word). No button is pre-selected and Enter answers nothing. The window cannot be closed while a step is running; it can be closed while a question is open (run the installer again to continue). The text version does exactly the same with typed answers: run `Install-GpuUnlock.cmd -Console`; it is also used automatically when there is no desktop to show a window on.

Windows asks you to approve administrator rights (its own prompt) each time it starts. The same command is used to continue later:
run it again and it picks up where it stopped. If an earlier install is in progress it asks **Continue, Roll back or Exit**.

To rehearse, run `Install-GpuUnlock.cmd -DryRun`: it asks the same questions, prints what it would do and changes nothing. `Install-GpuUnlock.cmd -Rollback` goes straight to Roll back.

## What it asks you, in order

1. **Checks.** Read-only. It lists every check with pass / fail and what to do about a failure.
2. **Which card, and which adapter is your screen.** It lists every graphics adapter it sees and you confirm the target and the screen adapter. It never assumes.
3. **Build tools.** The boot programs are built on your PC. If LLVM 20.1.8, Python 3.12 or newer, or the Microsoft C++ Build Tools are missing it offers to install
   each through winget, with the download size, and waits for your yes (the Build Tools are several GB). Tools you agree to stay installed; Roll back lists them.
4. **The boot partition** (next section).
5. **The plan.** One screen listing everything it will change and how each item is undone. You confirm once.
6. **A backup** of the boot configuration, the firmware boot entries, the partition table and the Fast Startup value, kept in the installer's folder.
7. **A read-only diagnostic** is put on the boot partition and run once at the next start. It reads your PC and writes only a log. The firmware may need one extra
   restart to notice the new partition.
8. **A profile for your PC** is made from that log and shown to you; you confirm it is your PC. If the capture does not look right the installer says exactly why and stops.
9. **NVIDIA firmware files** are generated on your PC (a disclosed download of about 343 MB, every file checked against a pinned hash; see [ASSETS.en.md](ASSETS.en.md)).
   Nothing from NVIDIA is redistributed by this project.
10. **Build and test.** The boot programs are built and seven groups of host tests replay your own capture. No hardware is touched. A failed test stops the installer; there is no skip.
11. **The benchmark.** It is offered with a strong recommendation to say yes: it is the only way to find out whether the unlock is worth having on your PC. It downloads about 489 MB of
    NVIDIA's CUDA compiler and libraries into the installer's own folder (nothing is installed system-wide), and runs a matrix-multiply test on the target card for about a minute, before and after.
    If you say no, the installer cannot tell you whether it helped, and it offers the benchmark again at the end.
12. **The first unlock.** The tested programs go on the boot partition (any file they replace is saved first), one start is queued, and you confirm the restart. At that start the unlock
    program waits for you to **press U once**. Esc, or 30 seconds with no key, cancels it and Windows simply starts.
13. **The result.** After the restart the installer reads the program's report, measures the card again and prints a plain verdict: a clear improvement (+20% or more), a small one (+5% to +20%),
    or no meaningful improvement, in which case it recommends rolling back. Only matrix-heavy GPU work speeds up (AI prefill, training, image generation). Games, FP32 work and memory-bound work do not.
    The unlocked card draws more power and runs hotter; the report records power and temperature.
14. **Unlocking again later.** The unlock lasts until the PC is powered off or goes to sleep. The installer offers a Start-menu shortcut **"Unlock my GPU on next boot"** (and, as an extra choice, a copy on the
    desktop; a desktop shortcut can be edited by any program running as you, so the Start-menu one is the safer one). Use it after each power-off: it asks Windows for administrator approval, queues one unlock and offers the restart.
15. **Two optional extras** (see below), offered last.

## Restarts

The installer restarts the PC only after you answer **Y** to "Restart now?", with a 30 second countdown and the command to cancel (`shutdown /a`). At the first restart it also asks whether to
**continue automatically when you log back in**. If you say yes it adds one entry that runs once at your next login and opens a window ("step N of M ... Continue, Not now or Roll back"). Nothing
changes until you click Continue, and Windows then asks for administrator approval. The entry is removed whenever a run ends, fails or is rolled back. If you say no, run `Install-GpuUnlock.cmd` again after the restart.

## The boot partition

The unlock program lives on a small FAT32 partition labelled `GPUUNLOCK`. You always choose:

- an existing partition labelled `GPUUNLOCK` on an internal disk is used as it is (other EFI-type partitions, and anything on a USB disk, are shown as "found but not used" because they may belong to another operating system);
- or a new 2 GiB partition in the unallocated space of another internal GPT disk;
- or a new 2 GiB partition made by shrinking C:. This is a change to your Windows drive (no files are moved), so it needs a separate typed confirmation (`SHRINK`), and C: must keep at least 10 GB free.

## The two optional extras

Both are off unless you accept them, and each has its own screen with what it changes, what it does not change (every hardware check stays), its warnings and a disclaimer. You must type **I ACCEPT**.
They are offered only after the unlock is verified and the benchmark did not say "no meaningful improvement".

- **Extra 1, no key press.** The unlock runs by itself on a start that was queued; you no longer press U. There is still a 5 second window at the start and another 3 seconds after the drivers are released
  where Esc cancels. The installer tests it once and puts the manual setup back if it does not work. Only with this extra can you also choose **unlock at every start**: a Windows startup task that queues one
  unlock at each start. It checks first that Secure Boot and Fast Startup are still off and the boot partition is there, and it stops queuing by itself after a failed or unfinished run.
- **Extra 2, no Esc countdown.** Removes those two Esc windows (about 8 seconds faster). You can then no longer cancel from the keyboard during the start. It needs Git for Windows (to apply a patch while building).
  It is tested like Extra 1 and the version with the Esc windows is put back if it does not work. It has not been run on hardware yet.

If a hardware check fails during an automatic start, the screen stays frozen on purpose (it never retries or resets). Hold the power button, then power on. The queued start is already used up, so Windows starts normally.
"Switch the optional extras off" in the start menu puts the manual setup back without undoing anything else.

## Roll back

Choose **Roll back** in the start menu, in the resume window, from the result screen, or run `Install-GpuUnlock.cmd -Rollback`. It undoes only what this installer changed, and nothing else:

- it removes the automatic-resume entry and any queued one-time boot;
- it deletes the files the installer added to its boot partition **only if they are unchanged** (a changed file is left and reported), and puts back any file it replaced;
- it checks that the boot order still has Windows first (the installer never changes it);
- it removes the startup task, the shortcuts and their script, and puts the Fast Startup setting back to what it was;
- it deletes the installer's working files, including the copy of your card's own image. It keeps your reports, logs and backups.

It **asks first** before deleting the NVIDIA firmware files and the benchmark download (a new install can reuse them), before deleting a partition it created (you type `DELETE`; only if it holds nothing but the installer's own files),
and before giving space back to C: if it had shrunk it (it shows the exact sizes and you type `EXTEND`). Build tools installed through winget are left installed; remove them in Settings > Apps if you do not need them.
It ends with a checklist: removed, already gone, or left on purpose and why.

## What it will never do

Change the permanent boot order or the Windows boot entry; ask you to use the BIOS or a boot menu; write to the card's stored firmware; skip a check or a test; restart without your yes; upload anything (reports are saved locally and
contain no user name, serial numbers or network addresses, so they are safe to attach to a public issue).

## If something goes wrong

- A check or test fails: the installer says which and writes a short report in the `reports` folder. Attach it to an issue.
- The screen freezes at a start: hold the power button, then power on. Windows starts normally. Then run the installer and look at the result, or choose Roll back.
- The card does not look unlocked after a restart: the unlock is lost at every power-off and at sleep. Use the shortcut again and check straight after the restart.
- More: [CHECKS.md](CHECKS.md), [TROUBLESHOOTING.md](TROUBLESHOOTING.md), [BENCHMARK.en.md](BENCHMARK.en.md).

## Warranty

No warranty of any kind. This is unofficial, experimental software that writes to GPU registers before Windows starts; it is not supported by NVIDIA and may void a warranty. You use it at your own risk, under GPL-2.0-only.
