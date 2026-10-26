# Read-only system checks for the installer (docs/CHECKS.md). Nothing here changes the PC.
# Every check returns one object: Id, Name, Status (Pass | Fail | Info | Unknown), Detail, Fix.
# System queries sit in the Get-Sys* functions so tests can replace them with mocked answers.

# Accepted target IDs: Zagitta/gpu-unlock main, kernel/gpu_unlock/main.c (checked 2026-10-25).
$script:SupportedDeviceIds = @(
 0x2200,0x2203,0x2204,0x2205,0x2206,0x2207,0x2208,0x220a,0x220d,0x2216,0x222b,0x222f,
 0x2480,0x2482,0x2483,0x2484,0x2486,0x2487,0x2488,0x2489,0x248a,0x248c,0x248d,0x248e,
 0x249c,0x249d,0x249f,0x24a0,0x24a4,0x24ac,0x24ad,0x24af,0x24bf,0x24c0,0x24c7,0x24c8,
 0x24c9,0x24dc,0x24dd,0x24df,0x24e0,
 0x2414,
 0x2501,0x2503,0x2504,0x2505,0x2507,0x2508,0x2509,0x252f,0x2544
)
$script:EspGptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:NeededBytes = 2GB

function New-Result([string]$Id,[string]$Name,[string]$Status,[string]$Detail,[string]$Fix='') {
 [pscustomobject]@{Id=$Id;Name=$Name;Status=$Status;Detail=$Detail;Fix=$Fix}
}

# --- system queries (replaceable in tests) ---
function Get-SysIsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Get-SysOs { $o=Get-CimInstance Win32_OperatingSystem; [pscustomobject]@{Build=[int]$o.BuildNumber;Is64=[Environment]::Is64BitOperatingSystem;Caption=$o.Caption} }
function Get-SysBootMgrPath { $t=(& bcdedit.exe /enum '{bootmgr}') -join "`n"; if($LASTEXITCODE -ne 0){return $null}; if($t -match '(?mi)^path\s+(\S+)'){$Matches[1]}else{$null} }
function Get-SysSecureBoot { try{ if(Confirm-SecureBootUEFI){'On'}else{'Off'} }catch{ 'Unsupported' } }
function Get-SysBitLocker {
 $v=Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='C:'" -ErrorAction SilentlyContinue
 if(-not $v){return [pscustomobject]@{Known=$false}}
 $c=Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus -ErrorAction SilentlyContinue
 [pscustomobject]@{Known=$true;ProtectionStatus=[int]$v.ProtectionStatus;ConversionStatus=$(if($c){[int]$c.ConversionStatus}else{-1})}
}
function Get-SysDisk {
 $p=Get-Partition -DriveLetter C -ErrorAction Stop
 $d=Get-Disk -Number $p.DiskNumber
 $esp=@(Get-Partition -DiskNumber $p.DiskNumber | Where-Object {$_.GptType -eq $script:EspGptType})
 $sz=Get-PartitionSupportedSize -DriveLetter C
 $cand=@(Get-Volume | Where-Object {$_.FileSystem -eq 'FAT32' -and $_.Size -ge 1GB -and $_.Size -le 4GB -and $_.DriveLetter} |
  ForEach-Object {[pscustomobject]@{Letter=[string]$_.DriveLetter;Label=$_.FileSystemLabel;SizeGiB=[math]::Round($_.Size/1GB,2)}})
 [pscustomobject]@{Style=[string]$d.PartitionStyle;EspCount=$esp.Count;ShrinkableBytes=[int64]($p.Size-$sz.SizeMin);Candidates=$cand}
}
function Get-SysAdapters {
 @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object {
  $loc=(Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data
  [pscustomobject]@{Name=$_.FriendlyName;InstanceId=$_.InstanceId;Location=[string]$loc}
 })
}
function Get-SysChassis { [pscustomobject]@{Types=@((Get-CimInstance Win32_SystemEnclosure).ChassisTypes);Manufacturer=(Get-CimInstance Win32_ComputerSystem).Manufacturer;Model=(Get-CimInstance Win32_ComputerSystem).Model} }
function Get-SysInstallerRoot { Split-Path -Parent $PSScriptRoot }
function Get-SysFastStartup { $k=Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; if($k.GetValueNames() -contains 'HiberbootEnabled'){[int]$k.GetValue('HiberbootEnabled')}else{$null} }
function Get-SysQueuedBoot { ((& bcdedit.exe /enum '{fwbootmgr}') -join "`n") -match '(?mi)^bootsequence\s' }

