# Decision-logic tests for installer\Checks.ps1 with mocked system answers. Reads and changes nothing on the PC.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Checks.ps1')
$fail = 0
function Expect([string]$Name, $Actual, $Wanted) {
 if ($Actual -ceq $Wanted) { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name : got '$Actual', wanted '$Wanted'" -ForegroundColor Red; $script:fail++ }
}

function Get-SysIsAdmin { $false }
Expect 'not admin fails' (Test-C01Admin).Status 'Fail'
function Get-SysIsAdmin { $true }
Expect 'admin passes' (Test-C01Admin).Status 'Pass'

function Get-SysSecureBoot { 'On' }
Expect 'secure boot on fails' (Test-C03SecureBoot).Status 'Fail'
function Get-SysSecureBoot { 'Unsupported' }
Expect 'secure boot unreadable fails' (Test-C03SecureBoot).Status 'Fail'
function Get-SysSecureBoot { 'Off' }
Expect 'secure boot off passes' (Test-C03SecureBoot).Status 'Pass'

function Get-SysOs { [pscustomobject]@{Build=19045;Is64=$true;Caption='Windows 10'} }
function Get-SysBootMgrPath { '\EFI\Microsoft\Boot\bootmgfw.efi' }
Expect 'windows 10 fails' (Test-C02Uefi).Status 'Fail'
function Get-SysOs { [pscustomobject]@{Build=26300;Is64=$true;Caption='Windows 11'} }
function Get-SysBootMgrPath { '\Windows\system32\winload.exe' }
Expect 'legacy boot fails' (Test-C02Uefi).Status 'Fail'
function Get-SysBootMgrPath { '\EFI\Microsoft\Boot\bootmgfw.efi' }
Expect 'win11 uefi passes' (Test-C02Uefi).Status 'Pass'

function Get-SysBitLocker { [pscustomobject]@{Known=$true;ProtectionStatus=1;ConversionStatus=1} }
Expect 'bitlocker on fails' (Test-C04BitLocker).Status 'Fail'
function Get-SysBitLocker { [pscustomobject]@{Known=$true;ProtectionStatus=0;ConversionStatus=0} }
Expect 'bitlocker off passes' (Test-C04BitLocker).Status 'Pass'
function Get-SysBitLocker { [pscustomobject]@{Known=$false} }
Expect 'bitlocker unreadable is unknown' (Test-C04BitLocker).Status 'Unknown'

function Get-SysDisk { [pscustomobject]@{Style='MBR';EspCount=0;ShrinkableBytes=50GB;Candidates=@()} }
Expect 'mbr fails' (Test-C05Gpt).Status 'Fail'
function Get-SysDisk { [pscustomobject]@{Style='GPT';EspCount=1;ShrinkableBytes=1GB;Candidates=@()} }
Expect 'no room fails' (Test-C06BootPartition).Status 'Fail'
function Get-SysDisk { [pscustomobject]@{Style='GPT';EspCount=1;ShrinkableBytes=1GB;Candidates=@([pscustomobject]@{Letter='U';Label='X';SizeGiB=2})} }
Expect 'existing partition passes' (Test-C06BootPartition).Status 'Pass'

function Get-SysAdapters { @([pscustomobject]@{Name='Card';InstanceId='PCI\VEN_10DE&DEV_2544&SUBSYS_0';Location='PCI bus 1, device 0, function 0'}) }
Expect 'rtx 3060 supported' (Test-C07Cards).Status 'Pass'
Expect 'single adapter fails second-adapter check' (Test-C09SecondAdapter).Status 'Fail'
function Get-SysAdapters { @([pscustomobject]@{Name='Card';InstanceId='PCI\VEN_10DE&DEV_2F04&SUBSYS_0';Location='PCI bus 2, device 0, function 0'},[pscustomobject]@{Name='Intel';InstanceId='PCI\VEN_8086&DEV_4680';Location=''}) }
Expect 'rtx 5070 not supported' (Test-C07Cards).Status 'Fail'
Expect 'two adapters pass' (Test-C09SecondAdapter).Status 'Pass'
Expect 'bus address format' (ConvertTo-AdapterInfo ([pscustomobject]@{Name='x';InstanceId='PCI\VEN_10DE&DEV_2204';Location='PCI bus 1, device 0, function 0'})).Bus '01:00.0'
Expect 'rtx 3090 supported' (ConvertTo-AdapterInfo ([pscustomobject]@{Name='x';InstanceId='PCI\VEN_10DE&DEV_2204';Location=''})).Supported $true
Expect 'unlisted 0x2485 not supported' (ConvertTo-AdapterInfo ([pscustomobject]@{Name='x';InstanceId='PCI\VEN_10DE&DEV_2485';Location=''})).Supported $false

function Get-SysChassis { [pscustomobject]@{Types=@(10);Manufacturer='A';Model='B'} }
Expect 'laptop fails' (Test-C08Desktop).Status 'Fail'
function Get-SysChassis { [pscustomobject]@{Types=@(3);Manufacturer='VMware, Inc.';Model='VMware7,1'} }
Expect 'vm fails' (Test-C08Desktop).Status 'Fail'
function Get-SysChassis { [pscustomobject]@{Types=@(3);Manufacturer='MSI';Model='MS-7E25'} }
Expect 'desktop passes' (Test-C08Desktop).Status 'Pass'

function Get-SysFastStartup { 1 }
Expect 'fast startup on fails' (Test-C11FastStartup).Status 'Fail'
function Get-SysFastStartup { $null }
Expect 'fast startup missing value fails' (Test-C11FastStartup).Status 'Fail'
function Get-SysFastStartup { 0 }
Expect 'fast startup off passes' (Test-C11FastStartup).Status 'Pass'

function Get-SysQueuedBoot { $true }
Expect 'queued boot is info' (Test-C13PendingBoot).Status 'Info'

# C15: the installer folder's path (Windows limits a full path to 259 characters; the build makes names up to 149 characters below it)
function Get-SysInstallerRoot { 'C:\' + ('a' * 97) }      # 100 characters
Expect 'a 100 character folder path passes' (Test-C15PathLength).Status 'Pass'
function Get-SysInstallerRoot { 'C:\' + ('a' * 98) }      # 101 characters
$c15 = Test-C15PathLength
Expect 'a 101 character folder path fails' $c15.Status 'Fail'
Expect 'the fix names a short folder' ($c15.Fix -like '*C:\GpuUnlock*') $true
Expect 'the detail says how long it is' ($c15.Detail -like '*101 characters*') $true
Expect 'the real installer folder is measured' ((Get-Command Get-SysInstallerRoot).ScriptBlock.ToString().Length -gt 0) $true

# C16: is this the latest release (only meaningful for a real release download, never blocks, never fails)
$c16Root = Join-Path ([IO.Path]::GetTempPath()) ('gpuunlock-c16-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $c16Root -Force)
try {
 function Get-SysInstallerRoot { $script:c16Root }
 function Get-SysLatestReleaseTag { 'v9.9.9' }
 Expect 'no VERSION file (a checkout, not a release): passes, nothing to compare' (Test-C16ReleaseVersion).Status 'Pass'
 Set-Content -LiteralPath (Join-Path $c16Root 'VERSION') 'v1.0.0' -NoNewline
 Expect 'an older version than the latest release: info, never a failure' (Test-C16ReleaseVersion).Status 'Info'
 Expect 'the info names both versions and a link' ((Test-C16ReleaseVersion).Detail -like '*v1.0.0*' -and (Test-C16ReleaseVersion).Detail -like '*v9.9.9*' -and (Test-C16ReleaseVersion).Detail -like '*releases/latest*') $true
 function Get-SysLatestReleaseTag { 'v1.0.0' }
 Expect 'the current version matches the latest release: passes' (Test-C16ReleaseVersion).Status 'Pass'
 function Get-SysLatestReleaseTag { $null }
 Expect 'no internet or GitHub did not answer: passes, never blocks' (Test-C16ReleaseVersion).Status 'Pass'
} finally { Remove-Item -LiteralPath $c16Root -Recurse -Force -ErrorAction SilentlyContinue }
if ($fail) { Write-Host "$fail test(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'all tests passed' }
