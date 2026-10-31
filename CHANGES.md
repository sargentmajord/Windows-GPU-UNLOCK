# Changes

## 2026-10-30 - Correction: the cudafe++ crash was `-allow-unsupported-compiler`, not transient interference; removed it and the retry

- The retry added for the cudafe++ `ACCESS_VIOLATION` crash (previous entry below) was not the fix: the same
  build hit the identical crash again on the very next real run, including on the automatic retry itself.
  Told directly to stop treating the symptom and find the actual cause instead.
- Found by reading CUDA 12.6's own `host_config.h` rather than guessing again: its Visual Studio version
  check accepts any `_MSC_VER` from 1910 up to (not including) 1950. Queried the installed `cl.exe` directly
  or `/* #include <stdio.h>; printf("%d", _MSC_VER); */` - it reports `_MSC_VER 1944`, squarely inside that
  accepted range. So `-allow-unsupported-compiler` (added 2026-10-30, see below) was never actually needed
  to get past that check for this compiler - and the flag's real effect reaches further than that one check:
  it relaxes other internal nvcc/host-compiler validation too, which is a plausible, better-fitting
  explanation for an intermittent crash inside nvcc's own compiler subprocess than "something external
  collided with it." Rebuilt `compute-benchmark.cu` six times in a row with the flag removed entirely:
  6 of 6 clean. Removed it from `benchmark/build.ps1`.
- Also removed the automatic retry from `installer/Benchmark.ps1`'s `Initialize-Benchmark` added for the
  same incident - it was covering for a bug that is now actually fixed, and keeping it would have silently
  hidden a real recurrence if this (or anything else) ever broke the build again. A single failed build is
  reported as an error again, not retried.
- Verified: `Run-AllTests.ps1`, 1182 of 1182, run elevated (the two retry-specific tests added for the
  removed behavior were removed with it).

## 2026-10-30 - The benchmark build now retries once on a transient compiler crash

- Found live: the benchmark build failed with `nvcc error: 'cudafe++' died with status 0xC0000005
  (ACCESS_VIOLATION)`. Checked directly rather than assuming the toolchain was actually broken: re-ran the
  exact same `benchmark/build.ps1` command immediately afterward, with no code or environment change at
  all, and it built cleanly (nvcc, cl.exe and the CUDA version check all matched what passed before). So
  this specific failure was a one-off crash in nvcc's own compiler subprocess, not a real incompatibility -
  the kind of thing a background scan or other momentary load can trigger in a spawned child process.
- `installer/Benchmark.ps1`'s `Initialize-Benchmark` now retries the build step itself once, automatically,
  before giving up, telling the person it is doing so. The download step is unchanged (still one attempt,
  still a real error if it fails) - only the compiler invocation, the part just shown to fail transiently
  and then succeed with nothing else different, gets the retry.
- Verified: `Run-AllTests.ps1`, 1189 of 1189, run elevated (new coverage: a build that fails once then
  succeeds on the retry, and the case where it fails twice in a row and is still reported as a real error,
  not retried forever).

## 2026-10-30 - Fixed two bugs reported live on a fresh clone (issue #1): the LLVM install and the diagnostic build

- Reported live by a real tester on a fresh clone (GitHub issue #1, testing the 10-28 build with LLVM
  uninstalled first): step 3 failed with `winget install of LLVM.LLVM failed with code System.Object[]`
  about a minute into the download, even though LLVM had actually installed successfully (confirmed: the
  next run got past step 3 on its own). Root cause: `Invoke-SysWinget` (`installer/Tools.ps1`) ran winget
  without capturing its own stdout (`& winget.exe @WingetArgs; $LASTEXITCODE`) - an unassigned
  native-command statement's output becomes part of the *function's own* return value in PowerShell, so the
  caller's `$code` was really an array of every line winget printed during the download, plus the real exit
  code, bundled together - which is exactly what formats to the literal text `System.Object[]`. Every other
  native-command wrapper in this codebase already captures that output into a throwaway variable first;
  this was the one that didn't. Fixed by always capturing it (`Invoke-SysExeForExitCode`, reused by
  `Invoke-SysWinget`); also fixed the same latent shape in `Invoke-SysRestart` (`installer/BootEntry.ps1`),
  which had the identical pattern, though it was not reported. Also added a line before a tool install
  starts saying it can take a few minutes and nothing more will print until it is done, since the silence
  during the download is exactly what made this look stuck rather than just slow.
- Reported in the same comment: step 8 ("building the read-only diagnostic") then failed with
  `handoff.c: fatal error: 'generated.h' file not found`. Root cause: `handoff.c` unconditionally
  `#include`s `generated.h` just to satisfy the compiler - under the diagnostic-only build nothing in it is
  ever loaded or checked at runtime (this exact fact is already written down in
  `docs/PROFILE-Z790-3060.en.md` as a manual prerequisite for reproducing the diagnostic build by hand) - but
  the file is gitignored (it normally comes from a real unlock-child build) and nothing in the *installer's*
  own build step ever wrote it, so a fresh clone has none and the build fails before compiling anything of
  its own. Fixed in `installer/Capture.ps1`'s `Build-Diagnostic`: before invoking the build script, write a
  clearly-labelled, all-zero placeholder `generated.h` only when there truly is none; a real one left over
  from a full build (as this dev machine already had) is never touched.
- Verified: `Run-AllTests.ps1`, 1182 of 1182, run elevated (new coverage: the real exit-code wrapper against
  an actual multi-line-output process, so this is proven against a real native command, not a mock; the
  diagnostic build writing the placeholder only when missing and never overwriting a real one).
- Posted a status update on the GitHub issue; will follow up there once this is confirmed fixed on the
  reporter's machine too.

## 2026-10-30 - The build-tool uninstall offer moved from Roll back into the normal end-of-install flow

- Raised directly: burying the keep-or-uninstall question inside Roll back only reaches the person who runs
  Roll back - most people who finish a successful install never do. It needs to be asked once, right when
  the install actually finishes, not left for a path most people never take.
- Added `Invoke-ToolCleanupOffer` (`installer/Tools.ps1`), called once at the natural end of a successful,
  non-dry-run install (`installer/Main.ps1`, guarded so a later status check on an already-finished install
  never re-asks). It lists, by name, only the build tools *this run* installed, and asks about each one in
  turn; declining leaves it in place, accepting runs the same exact-id winget uninstall Roll back's version
  uses. Roll back keeps its own copy of the same offer as a safety net for anyone who does run it later.
- The guarantee the person asked for directly - that an enthusiast's own pre-existing toolchain is never
  touched against their wishes - was already structural, not a runtime check that could be wrong: a tool
  only ever gets an `install <winget id>` journal entry when `Get-ToolStatus` found it missing in the first
  place (`Resolve-Tools`'s own `$missing` filter), so a tool that was already there has nothing in the
  journal for either offer to act on. Added a dedicated test proving this directly - an empty journal (the
  pre-existing-tool case) asks zero questions and calls winget zero times - rather than leaving it as an
  inference from the install-offer tests alone.
- Verified: `Run-AllTests.ps1`, 1176 of 1176, run elevated (new coverage: the end-of-run offer with nothing
  installed, with one tool installed and accepted, and with one tool installed and declined).

## 2026-10-30 - Slimmed the VS Build Tools install, and Roll back now offers to uninstall what it installed

- Asked directly: a random person with nothing installed is being offered a 3-7 GB Visual Studio download
  just to run an *optional* benchmark - that is a real adoption cost worth questioning, not accepting as a
  given.
- `installer/Tools.ps1`'s winget install of `Microsoft.VisualStudio.2022.BuildTools` dropped
  `--includeRecommended`. That flag pulls in everything Microsoft marks Recommended, not Required, for the
  C++ workload - ARM64/ARM64EC cross-compilation toolsets, CMake tools, a second, Clang-based compiler for
  Windows (redundant: this project already brings its own LLVM separately, for the main build), test
  adapters, extra SDK versions. None of it is used anywhere in this project; only the Required set - the
  compiler, the linker, and one Windows SDK - is what `vcvars64.bat`, `cl.exe` and `nvcc`'s host-compiler
  calls actually need. Updated the disclosed size from "roughly 3 to 7 GB" to "roughly 1 to 2 GB" to match.
  Caveat, stated plainly rather than overclaimed: this machine already had Visual Studio installed, so the
  new figure is an informed estimate from Microsoft's own documented Required-vs-Recommended component
  semantics, not a byte count measured from a genuinely fresh install here - verifying it exactly would mean
  uninstalling a working VS install on this machine first, which wasn't done.
- Separately: `installer/Rollback.ps1` already correctly distinguished, in its journal, a build tool it had
  to install (because `Get-ToolStatus` found it missing) from one that was already on the PC - only the
  former ever gets an `install <winget id>` journal entry at all, so Roll back can never be offered a tool
  the person already had for something else, by construction, not by a runtime check that could be wrong.
  It just never acted on that distinction: a tool it installed was always silently left in place, with a
  passive "remove it yourself in Settings > Apps" note. Roll back now actually asks, by name, whether to
  uninstall each tool it installed - matching the same pattern already used for the NVIDIA firmware files and
  the benchmark download (disclose, then ask, never assume) - and does it through winget itself when agreed
  to, reporting success, a declined choice, or a failed uninstall (with winget's own exit code) distinctly.
- Verified: `Run-AllTests.ps1`, 1165 of 1165, run elevated (new coverage: the uninstall offer accepted,
  declined, and failing, plus the existing explanation-text and journal cross-checks extended to match).

## 2026-10-30 - The benchmark build refused a newer Visual Studio point release CUDA hadn't heard of yet

- Found live: "preparing the benchmark" failed outright with `fatal error C1189: #error: -- unsupported
  Microsoft Visual Studio version! Only the versions between 2017 and 2022 (inclusive) are supported!`.
  Checked directly rather than guessing: the active compiler is genuinely `cl.exe` 19.44.35229 from the same
  VS2022 BuildTools install this project already uses everywhere else - not a wrong Visual Studio edition
  being picked up, just a later VS2022 point release than CUDA 12.6's `host_config.h` had a hard-coded
  version number for when it shipped. nvcc's own error text names the fix: `-allow-unsupported-compiler`,
  which lifts only that specific version-range check and nothing else nvcc or cl.exe would otherwise enforce.
- Added that flag to the one nvcc invocation in `benchmark/build.ps1`. Verified by actually rebuilding against
  this machine's real downloaded CUDA packages (not a mock): compiled, linked, and the build's own
  metadata-only version check confirmed `cuda_runtime: 12060, cublas: 12.6.0` - the exact versions expected.
  No test file exercises this script's nvcc command line directly (`Test-Benchmark.ps1` mocks the whole build
  step), so this had no automated coverage to update - it was only ever going to be caught by actually
  building, which is what running the real installer, on a real machine, today did.
- Verified: `Run-AllTests.ps1`, 1161 of 1161, run elevated.

## 2026-10-30 - The diagnostic log itself couldn't write; found why the resume keeps failing, and mitigated it

- The scheduled-task migration got its first real test on an actual login a few minutes after being set up:
  Task Scheduler's own operational log (enabled today specifically for this - it's off by default) confirms
  the "at log on" trigger fired, launched the process, and that process ran for about 8 seconds before
  exiting with an unhandled-error code. The installer's own `last-launch.log`, though, was still completely
  empty for that launch.
