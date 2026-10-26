# Release checklist (draft)

Nothing here has been done and nothing is published. These are the two plan requirements that are release-time work, not installer code: requirement 17 (integrity of the download itself) and the hardware half of requirement 29 (the recovery drill). Do not publish or push anything until the owner approves; only the `publish` branch may ever be pushed.

## Requirement 17: integrity of the download

What to do for each release, and what to tell users.

1. **Build the release archive from a clean checkout** of the release commit (the installer folder as a user will receive it: `Install-GpuUnlock.cmd`, `Install-GpuUnlock.ps1`, `installer/`, `internal-boot/`, `tools/`, `firmware-tools/`, `benchmark/`, `patches/`, `docs/`, licence files). Never include `captures`, the user's video BIOS images, NVIDIA firmware or `platform-config.h` / `local-config.json`.
2. **Publish a `SHA256SUMS` file** next to the archive (one line per file: hash, two spaces, name). Users compare it with PowerShell. `Get-FileHash` uses SHA256 by default and returns the hash in its `Hash` property ([Microsoft: Get-FileHash](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash)):

   ```powershell
   (Get-FileHash .\Windows-GPU-UNLOCK.zip).Hash -eq '<hash from SHA256SUMS>'   # prints True when they match (the comparison ignores letter case)
   ```
3. **Publish a GitHub artifact attestation** for the archive. In the release workflow, after the build step, use `actions/attest` with `subject-path` set to the archive, and give the workflow the permissions `id-token: write`, `contents: read` and `attestations: write` ([GitHub: artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations); the pinned version in that page was `actions/attest@v4` when checked, so pin an exact version when writing the workflow). Users verify with the GitHub CLI, naming the repository that produced it ([gh attestation verify](https://cli.github.com/manual/gh_attestation_verify)):

   ```powershell
   gh attestation verify .\Windows-GPU-UNLOCK.zip --repo <owner>/<repo>
   ```
   The command checks that the attestation was produced by that repository (and, by default, a SLSA provenance predicate). `--signer-workflow` can pin the workflow too.
4. **Say what neither does.** Neither a hash file nor an attestation is code signing: they show the archive is the one the project built, not that Windows trusts the publisher.
5. **The README note about unsigned scripts** (draft text, to be added to the release README when there is a release):

   > The scripts are not digitally signed. Check the download first (SHA256SUMS, and `gh attestation verify` if you use the GitHub CLI). Windows may mark a downloaded zip and what you extract from it as coming from the internet and show a warning when you open `Install-GpuUnlock.cmd`; read the scripts if you want to, then choose to run it. `Install-GpuUnlock.cmd` starts the installer with the PowerShell execution policy bypassed for that one run only and changes no system setting. If you prefer, right-click the extracted `.ps1` and `.cmd` files, open Properties and tick Unblock, or run `Unblock-File` on them: it removes the "downloaded from the internet" mark, the same as the Unblock button in Properties ([Microsoft: Unblock-File](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/unblock-file)). Only do that after you have checked the file and where it came from.

   (The exact wording of the Windows warning on the current Windows 11 build has not been checked here; the note above says "may" on purpose. Check it on a clean PC with a downloaded zip before release.)
6. **Check the archive does not leak private data**: run a text search over the archive for the owner's real name, email and any `C:\Users\<name>` path, and for the private project's name, before publishing.

## Requirement 29: the recovery drill on hardware

What was done once: a test image that deliberately hangs was staged and queued on the reference machine, and holding the power button then powering on gave a normal Windows start with no BIOS and no menu (recorded in CHANGES.md). The boot programs' failure text was changed to the power-button instruction.

What must be repeated with the release build, on the reference machine, before each release (each step needs the owner's go-ahead because it touches the boot queue):

1. Build the hanging test image (`internal-boot/boot/build-hang.ps1`) from the release commit.
2. Stage it on the boot partition the way the installer stages programs (so the saved-copy and Roll back paths are the ones users get), queue one boot, restart.
3. Confirm the screen freezes, hold the power button until the PC turns off, power on, and confirm Windows starts normally with no queued boot left (`bcdedit /enum {fwbootmgr}` shows no `bootsequence`).
4. Confirm the startup task, if enabled, stays quiet after the failed run (its circuit breaker: a run that left no report or did not end clean stops further queuing and says so in its log).
5. Run Roll back and confirm the hanging image and every other staged file are gone and the original files are back.
6. Record the result (date, commit, what was seen) in CHANGES.md. Do not rely on it for any other machine: the drill proves the mechanism on the reference PC only.

## Also before a release

- Full installer test suite green (`installer/tests/Run-AllTests.ps1`), the Python tests, and the manual integration scripts (`Integration-RealPipeline.ps1`, `Integration-Dialog.ps1`, `Integration-Gui.ps1`) run on the reference PC.
- A dry run of the installer on a PC that has never seen it, with a display attached to the target card, to catch a first-run problem the reference PC hides.
- The README's status section updated to say exactly what was and was not verified for this release.
