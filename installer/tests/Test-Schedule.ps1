# The shortcut script and shortcut, the every-boot opt-in and its gates. The generated shortcut script is also EXECUTED here, with fake
# bcdedit and shutdown programs first on PATH, so what it asks and what it queues is proven rather than assumed.
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks', 'CardSelect', 'Tools', 'BootPartition', 'Backup', 'Plan', 'BootEntry', 'Capture', 'Firmware', 'BuildTest', 'Benchmark', 'Unlock', 'Schedule', 'Resume', 'Rollback', 'Extras', 'Status', 'Main') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$repo = Split-Path -Parent $base
Set-RepoRoot $repo

# ---------------- the generated script (text) ----------------
foreach ($mode in 'manual', 'automatic') {
 $text = Get-ShortcutScriptText $mode
 $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$e)
 Expect "$mode script is valid PowerShell" $e.Count 0
 ExpectTrue "$mode script embeds the shared firmware-entry lookup, unchanged" ($text.Contains((Get-LookupCode).Trim()))
 ExpectTrue "$mode script queues only the one-time boot" (($text -like "*bcdedit.exe /set '{fwbootmgr}' bootsequence*") -and ($text -notmatch 'displayorder|/default|/bootsequence|/timeout'))
 ExpectTrue "$mode script gives the power-button recovery and never mentions BIOS or a boot menu" (($text -like '*hold the power button*') -and ($text -notmatch 'BIOS|F11|F8|boot menu'))
 ExpectTrue "$mode script restarts with a 30 s countdown and says how to cancel" (($text -like '*shutdown.exe /r /t 30*') -and ($text -like '*shutdown /a*'))
 ExpectTrue "$mode script checks Secure Boot and administrator rights" (($text -like '*Confirm-SecureBootUEFI*') -and ($text -like '*Administrator*'))
 ExpectTrue "$mode script holds no user name or personal path" (($text -notlike "*$env:USERNAME*") -and ($text -notlike '*C:\Users\*'))
}
ExpectTrue 'manual text asks for U and mentions Esc and 30 seconds' ((Get-ShortcutScriptText 'manual') -like '*press U once*Esc*30 seconds*')
ExpectTrue 'automatic text says no key is needed' ((Get-ShortcutScriptText 'automatic') -like '*no key is needed*')
ExpectThrows 'an unknown mode is refused' { Get-ShortcutScriptText 'turbo' } '*turbo*'