- Root cause of the empty log, found by testing directly: `last-launch.log` was being written inside this
  project's own installer data folder, which `Protect-DataFolder` deliberately locks to Administrators and
  SYSTEM only. `-Resume` always starts non-elevated - by design, specifically so the dialog can show before
  anyone approves elevation - and a non-elevated process, even one run by an administrator account, cannot
  write there: Windows' UAC split token marks the Administrators SID "deny only" on the filtered token, so
  the ACL's Administrators grant simply isn't available to check against. Confirmed directly: `whoami
  /groups` on a non-elevated session shows exactly that "deny only" marking, and a plain write to the old
  log path failed with Access Denied; the same write to the new path succeeded. Every `Out-File` call already
  had `-ErrorAction SilentlyContinue` (so a logging failure could never break the actual resume), which meant
  the Access Denied was being swallowed silently every single time, on every launch, from the moment the
  logging was added - it could never have produced evidence, logging the one case that most needed it.
  Moved `last-launch.log` to the current user's own per-profile folder (`%LOCALAPPDATA%\WindowsGPUUnlock`),
  which needs no elevation to write to either before or after Continue is clicked. Verified directly, both
  ways: the old path still refuses a non-elevated write, the new one now succeeds.
- Separately, likely (not yet confirmed) root cause of the 8-second-then-crash itself: an "at log on" trigger
  fires essentially the instant Windows considers the user logged on, which can be before the desktop session
  has actually finished settling - a well-known class of problem for logon-triggered tasks that depend on a
  fully-up session, and manual testing all day (always run well after an active session was already settled)
  would never have reproduced it. `Set-SysResumeTask` (`installer/Resume.ps1`) now sets a 20-second delay on
  the trigger (`$trigger.Delay = 'PT20S'`) before it's allowed to fire, to give the session room to finish
  coming up first. This changes nothing about what runs or how it's elevated, only when it's allowed to start.
- Verified: `Run-AllTests.ps1`, 1161 of 1161, run elevated (the new trigger-delay property included in
  `Test-Resume.ps1`'s real-system verification block).
- Confirmed live, same day, on a genuinely fresh install's first restart, with no manual intervention of any
  kind: the trigger fired on its own, `last-launch.log` captured every step (module load, dialog shown,
  "Continue" clicked, elevated relaunch), and Task Scheduler's own log records "successfully completed ...
  return code 0" - the same task that had failed with an unhandled-error code the first time, before either
  fix. The fully automatic resume - the thing that had never once worked unattended before today - worked.

## 2026-10-30 - Replaced the automatic-resume RunOnce entry with a scheduled task

- The diagnostic logging added earlier today got its answer on the very next restart: `last-launch.log` was
  empty. Not "crashed loading a module", not "Test-DesktopAvailable failed" - nothing, not even the single
  unconditional line written before anything else in the script could fail. No trace in the Windows Event
  Log either. The conclusion: the process RunOnce was supposed to launch never actually started, or never
  got far enough to execute a single line of PowerShell - a failure in how Windows invoked it, not anything
  the script itself did. The same exact command, run by hand every single time today (manually, and later
  through the elevated-runner scheduled task set up today for a separate reason), always worked.
- Replaced the mechanism rather than keep guessing at RunOnce's own internals, which are undocumented enough
  that Microsoft's own "Run and RunOnce" reference doesn't explain this kind of silent failure, and which
  keep no log of their own to find out from. The resume entry is now one current-user scheduled task
  ("at log on"), registered and removed through `installer/Resume.ps1`'s `Set-SysResumeTask` /
  `Get-SysResumeTask` / `Remove-SysResumeTask` (replacing `Set-SysRunOnceValue` / `Get-SysRunOnceValue` /
  `Remove-SysRunOnceValue`). Deliberately kept at the same safety level as before - `LogonType Interactive`,
  `RunLevel Limited` - so nothing about when or how it elevates changes: the dialog still shows first,
  completely unelevated, and only clicking Continue triggers Windows' own administrator prompt, exactly as
  before. An "at log on" trigger fires on every future log-on, not once, so the task still has to remove
  itself at the same point the RunOnce value used to (the start of `Invoke-ResumeStart`, before the dialog
  is shown) - functionally the same "runs once" guarantee, just enforced by the script instead of by the
  registry key's own semantics.
- `Main.ps1`, `Rollback.ps1` and `Session.ps1` needed no changes at all: all three only ever called the
  high-level `Test-ResumeEntry` / `Set-ResumeEntry` / `Remove-ResumeEntry` functions, never the registry
  directly, so the whole migration stayed inside `Resume.ps1` and its tests.
- `installer/tests/Test-Resume.ps1` gained a new admin-gated block that exercises the real
  `Register-ScheduledTask` / `Get-ScheduledTask` / `Unregister-ScheduledTask` round trip - under its own
  dedicated task name (`WindowsGPUUnlockResumeTest`), never the real `WindowsGPUUnlockResume` one, so a test
  run can never collide with or disturb an actual pending resume on a machine that has one. Confirms, against
  the real system rather than a mock: the registered action, that `RunLevel` really is `Limited` and
  `LogonType` really is `Interactive`, and that the trigger really is an at-log-on one.
- Verified: `Run-AllTests.ps1`, 1153 of 1153, run elevated.
- Still to confirm: a real restart, to see whether this actually launches where RunOnce didn't. The
  diagnostic logging from the previous entry stays in place either way, since Task Scheduler's own
  Microsoft-Windows-TaskScheduler/Operational log is a second, independent source of truth if this doesn't
  fully resolve it.

## 2026-10-30 - Diagnostic logging for the automatic-resume RunOnce entry that keeps launching invisibly

- Not a fix - this is instrumentation, added because the actual bug has no evidence yet to fix from. The
  resume entry the installer offers after a restart (`WindowsGPUUnlockResume`, in `HKCU\...\RunOnce`) has
  now consumed itself at login, with no window, no console and nothing visible at all, on five or six
  separate restarts today - every one of them recovered only by manually re-running `Install-GpuUnlock.ps1
  -Resume` by hand afterward, which has worked every single time. RunOnce has no console attached and
  nowhere to show a terminating error, so a failure early enough (loading a module, or
  `Test-DesktopAvailable` itself) would look exactly like "nothing happened at all" - indistinguishable,
  from the outside, from the dialog silently hanging instead.
- `Install-GpuUnlock.ps1` now writes one line, unconditionally, before anything else can fail, to
  `C:\ProgramData\WindowsGPUUnlock\installer\last-launch.log` (PID, session ID, which switches were passed),
  then another once module loading and the window/console decision succeed, with the loading and
  `Test-DesktopAvailable` steps each wrapped in their own try/catch that logs the exact exception before
  re-throwing (behavior on failure is unchanged - still throws - this only adds a record of what happened
  first). Inside `-Resume` specifically, it also logs right before `Invoke-ResumeStart` is called and right
  after it returns an answer, and logs inside that path's existing `catch` block too (previously that catch
  only showed a notice via `Show-Notice`, itself dependent on `$useWindow` - if that was ever the actual
  problem, the notice could have been just as silent as everything else).
- Nothing about the registered RunOnce command line changes: `Test-Resume.ps1`'s own assertion that it's
  exactly `!"<powershell.exe>" -NoProfile -ExecutionPolicy Bypass -File "<ScriptPath>" -Resume`, nothing
  appended, stays true - the logging lives inside the script RunOnce already launches, not in how it's
  launched.
- Verified: `Run-AllTests.ps1`, 1153 of 1153, run elevated.
- Still open: next time this happens, `last-launch.log` should finally say whether it never started,
  crashed loading a module, failed `Test-DesktopAvailable`, or actually reached and hung inside the resume
  dialog - at which point there'll be something real to fix instead of a fifth guess.

## 2026-10-30 - Dropped the Start menu shortcut option; the desktop shortcut is now the only one

- On the reference machine, even after the 10-28 fix made a failed shortcut non-fatal, the underlying refusal
  kept recurring: the Start Menu folder's own permissions (outside this project's control, shared with every
  other app on the machine) got reset back to a state the installer correctly refuses - most plausibly by a
  routine Windows feature update applying its own default ACL template during a large build upgrade. That
  isn't a bug in the installer's check (a personal account SID on that folder genuinely is the tampering risk
  the check exists to catch); it's that the folder isn't this project's to keep fixed every time something
  else resets it. Decided not to chase that any further: the desktop shortcut nobody turns out to need the
  Start Menu one for.
- `New-UnlockShortcut` (`installer/Schedule.ps1`) no longer takes a `-Desktop` switch or builds a two-location
  `$links` array - it always makes exactly one shortcut, on the desktop, and the icacls-hardening block that
  only ever applied to the Start Menu location (`/setowner`, `/reset`, `/inheritance:r` on the link itself) is
  gone with it, along with `Get-SysStartMenuPath`.
