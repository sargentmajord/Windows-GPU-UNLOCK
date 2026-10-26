# Target card and console adapter selection tests (plan requirement 15), with mocked adapters.
$base = Split-Path -Parent $PSScriptRoot
. (Join-Path $base 'Ui.ps1'); . (Join-Path $base 'State.ps1'); . (Join-Path $base 'Checks.ps1'); . (Join-Path $base 'CardSelect.ps1')
. (Join-Path $PSScriptRoot 'Harness.ps1')

function Adapter($Name, $Dev, $Sub, $Bus, $Ven = '10DE') {
 $b = $Bus -split '[:.]'
 [pscustomobject]@{ Name = $Name; InstanceId = "PCI\VEN_$Ven&DEV_$Dev&SUBSYS_$Sub&REV_A1\X"; Location = ('PCI bus {0}, device {1}, function {2}' -f [int]$b[0], [int]$b[1], [int]$b[2]) }
}
$rtx3060 = Adapter 'NVIDIA GeForce RTX 3060' '2544' '397D1462' '01:00.0'
$rtx5070 = Adapter 'NVIDIA GeForce RTX 5070' '2F04' '89F21043' '02:00.0'
$rtx3080 = Adapter 'NVIDIA GeForce RTX 3080' '2206' '12345678' '03:00.0'
$intel = Adapter 'Intel UHD Graphics' '4680' '86941043' '00:02.0' '8086'

function Get-SysNvidiaSmi { @([pscustomobject]@{ Bus = '01:00.0'; VramMiB = 12288; Display = 'Disabled' }, [pscustomobject]@{ Bus = '02:00.0'; VramMiB = 12227; Display = 'Enabled' }) }

# --- table ---
function Get-SysAdapters { @($rtx5070, $rtx3060) }
$tbl = @(Get-CardTable)
Expect 'table is numbered in bus order' $tbl[0].Bus '01:00.0'
Expect 'first card number' $tbl[0].Number 1
Expect 'second card number' $tbl[1].Number 2
Expect 'id' $tbl[0].Id '10de:2544'
Expect 'subsystem is vendor:device' $tbl[0].Subsystem '1462:397d'
Expect 'vram from nvidia-smi' $tbl[0].VramMiB 12288
Expect 'display flag disabled' $tbl[0].DrivingDisplay $false
Expect 'display flag enabled' $tbl[1].DrivingDisplay $true
ExpectTrue 'rtx 3060 supported' $tbl[0].Supported
ExpectTrue 'rtx 5070 not supported' (-not $tbl[1].Supported)
ExpectTrue 'line mentions verdict' ((Format-CardLine $tbl[1]) -like '*not supported*')

# without nvidia-smi the table still works
function Get-SysNvidiaSmi { @() }
$tbl2 = @(Get-CardTable)
ExpectTrue 'vram unknown without nvidia-smi' ($null -eq $tbl2[0].VramMiB)
ExpectTrue 'display unknown without nvidia-smi' ($null -eq $tbl2[0].DrivingDisplay)
ExpectTrue 'line says unknown' ((Format-CardLine $tbl2[0]) -like '*unknown*')

# --- selection: single candidate is still confirmed, nothing is silent ---
function Get-SysAdapters { @($rtx3060, $rtx5070) }
Set-Answers @('Y', 'Y')
$sel = Select-Cards
Expect 'target bus' $sel.Target.Bus '01:00.0'
Expect 'console bus' $sel.Console.Bus '02:00.0'
Expect 'both were asked' $script:Asked.Count 2
ExpectTrue 'fingerprint saved' ($sel.Fingerprint -like '*01:00.0|10de:2544|1462:397d*')

Set-Answers @('N'); ExpectTrue 'declining the target changes nothing' ($null -eq (Select-Cards))
Set-Answers @('Y', 'N'); ExpectTrue 'declining the console adapter changes nothing' ($null -eq (Select-Cards))

# no supported card: no question at all
function Get-SysAdapters { @($rtx5070, $intel) }
Set-Answers @()
ExpectTrue 'no supported card gives null' ($null -eq (Select-Cards))
ExpectTrue 'says nothing was changed' ((OutText) -like '*Nothing was changed*')

# only one adapter: needs a second
function Get-SysAdapters { @($rtx3060) }
Set-Answers @('Y')
ExpectTrue 'no second adapter stops' ($null -eq (Select-Cards))
ExpectTrue 'says a second adapter is needed' ((OutText) -like '*No second graphics adapter*')

# two supported cards: the user types a number; unsupported number cannot be chosen
function Get-SysAdapters { @($rtx3060, $rtx5070, $rtx3080) }
Set-Answers @('3', '2')
$sel = Select-Cards
Expect 'chosen second supported card' $sel.Target.Bus '03:00.0'
Expect 'console picked by number' $sel.Console.Bus '02:00.0'
Set-Answers @('2')
ExpectTrue 'unsupported number refused' ($null -eq (Select-Cards))
Set-Answers @('1', '1')
ExpectTrue 'console equal to target refused' ($null -eq (Select-Cards))
Set-Answers @('NONE'); ExpectTrue 'NONE at target stops' ($null -eq (Select-Cards))

# intel iGPU as console adapter works (any vendor)
function Get-SysAdapters { @($intel, $rtx3060) }
Set-Answers @('Y', 'Y')
$sel = Select-Cards
Expect 'igpu console id' $sel.Console.Id '8086:4680'

# --- re-check at every phase ---
function Get-SysAdapters { @($rtx3060, $rtx5070) }
Set-Answers @('Y', 'Y'); $saved = Select-Cards
ExpectTrue 'unchanged passes' (Test-CardsUnchanged $saved).Ok
function Get-SysAdapters { @($rtx3060, $rtx5070, $rtx3080) }
ExpectTrue 'added card is noticed' (-not (Test-CardsUnchanged $saved).Ok)
function Get-SysAdapters { @($rtx3060, (Adapter 'NVIDIA GeForce RTX 5070' '2F04' '89F21043' '04:00.0')) }
ExpectTrue 'moved console card is noticed' (-not (Test-CardsUnchanged $saved).Ok)
function Get-SysAdapters { @((Adapter 'NVIDIA GeForce RTX 3060' '2544' '397D1462' '05:00.0'), $rtx5070) }
ExpectTrue 'moved target card is noticed' (-not (Test-CardsUnchanged $saved).Ok)
function Get-SysAdapters { @((Adapter 'NVIDIA GeForce RTX 3060' '2544' 'AAAA1111' '01:00.0'), $rtx5070) }
ExpectTrue 'different subsystem is noticed' (-not (Test-CardsUnchanged $saved).Ok)
function Get-SysAdapters { @($rtx5070) }
ExpectTrue 'removed card is noticed' (-not (Test-CardsUnchanged $saved).Ok)

# two identical cards are told apart by bus address
$a = Adapter 'NVIDIA GeForce RTX 3060' '2544' '397D1462' '01:00.0'
$b = Adapter 'NVIDIA GeForce RTX 3060' '2544' '397D1462' '03:00.0'
function Get-SysAdapters { @($a, $b, $rtx5070) }
Set-Answers @('3', '2')
$sel = Select-Cards
Expect 'identical card chosen by bus' $sel.Target.Bus '03:00.0'

Complete-Tests
