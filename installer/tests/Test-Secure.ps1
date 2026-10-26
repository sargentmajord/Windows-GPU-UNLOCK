# The protected data folder (review items S1/S2): a pre-planted folder, file or junction must not leave anything an ordinary user can later
# rewrite and have run elevated or as SYSTEM. These tests use the REAL Windows permissions on temporary folders, so they need an
# administrator session (they are skipped otherwise).
$base = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Ui', 'State', 'Checks') { . (Join-Path $base "$m.ps1") }
. (Join-Path $PSScriptRoot 'Harness.ps1')
$repo = Split-Path -Parent $base

if (-not (Get-SysIsAdmin)) { Write-Host 'skip: needs an administrator session'; Complete-Tests; return }

$USERS = '*S-1-5-32-545'
function Icacls { & icacls.exe @args | Out-Null; if ($LASTEXITCODE -ne 0) { throw "icacls failed: $args" } }
$t = New-TestRoot
try {
 # ---------- the check itself ----------
 $d = Join-Path $t 'data'
 [void](New-Item -ItemType Directory $d)
 $p = @(Get-SecurityProblems $d)
 ExpectTrue 'a plain new folder in a temp directory is NOT safe (owned by a user account, writable by users)' ($p.Count -gt 0)
 Protect-DataFolder $d
 Expect 'after Protect-DataFolder there are no problems' (@(Get-TreeSecurityProblems $d)).Count 0
 $acl = Get-Acl $d
 Expect 'owner is the Administrators group' $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value 'S-1-5-32-544'
 Expect 'inheritance from the parent is off' $acl.AreAccessRulesProtected $true
 $userRules = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' })
 ExpectTrue 'ordinary users may only read and run' (($userRules.Count -eq 1) -and ((([int]$userRules[0].FileSystemRights) -band (2 + 4 + 65536 + 262144)) -eq 0) -and ((([int]$userRules[0].FileSystemRights) -band 131241) -ne 0))
 ExpectTrue 'a missing path is reported' ((@(Get-SecurityProblems (Join-Path $t 'nope'))) -like '*does not exist*')

 # ---------- ACL loosened later: noticed ----------
 Icacls $d /grant "${USERS}:(OI)(CI)M" /Q
 $p = @(Get-SecurityProblems $d)
 ExpectTrue 'Modify rights for Users are reported' (($p.Count -ge 1) -and ($p[0] -like '*S-1-5-32-545 can change*'))
 Protect-DataFolder $d
 Expect 'and Protect-DataFolder puts it right' (@(Get-TreeSecurityProblems $d)).Count 0
 foreach ($sid in '*S-1-1-0', '*S-1-5-11') {      # Everyone, Authenticated Users
  Icacls $d /grant "${sid}:(OI)(CI)W" /Q
  ExpectTrue "write for $sid is reported" (@(Get-SecurityProblems $d).Count -ge 1)
  Protect-DataFolder $d
 }
 Icacls $d /grant "${USERS}:(OI)(CI)RX" /Q
 Expect 'read and execute for Users alone is fine' (@(Get-SecurityProblems $d)).Count 0

 # ---------- a file planted by an ordinary user ----------
 $f = Join-Path $d 'Unlock-Next-Boot.ps1'
 Set-Content -LiteralPath $f -Value 'planted by a user'
 Icacls $f /setowner $USERS /Q                       # owned by the Users group (stands for a standard user's account)
 ExpectTrue 'a file owned by a non-administrator is reported' ((@(Get-SecurityProblems $f)) -like '*is owned by S-1-5-32-545*')
 ExpectTrue 'the tree check finds it' ((@(Get-TreeSecurityProblems $d)) -like '*Unlock-Next-Boot.ps1*')
 Write-SecureFile $f 'written by the installer'
 Expect 'Write-SecureFile replaces the planted file with a protected one' (@(Get-SecurityProblems $f)).Count 0
 Expect 'with the new content' (Get-Content -LiteralPath $f -Raw).Trim() 'written by the installer'
 Expect 'the new owner is the Administrators group' (Get-Acl $f).GetOwner([Security.Principal.SecurityIdentifier]).Value 'S-1-5-32-544'
 ExpectTrue 'no temporary file is left behind' (@(Get-ChildItem $d -Force | Where-Object Name -like '.new-*').Count -eq 0)
 # a planted file with a write rule for Users
 $g = Join-Path $d 'arm-state.json'; Set-Content $g 'x'
 Icacls $g /inheritance:r /grant "${USERS}:F" '*S-1-5-32-544:F' /Q
 ExpectTrue 'a file with a Users write rule is reported' (@(Get-SecurityProblems $g).Count -ge 1)
 Protect-DataFolder $d
 Expect 'Protect-DataFolder resets the permissions of files inside' (@(Get-TreeSecurityProblems $d)).Count 0

 # ---------- writing into an unsafe folder is refused ----------
 $bad = Join-Path $t 'unsafe'; [void](New-Item -ItemType Directory $bad)
 ExpectThrows 'Write-SecureFile refuses to write into an unprotected folder' { Write-SecureFile (Join-Path $bad 'a.ps1') 'x' } '*Refusing to write into*'
 ExpectTrue 'and writes nothing' (@(Get-ChildItem $bad -Force).Count -eq 0)

 # ---------- a junction at the data path ----------
 $victim = Join-Path $t 'victim'; [void](New-Item -ItemType Directory $victim); Set-Content (Join-Path $victim 'precious.txt') 'do not touch'
 $jp = Join-Path $t 'junction-data'
 [void](New-Item -ItemType Junction -Path $jp -Target $victim)
 ExpectTrue 'a junction is reported as a link' ((@(Get-SecurityProblems $jp)) -like '*is a link*')
 Protect-DataFolder $jp
 ExpectTrue 'Protect-DataFolder replaces the junction with a real folder' (-not ((Get-Item $jp -Force).Attributes -band [IO.FileAttributes]::ReparsePoint))
 Expect 'the folder it pointed to is untouched' (Get-Content (Join-Path $victim 'precious.txt') -Raw).Trim() 'do not touch'
 Expect 'and keeps its original permissions (nothing was changed through the link)' ((Get-Acl $victim).AreAccessRulesProtected) $false
 Expect 'the new folder is safe' (@(Get-TreeSecurityProblems $jp)).Count 0
 # a symbolic link to a file inside a protected folder
 $linkTarget = Join-Path $t 'outside.txt'; Set-Content $linkTarget 'outside'
 $symlink = Join-Path $d 'linked.ps1'
 $made = $true; try { [void](New-Item -ItemType SymbolicLink -Path $symlink -Target $linkTarget) } catch { $made = $false }
 if ($made) {
  ExpectTrue 'a symbolic link to a file is reported' ((@(Get-SecurityProblems $symlink)) -like '*is a link*')
  Write-SecureFile $symlink 'replaced'
  Expect 'Write-SecureFile replaces the link itself' (@(Get-SecurityProblems $symlink)).Count 0
  Expect 'and does not write through it' (Get-Content $linkTarget -Raw).Trim() 'outside'
 } else { Write-Host 'skip symbolic link test (not allowed here)' }

 # ---------- the same check inside a generated script ----------
 $dir2 = Join-Path $t 'gen'; Protect-DataFolder $dir2
 $scriptText = $script:SecurityCheckCode + "`r`n" + '$problems = @(Get-SecurityProblems $PSCommandPath) + @(Get-SecurityProblems (Split-Path -Parent $PSCommandPath)); if ($problems.Count) { "REFUSED: " + ($problems -join "; ") } else { "RAN" }'
 $s1 = Join-Path $dir2 'gen.ps1'
 Write-SecureFile $s1 $scriptText
 $run = { param($f) (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String).Trim() }
 Expect 'the embedded check lets a protected script run' (& $run $s1) 'RAN'
 Icacls $dir2 /grant "${USERS}:(OI)(CI)M" /Q
 ExpectTrue 'the embedded check refuses once ordinary users can change the folder' ((& $run $s1) -like 'REFUSED:*')
 Protect-DataFolder $dir2
 Icacls $s1 /setowner $USERS /Q
 ExpectTrue 'the embedded check refuses a script owned by a non-administrator' ((& $run $s1) -like 'REFUSED:*is owned by*')

 # ---------- the real scripts carry the check ----------
 $sched = Get-Content (Join-Path $repo 'internal-boot\Set-UnlockSchedule.ps1') -Raw
 ExpectTrue 'the startup script template embeds the check and refuses first' (($sched -like '*__SECURITY__*') -and ($sched -like '*refusing to run*') -and ($sched.IndexOf('__SECURITY__') -lt $sched.IndexOf('__LOOKUP__')))
 ExpectTrue 'the startup script and the state are written through Write-SecureFile' (($sched -like '*Write-SecureFile $armScript*') -and ($sched -like '*Write-SecureFile $stateFile*'))
 ExpectTrue 'the data folder is made safe before anything is written' ($sched -like '*Protect-DataFolder $root*')
} finally { Remove-TestRoot $t }
Complete-Tests