- `installer/Main.ps1`'s `schedule` phase now asks one question ("Create the shortcut ... on the desktop?")
  instead of two ("... in the Start menu?" then "Also put a copy on the desktop?"), and shows the
  edit-by-any-program-running-as-you warning up front, since it now applies to the only option offered.
  `installer/Extras.ps1`'s `extra1-shortcut` (rewords the shortcut for automatic mode) and `Revert-ToManual`
  (rewords it back) both drop the now-nonexistent `-Desktop:$withDesktop` argument - the second of those was a
  real latent bug already: it would have thrown a parameter-binding error the first time anyone actually hit
  that code path, since nothing had called it with the old two-shortcut shape in a long time.
- `installer/Rollback.ps1` is deliberately left untouched: it still recognizes a journaled
  `'create the Start menu shortcut'` entry from an install made before this change, so rolling one of those
  back still works. `installer/tests/Test-Rollback.ps1` keeps a fixture proving exactly that, now explicitly
  uncoupled from the cross-file consistency check (which does need Schedule.ps1 to still contain every string
  Rollback.ps1 looks for in a *current* install).
- Verified: `Run-AllTests.ps1`, 1152 of 1152, run elevated.

## 2026-10-28 - A failed Start menu shortcut used to stop the whole install, with no visible way out

- Found live: on a machine where the shortcut fails (an admin/ACL problem on that one PC, same as the one
  this project already hit on its own reference machine), `New-UnlockShortcut` throws, and neither place
  that calls it (`Invoke-Phase-schedule` in `Main.ps1`, `Invoke-Phase-extra1-shortcut` in `Extras.ps1`) had
  anything catching it - the whole install just stopped with a raw error. Because the shortcut step hadn't
  advanced the saved phase, resuming landed on the exact same question and failed the exact same way every
  time; the only way out was realizing, unprompted, that answering "No" to "create the shortcut?" the
  second time around would skip it instead of retrying it. Nothing told the person that.
- Fixed by wrapping both calls in a try/catch: a failure is now reported in plain language ("the shortcut
  was not made: <reason>... this is optional and does not affect the unlock itself") and the install
  continues on its own, the same way the startup-task step right next to it (`Enable-EveryBoot`, same file)
  already handled its own failures - one of the two call sites was just missing the pattern the other one
  already used.
- Verified: `Run-AllTests.ps1`, 1161 of 1161, run elevated so `Test-Schedule.ps1` and `Test-Secure.ps1`
  (both need real elevation) actually ran rather than skipping.

## 2026-10-28 - Two more fixes found live during a second real power loss: a stuck build, and a GOP race that outgrew its own fix

- **`internal-boot/boot/prepare-console.c`**: a real hard power loss on the reference machine hit `HANDOFF
  STOPPED` at `console-prepare-preflight` with `EFI_UNSUPPORTED` - the exact slow-second-GPU-GOP race an
  earlier fix today was built for, except that fix only retried the first call (`Displays`); this time the
  same race apparently surfaced one step later, in `Snapshot`, `Consumers` or `Alive`, none of which were
  covered. Widened the existing retry loop to cover the whole discovery-and-check chain together, re-run
  from a freshly zeroed `PLAN` each attempt, instead of only its first step - same bound (15 retries, 200ms
  apart, only on `EFI_UNSUPPORTED`, same as before), just covering all four checks instead of one.
  Verified against this machine's own real captured hardware data: `test-console.ps1` (366 checks) and
  `test-full.ps1` (9032 + 39 checks), both passing.
- **`installer/Main.ps1`**: on the very first clean install after today's rollback fix, step 8 (building the
  read-only diagnostic) failed outright - `platform-config.h file not found`. Root cause: that file is only
  generated inside the later `build` phase (step 15), but the diagnostic needs it seven steps earlier; every
  prior run that happened to work was quietly relying on a stale copy left over from earlier development on
  this machine, never on a truly clean checkout. Fixed by generating it at the start of `diag-build` too
  (the existing `build`-phase call is untouched, so it's written twice, harmlessly, with the same content).
  Verified: `Run-AllTests.ps1`, 1054 of 1055 (the one failure is the known non-elevated Test-Schedule skip).
- Also, while chasing the Start-menu-shortcut refusal again on this run: the machine's actual Start Menu
  folder had two personal-account ACEs baked directly into its permissions (one for a long-deleted account
  this machine had RID 1000, and - more interestingly - one for the current administrator's own account).
  Removed both by hand (Administrators-group membership already grants everything the personal one did, so
  this changes no actual access) - not a code fix, just real drift on this one machine, cleaned up so the
  install can actually exercise the shortcut step instead of always hitting this machine's own pre-existing
  condition.

## 2026-10-28 - Roll back left its own every-boot state file behind

- Found live, on the first full clean end-to-end run: Roll back correctly removed the "unlock at every
  start" scheduled task and put Fast Startup back, but left `arm-state.json` (the task's own
  circuit-breaker state, "armed or not, how many runs left") sitting in the data folder afterward.
  Harmless once the task itself is gone - nothing reads it - but still a real gap, not what Roll back's
  own promise ("deletes the installer's working files") says it does.
- Root cause: `Rollback.ps1`'s cleanup list named the file `unlock-schedule-state.json` - a name from
  before this file was renamed to `arm-state.json` elsewhere (`internal-boot/Set-UnlockSchedule.ps1`),
  never updated here. `Test-Rollback.ps1`'s own fixture had the same stale name baked into it, which is
  exactly why the test never caught the mismatch - both sides agreed on the wrong name. Fixed both to the
  real name, `arm-state.json`.
- Also removed the one real leftover file this bug had already produced, on the reference machine, by
  hand (elevated - the data folder only an administrator or SYSTEM can write to).
- Verified: `Test-Rollback.ps1`, 98 of 98.

## 2026-10-28 - GUI: rounded window corners and buttons that follow whatever Windows theme is already running

- Cosmetic only, no change in behavior. Went through three real attempts, each one seen rendered on the
  reference machine and judged on that, not on how the code read:
  1. A fixed custom color theme (light background, dark-navy header banner, a blue accent, flat
     borderless buttons). Rejected on sight: numbered-option buttons had a near-invisible border, the
     whole thing read as flat and plain, and a second pass that gave those buttons an accent-colored
     outline was rejected too, for the same reason in reverse - the colors were the wrong fix, not the
     amount of color.
  2. Reverted `installer/Gui.ps1` entirely back to its original plain-default-controls state (no custom
     theme, no overridden `FlatStyle`). Judged better than either colored attempt, but still "looks old" -
     square window corners and square buttons, the two things every current Windows app has and this one
     didn't.
  3. What actually shipped: the window's own corners are now genuinely rounded, via a direct
     `DwmSetWindowAttribute` call (`DWMWCP_ROUND`) - ignored harmlessly on anything older than Windows 11,
     not emulated. The whole window's colors now follow whatever light/dark mode the person already has
     Windows set to (read once from `HKCU\...\Personalize\AppsUseLightTheme`, applied via
     `DWMWA_USE_IMMERSIVE_DARK_MODE` for the title bar and a matching palette for everything else) -
     stock default colors in light mode, unchanged from attempt 2; a proper dark palette only in dark
     mode. Buttons are repainted with a real anti-aliased rounded rectangle instead of a hard corner -
     a `Region` clip was tried first and rejected as "blocky": clipping has no anti-aliasing, so the curve
     comes out as a visible pixel staircase, not smooth. Owner-drawing it with `GraphicsPath` and
     `SmoothingMode.AntiAlias` was the only way to get an actual smooth curve in classic WinForms.
- Two real bugs, both caught by the test suite before being called done, not after:
  - The same top-level/dot-source-time ordering mistake as earlier today, recurring in the new dark-theme
    color table: it built `System.Drawing.Color` values before `Add-Type -AssemblyName System.Drawing` had
    run. Fixed the same way, by moving the `Add-Type` call ahead of the table.
  - The first rounded-button draft blanked each button's real `Text` property (to avoid drawing the label
    twice) - broke the test suite's own click-by-text lookup (`ButtonNamed`, via `Where-Object Text -eq`)
    and would have broken screen-reader access the same way. Fixed by keeping `Text` set normally: the
    repaint already erases and redraws the whole face before adding the label back, so nothing is actually
    drawn twice on screen either way.
- Verified: `installer/tests/Test-Gui.ps1`, 56 of 56, after each of the three attempts. Confirmed live on
  the reference machine: rendered, looked at, and approved ("perfect") only after attempt 3 - attempts 1
  and 2 were both rejected the same way, by looking at the real window, not by the tests passing.

## 2026-10-28 - a real administrator's own account could get the Start menu shortcut refused

- Found live: the Start menu shortcut was created, then immediately refused and deleted - "can be
  changed by ordinary users" - naming the installer's own creator account, a genuine local
  administrator. `New-UnlockShortcut` (`installer/Schedule.ps1`) only reset the shortcut's *owner*
  (`icacls /setowner`) after creating it; a freshly created file also keeps whoever's elevated session
  made it as an explicit entry on its own permissions, same as any new file (the comment already on
  `Write-SecureFile`, elsewhere in this project, says as much for the data folder) - changing the owner
  alone never clears that.
- Considered, and rejected, loosening the security check itself (`Get-SecurityProblems`) to also trust
  current members of the Administrators group by their own account SID, not just the group alias.
  `installer/tests/Test-Secure.ps1` caught exactly why that is the wrong fix: a personal SID baked into
  a permission entry survives that person later being removed from Administrators, while the group
  alias is resolved fresh by Windows at access time - trusting personal admin SIDs would have quietly
  reopened the exact tampering risk this check exists to prevent, for everyone, not just on this one
  machine. Reverted that change entirely.