# --- helpers ---
function ConvertTo-AdapterInfo($Adapter) {
 $ven=$null;$dev=$null
 if($Adapter.InstanceId -match 'VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})'){$ven=[Convert]::ToInt32($Matches[1],16);$dev=[Convert]::ToInt32($Matches[2],16)}
 $bus=if($Adapter.Location -match 'PCI bus (\d+), device (\d+), function (\d+)'){'{0:D2}:{1:D2}.{2}' -f [int]$Matches[1],[int]$Matches[2],[int]$Matches[3]}else{'unknown'}
 $verdict=if($null -eq $ven){'cannot tell'}
  elseif($ven -ne 0x10DE){'not supported: not an NVIDIA card'}
  elseif($script:SupportedDeviceIds -contains $dev){'supported (accepted RTX 30 series ID)'}
  else{'not supported: ID not on the accepted list'}
 [pscustomobject]@{Name=$Adapter.Name;Id=$(if($null -ne $ven){'{0:x4}:{1:x4}' -f $ven,$dev}else{'unknown'});Bus=$bus;Verdict=$verdict;Supported=$verdict.StartsWith('supported')}
}

# --- checks ---
function Test-C01Admin {
 if(Get-SysIsAdmin){New-Result C01 'Administrator rights' Pass 'Running as administrator.'}
 else{New-Result C01 'Administrator rights' Fail 'Not running as administrator.' 'Run the installer again and approve the Windows prompt.'}
}
function Test-C02Uefi {
 $os=Get-SysOs;$path=Get-SysBootMgrPath
 if($os.Build -lt 22000 -or -not $os.Is64){return New-Result C02 'Windows 11 x64, UEFI mode' Fail ("Windows build {0}, 64-bit: {1}." -f $os.Build,$os.Is64) 'Windows 11 x64 is required.'}
 if($path -and $path -match '\.efi$'){New-Result C02 'Windows 11 x64, UEFI mode' Pass ("Windows 11 build {0}, UEFI boot manager." -f $os.Build)}
 else{New-Result C02 'Windows 11 x64, UEFI mode' Fail 'Windows is not started in UEFI mode.' 'The PC boots in legacy (CSM) mode. Not supported.'}
}
function Test-C03SecureBoot {
 switch(Get-SysSecureBoot){
  'Off'{New-Result C03 'Secure Boot is off' Pass 'Secure Boot is off.'}
  'On'{New-Result C03 'Secure Boot is off' Fail 'Secure Boot is on.' 'The unlock program is not signed, so the firmware refuses to run it. Turn Secure Boot off in the BIOS. Games with anti-cheat that needs Secure Boot will not run while it is off.'}
  default{New-Result C03 'Secure Boot is off' Fail 'Secure Boot state cannot be read (the PC is probably not in UEFI mode).' 'See check C02.'}
 }
}
function Test-C04BitLocker {
 $b=Get-SysBitLocker
 if(-not $b.Known){return New-Result C04 'BitLocker and device encryption are off' Unknown 'Encryption state could not be read.' 'Check Settings > Privacy & security > Device encryption and BitLocker by hand.'}
 if($b.ProtectionStatus -eq 0 -and $b.ConversionStatus -eq 0){New-Result C04 'BitLocker and device encryption are off' Pass 'Drive C: is fully decrypted, protection off.'}
 else{New-Result C04 'BitLocker and device encryption are off' Fail 'Drive C: is encrypted or still decrypting.' 'Turn off BitLocker / device encryption and wait until decryption finishes. An unsigned boot program changes the TPM measurements and can trigger a recovery-key prompt.'}
}
function Test-C05Gpt {
 try{$d=Get-SysDisk}catch{return New-Result C05 'GPT disk with an EFI system partition' Unknown 'Disk layout could not be read.'}
 if($d.Style -eq 'GPT' -and $d.EspCount -ge 1){New-Result C05 'GPT disk with an EFI system partition' Pass 'Windows disk is GPT with an EFI system partition.'}
 else{New-Result C05 'GPT disk with an EFI system partition' Fail ("Windows disk style {0}, EFI system partitions: {1}." -f $d.Style,$d.EspCount) 'A GPT disk booted in UEFI mode is required.'}
}
function Test-C06BootPartition {
 try{$d=Get-SysDisk}catch{return New-Result C06 'Room for a dedicated boot partition' Unknown 'Disk layout could not be read.'}
 $detail=@()
 if($d.Candidates.Count){$detail+='Existing FAT32 partitions of 1 to 4 GiB: '+(($d.Candidates|ForEach-Object{'{0}: ({1}, {2} GiB)' -f $_.Letter,$_.Label,$_.SizeGiB}) -join '; ')+'.'}
 $canShrink=$d.ShrinkableBytes -ge $script:NeededBytes
 $detail+=('C: can give back up to {0} GiB.' -f [math]::Round($d.ShrinkableBytes/1GB,1))
 if($d.Candidates.Count -or $canShrink){New-Result C06 'Room for a dedicated boot partition' Pass ($detail -join ' ') 'The installer will ask which option to use; it never picks for you.'}
 else{New-Result C06 'Room for a dedicated boot partition' Fail ($detail -join ' ') 'Free up 2 GiB on C: or attach a drive with a small FAT32 partition.'}
}
function Test-C07Cards {
 $cards=@(Get-SysAdapters|ForEach-Object{ConvertTo-AdapterInfo $_})
 $ok=@($cards|Where-Object Supported)
 $list=($cards|ForEach-Object{'{0} [{1}] bus {2}: {3}' -f $_.Name,$_.Id,$_.Bus,$_.Verdict}) -join "`n"
 if($ok.Count){New-Result C07 'A supported target card' Pass $list}
 else{New-Result C07 'A supported target card' Fail $list 'No RTX 30 series card from the accepted list was found.'}
}
function Test-C08Desktop {
 $c=Get-SysChassis
 $laptop=@($c.Types|Where-Object{$_ -in 8,9,10,11,14,30,31,32}).Count -gt 0
 $vm=("$($c.Manufacturer) $($c.Model)") -match 'VMware|VirtualBox|QEMU|Virtual Machine|KVM|Xen'
 if($laptop -or $vm){New-Result C08 'Desktop PC, not a laptop or virtual machine' Fail ("Chassis types {0}; {1} {2}." -f ($c.Types -join ','),$c.Manufacturer,$c.Model) 'Laptops and virtual machines are not supported.'}
 else{New-Result C08 'Desktop PC, not a laptop or virtual machine' Pass ("Chassis types {0}." -f ($c.Types -join ','))}
}
function Test-C09SecondAdapter {
 $n=@(Get-SysAdapters).Count
 if($n -ge 2){New-Result C09 'A second display adapter keeps the screen working' Pass "$n display adapters found."}
 else{New-Result C09 'A second display adapter keeps the screen working' Fail "$n display adapter found." 'Another graphics adapter (any vendor) is needed to keep the screen working while the target card is released.'}
}
function Test-C11FastStartup {
 $v=Get-SysFastStartup
 if($v -eq 0){New-Result C11 'Windows Fast Startup is off' Pass 'Fast Startup is off.'}
 else{New-Result C11 'Windows Fast Startup is off' Fail 'Fast Startup is on, so Shut down is not a cold boot.' 'Turn it off yourself, then run the installer again: Control Panel > Power Options > Choose what the power buttons do > Change settings that are currently unavailable > clear "Turn on fast startup" > Save changes.'}
}
# The longest file the build and tests create sits 149 characters below the installer folder, and Windows limits a path to 259.
$script:MaxInstallerPath = 100
function Test-C15PathLength {
 $p = Get-SysInstallerRoot
 if ($p.Length -le $script:MaxInstallerPath) { return New-Result C15 'Installer folder path is short enough' Pass ("The folder path is {0} characters (limit {1})." -f $p.Length, $script:MaxInstallerPath) }
 New-Result C15 'Installer folder path is short enough' Fail ("The folder path is {0} characters; the limit is {1}." -f $p.Length, $script:MaxInstallerPath) `
  'Move the whole folder to a short path such as C:\GpuUnlock and start the installer from there. Windows cannot open files whose full path is longer than 259 characters, and the build creates long file names.'
}
function Test-C13PendingBoot {
 if(Get-SysQueuedBoot){New-Result C13 'No one-time boot is queued' Info 'A one-time boot is already queued (for example by an earlier unlock setup).'}
 else{New-Result C13 'No one-time boot is queued' Pass 'Nothing is queued.'}
}

function Invoke-AllChecks {
 $names='Test-C01Admin','Test-C02Uefi','Test-C03SecureBoot','Test-C04BitLocker','Test-C05Gpt','Test-C06BootPartition','Test-C07Cards','Test-C08Desktop','Test-C09SecondAdapter','Test-C11FastStartup','Test-C13PendingBoot','Test-C15PathLength'
 foreach($n in $names){
  try{& $n}catch{New-Result ($n -replace '^Test-(C\d\d).*','$1') $n Unknown ("The check could not run: "+$_.Exception.Message)}
 }
}
