# Keeps the scripts that run ELEVATED or as SYSTEM (and the journal that Roll back trusts) out of reach of ordinary users.
# Why: C:\ProgramData lets any user create folders and files, and a user who creates the folder or a file first stays its owner with full
# control, so the user could later rewrite a script that runs as an administrator or as SYSTEM, or edit the journal Roll back acts on.
# So the data folder must be: a real folder (not a junction or symbolic link), owned by the administrators or SYSTEM, and writable by
# nobody else. This file is loaded by Set-UnlockSchedule.ps1 and by the installer; the check below is also pasted, unchanged, into every
# script that is generated for an elevated or SYSTEM run, which re-checks itself before doing anything.

# --- the check (ONE source: this text is both loaded here and pasted into the generated scripts) ---
$script:SecurityCheckCode = @'
function Get-SecurityProblems([string]$Path) {
 $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')   # SYSTEM, Administrators, TrustedInstaller
 $writeMask = 2 + 4 + 16 + 64 + 256 + 65536 + 262144 + 524288   # write data/create files, append/create folders, write extended attributes, delete children, write attributes, delete, change permissions, take ownership
 $problems = @()
 if (-not (Test-Path -LiteralPath $Path)) { return @("$Path does not exist") }
 $item = Get-Item -LiteralPath $Path -Force
 if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $problems += "$Path is a link (junction or symbolic link), not a real item" }
 $acl = Get-Acl -LiteralPath $Path
 $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
 if ($trusted -notcontains $owner) { $problems += "$Path is owned by $owner, not by the administrators or SYSTEM" }
 foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
  if ($rule.AccessControlType -ne 'Allow') { continue }
  $sid = $rule.IdentityReference.Value
  if ($trusted -contains $sid) { continue }
  if ($item.PSIsContainer -and ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }   # applies to items created later, which are checked when they exist
  if ((([int]$rule.FileSystemRights) -band $writeMask) -ne 0) { $problems += "$sid can change $Path ($($rule.FileSystemRights))" }
 }
 $problems
}
'@
Invoke-Expression $script:SecurityCheckCode

# --- system calls (replaceable in tests) ---
function Invoke-SysIcacls([string[]]$IcaclsArgs) { $ErrorActionPreference = 'Continue'; $o = & icacls.exe @IcaclsArgs 2>&1; if ($LASTEXITCODE -ne 0) { throw ("icacls $($IcaclsArgs -join ' ') failed: " + ($o | Out-String)) } }
function Invoke-SysDeleteLink([string]$Path) { [IO.Directory]::Delete($Path) }   # removes a junction or symbolic link itself, never what it points to

# Problems for a folder and every file and folder inside it.
function Get-TreeSecurityProblems([string]$Path) {
 $all = @(Get-SecurityProblems $Path)
 if (Test-Path -LiteralPath $Path -PathType Container) {
  foreach ($child in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)) { $all += @(Get-SecurityProblems $child.FullName) }
 }
 @($all | Where-Object { $_ })
}

# Makes the folder a real, administrator-owned folder that only the administrators and SYSTEM can change (everyone else may read and run).
# An existing link at the path is removed (the link only); wrong owners and permissions inside are reset. Throws if it cannot be made safe.
function Protect-DataFolder([string]$Path) {
 if (Test-Path -LiteralPath $Path) {
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Invoke-SysDeleteLink $Path }
 }
 if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -ItemType Directory -Path $Path) }
 Invoke-SysIcacls @($Path, '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q')
 Invoke-SysIcacls @($Path, '/reset', '/T', '/C', '/Q')
 Invoke-SysIcacls @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/Q')
 $p = @(Get-TreeSecurityProblems $Path)
 if ($p.Count) { throw ('The data folder could not be made safe: ' + ($p -join '; ')) }
}

# Writes a file that the folder's rules protect. A file that is already there (possibly planted by another user, possibly a link) is replaced by
# a new one, never written into; the result is read back and refused (and deleted) if anyone but the administrators or SYSTEM could change it.
function Write-SecureFile([string]$Path, [string]$Text, [Text.Encoding]$Encoding = [Text.UTF8Encoding]::new($false)) {
 $dir = Split-Path -Parent $Path
 $p = @(Get-SecurityProblems $dir)
 if ($p.Count) { throw ("Refusing to write into $dir : " + ($p -join '; ')) }
 $tmp = Join-Path $dir ('.new-' + [guid]::NewGuid().ToString('N'))
 [IO.File]::WriteAllText($tmp, $Text, $Encoding)
 try {
  # an elevated administrator's new file is owned by that account; make the owner the Administrators group so the strict owner check holds
  Invoke-SysIcacls @($tmp, '/setowner', '*S-1-5-32-544', '/Q')
  $p = @(Get-SecurityProblems $tmp)
  if ($p.Count) { throw ('The new file is not protected: ' + ($p -join '; ')) }
  if (Test-Path -LiteralPath $Path) {
   $old = Get-Item -LiteralPath $Path -Force
   if ($old.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $Path -Force }
  }
  Move-Item -LiteralPath $tmp -Destination $Path -Force
 } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw }
 $p = @(Get-SecurityProblems $Path)
 if ($p.Count) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue; throw ('The file was removed because it is not protected: ' + ($p -join '; ')) }
}