- Fixed where the real gap actually was: the shortcut now gets the same full reset-and-explicit-grant
  this project already uses for its own data folder (`Protect-DataFolder`, same file) - not just a new
  owner, but the whole permission list reset and re-granted to exactly SYSTEM, Administrators and Users
  (read-only), so the shortcut's own permissions never depend on who happened to be logged in when it
  was made.
- Verified directly against the real Start menu location on the reference machine (not only the test's
  temp fixtures): a shortcut built the same way the installer builds one, then hardened the same way,
  now reports zero problems. Full installer suite, run elevated end to end for the first time today:
  1161 of 1161 pass, zero failures - including `Test-Secure.ps1` and `Test-Schedule.ps1`, which need
  real elevation to run at all and had been silently skipping or reporting an unrelated-looking failure
  in every earlier non-elevated run today.
- Separately, honestly: this reference machine's actual Start menu *folder* (not the shortcut itself,
  and not something this project creates or controls) also carries a stale permission entry from a
  local user account that no longer exists - a harmless leftover with nobody left who could exploit it,
  but still enough to make the installer's parent-folder check refuse on this one machine specifically,
  even with the fix above. That check staying strict there is correct, not a bug: a parent folder that
  genuinely allowed deleting and replacing the shortcut would be a real tampering vector. The shortcut
  is optional - declining it does not affect the actual unlock.

## 2026-10-28 - the first real unlock applied cleanly, then got refused at the final handoff check

- **The unlock itself worked.** On the reference machine's first fully clean run all the way through
  (every fix above in place, U pressed in time): the FLR completed, `SS0=0x88888888 SS1=0x00000008`
  confirmed in the transaction report - the exact unlocked target values. `HANDOFF STOPPED` happened
  one stage later, at `full-release.c`'s final pre-Windows safety recheck (`verify-driver-graph-match`,
  `FullExpected(&g,4)`), which failed with `EFI_NOT_READY`.
- Diffed the two full system handle/protocol graph captures this run wrote (`FULL03.TXT`, before and
  after the unlock) directly against each other. The target card's own PCI handle
  (`PreparedPlan.RtxPci`) lost three driver-level bindings across the FLR: two from the already-known
  NVIDIA driver agent (already tolerated by an existing stage-4 exception), and one from a second,
  separate agent bound through a protocol GUID (`fe47349a-7f0d-4641-822b-34baa28ecdd0`) this project
  has never named or tracked anywhere. A real FLR can legitimately disturb any driver-level binding the
  reset device held, not only the one agent this anticipated - and `FullExpected` required every
  `PreparedGraph` edge on that handle to still exist, with no exception for this one.
- Fixed, carefully: a `PreparedGraph` edge on the target's own PCI handle may now be missing at the
  final stage, from any agent - but a genuinely new, unaccounted-for edge on that same handle is still
  caught exactly as before, by folding its live count into the running total instead of exempting the
  handle outright. Nothing about any other handle's verification changed.
- Verified the distinction matters, not just the headline fix: an initial, simpler version (exempt the
  whole handle unconditionally) silently broke an existing host test built for exactly this edge case -
  `test_full.c` injects a deliberately suspicious new edge on this same handle and expects it caught.
  The corrected version passes that test *and* the real captured post-unlock graph. Full-release host
  suite: 9032 checks. Real `FULL.EFI` build: clean, PE-verified. Full host-mock and installer suites:
  no regressions (same two pre-existing, unrelated environment gaps as every run today - missing pinned
  stock-asset fixtures, and one local test-fixture ACL flake).

## 2026-10-28 - a missed keypress during the first manual unlock was reported as a hard failure

- The manual unlock's keypress wait (`internal-boot/unlock/app.c`'s `Arm()`, `stage="arming"`) cancels
  two ways by design, both completely benign and clearly documented on screen - "Press U to attempt
  once; Esc or 30-second timeout cancels": `EFI_TIMEOUT` if nobody presses U in time, `EFI_ABORTED` if
  Esc is pressed. Neither touches the hardware (`attempted=0`). `installer/Unlock.ps1`'s
  `Read-RunReport` classifier required a literal `status=0` for its benign "nothing happened"
  (`NotApplied`) class; a timeout or Esc reports its own actual EFI_STATUS code there instead (that is
  simply what the check recorded), so both fell through to `Failed` - the installer told the user to
  post a public bug report for a report that was created by not noticing a prompt. `Failed` also never
  offers "Try again?", only "Close" - found live on the reference machine after a real missed keypress.
- Fixed: the classifier now also accepts `attempted=0` at `stage=arming` with exactly those two known-
  benign codes as `NotApplied`. Every other combination - including those same two codes at any other
  stage - still correctly classifies as `Failed`, so this cannot mask an unrelated real failure that
  happens to share one of these status values.
- Verified: added three test cases (`installer/tests/Test-Unlock.ps1`) - timeout at arming, Esc at
  arming, and the same timeout code at a different stage (must still fail) - using the real `%#llx`-
  formatted status string `app.c` actually emits. Full installer suite: 1055 of 1055 relevant tests
  pass (same one unrelated, pre-existing local ACL flake as every run today).

## 2026-10-28 - the console-prepare GOP-retry fix crashed its own host test (null function pointer)

- The GOP-discovery retry added earlier today calls `bs->Stall(...)`. `tests/test_console.c`'s mocked
  `EFI_BOOT_SERVICES` never set `Stall` - a null function pointer - so any negative-test scenario that
  reached the retry path (most of them; that is the whole point of "negative case fails closed") now
  crashed instead of returning cleanly, which is exactly what the earlier `-Werror`-clean build and
  `test-all.ps1` pass could never have caught: `test_console.c` isn't part of that suite, it is its own
  script (`test-console.ps1`), and it was never re-run after the retry change. Found live, the first
  time the real installer ran its full host-test plan against a fresh capture rather than a cached one.
- Fixed: added a no-op `Stall` mock (`tests/test_console.c`) - a host test replays a fixed, already-
  known graph, so a real wait could never discover anything a no-op wouldn't; every negative scenario
  still correctly fails closed on the first or last retry attempt exactly as before, now without
  crashing to get there.
- Verified: confirmed every other host-test source file for anything that reaches `GuPrepareConsole`
  or includes `prepare-console.c`/`full-release.c` - `test_console.c` was the only one. Rebuilt and ran
  it against the reference machine's real fresh capture from this morning: 351 checks pass.

## 2026-10-28 - two installer bugs found live while updating in place on the reference machine, both fixed

- **The diagnostic and first-unlock "has it run yet" checks were blind to who queued the boot.**
  `Test-QueuedBoot` (`installer/BootEntry.ps1`) only checks whether the firmware's single one-time-
  boot slot has anything queued at all - it was never able to tell its own queued boot apart from an
  unrelated one. Every-boot mode's own startup task (`internal-boot\Arm-NextBoot.ps1`) queues and
  consumes that exact same slot completely independently. Hit live: the installer's diag-collect phase
  queued a diagnostic boot, it ran and left its log, but every-boot mode's task then re-armed a real
  unlock boot for an unrelated reason - so the installer, relaunched to collect its already-finished
  diagnostic, saw a boot queued and concluded its own hadn't happened yet, over and over. Fixed in
  `Invoke-Phase-diag-collect`, `Invoke-Phase-unlock-collect` (`installer/Main.ps1`) and the shared
  `Get-ExtraRunOutcome` (`installer/Extras.ps1`, backs the optional-extras and update-in-place
  collect phases too): each now checks for its own actual new report or log first, and only falls
  back to `Test-QueuedBoot` - to tell "still waiting" apart from "ran and left nothing" - when no
  report exists yet. A real new report now always wins over an unrelated queued boot, whatever else
  queued it.
- **A background host-test step could hang forever waiting for keyboard input that could never come.**
  `tests/test_stock_selection.py` proves `build.ps1`/`test-all.ps1` reject bad arguments by invoking
  them with mandatory parameters deliberately left out - but without `-NonInteractive`, PowerShell's
  normal response to a missing mandatory parameter is to prompt on stdin for it, not fail. That stayed
  invisible running from an ordinary console (stdin closed/non-interactive, so the prompt fails fast
  instead of blocking) until it hung for real, live, deep inside a UAC-elevated GUI installer's process
  chain during an update-in-place run: the inherited stdin handle there was open but nothing was ever
  going to write to it, and the prompt blocked indefinitely with no console the person could type into.
  Fixed: added `-NonInteractive`, which makes every one of these intentionally-invalid calls fail
  immediately, exactly as the test already expected.
- Verified: reran the specific hung command standalone to confirm the exact missing-mandatory-
  parameter prompt is the mechanism, confirmed `-NonInteractive` fixes it, then ran the complete
  negative-test script (19 compile-time + 14 build/test parameter-rejection cases) clean. Full
  installer test suite: 1052 of 1052 relevant tests pass (one unrelated, pre-existing local test-
  fixture ACL failure on this machine, reproduces identically with or without these changes).

## 2026-10-28 - the stuck-notification's Repair and "No, turn it off" buttons never actually worked

- Found live, on the reference machine, while testing the console-prepare fix below: clicking Repair on
  the every-boot-stuck toast, approving its UAC prompt, and confirming the elevated process actually
  launched - `arm-state.json` was still untouched afterward. Root cause: `Handle-NotifyAction.ps1`'s
  `Invoke-Elevated` built each action's command text from a scriptblock that used `$using:stateFile`,
  `$using:taskName`, `$using:power`. `$using:` is only valid inside `Invoke-Command`, `Start-Job`, or
  workflow `InlineScript` - it was never valid for a plain `Start-Process -Verb RunAs` to a brand-new
  process, which cannot see the calling process's variables at all. Every elevated action threw
  `UsingWithoutInvokeCommand` immediately and did nothing - not only when not already elevated, but
  even when already elevated, since `$using:` is invalid either way. The failure was also silent:
  nothing checked the elevated child's exit code, so neither Repair nor "No, turn it off" ever gave any
  sign they hadn't worked.
