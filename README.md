# Windows GPU UNLOCK - universal installer fork

> **⏸ Paused, 2026-10-28: please hold off running the installer for now.** Actually running the installer wizard
> start-to-finish (not just the unlock mechanism underneath it) surfaced several real, previously-unknown bugs today -
> most now fixed and pushed, one full clean end-to-end pass still not yet confirmed. See
> [the changelog](#changelog) below for exactly what changed and why. This notice comes down once that one clean
> run is confirmed.

A fork of [impacifist/Windows-GPU-UNLOCK](https://github.com/impacifist/Windows-GPU-UNLOCK), the Windows UEFI
port of [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock). It runs a short program before Windows starts that sets the tensor-math
speed selectors of one RTX 30 series card, then hands over to Windows without a reset. This fork adds a guided, self-service installer
(text and graphical) with roll back, update-in-place and a full test suite, built and verified on one documented machine.

**[Download the latest release](https://github.com/sargentmajord/Windows-GPU-UNLOCK/releases/latest)** (`Install-GpuUnlock.cmd`; how to use it: [docs/INSTALLER-GUIDE.en.md](docs/INSTALLER-GUIDE.en.md)). **Status: paused - see the notice above.** Only one machine is known to have gotten this far - see what that means for other hardware in [What has been verified](#what-has-been-verified-one-machine-2026-10-25) below. Everything below describes that machine unless noted otherwise.

## Read this before trying anything

- **No warranty.** This writes to GPU registers before Windows starts. It is unofficial, unsupported by NVIDIA and may void a warranty.
  Use a card you can afford to lose, and know the recovery: if a start freezes, hold the power button and power on again (Windows then starts normally). Nothing here flashes the video BIOS; the unlock is lost at every
  power-off and applied again each boot.
- **Requirements:** Windows 11 x64 in UEFI mode, Secure Boot **off**, BitLocker off, Windows Fast Startup off (for automatic mode), a second
  graphics adapter that keeps the screen working, and a display attached to the target card. Games with anti-cheat that requires Secure Boot
  will not run with it off. See [docs/CHECKS.md](docs/CHECKS.md) and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
- **Not included:** NVIDIA firmware, video BIOS images and drivers are never redistributed. Firmware files are generated locally
  ([docs/ASSETS.en.md](docs/ASSETS.en.md)).
- **The scripts are not digitally signed.** Check the download first (`SHA256SUMS`, and `gh attestation verify` if you use the GitHub CLI — see
  the release page). Windows may mark a downloaded zip and what you extract from it as coming from the internet and show a warning when you
  open `Install-GpuUnlock.cmd`; read the scripts if you want to, then choose to run it. `Install-GpuUnlock.cmd` starts the installer with the
  PowerShell execution policy bypassed for that one run only and changes no system setting. If you prefer, right-click the extracted `.ps1`
  and `.cmd` files, open Properties and tick Unblock, or run `Unblock-File` on them. Only do that after you have checked the file and where
  it came from. A checksum file and an attestation are not the same thing as code signing: they show the archive is the one this project
  built, not that Windows trusts the publisher.

## What has been verified (one machine, 2026-10-25)

Reference machine: MSI MEG Z790 GODLIKE (BIOS 1.I0), Core i9-14900KF (no integrated GPU), RTX 3060 12 GB as the target, RTX 5070 keeping the
screen working, Windows 11, UEFI, Secure Boot off. Details: [docs/PROFILE-Z790-3060.en.md](docs/PROFILE-Z790-3060.en.md).

- The read-only diagnostic, a console-detach test, a release-only test and the manual unlock (twice, on separate boots) all completed and
  returned to Windows.
- Matrix-multiply benchmark (4096x4096, median of three, driver 617.42): FP16 tensor 26.51 -> 48.13 TFLOPS (+81.6%), BF16 tensor
  26.40 -> 50.34 TFLOPS (+90.7%), FP32 unchanged (8.20 -> 8.18). A five-minute sustained run stayed within about 3% of those values.
- **Reproduced a day later (2026-10-26), plus two new findings:** a normal Windows Restart confirmed to reset the card back to locked, and a
  first measurement of how much of the raw tensor-math gain reaches real local LLM inference (prefill +3.2% to +7.6%, decode unchanged). Full
  numbers: see the [Changelog](#changelog) below or [docs/PROFILE-Z790-3060.en.md](docs/PROFILE-Z790-3060.en.md#locked-vs-unlocked-reproduced-a-day-later-2026-10-26).
- **Not verified:** other cards, boards, firmware versions or operating systems; sleep; the automatic (no keypress) mode beyond one boot; the guided installer on any other PC; the no-cancel extra on hardware; a real run of the optional automatic mode through the installer (requirements: [docs/UNIVERSAL-INSTALLER-PLAN.md](docs/UNIVERSAL-INSTALLER-PLAN.md)).
- **Other cards and PCs are refused, not guessed.** The installer builds its boot programs from a read-only capture of your own PC, runs every check again at boot, and runs host tests
  against your own capture before anything is put on the boot partition. As of 2026-10-26 the host tests no longer assume the reference card's own exact firmware numbers - they check that
  whatever your card's capture contains is internally consistent, proven against firmware shapes that aren't the reference card at all. That removes the known blocker, but it doesn't yet
  prove any *specific* other card works: only the reference machine has actually been confirmed end to end. If a check fails, the installer stops and writes a report instead of continuing -
  that is the safe direction. Reports from other PCs are how this actually gets confirmed; see [impacifist/Windows-GPU-UNLOCK#41](https://github.com/impacifist/Windows-GPU-UNLOCK/issues/41).
- Only matrix-heavy GPU work speeds up (for example AI prefill, training, image generation) - and real-world gains are well below the raw
  TFLOPS number, since actual workloads mix in memory-bound work the unlock doesn't touch; measured real local LLM prefill gained +3-8%, not
  +82%. Games, FP32 work and memory-bound work (including LLM token generation/decode) do not speed up at all.

## Where things are

| Path | Purpose |
|---|---|
| [docs/INSTALLER-GUIDE.en.md](docs/INSTALLER-GUIDE.en.md) | how to use the installer, step by step, and how Roll back works |
| [docs/PROFILE-Z790-3060.en.md](docs/PROFILE-Z790-3060.en.md) | the reference machine and its measured results |
| [docs/CHECKS.md](docs/CHECKS.md), [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | pre-flight checks and fixes |
| [docs/UNIVERSAL-INSTALLER-PLAN.md](docs/UNIVERSAL-INSTALLER-PLAN.md) | requirements the installer is built to |
| [docs/AUDIT-2026-10-25.md](docs/AUDIT-2026-10-25.md) | what was checked before the first hardware step |
| `internal-boot/` | the boot programs, build and staging scripts, host tests |
| `patches/` | optional patches, including one that removes the automatic mode's Esc cancel windows (with disclaimer) |
| `benchmark/` | the before/after benchmark |

## Changelog

Every dated entry below, start to finish, trimmed of internal engineering detail (exact hashes, raw test-count
tallies, file-rename bookkeeping) that only matters to someone editing the code. Full untrimmed history: [CHANGES.md](CHANGES.md).

### 2026-10-30 - The "unlock again" shortcut is now desktop-only

The Start Menu option is gone. Even with the 10-28 fix, the underlying refusal kept coming back on the
reference machine - that folder's permissions aren't this project's to control, and something as ordinary
as a Windows feature update was enough to reset them into a state the installer correctly refuses. The
desktop shortcut (the same already-accepted tradeoff it always had) is now the only option offered.

### 2026-10-28 - A failed Start menu shortcut no longer stops the whole install

If creating the optional Start menu shortcut fails (an admin/permissions problem specific to one PC), the
installer used to stop outright with no clear way forward - restarting it just asked the same question
again and failed the same way, with nothing explaining that declining the shortcut was the way past it.
It now reports the failure in plain terms and continues on its own; the shortcut is optional and never
affects the unlock itself.

### 2026-10-28 - A second real power loss found a gap in the previous fix, plus a genuinely fresh-install-only bug

The boot-safety fix from earlier today only re-tried its first check after a hard power loss; a second
power loss showed the same timing race can surface in one of the later checks instead, so all of them now
get the same retry. Separately, a truly from-scratch install (no leftover files from earlier development)
hit a real bug building the read-only diagnostic - one generated file was only being created later than it
was first needed - now fixed.

### 2026-10-28 - Roll back now cleans up a small file it used to leave behind

Found on the first full clean install-to-rollback run: Roll back correctly removed the "unlock at every
start" task and restored Fast Startup, but left one small, harmless state file of its own behind
afterward - a leftover from a file rename that one cleanup line never caught up with. Fixed; Roll back
now removes it too.

### 2026-10-28 - a modern look for the installer's GUI, matching whatever Windows theme is already running

Cosmetic only. Tried a fixed custom color theme first; seen rendered, it looked worse than the plain
default controls it replaced, so that was dropped entirely in favor of this instead: the window's own
corners are now genuinely rounded (Windows 11 only; ignored harmlessly on older Windows), every button
gets a real anti-aliased rounded face instead of a hard rectangle, and the whole window's colors now
follow whatever light or dark mode the person already has Windows set to - plain default colors in light
mode (unchanged from before), a proper dark palette in dark mode - rather than a fixed skin of its own
that matches neither.

### 2026-10-28 - a real administrator's own account could get the optional Start menu shortcut refused

The optional Start menu shortcut could get created, then immediately refused and removed, naming the
installer's own (genuinely administrator) account as the problem - a new file keeps whoever made it on
its own permissions, same as any file, and only the owner was being reset, not the rest. Now fully
locked down the same proven way this project already protects its own data folder. (A fix that instead
loosened the underlying security check was tried and deliberately reverted - it would have quietly
weakened real tampering protection for everyone, not just fixed this one case.)

### 2026-10-28 - the first real unlock applied cleanly, then got refused one stage too late

The unlock itself worked - the firmware reset applied and the card's registers confirmed the unlocked
state - but a final safety check one stage later, re-verifying nothing unexpected had changed before
handing off to Windows, refused anyway. That check expected only one specific driver binding to
disappear from the just-reset card; a second, unrelated one also legitimately disappeared and wasn't
accounted for. Fixed to tolerate any binding loss on that one card's own handle - and confirmed, with a
host test built for exactly this, that a genuinely suspicious new binding appearing there is still
caught, not waved through along with it.

### 2026-10-28 - a missed keypress on the first unlock was wrongly reported as a hard failure

If you didn't press U in time (or pressed Esc) during the first manual unlock, the installer treated
that as if something had actually gone wrong - straight to "post a public bug report," no "Try again?"
option, even though nothing was touched and the card kept its normal speed. It now correctly recognizes
a plain missed keypress or Esc and offers to try again, like it already did for every other benign
cancel.

### 2026-10-28 - fixed a crash the console-prepare GOP-retry fix introduced in its own host test

The GOP-discovery retry added earlier the same day called a function the test's mock environment never
provided, crashing the one host test that exercises this code instead of failing it cleanly. Found live
the first time the real installer tested a fresh capture; fixed, and reran against that exact capture
to confirm.

### 2026-10-28 - two installer bugs found live while updating in place, both fixed

The installer could get stuck thinking its own diagnostic or first-unlock boot "hasn't happened yet" when
every-boot mode's own background task happened to queue an unrelated boot at the same time - fixed to check
for its own actual result first. Separately, a background self-check during the install could hang
indefinitely waiting for keyboard input nothing was ever going to provide - fixed to fail fast instead, as
it was always supposed to.

### 2026-10-28 - the stuck-notification's Repair and "No, turn it off" buttons never actually worked

Clicking Repair (or "No, turn it off") on the every-boot-stuck notification, and approving its permission prompt,
silently did nothing - a bug in how the elevated action was built meant it failed before making any change, with
no sign of failure. Fixed; both buttons now actually do what they say.

### 2026-10-28 - console-prepare retries before refusing a GPU's GOP as missing after a hard power loss

On a dual-GPU setup, a real power loss (not just a PC restart - the monitor losing power too) can leave the
non-console GPU's own firmware graphics driver still initializing when the pre-unlock safety check first looks
for it, since a hard power cycle changes PCIe link-training timing compared to a graceful shutdown. That check
now waits up to 3 seconds for both GPUs to be ready before concluding one is actually missing. Nothing about
what the check validates got looser - a genuinely wrong or missing GPU still gets refused exactly as before.

### 2026-10-28 - re-enabling every-boot mode no longer inherits a stale circuit-breaker trip

Turning every-boot mode back on after it had been off used to inherit whatever circuit-breaker state was left
over from before - including a trip from days earlier - so the very first re-arm attempt could falsely report
itself stuck with nothing having actually failed this time. Re-enabling now always starts from a clean slate.

### 2026-10-26 - generalized the last hardcoded reference-card assumption in the host tests

One of the host tests still assumed any real firmware capture it parsed must match this machine's exact numbers -
the known blocker flagged earlier as stopping other cards from passing. Replaced it with checks that validate
whatever real card's firmware is internally consistent, instead of requiring an exact match to the reference
card. Proved this actually generalizes (not just asserted) with a new test against two firmware shapes that
aren't this card at all, including one deliberately misaligned by a different amount than this card's own case.
Confirmed the same evening with a fresh real capture (a new diagnostic boot, not reused data): rebuilt the real
EFI image and ran the complete host test suite against it - all 12 groups pass, zero regression on the one card
this has always been verified on. This removes the known blocker; it doesn't yet prove any specific other card
works - that still needs someone with that hardware to actually try it and report back.

### 2026-10-26 - reproduced locked-vs-unlocked a day later, and measured real local LLM inference

Repeated the GEMM benchmark from the day before on the same machine and got consistent results. Specifically tested
whether a plain Windows Restart (not a full power-off) resets the card - confirmed yes, both the locked and
unlocked state verified independently rather than assumed (register readout, and the FP16/FP32 ratio matching each
documented reference). New: measured how much of the raw tensor-math gain reaches actual local LLM inference on the
same card - prompt processing (prefill) gained +3.2% on a ~7,600-token prompt and +7.6% on a ~31,000-token prompt;
token generation (decode) showed no measurable change at any size tested, and why that gap is expected. See
[PROFILE-Z790-3060.en.md](docs/PROFILE-Z790-3060.en.md).

### 2026-10-26 - a notification for the stuck circuit breaker, and a release-freshness check

Every-boot mode now shows a Windows notification the moment its circuit breaker stops queuing (instead of only
showing on the status screen), with three choices: Repair (clears it, queues normally again), Ignore (asks again
next logon if still stuck), or "No, turn it off" (disables every-boot mode). The installer also now checks whether
you're running the latest release and links straight to it if not - never blocks, never fails. Every release's
GitHub page now gets a real changelog instead of a bare compare link.

### 2026-10-26 - every-boot mode's circuit breaker is now visible and repairable

Found on the reference machine: when every-boot mode's startup task queues an unlock and that run leaves no report
(a real freeze, a power loss, or a deliberate test), its circuit breaker correctly stops queuing new ones - but
nothing told the user that happened, and there was no way back except deleting a file by hand. The status screen
now explains plainly what happened and offers a one-click repair.

### 2026-10-26 - release checklist drafted; the hardware recovery drill repeated

Added a release checklist (checksums, attestation, the unsigned-script note). Repeated the hardware recovery drill
on the reference machine: a hanging test image was staged in place of the fallback boot file, the screen froze as
expected, holding the power button and powering on gave a normal Windows start with no BIOS and no menu, and the
circuit breaker correctly refused to queue anything further until cleared. Roll back then restored everything.

### 2026-10-26 - status screen, update-in-place, and plain roll-back wording

Roll back's text now plainly states what it never touches (Windows files, your data, BIOS settings, the card's
stored firmware). A finished install now shows a full status screen on every run (Secure Boot, Fast Startup,
BIOS/board, the boot partition, whether the fallback boot file is still the installer's own) with one-click repairs
that always ask first. If the board or BIOS changes later, the installer notices, explains what changed, and offers
to start fresh rather than silently continuing on stale assumptions. If the installer's own code is newer than what
you have installed, it offers to update your existing install in place without re-asking the first-time questions.

### 2026-10-26 - graphical front end

`Install-GpuUnlock.cmd` now opens a graphical window by default (ships with Windows, no extra download) instead of
only a text console - a step line, a progress bar, a coloured log, and plain Yes/No and multiple-choice buttons.
The text version is still available (`-Console`) and used automatically if no desktop is available. Both front ends
run the identical installer logic underneath.

### 2026-10-26 - user guide, launcher arguments, clearer check text

Added a plain-words guide to the installer covering everything it asks, in order, and what Roll back does and
never does. A few check messages were made clearer about exactly what to fix and how.

### 2026-10-26 - installer stage 8: the two optional extras

Added two opt-in extras, offered only after the unlock is verified and showed a real improvement: no-keypress
automatic mode (each boot unlocks itself with nothing to press) and, after that, no cancel-countdown windows either.
Both require typing `I ACCEPT` after reading a plain-words explanation of what changes, the freeze-and-power-button
recovery, and a disclaimer; declining or a failed check changes nothing and the previous working setup is put back
automatically. A start-menu option turns either extra back off at any time.

### 2026-10-25 - installer stage 7: Roll back, and resuming automatically after a restart

Roll back reads a record of exactly what the installer did and undoes it, newest first, checking every file's
identity before touching it (nothing is ever deleted on a guess). At a restart, the installer can optionally
continue automatically when you log back in, picking up right where it left off instead of needing to be started by
hand again.

### 2026-10-25 - review fixes, and a protected data folder

A few hardening fixes from a security review: the installer's own data folder is now locked down so only
Administrators and SYSTEM can change it (refusing to run at all if it finds the folder has been tampered with), long
install paths are refused before they become a problem, and a firmware download failure now says exactly which file
to fetch and where it goes instead of just failing silently.

### 2026-10-25 - installer stage 6: the "Unlock my GPU on next boot" shortcut and the every-boot opt-in

Added a desktop shortcut that queues exactly one unlock on the next restart - nothing permanent, no BIOS or boot
menu involved. Every-boot mode (every single restart re-applies the unlock automatically) is an explicit opt-in with
a full warning, offered only once a real unlock has already been confirmed working.

### 2026-10-25 - installer stage 5: first unlock, before/after benchmark, verdict

The installer now runs the actual unlock for the first time, with a full plain-words explanation of what will
happen and the freeze/power-button recovery beforehand. A before-and-after matrix-multiply benchmark is offered
(strongly recommended, but skippable) and gives a plain verdict: clear improvement, small improvement, or no
meaningful improvement (with a roll-back suggestion).

### 2026-10-25 - installer stage 4: firmware files, build and tests on the user's own PC

The installer now generates NVIDIA's firmware files locally (never redistributed - every download is hash-checked
against NVIDIA's own published values), builds the actual boot programs against your specific hardware, and runs a
full suite of tests against your real captured data before anything touches the boot partition. Any failure stops
the installer and writes a report instead of continuing.

### 2026-10-25 - installer stage 3: a profile generated from a read-only capture of your PC

Per-machine values (card identity, console adapter, firmware driver fingerprints) now come from one profile file
built automatically from a read-only diagnostic capture of your own PC, rather than being hard-coded for one
reference machine. The capture tool refuses to generate a profile at all unless the card is confirmed untouched and
every expected condition is met - with a plain reason when it refuses.

### 2026-10-25 - installer stage 2: card and boot-partition choice, backups, a plan screen

Added the pieces that let you choose which card to target and where the boot partition goes (an existing one, a
new drive, or shrinking C: with sizes shown and a typed confirmation), with everything backed up first and a single
plan screen that is confirmed once before anything happens.

### 2026-10-25 - on-screen failure message now says to use the power button

If a boot program ever gets stuck, the on-screen message was pointing at the wrong recovery step (an F11/F8 boot
menu). It now correctly tells you to hold the power button until the PC turns off, then power back on.

### 2026-10-25 - startup task looks up the boot entry itself, every single time

The automatic re-queuing task no longer trusts a saved id for where to queue the unlock - it looks the entry up
fresh at every single start and double-checks Fast Startup and Secure Boot are still as expected before queuing
anything. If anything looks wrong, it logs why and queues nothing rather than guessing.

### 2026-10-25 - recovery drill passed; installer stage 1

First real test of the worst case: a program was deliberately made to hang during the one-time boot slot. The
screen froze as expected; holding the power button and powering back on started Windows completely normally, no
BIOS screen, no boot menu. This is also where installer stage 1 (the first screen, the administrator prompt, and
the first read-only checks) was built - it changes nothing on your PC at this stage.

### 2026-10-25 - boot order does not survive a cold boot; a one-time queue does

Discovered that setting a permanent boot order change from Windows does not survive a real cold boot - the firmware
quietly resets it back to Windows-first. A one-time queued boot (used ever since) does survive it. This is the
actual mechanism every-boot mode depends on.

### 2026-10-25 - automatic (no-keypress) mode verified once on the reference machine

The no-keypress automatic version of the unlock ran successfully for the first time: release, unlock, Windows
start, with a measured tensor-math improvement afterward and no errors logged.

### 2026-10-25 - pruning to only what this fork actually uses

Removed code, scripts and documents from the original upstream project that this fork doesn't use (other
developers' machine-specific research tools, old translated guides, an unused comparison harness), after
confirming nothing else depended on them.

### 2026-10-25 - final regression check before the first real hardware attempt

A full check before doing anything on real hardware: no machine-specific private paths left in tracked files, no
secrets, nothing added to Windows startup yet, and Secure Boot/BitLocker/boot order all still exactly as they were
before this project touched the PC.

### 2026-10-25 - a firmware-check bug fixed (credit: upstream issue #42)

Fixed a case where certain firmware error values could be mistaken for a successfully finished boot. Found and
fixed before it ever ran on real hardware.

### 2026-10-25 - second consistency check of this fork

The README and guides still described the original author's different PC as if it were this project's result.
Corrected throughout, with the original author's own material clearly separated out and labeled as not applicable
to this machine.

### 2026-10-25 - optional patch: no cancel-countdown windows

Added a standalone, opt-in patch (separate from the main installer at this point in the project) that removes the
few-second cancel windows from the fully automatic unlock, for anyone who wants it. Everything else about the
hardware safety checks is unchanged; typing an explicit acceptance phrase is still required.

### 2026-10-25 - first real hardware result (RTX 3060 12 GB, MSI MEG Z790 GODLIKE)

The actual first unlock on real hardware: manual version, one keypress, successful transaction, Windows started
normally with no reset needed. Matrix-multiply benchmark: FP16 tensor math +81.6%, BF16 +90.7%, FP32 (control, as
expected) basically unchanged. A 5-minute sustained run held steady with no errors. Not yet verified at this point:
a second boot, or what happens after a normal restart or sleep.

### 2026-10-25 - a release-only test build, with no unlock code in it at all

Added a build that does everything up to (but not including) the actual unlock - useful for testing the release and
recovery machinery itself in complete isolation from the part that writes anything to the card.

### 2026-10-25 - benchmark made to work with any supported card, not just one

The matrix-multiply benchmark no longer assumes a specific card - it selects whichever card you choose by its PCI
address and reports its real name, rather than assuming which GPU is being measured.

### 2026-10-25 - the unlock program's own tests now run against this real PC's data

The project's existing test suite (inherited from upstream) was still checking against a different, older
reference machine's captured data. Updated to check against this PC's own real captured values instead, and all
tests pass against the real data.

### 2026-10-25 - a real video-BIOS replay confirms the firmware-reading logic end to end

Captured this card's actual video BIOS data and replayed it through the project's own parsing logic as an automated
test, confirming the logic correctly handles this exact card's real firmware layout, not just a synthetic example.

### 2026-10-25 - a real hardware compatibility bug found and fixed (credit: upstream pull request #115)

This specific RTX 3060 variant (`10de:2544`) has a firmware data size that the original unlock code didn't handle -
it would have left the card stuck until a power cycle. Found before ever touching real hardware, fixed using a
patch written upstream (not yet merged there at the time), and verified with a dedicated regression test that fails
against the old code and passes with the fix.

### 2026-10-25 - converted into a single-machine copy for this specific PC

Up to this point the code still supported several different original machines. Simplified it down to support only
this one reference PC (RTX 3060 target, RTX 5070 as the console display, this specific motherboard), removing the
other configurations entirely from this copy to reduce complexity and risk.

### 2026-10-25 - a read-only diagnostic profile added for this PC (not yet tested on hardware)

Before ever allowing any actual unlock on this new PC, a diagnostic-only profile was added that can only read
identity information - any attempt to compile an actual unlock build against it fails to even compile, by design,
until there's been a real diagnostic run confirming it's safe to go further.

### 2026-10-24 - a display-detection bug fixed on a different motherboard

Fixed a case where a different firmware vendor exposed an unexpected number of display outputs, which had been
incorrectly rejected as invalid. Verified working after the fix on that machine.

### 2026-10-24 - a second machine verified (different motherboard and a different RTX card)

The project's approach was proven to generalize beyond the very first machine: a second, different PC (different
motherboard, a different RTX 30-series card, no second display GPU available) was set up from scratch and
successfully unlocked, with a measured tensor-math improvement. Also added: a safe, read-only diagnostic mode for
fingerprinting a brand new, unknown PC before ever attempting a real unlock on it.

### 2026-10-24 - the very first working internal, no-keypress test

The first time the fully automatic (no keypress) version worked end to end on real hardware: one successful
transaction, Windows returned normally, and a benchmark confirmed the improvement. This is also where the project
first added a real roll-back/recovery path and public documentation.

### 2026-10-23 - an internal experimental build, kept separate from the original public release

Started a separate development line for the automatic/no-keypress idea, kept fully apart from the original stable
public release so nothing already working could be put at risk while this was being worked out.

### 2026-10-23 - documentation made bilingual, and an early compatibility survey added

Added full English documentation alongside the original Korean, and a way to record compatibility reports from
different PCs without collecting anything private.

### 2026-10-20 - the project's starting point: a public case study this fork builds on

This is where this fork's history begins: based on an existing public release by another author, with the actual
hardware-check logic (card identity, memory layout) adapted, a safe read-only mode added by default, and the
project's own test suite built out alongside it from the very start. No proprietary files (firmware, drivers,
private paths) have ever been included in any public release of this project, from this very first entry onward.

## License and attribution

GPL-2.0-only; EDK2 and separately attributed components keep their licenses. Based on
[rough2515-hub/rtx3080-unlock-public](https://github.com/rough2515-hub/rtx3080-unlock-public/tree/a08254d269af30ace9e57237abd3d8e6c261e8f5)
and [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock/tree/0ebdb1c6308b6a2072be5bf04513472942541956), through impacifist's port.
The original author's own documents and measurements for his machines are in the [upstream repository](https://github.com/impacifist/Windows-GPU-UNLOCK) and are not repeated here. Keep [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [CHANGES.md](CHANGES.md). Changes in this fork were made by Sargentmajord with
assistance from Claude, an AI coding assistant. Not affiliated with or endorsed by NVIDIA.