# ---------------- creating the shortcut (real COM, temporary folders) ----------------
$t = New-TestRoot
try {
 $desk = Join-Path $t 'desktop'; $data = Join-Path $t 'data'; $start = Join-Path $t 'startmenu'; [void](New-Item -ItemType Directory $desk)
 function Get-SysDesktopPath { $desk }
 function Get-SysDataRoot { $data }
 function Get-SysStartMenuPath { $start }
 $isAdmin0 = Get-SysIsAdmin
 if ($isAdmin0) { Protect-DataFolder $data; Protect-DataFolder $start }     # the real thing: a protected data folder and Start menu folder
 else { Write-Host 'skip shortcut and script-protection tests (needs an administrator session)'; [void](New-Item -ItemType Directory $data, $start) }
 if ($isAdmin0) {
 $r = New-UnlockShortcut @{} 'manual'
 ExpectTrue 'script written' (Test-Path $r.Script)
 Expect 'one shortcut by default, in the Start menu' $r.Links.Count 1
 ExpectTrue 'it is in the all-users Start menu folder' ($r.Links[0] -like "$start*")
 ExpectTrue 'shortcut written' (Test-Path $r.Links[0])
 Expect 'shortcut name' (Split-Path -Leaf $r.Links[0]) 'Unlock my GPU on next boot.lnk'
 ExpectTrue 'the shortcut asks for administrator approval' (Test-ShortcutRunsAsAdmin $r.Links[0])
 $sh = New-Object -ComObject WScript.Shell; $l = $sh.CreateShortcut($r.Links[0])
 ExpectTrue 'it starts Windows PowerShell with the generated script' (($l.TargetPath -like '*WindowsPowerShell\v1.0\powershell.exe') -and ($l.Arguments -like "*-File `"$($r.Script)`"*") -and ($l.Arguments -like '*-NoProfile*'))
 ExpectTrue 'the script file parses' ((Get-Content $r.Script -Raw) -like '*Queues ONE unlock*')
 Expect 'the script is protected: nobody but administrators/SYSTEM can change it' (@(Get-SecurityProblems $r.Script)).Count 0
 Expect 'the Start menu shortcut is protected too' (@(Get-SecurityProblems $r.Links[0])).Count 0
 $j = @(Read-Journal)
 Expect 'two journaled changes, both done' (@($j | Where-Object { $_.Phase -eq 'schedule' -and $_.Status -eq 'done' }).Count) 2
 $n = $j.Count
 [void](New-UnlockShortcut @{} 'manual' -DryRun)
 Expect 'dry run writes and journals nothing' @(Read-Journal).Count $n
 # an optional desktop copy
 $rd = New-UnlockShortcut @{} 'manual' -Desktop
 Expect 'with the desktop option there are two shortcuts' $rd.Links.Count 2
 ExpectTrue 'the second one is on the desktop' ($rd.Links[1] -like "$desk*" -and (Test-Path $rd.Links[1]))
 ExpectTrue 'the desktop copy also asks for administrator approval' (Test-ShortcutRunsAsAdmin $rd.Links[1])
 Remove-Item $rd.Links[1] -Force
 # re-running replaces both and records that they existed
 $r2 = New-UnlockShortcut @{} 'automatic'
 Expect 'a second run records that the files existed' @(Read-Journal)[-1].Previous.Existed $true
 ExpectTrue 'the script now says no key is needed' ((Get-Content $r2.Script -Raw) -like '*no key is needed*')
 # a Start menu folder that ordinary users can write to is refused
 & icacls.exe $start /grant '*S-1-5-32-545:(OI)(CI)M' /Q | Out-Null
 ExpectThrows 'a shortcut in a folder ordinary users can change is removed and refused' { New-UnlockShortcut @{} 'manual' } '*can be changed by ordinary users*'
 ExpectTrue 'and no shortcut is left there' (-not (Test-Path (Join-Path $start 'Unlock my GPU on next boot.lnk')))
 Protect-DataFolder $start
 $r = New-UnlockShortcut @{} 'manual'
 }

 # ---------------- the generated script, executed ----------------
 $fakes = Join-Path $t 'fakes'; [void](New-Item -ItemType Directory $fakes)
 $bcdSrc = @'
using System; using System.IO;
class P { static int Main(string[] a) {
  string log = Environment.GetEnvironmentVariable("FAKE_LOG");
  string line = string.Join(" ", a);
  if (a.Length >= 2 && a[0] == "/enum" && a[1] == "firmware") { Console.Write(File.ReadAllText(Environment.GetEnvironmentVariable("FAKE_BCD_FILE"))); return 0; }
  if (log != null) File.AppendAllText(log, "bcdedit " + line + "\n");
  if (a.Length >= 1 && a[0] == "/set") return int.Parse(Environment.GetEnvironmentVariable("FAKE_SET_CODE") ?? "0");
  return 1; } }
'@
 $shutSrc = @'
using System; using System.IO;
class P { static int Main(string[] a) { File.AppendAllText(Environment.GetEnvironmentVariable("FAKE_LOG"), "shutdown " + string.Join(" ", a) + "\n"); return 0; } }
'@
 Add-Type -TypeDefinition $bcdSrc -OutputAssembly (Join-Path $fakes 'bcdedit.exe') -OutputType ConsoleApplication
 Add-Type -TypeDefinition $shutSrc -OutputAssembly (Join-Path $fakes 'shutdown.exe') -OutputType ConsoleApplication
 $vol = Get-Volume | Where-Object { $_.FileSystemLabel -ceq 'GPUUNLOCK' -and $_.DriveLetter } | Select-Object -First 1
 $secure = $null; try { $secure = Confirm-SecureBootUEFI } catch { }
 $isAdmin = Get-SysIsAdmin
 if (-not ($vol -and $isAdmin -and $secure -eq $false)) {
  Write-Host 'skip executing the generated script (needs an administrator session, Secure Boot off and a volume labelled GPUUNLOCK)'
 } else {
  $fw = "Firmware Application (101fffff)`r`n-------------------------------`r`nidentifier              {330a049f-d095-11f1-89aa-806e6f6e6963}`r`ndevice                  partition=$($vol.DriveLetter):`r`npath                    \EFI\BOOT\BOOTX64.EFI`r`ndescription             UEFI OS`r`n"
  $bcdFile = Join-Path $t 'bcd.txt'; Set-Content $bcdFile $fw
  $log = Join-Path $t 'calls.log'
  function RunScript([string]$ScriptPath, [string]$Answer) {
   Remove-Item $log -ErrorAction SilentlyContinue
   $env:FAKE_LOG = $log; $env:FAKE_BCD_FILE = $bcdFile; $saved = $env:PATH; $env:PATH = "$fakes;$saved"
   try { $out = ("$Answer`r`n`r`n" | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1 | Out-String) } finally { $env:PATH = $saved; Remove-Item Env:FAKE_LOG, Env:FAKE_BCD_FILE, Env:FAKE_SET_CODE -ErrorAction SilentlyContinue }
   [pscustomobject]@{ Out = $out; Calls = $(if (Test-Path $log) { @(Get-Content $log) } else { @() }) }
  }
  $res = RunScript $r.Script 'N'
  # (the script file now holds the automatic variant from the second creation; both share the same logic)
  Expect 'it queued exactly one one-time boot for the firmware entry found by label and path' ($res.Calls | Where-Object { $_ -like 'bcdedit*' }) 'bcdedit /set {fwbootmgr} bootsequence {330a049f-d095-11f1-89aa-806e6f6e6963}'
  ExpectTrue 'N: no restart was started' (-not ($res.Calls | Where-Object { $_ -like 'shutdown*' }))
  ExpectTrue 'N: it says the unlock stays queued' ($res.Out -like '*stays queued*')
  $res = RunScript $r.Script 'Y'
  Expect 'Y: a restart with a 30 second countdown and a reason' ($res.Calls | Where-Object { $_ -like 'shutdown*' }) 'shutdown /r /t 30 /c Windows GPU Unlock: restarting to apply the unlock.'
  ExpectTrue 'Y: it prints how to cancel' ($res.Out -like '*shutdown /a*')

  # tampering: if ordinary users can change the script's folder, the script refuses to run (it re-checks its own protection)
  & icacls.exe $data /grant '*S-1-5-32-545:(OI)(CI)M' /Q | Out-Null
  $res = RunScript $r.Script 'Y'
  ExpectTrue 'a script in a folder ordinary users can change refuses to run' (($res.Out -like '*can be changed by ordinary users*') -and -not $res.Calls)
  Protect-DataFolder $data
  $res = RunScript $r.Script 'N'
  ExpectTrue 'after the folder is protected again it runs' ($res.Calls | Where-Object { $_ -like 'bcdedit*' })
  # no matching entry: nothing is queued
  Set-Content $bcdFile ($fw -replace 'BOOTX64', 'OTHER')
  $res = RunScript $r.Script 'Y'
  ExpectTrue 'no entry: nothing queued, nothing restarted' (-not $res.Calls)
  ExpectTrue 'no entry: plain message' (($res.Out -like '*Could not queue the unlock*') -and ($res.Out -like '*Nothing was changed*'))
  Set-Content $bcdFile $fw
  # bcdedit refuses
  $env:FAKE_SET_CODE = '5'; $env:FAKE_LOG = $log
  $res = RunScript $r.Script 'Y'
  ExpectTrue 'bcdedit failure: reported and no restart' (($res.Out -like '*could not queue*') -and -not ($res.Calls | Where-Object { $_ -like 'shutdown*' }))
 }

 # ---------------- every boot: the gates and the call ----------------
 $script:Calls = New-Object System.Collections.ArrayList; $script:Code = 0
 function Invoke-SysScheduleScript([string]$CommandText) { [void]$script:Calls.Add($CommandText); [pscustomobject]@{ Code = $script:Code; Output = 'ok' } }
 function Get-SysFastStartup { 0 }
 ExpectThrows 'every boot needs automatic mode' { Enable-EveryBoot ([ordered]@{ Unlock = [ordered]@{ Applied = $true } }) } '*needs automatic mode*'
 ExpectThrows 'every boot needs a verified unlock' { Enable-EveryBoot ([ordered]@{ Automatic = [ordered]@{ Active = $true } }) } '*only after an unlock has been verified*'
 Expect 'refused attempts called nothing' $script:Calls.Count 0
 $ok = [ordered]@{ Automatic = [ordered]@{ Active = $true }; Unlock = [ordered]@{ Applied = $true } }
 Enable-EveryBoot $ok
 ExpectTrue 'the project''s own script is called with -Mode EveryBoot' ($script:Calls[0] -like "*Set-UnlockSchedule.ps1* -Mode 'EveryBoot'*")
 ExpectTrue 'it is recorded in the state' ($ok.Schedule.Mode -eq 'EveryBoot')
 Expect 'journaled with the Fast Startup value to restore' @(Read-Journal)[-1].Previous.FastStartup 0
 $script:Calls.Clear(); Enable-EveryBoot $ok -DryRun
 Expect 'dry run calls nothing' $script:Calls.Count 0
 $script:Code = 1
 ExpectThrows 'a failing task setup is an error' { Enable-EveryBoot ([ordered]@{ Automatic = [ordered]@{ Active = $true }; Unlock = [ordered]@{ Applied = $true } }) } '*startup task failed*'
 Expect 'and is journaled as failed' @(Read-Journal)[-1].Status 'failed'
 $script:Code = 0; $script:Calls.Clear()
 [void](Disable-EveryBoot)
 ExpectTrue 'Off calls the project''s script with -Mode Off' ($script:Calls[0] -like "*Set-UnlockSchedule.ps1* -Mode 'Off'*")

 # the opt-in question
 Set-Answers @('N'); ExpectTrue 'the default answer path is No' (-not (Ask-EveryBoot))
 $w = OutText
 ExpectTrue 'the warning says what runs at every start' ($w -like '*startup task*runs a small script at every Windows start*')
 ExpectTrue 'it says a failed check freezes the screen and the power-button recovery' (($w -like '*the screen freezes*') -and ($w -like '*Hold the power button*'))
 ExpectTrue 'it says no BIOS or boot menu is needed' ($w -like '*No BIOS or boot menu is needed*')
 ExpectTrue 'it says Fast Startup is turned off and its old value saved' ($w -like '*Fast Startup is turned off (its old value is saved)*')
 ExpectTrue 'it mentions the backup and Roll back' (($w -like '*backup of the boot configuration*') -and ($w -like '*Roll back*'))
 Set-Answers @('Y'); ExpectTrue 'only an explicit Y turns it on' (Ask-EveryBoot)

 # ---------------- the phase ----------------
 $opt = @{ DryRun = $false; ReportFolder = ''; CaptureFolder = $null }
 Get-ChildItem $start -Filter '*.lnk' | Remove-Item -Force
 $st = [ordered]@{}
 Set-Answers @('Y', 'N'); $res2 = Invoke-Phase-schedule $st $opt
 Expect 'phase: extra 1 is offered after the shortcut' $res2.Next 'extra1-offer'
 ExpectTrue 'phase: the Start menu shortcut exists, no desktop copy was made, and it is recorded' ((Test-Path $r.Links[0]) -and -not (Get-ChildItem $desk -Filter '*.lnk') -and $st.Shortcut.Mode -eq 'manual' -and $st.Shortcut.Links.Count -eq 1)
 ExpectTrue 'phase: it explains the desktop copy risk' ((OutText) -like '*any program running as you can edit a desktop shortcut*')
 ExpectTrue 'phase: it explains what lasts until power-off' ((OutText) -like '*lasts until the PC is powered off or goes to sleep*')
 $st = [ordered]@{ Automatic = [ordered]@{ Active = $true } }
 Set-Answers @('Y', 'Y'); [void](Invoke-Phase-schedule $st $opt)
 Expect 'phase: automatic mode makes the automatic shortcut' $st.Shortcut.Mode 'automatic'
 Expect 'phase: Y to the desktop question adds the desktop copy' $st.Shortcut.Links.Count 2
 Get-ChildItem $start, $desk -Filter '*.lnk' | Remove-Item -Force
 $st = [ordered]@{}; Set-Answers @('N'); $res2 = Invoke-Phase-schedule $st $opt
 ExpectTrue 'declining makes no shortcut and says how else to unlock again' ((-not (Test-Path $r.Links[0])) -and ((OutText) -like '*run this installer again*') -and -not $st.Contains('Shortcut'))
 Set-Answers @('Y', 'N'); [void](Invoke-Phase-schedule ([ordered]@{}) @{ DryRun = $true; ReportFolder = ''; CaptureFolder = $null })
 ExpectTrue 'dry run: no shortcut' (-not (Test-Path $r.Links[0]))
} finally { Remove-TestRoot $t; Remove-Item Env:FAKE_LOG, Env:FAKE_BCD_FILE, Env:FAKE_SET_CODE -ErrorAction SilentlyContinue }
Complete-Tests