- Fixed: `Invoke-Elevated` now takes an explicit `-With` hashtable of the values its scriptblock needs;
  for a new elevated process these are re-declared as literal, single-quoted assignments before the
  body runs (a separate process can only receive literal text, never live variable references - that's
  the whole reason `$using:` existed as a feature elsewhere, and the whole reason it cannot work here).
  All three call sites (`repair`, `no`) updated to pass their values this way and drop every `$using:`.
  The already-elevated fast path is unaffected by this bug or its fix: plain variable names already
  resolve correctly there through ordinary scriptblock scoping. Also added: the elevated child's exit
  code is now checked and a failure throws, instead of being silently swallowed.
- Verified: reproduced the exact failure standalone first (confirmed the precise `UsingWithoutInvoke-
  Command` error), then reproduced the fix standalone with a real UAC-elevated delete before applying
  it to the real file.

## 2026-10-28 - console-prepare retries before refusing a GPU's GOP as missing after a hard power loss

- Found on the reference machine after a real power loss: `GuPrepareConsole`'s first discovery pass
  (`internal-boot/boot/prepare-console.c`) requires both GPUs' own UEFI GOP (Graphics Output Protocol)
  handles to be registered before it will validate anything - the dual-console topology check needs
  `count>=2`. Diagnostic capture of the failed boot confirmed both GPUs were present at the PCI level
  (both bus addresses, both device IDs, config space intact) but only ONE GOP handle existed on the
  system at that moment: the console-driving card's GOP had come up, the target card's own GOP had
  not finished option-ROM initialization yet. A hard power loss changes PCIe link training and ROM
  shadowing timing compared to a graceful shutdown, so a secondary (non-console) GPU's GOP driver can
  genuinely take longer to appear - this was not a wrong-hardware or corrupted-state condition, just a
  boot-time race the check wasn't giving any time to resolve before concluding failure.
- Fixed: the first discovery pass now retries up to 15 times, 200ms apart (3 seconds worst case),
  specifically and only on `EFI_UNSUPPORTED` from that pass - never on a hard error, and never on any
  later verification pass. This changes nothing about WHAT is validated: every PCI identity check,
  driver-binding check, and topology match stays exactly as strict as before. It only gives a
  genuinely-still-initializing second GPU a bounded grace period before the check gives up, instead of
  failing on the very first look. A real missing or wrong GPU still fails exactly as before, just after
  the grace period instead of immediately.
- Verified: the change compiles clean (`-Wall -Wextra -Werror`) into the real deployable automatic-
  unlock EFI (`build-automatic.ps1`, PE-verified), and the full host-mock test suite still passes
  everything it did before (this file isn't host-testable itself - it needs real UEFI GOP handles -
  but nothing else regressed).

## 2026-10-28 - re-enabling every-boot mode no longer inherits a stale circuit-breaker trip

- Found on the reference machine: every-boot mode's circuit breaker (added 2026-10-26) correctly
  stops queuing after a run leaves no report, but `Set-UnlockSchedule.ps1 -Mode EveryBoot` never
  cleared that stuck state on a fresh (re-)enable. Turning every-boot mode back on after it had
  been off inherited whatever circuit-breaker state was left over from before - including a trip
  from a session that ended days earlier - so the very first re-arm attempt could report itself
  stuck with nothing having actually failed this time. Fixed: `-Mode EveryBoot` now deletes any
  existing `arm-state.json` before writing the startup task and running the first arm, so an
  explicit (re-)enable always starts from a clean slate. Confirmed on the reference machine: with
  a real stale-stuck state left over from an earlier day, re-running `-Mode EveryBoot` produced a
  clean "armed" log line instead of the stale "not armed: ... left no report" it produced before
  the fix.

## 2026-10-26 - generalized the last hardcoded reference-card assumption in the host tests

- `tests/test_efi_transaction.c`'s `check_fwsec_image()` asserted that any real firmware capture
  it parsed must equal this machine's exact numbers (`image_size==0xed00 && dmem_size==0x980`) -
  the one remaining hardcoded assumption flagged in an earlier entry as blocking other cards from
  passing. Replaced with self-consistency checks (sizes are positive, in-bounds, and the DMA
  rounding from upstream pull request #115 rounds up by less than one block and still fits the
  on-chip buffer) that hold for any real card's firmware, not just this one. A fixed-size local
  buffer sized to this card's exact image (`UINT8 expected[0xed00]`) became a buffer sized from the
  parsed image itself, with an added bounds check that the image's offset and size both stay
  inside the captured data before anything is copied.
- New `tests/test_fwsec_generalizes.c`: proves those checks hold for firmware shapes that are not
  this card at all - a synthetic fixture already used elsewhere in the test suite, and a second
  copy with its DMEM size mutated to a different, non-reference misalignment (not the same 0x980
  case) - so the generalization isn't just unverified assertion, it's demonstrated against two
  independent shapes with no real hardware involved. Added to the main host test run
  (`test-all.ps1`) so it runs automatically from now on.
- Confirmed with a fresh real capture from the reference machine the same evening (a new
  diagnostic boot, not reused old data): rebuilt the real experimental EFI image from the repo's
  committed reference profile and ran the complete host test suite against it - all 12 groups
  pass (`AllPassed: true`, `ExperimentalComplete: true`), including the generalized check against
  this fresh real PROM and the new synthetic proof. Zero regression on the one card this has
  always been verified on.
- Real-hardware confirmation on a genuinely different card still depends on someone with that
  hardware running the installer and reporting back - see the ask already in
  [impacifist/Windows-GPU-UNLOCK#41](https://github.com/impacifist/Windows-GPU-UNLOCK/issues/41).
  This change removes the known blocker; it doesn't yet prove any specific other card works.

## 2026-10-26 - the full changelog now lives in the README too

The README only had a two-entry preview linking out to this file. Readers land on the README first and shouldn't
have to click away to see the project's history, so every dated entry above now also appears directly in the
README, summarized to drop internal engineering detail (hashes, raw test-count tallies, file-rename bookkeeping)
that only matters to someone editing the code - this file stays the untrimmed, authoritative version. Removed the
old, now-redundant "Changes in this fork" section that duplicated part of the same story.

## 2026-10-26 - reproduced locked-vs-unlocked a day later, and measured real local LLM inference

- Repeated the locked-vs-unlocked GEMM benchmark from 2026-10-25 a day later on the same machine: FP16 tensor
  26,338.7 -> 47,938.4 GFLOPS (+82.0%), BF16 26,296.6 -> 50,071.9 (+90.4%), FP32 control +0.8% (noise). Consistent
  with the earlier run within normal variance.
- Specifically tested whether a plain Windows **Restart** (not a full power-off) resets the card: confirmed yes -
  this was the one open question left in the profile's hardware results. Both the locked and the unlocked side of
  this comparison were independently confirmed (not just assumed from whether the unlock was scheduled): locked by
  the FP16/FP32 ratio matching the documented locked reference, unlocked by the unlock program's own post-reset
  register readout in its boot report.
- New: measured how much of that raw gain reaches actual local LLM inference (a llama.cpp-based server), isolated
  to this one card. Prefill (prompt processing) gained +3.2% on a ~7,600-token prompt and +7.6% on a ~31,000-token
  prompt; decode (token generation) showed no measurable change at any size tested. Documented why the gap between
  +82% raw and +3-8% real is expected (KV-cache memory bandwidth, elementwise ops, quantization and smaller/more
  fragmented matmuls don't benefit the way one continuous saturating GEMM does). See
  [PROFILE-Z790-3060.en.md](docs/PROFILE-Z790-3060.en.md).

## 2026-10-26 - a notification for the stuck circuit breaker, and a release-freshness check

- **Every-boot mode now tells you, not just the status screen.** The startup task's circuit breaker (see
  below) only shows up if you reopen the installer. Added a second, logon-triggered task that runs as the
  signed-in user (not SYSTEM, which cannot show UI to a desktop session) and shows a Windows notification
  the moment it's stuck, with three choices: Repair (clears it, queues normally again from the next start),
  Ignore (dismiss, asks again next logon if still stuck), or "No, turn it off" (disables every-boot mode;
  run the installer again to turn it back on). Each choice is handled by a small, self-contained script
  registered against a dedicated URI, so it works even if the original installer download is long gone.
  Privileged actions (Repair, No) prompt for administrator approval the same way the Start-menu shortcut
  already does - nothing happens silently.
- **The installer now checks whether you're running the latest release** (its own check, C16): a VERSION
  file is stamped into the archive at build time; the installer compares it against GitHub's actual latest
  release tag. Never blocks, never fails - no internet or GitHub not answering just skips it quietly, and
  running from a plain checkout (not a release download) has nothing to compare, so it also passes quietly.
  When out of date, it names both versions and links straight to the releases page.
- Every release's GitHub page now gets a real changelog (the top CHANGES.md entry) instead of a bare
  compare link; fixed on the existing v1.0.0 release too.
- Tests: 5 new release-version checks, plus the notification machinery itself (not unit-testable - it needs
  a real logon session, a real toast, and a real administrator prompt; verified by hand instead: the exact
  stuck-detection logic it reuses is already covered, and the real GitHub API call was confirmed working
  against the live repo). Installer total 1158 checks.

## 2026-10-26 - every-boot mode's circuit breaker is now visible and repairable

- Found on the reference machine: when every-boot mode's startup task queues an unlock and that run leaves no
  report (a real freeze, a power loss, or a deliberate test can all cause this), its circuit breaker correctly
  stops queuing new ones - but until now nothing told the user that happened, and there was no way back except
  deleting a file by hand in ProgramData. A real user hitting this for real (not testing) would just find every-boot
  mode had silently stopped, with no explanation and no self-service fix.
- The status screen now checks for this (only when every-boot mode is on), explains plainly what happened, and
  offers a repair - same pattern as every other repair here: it asks first, and only clears the stopped state so
  the startup task's own normal check does the rest starting at the next restart. Nothing is forced or restarted
  by this repair itself.
- Tests: 8 new checks (not flagged outside every-boot mode or before it has run once; detected from the circuit
  breaker's own log line; shown with a repair offered; declining changes nothing; confirming clears the stuck file).
  Installer total 1153 checks.

## 2026-10-26 - release checklist drafted; requirement 29's hardware drill repeated

- `docs/RELEASE-CHECKLIST.en.md` added: the steps for requirement 17 (SHA256SUMS, a GitHub artifact
  attestation, the README note on unsigned scripts) and the repeat of the hardware recovery drill
  for requirement 29, kept as release-time process rather than installer code.
- The hardware drill (steps 1-5 of the checklist) was repeated on the reference machine: a hanging
  test image was staged in place of the fallback boot file, one boot was queued, the screen froze as
  expected, holding the power button then powering on gave a normal Windows start with no BIOS and no
  menu, and the startup task's circuit breaker logged "not armed: the previously queued unlock left no
  report" and queued nothing further. Roll back then restored the original boot file (hash-checked)
  and confirmed nothing was left queued; the startup task and Fast Startup were unchanged throughout.
- `publish` branch rebuilt from this commit: full tree brought across (a single clean commit, no
  installer code changed), re-tested (1145/0), and scanned for the owner's real name/email and any
  personal path — none found in file contents (the only place the real identity ever appears is
  `main`'s own commit history, which is why only `publish` is ever pushed).

## 2026-10-26 - requirements 14, 16 and 31 closed

- 14: the Roll back text (first screen and confirmation) now carries the plan's last paragraph: it never touches your Windows files, your data, BIOS settings or the card's stored firmware; prerequisites you changed yourself (Secure Boot) are not reversed; the card behaves as if the installer never ran.
- 16: when the profile is accepted the installer records the board and BIOS version. If either differs later (a BIOS update), the phase loop stops, says what changed, offers to remove the startup task until then, and on a yes forgets everything that depended on the old capture (profile, build, tests, verdict, extras) and starts a new capture; the choices (cards, boot partition, backup) are kept. A finished install now shows a status screen on every run: Secure Boot, Fast Startup, BIOS/board, the firmware's boot entry, the boot partition's identity, and whether the fallback file `EFI\BOOT\BOOTX64.EFI` is the program the installer put there. Repairs ask first: put the boot programs back (saved copies of anything replaced), or restart so the firmware makes its entry again. Secure Boot and Fast Startup are only reported (the installer does not change them).
- 31: the boot programs' source fingerprint is stored at build time. A finished install whose installer carries different sources shows the latest CHANGES headings and asks "Update the boot programs now?" (default none). Yes rebuilds from the existing capture, reruns the host tests (no skip), stages the new programs (replaced files saved first; manual pair, plus the automatic pair if extra 1 is on; extra 2 goes back to the Esc version), runs one unlock to check them, and keeps the user's choices. No benchmark or first-time questions are asked again. Three new phases: update-stage, update-queue, update-collect (38 in all).
- Plan doc: a status section lists what is deliberately not code (requirement 17 and the hardware half of 29 are release-time tasks; 23's per-layout recovery text is optional polish).
- Tests: Status 73 new checks (BIOS and board change, a forced new capture through the phase loop and the session, every status item, repairs, fingerprint, update offer and the update phases). The real build phase is replaced in those tests because it writes the local partition configuration.

## 2026-10-26 - graphical front end (plan requirement 32)

- `Install-GpuUnlock.cmd` now opens a Windows Forms window (no download: it ships with Windows PowerShell 5.1). `-Console` (or no desktop to show a window on, or a window that cannot be built) uses the text version. The installer runs in a worker (a separate runspace) so the window never freezes; the worker's prompt functions (`installer/GuiPrompts.ps1`) replace `Read-Answer`, `Ask-YesNo`, `Ask-Number`, `Ask-Phrase`, `Write-Plain` and `Write-Host`, and send everything to the window (`installer/Gui.ps1`) through a queue. The phases, state, journal, safety rules and tests are the shared modules; the session body moved from the launcher into `installer/Session.ps1`, which both front ends run.
- The window: step line ("step N of 35 (what it is)"), a bar that moves while a step runs, a coloured scrolling log, and an answer area with Yes/No (nothing selected, Enter does nothing), one button per numbered option plus the question's own none word, a check box + Confirm where the console wants a typed word (shown with the question's exact sizes), and a Close button at the end. It cannot be closed while a step is running; closing at a question stops the worker at that question.
- Tests: Test-Gui 56 (the worker's prompt functions run in a real second runspace and are answered from the test; the window's controls built and clicked; one set of questions for both front ends). `tests/Integration-Gui.ps1` opens the real window and runs the real installer session in dry run with real read-only queries and scripted answers (4 questions, layout measured, nothing changed). A text-mode dry run of the launcher was also run with piped answers. Installer total 1071 checks. A trial that took screen pictures of the window also captured other windows on the desktop; those pictures were deleted and the approach dropped (the script now measures the layout instead). Plan text for the shortcut step corrected (Start menu, not desktop).
- Not tested: a full real install through the window (needs the restarts); the window on other Windows versions or display scaling settings; the Windows approval prompt.

## 2026-10-26 - user guide, launcher arguments, check text

- `docs/INSTALLER-GUIDE.en.md`: a plain-words guide to the installer as it is today (what it needs, every question in order, restarts and the optional automatic resume, the boot partition choices, the two extras, what Roll back does and asks, what it never does). README status and table updated.
- `Install-GpuUnlock.cmd` now passes its arguments on (`-DryRun`, `-Rollback`).
- Check C11 told the user the installer would turn Fast Startup off, but a failed check stops the installer; the message now says how to turn it off and run again.
- Roll back compares a shortcut's target as text, not as a wildcard pattern.
- A guard refuses to write a resume entry that points into a test folder. Reason: in the first run of the new tests, before the test harness replaced the registry functions, two failing tests wrote one real RunOnce value (pointing at a temporary test folder); it was found by a read-only dry run, removed, and confirmed gone; nothing else outside the repository was touched.

## 2026-10-26 - installer stage 8: the two optional extras

- `installer/Extras.ps1`, ten new phases after the schedule step. Offered only if the unlock was verified and the benchmark did not say "no meaningful improvement". Each extra has its own screen (what changes, what does not, warnings, the freeze-and-power-button recovery, disclaimer) and needs the typed words `I ACCEPT` (case-sensitive); declining or a wrong answer changes nothing.
- Extra 1 (no key press): stages UNLOCK-AUTO.EFI, AUTO.EFI and makes AUTO.EFI the file the firmware entry starts (each replaced file saved first), queues one automatic run, and confirms it from the run report and, if the benchmark is on, a measurement that looks unlocked. Only then is automatic mode marked active, the shortcut remade ("no key needed") and unlock at every start offered. A cancelled run, a failed check, no report or a card that does not look unlocked puts the manual setup back at once (a failed check also writes a public-safe report).
- Extra 2 (no Esc countdown), offered only after Extra 1 works: needs Git for Windows (the patch is applied with `git apply`); applies `patches/no-cancel-windows.patch` only while building, builds the private pair against the user's own profile, runs the automatic-mode and manual-mode host tests on it, and ALWAYS takes the patch off again (a leftover patch from an interrupted build is removed first, and by Roll back). Then it stages the pair, runs it once and confirms from the report; any failure puts the version with the Esc windows back.
- "Switch the optional extras off" appears in the start menu while automatic mode is active: it puts the manual wrapper back, removes the startup task (Fast Startup restored), remakes the shortcut as manual; nothing else is undone. Roll back also restores the user's original files through the saved copies.
- Bug found while testing against the real tree: `patches/no-cancel-windows.patch` no longer applied after the stage 3 profile change (build.ps1's parameter list and the test file had moved). The patch was regenerated. Real check on the reference PC: applied with Apply-NoCancelWindows.ps1, built, hashes AUTO.EFI 6734a56e82f8 and UNLOCK-AUTO-NOESC 784dfd511fb1 (identical to the earlier no-wait pair), patch removed again, tree clean; nothing staged or queued. A test now runs `git apply --check` on the real tree.
- Tests: Extras 93 (typed acceptance, gating, staging with saved originals, every revert path, the patch always removed, whole chain through the phase loop, Roll back after both extras restores the user's original file byte for byte). Installer total 1014 checks. Not tested: a real run of automatic mode or the no-cancel version through the installer (it needs the restart); the no-cancel version has not been run on hardware.

## 2026-10-25 - installer stage 7: Roll back, restart with optional automatic resume, resume dialog

- `installer/Rollback.ps1` (`Install-GpuUnlock.ps1 -Rollback`, or Roll back from the start menu, the resume window or the verdict screen): reads the journal and undoes, newest first, only what it says the installer did. Every step is checked first: a boot-partition file is deleted only if its hash is still the one the installer wrote (otherwise it is left and reported); a file the installer replaced is put back from the saved copy after that copy's hash is checked; empty folders the installer made are removed; the boot partition is used only if it is still the recorded partition (same GUID) and still labelled GPUUNLOCK (the drive letter is looked up again, never trusted from the journal). A partition the installer created is deleted only if it holds nothing but the installer's and the programs' own files, after a typed `DELETE`; an existing partition is never deleted. If the installer shrank C:, the exact sizes are shown and C: is extended only after a typed `EXTEND` (and only if the freed space is really free; otherwise a Disk Management hint is given). Also undone: the automatic-resume entry, a one-time boot the installer queued, the startup task and its generated files (Fast Startup back to its saved value), the shortcuts and their script (only if they still point at the installer's script), the generated partition configuration. Asked, not assumed: keep or delete the generated NVIDIA firmware files and the benchmark download. The rest of the work folder (including the card's own image) is deleted; reports, logs and backups are kept; build tools installed by winget are listed as left installed. It ends with a checklist (removed / already gone / LEFT / kept) and compares Fast Startup and the firmware boot order with the backup. The journal is archived and the state file removed. `-DryRun` lists what it would do and asks nothing.
- Bug found by the new tests and fixed in `Capture.ps1`: the saved copy of a replaced boot-partition file had the same name every time, so replacing the same file twice (diagnostic, then unlock program) overwrote the user's original. The name now carries the replaced file's hash.
- `installer/Resume.ps1`: at a restart the installer asks once "Continue automatically when you log back in?" (the answer is kept). Y registers one current-user RunOnce value (with the `!` prefix) that starts `Install-GpuUnlock.ps1 -Resume`; the entry is journaled. The resumed run opens a window (Windows Forms, console fallback) saying "step N of 25 (what it is)" with Continue / Not now / Roll back; nothing changes before Continue, then Windows shows its own administrator prompt. The entry is removed in every case: when the resumed run starts, when a run ends without a restart having started, when the restart is declined or refused, on any error, on Roll back and at the end; a leftover entry is reported and removed at the start of every run. A run that finds an earlier install offers Continue / Roll back / Exit. The first screen and the Roll back confirmation show the plain-words explanation from plan requirement 14.
- Tests: installer 817 + new checks (Rollback 98, Resume 55; Pipeline and others adjusted for the consent question). Roll back is exercised on real files in temporary folders with every system call replaced; the partition and C: cases include shrink-succeeded-but-creation-failed (C3), a foreign file on the partition, a partition with a different identity and a changed file. `tests/Integration-Dialog.ps1` shows the real window for a moment and clicks each button (4/4); the rendering was looked at in a saved picture. Not tested: the registry value and the partition calls on a real PC (replaced in the tests), a different Windows account elevating (the RunOnce key is the elevated account's).

## 2026-10-25 - review fixes (path length, run detection, partition choice, download help) and a protected data folder

- Folder path: new check C15 refuses an installer folder path over 100 characters (the build makes names up to 149 characters below it; Windows allows 259), the host test programs say when a file cannot be opened, and every script that imports the Visual Studio environment puts vswhere's folder on PATH itself.
- The new unlock run and the new diagnostic log are found by folder or file counter (the item that was not there before queueing), not by file times from the firmware clock; tests use clocks 5 hours ahead and behind.
- Boot partition: only a partition labelled GPUUNLOCK on an internal disk is used as it is; other EFI-type partitions and USB disks are reported as "found but not used". After a C: shrink the partition is created exactly in the freed space (offset), its identity is journaled before the position is checked, so Roll back can find it.
- The FP16/FP32 "already unlocked" guard is documented as a hint only (an unlocked RTX 3090 sits near 4.0); the authoritative check is the capture's selector state. A failed firmware download now prints exactly which file(s) and SHA-256 to fetch by any means and where to put them. README states that other cards may be refused. Plan requirement 32 (a graphical front end) added.
- Security (from the first session's review): `internal-boot/SecureFolder.ps1` makes C:\\ProgramData\\WindowsGPUUnlock a real folder (a junction or symbolic link at the path is removed, the link only) owned by the Administrators group and changeable only by administrators and SYSTEM; files are written to a new name, owner-set, read back and removed if any other account could change them. The startup script (SYSTEM) and the shortcut script (administrator) embed the same check and refuse to run if their file or folder can be changed by ordinary users. The state and journal that Roll back trusts live in the protected folder; a dry run only reports an unsafe folder. The shortcut goes in the all-users Start menu (administrators only); a desktop copy is an optional extra with a plain note. Tested with real permissions on temporary folders: planted file owned by the Users group, junction at the path, loosened permissions, symbolic link. Installer tests: 767 checks.

## 2026-10-25 - installer stage 6: the "Unlock my GPU on next boot" shortcut and the every-boot opt-in

- `installer/Schedule.ps1`: creates a script in the installer's data folder and the desktop shortcut "Unlock my GPU on next boot" with the Run-as-administrator flag, so Windows shows its own approval prompt. The script checks administrator rights and that Secure Boot is off, finds the firmware entry by label and path every time (never stored), queues ONE one-time boot, tells the user what will happen (manual: press U once, Esc or 30 s cancels; automatic: no key), gives the power-button recovery, and offers a restart with a 30 s countdown and the `shutdown /a` cancel command. It queues nothing permanent and never mentions the BIOS or a boot menu. Roll back (stage 7) removes both.
- The firmware-entry lookup now lives in one file, `internal-boot/UnlockEntryLookup.ps1`, used by `Set-UnlockSchedule.ps1` (and pasted into the startup script it generates) and by the shortcut script; a test checks the shortcut script embeds it unchanged.
- Every boot is an opt-in (default No) with the full warning (what runs, the freeze-and-power-button recovery with no BIOS or menu, Fast Startup turned off with its old value saved, the backup, how to undo) and is refused unless automatic mode is active and an unlock has been verified. It is wired through `Set-UnlockSchedule.ps1 -Mode EveryBoot` / `Off`. It needs automatic mode because its circuit breaker reads automatic-mode run folders (AUTO*) and so cannot protect a manual setup; it is therefore offered together with Extra 1 at the very end (stage 8).
- New phase: schedule (after the verdict). Tests: installer 677 checks (Schedule 59). The generated shortcut script is EXECUTED in a test with fake bcdedit and shutdown programs first on PATH: it queues exactly `bcdedit /set {fwbootmgr} bootsequence <entry>`, restarts only after Y, queues nothing when no entry matches or bcdedit refuses, and says "Nothing was changed". The shortcut is created for real (COM) in a temp folder and its run-as-administrator flag is read back. A whole-flow dry run on the reference machine (real read-only queries) left the desktop, boot queue, U: files, startup task, Fast Startup and platform config unchanged.

## 2026-10-25 - installer stage 5: first unlock, benchmark before and after, verdict

- Benchmark generalized: `benchmark/compute-benchmark.cu` (renamed from the 3060-specific file) selects the card by PCI address (`--pci 0000:BB:DD.F`) and reports its name instead of assuming it. `setup.ps1`, `build.ps1`, `run-benchmark.ps1` take `-Root` (the installer keeps everything in its own folder); `run-benchmark.ps1 -Bus` works on one card only, refuses a busy (over 5% load or 2048 MiB) or hot (over 65 C) card by naming the programs using it (file names only), and writes `summary.json` with medians, highest power, temperature and clock, and the driver. `setup.ps1 -ListOnly` reports the exact download: 488,838,722 bytes in four files (the plan's "about 470 MB" was roughly MiB; it now says about 489 MB). The benchmark builds with NVIDIA's toolchain on the reference machine (metadata check only; no GPU load was run on the user's cards for these changes).
- `installer/Benchmark.ps1`: the offer with the required strong recommendation word for word, decline path ("improvement not measured", offered again at the end), preparation, per-card runs, an "already looks unlocked" check (FP16/FP32 ratio at or above 4.5; about 3.2 locked and 5.9 unlocked on the reference card, an inference for other cards), the verdict (better of FP16/BF16: at least +20% clear, +5% to +20% small, otherwise no meaningful improvement and rollback recommended; the FP32 control flags unequal conditions; a one-precision gain mentions upstream issue 28; percentages are compared as displayed, one decimal) and a public-safe report.
- `installer/Unlock.ps1`: stages the manual pair only (UNLOCK.EFI, MANUAL.EFI), the five firmware files under RTX3060-UNLOCK\ASSETS and the manual wrapper as the firmware entry's file, each replaced file saved first, refused if a built file changed after the tests, read back afterwards; reads the run report (Applied / NotApplied / Failed / Unreadable); first-unlock instructions (press U once, Esc or 30 s cancels, power-button recovery, no BIOS or menu). New phases: benchmark-offer, benchmark-prepare, benchmark-before, stage, unlock-queue, unlock-collect, benchmark-after, verdict. Programs that have not passed the host tests are never staged.
- Tests: installer 618 checks (new: Benchmark 68 including the REAL run-benchmark.ps1 against small fake nvidia-smi and benchmark programs, Unlock 52, Verdict 41, Pipeline extended to a whole install across four runs with three restarts, benchmark and verdict). A dry run of the whole flow on the reference machine with real read-only queries found one bug the mocks missed (staging in a dry run had no build record yet; fixed) and then finished with the boot queue, U: files, startup task, Fast Startup and platform config unchanged.
- Not testable here: a real GEMM run (needs the target card under load), the unlock itself on another PC.

## 2026-10-25 - installer stage 4: firmware files, build and host tests on the user's own capture

- NVIDIA firmware on Windows without WSL: `firmware-tools/` holds unchanged copies of upstream's four generator files (Zagitta/gpu-unlock at the pinned commit, GPL-2.0-only; credited in THIRD_PARTY_NOTICES.md). `installer/Firmware.ps1` asks first, discloses every download (about 343 MB in all: NVIDIA source 26 MB from download.nvidia.com, the nvidia-utils package 315 MB from archive.cachyos.org, portable zstd 1.7 MB from github.com), checks each against its pinned SHA-256, checks the bundled scripts against pinned hashes, runs them with Python 3.12 and zstd, and verifies the five results against internal-boot/unlock/assets.json; a failure leaves no half-made folder. Verified for real: the route reproduced all five files, with matching sizes and hashes, in about 20 seconds. Upstream's README says Python 3.14 is needed; at this commit the scripts call the zstd command instead, so Python 3.12 is the minimum the installer now asks for.
- `installer/BuildTest.ps1`: writes the local partition configuration (golden: byte-identical to the one the reference build uses), builds the manual and automatic boot programs against the generated profile (stale images removed first), and runs seven host test groups in separate processes: boot programs, diagnostic, console release replay, full release replay, the unlock program/checks/transaction on the user's own PROM and firmware, automatic mode, manual mode. Any failure stops the installer and writes a public-safe report; there is no skip. Test scripts changed to take this PC's values: `-FixtureArgs` (test-console, test-full), `test-full.ps1` passes the monitor-driver image only for firmware that binds one (the old script always passed it and failed on the reference layout), `test-automatic.ps1` takes `-VcVars`, and the fixed card id was dropped from the test builds (the profile supplies it).
- The profile summary now carries the card ids, path nodes and driver image name the replay tests need. Phases added: firmware, build, hosttests. The capture's PROM.BIN is kept in the local work folder for the tests (never reported or published); each capture gets its own folder.
- Real end-to-end check on the reference machine (`installer/tests/Integration-RealPipeline.ps1`, about 3 minutes): profile generated from its capture, platform config identical, the four images rebuilt with the identical hashes (manual 78aeb10ab783 / 663383920a33, automatic 111af4aa1236 / c1e4103d493d), all seven host test groups pass.
- Tests: installer 446 checks (adds Build 77, Pipeline 33: a whole install across three runs with two restarts and a failure/refusal path), tools 30, integration 16.
- Known limit: some unlock-side host tests contain the reference card's own expectations (its FWSEC image size and offsets, from its PROM). They pass for it; on a different card they may fail and the installer then refuses, which is the safe direction. They need generalizing before other cards can pass.

## 2026-10-25 - installer stage 3: tools, capture, and a profile generated from the capture

- Per-machine values now come from one profile file. `internal-boot/unlock/machine-profile.h` selects `profile.h` from the include path (a build passes `CPATH=<folder>`; without it the reference profile `unlock/profiles/z790-3060/profile.h` is used). Values that were hard-coded for the reference machine became profile values: target PCI bus, class/revision dword, the PCI Express and MSI-X capability pins, the GOP driver's code offset and file name, the two console drivers' firmware file ids, and the card names shown on screen. Result: the reference machine's boot images are byte-identical before and after (AUTO.EFI 111af4aa1236, FULL.EFI 78aeb10ab783, UNLOCK-AUTO.EFI c1e4103d493d, and the no-wait pair 6734a56e82f8 / 784dfd511fb1); host tests all pass.
- `tools/profile_gen.py` builds a profile from one read-only capture: it refuses (with a plain reason and a fix) unless the capture is complete, the card is untouched (cold registers and selectors), there is a display output on the target, both cards use the same two firmware console drivers, there is no monitor-identity (EDID) driver or virtual console, and the card's GOP driver can be fingerprinted. Golden test: from the reference capture it reproduces all 49 values of the hand-verified reference profile with zero differences, and images built with the generated profile are byte-identical to the reference ones. `--discovery` writes the minimal profile the read-only diagnostic needs; write-capable builds refuse it. 21 unit tests plus the existing tool tests (30 in all).
- `unlock/build.ps1` no longer carries a one-machine table: it reads the effective profile.h.
- Installer modules: `Tools.ps1` (finds LLVM 20.1.8, Python, MSVC build tools; offers winget installs with sizes and sources, only after Y), `BootEntry.ps1` (looks the firmware entry up every time; one-time boot queue; restart prompt with 30 s countdown and `shutdown /a`), `Capture.ps1` (diagnostic build and staging with backup of replaced files, collecting the capture, profile generation, plain-words summary and refusal report). Phases added to `Main.ps1`: tools, diag-build, diag-stage, diag-entry (one restart so the firmware makes its entry), diag-queue, diag-collect, profile. `-CaptureFolder` rehearses the rest in a dry run only.
- Bug found by the new tests and fixed: inside `Invoke-JournaledChange` the function's own `$id` hid the caller's `$id`, so the one-time boot would have been queued with the journal id instead of the firmware entry id. Locals now use a `jc_` prefix; regression test added.
- Tests: installer 336 checks (State 25, Cards 37, BootPartition 61, Flow 37, Tools 47, Capture 101, Checks 28), tools 30, internal-boot host suites rerun. A full dry run on the reference machine with real read-only queries and scripted answers finished with the boot queue, the files on U:, the startup task and Fast Startup unchanged.
- Not testable here: winget installs, the firmware creating its boot entry after the first restart on other boards, a real diagnostic run on another PC.

## 2026-10-25 - installer stage 2: state and journal, card selection, boot partition choice, backups, plan screen

- New modules under installer/: `State.ps1` (atomic state file; journal written before each change, with previous values, so Roll back knows what to undo), `Ui.ps1` (Y/N, number and typed-phrase prompts, no defaults), `CardSelect.ps1` (target card and screen adapter chosen by the user, told apart by bus address, re-checked at every phase; requirement 15), `BootPartition.ps1` (existing dedicated partition used and shown; otherwise the user chooses between another internal GPT drive and shrinking C:, with a separate typed SHRINK confirmation showing the exact sizes; never a default; requirement 9), `Backup.ps1` (boot configuration, firmware entries, partition table, Fast Startup value), `Plan.ps1` (one plan screen, confirmed once; requirement 30), `Main.ps1` (the resumable phase loop with -DryRun; requirement 8).
- `Install-GpuUnlock.ps1` now runs that loop. Phase order differs from the first plan: the boot partition is chosen and created before the capture, because the diagnostic runs from it.
- Tests: installer/tests (Harness, State, Cards, BootPartition, Flow, plus the earlier Checks) with scripted answers and mocked system queries; Run-AllTests.ps1 runs them all (187 checks, all pass). The real read-only queries were also run on the reference machine and read correctly (existing U: partition found, both cards listed).
- Not testable here: the real shrink, partition creation and format calls (Invoke-SysResizeC and Invoke-SysNewDedicatedPartition) run only on a PC that needs them; tests check their order, sizes and journal entries with mocks.

## 2026-10-25 - failure text now says to use the power button (plan requirement 29)

- internal-boot/boot/handoff.c: the four on-screen failure messages (the stop message and the release-only, headless-research and R2 console test banners) said "Windows Boot Manager" / F11 / F8. They now say to hold the power button until the PC turns off, then power on. The status line "Starting Windows Boot Manager directly" is unchanged.
- patches/no-cancel-windows.patch: context lines updated to the new text; `git apply --check`, apply and `-Undo` all work.
- Rebuilt into build folders only (nothing staged, no boot setting changed). AUTO.EFI with the Esc windows 8c43211b8674 -> 111af4aa1236; no-wait AUTO.EFI e6cb380d224d -> 6734a56e82f8. UNLOCK-AUTO.EFI is unchanged in both builds (c1e4103d493d with Esc windows, 784dfd511fb1 no-wait), because the unlock program itself did not change. Both new AUTO.EFI contain the new text and no F11 or F8 text.
- Host tests that cover this file pass: handoff 40 checks, diagnostic 35, console prepare 291. The unlock-side suite (test-all.ps1) was not re-run: nothing under internal-boot/unlock changed and its output hashes are identical.
- Not yet run on hardware. The images on the boot partition are still the earlier builds.

## 2026-10-25 - startup task looks up the firmware entry and checks its prerequisites at every start (plan requirements 27, 28)

- internal-boot/Set-UnlockSchedule.ps1: the generated Arm-NextBoot.ps1 no longer embeds the firmware entry id. It finds the entry for the GPUUNLOCK partition at every start (same function as the installer-time lookup, one source) and logs the id it queued. It also checks, each start, that Fast Startup is off, Secure Boot is confirmed off and the boot partition is present; if anything is wrong or the lookup finds zero or several entries it logs the reason and queues nothing.
- Verified on the reference machine: the script parses, the dry run finds the entry, the real run installed the new script with no leftover placeholder or embedded id; the prerequisites and lookup passed (the breaker then declined to queue because the earlier queued boot had not run yet). The first real re-arm with the new script happens at the next Windows start.

## 2026-10-25 - recovery drill passed; installer stage 1 (launcher, admin prompt, read-only checks)

- Recovery drill (plan requirement 29): `internal-boot/boot/hang.c` and `build-hang.ps1` build HANG.EFI, which prints one line, turns the firmware watchdog off and hangs, writing nothing. It was placed in the one-time boot slot and queued from Windows. The screen froze; holding the power button and powering on started Windows normally, with no BIOS and no menu. The slot was then restored to the automatic image (hash checked) and no boot was left queued.
- The startup task's circuit breaker was exercised by the same run: the hang left no report, and the next start logged "not armed: the previously queued unlock left no report" and queued nothing. Clearing it needs `arm-state.json` removed (done by hand after the drill).
- Stage 1 of the installer: `Install-GpuUnlock.cmd` (double-click), `Install-GpuUnlock.ps1` (first screen, administrator prompt that relaunches elevated only after a Y), `installer/Checks.ps1` (read-only checks C01-C09, C11, C13, one result object each; system queries replaceable for tests), `installer/tests/Test-Checks.ps1` (28 mocked cases, all pass). It changes nothing; it saves a report under `reports/` (git-ignored) with no user name or personal paths.
- docs/CHECKS.md: the accepted-ID list now matches Zagitta/gpu-unlock `main` exactly (the earlier text wrongly included 0x2485 through a range). The commit this fork is based on matches only the RTX 3090 in code.

## 2026-10-25 - boot order does not survive a cold boot; one-time queue does

- A boot order set from Windows (unlock entry first) was back to Windows-first after a cold boot, so the permanent-order approach did not run the unlock. A read-only logger (`internal-boot/boot/bootlist.c`, `build-bootlist.ps1`) showed the firmware's own list was already `Windows Boot Manager, UEFI OS` before Windows started, and that a one-time queued boot (BootNext) does run on a cold boot.
- Unlock from a cold boot using only the one-time queue: transaction result 0, FP16 48.24, BF16 49.88, FP32 8.16 TFLOPS.
- Added `internal-boot/Set-UnlockSchedule.ps1` (`-Mode Once | EveryBoot | Off | Status`, `-DryRun`): queues the one-time boot, or registers a startup task that queues it at every Windows start, with a backup, Fast Startup handling, an undo, and a stop when a queued run leaves no report or ends unclean. It never changes the permanent boot order. Dry run and the arm logic were tested on the reference machine; the startup task itself is not yet tested on hardware.
- Four-boot test with `-Mode EveryBoot`, nothing pressed: cold, restart, restart, cold. All four ran the unlock (transaction result 0, clean=1); FP16 48.07-48.69, BF16 49.87-50.40, FP32 8.18-8.21 TFLOPS. The startup task re-queued the next unlock after every boot.
- Plan requirements 23 and 24 added (never require BIOS or the boot menu; the choice of Once / Every boot / Off).

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
- Checked: history has no firmware, video BIOS or capture files from this work; no secrets; no scheduled task or run-key was added; Windows boot order, Fast Startup, Secure Boot and BitLocker are as before.
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
