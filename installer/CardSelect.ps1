# Target card and console adapter selection (plan requirement 15). Read-only; the user always chooses.
# Depends on Checks.ps1 (Get-SysAdapters, ConvertTo-AdapterInfo) and Ui.ps1.

# nvidia-smi rows by bus address; empty when nvidia-smi is not installed.
function Get-SysNvidiaSmi {
 $exe = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
 if (-not $exe) { return @() }
 $out = & $exe.Source --query-gpu=pci.bus_id,name,memory.total,display_active --format=csv,noheader,nounits 2>$null
 if ($LASTEXITCODE -ne 0) { return @() }
 @($out | ForEach-Object {
  $f = $_ -split ',\s*'
  if ($f.Count -ge 4 -and $f[0] -match '([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2})\.(\d)$') {
   [pscustomobject]@{ Bus = ('{0}:{1}.{2}' -f $Matches[1].ToLower(), $Matches[2].ToLower(), $Matches[3]); VramMiB = [int]$f[2]; Display = $f[3] }
  }
 })
}

function ConvertFrom-SubsysId([string]$InstanceId) {
 if ($InstanceId -match 'SUBSYS_([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})') { return ('{0}:{1}' -f $Matches[2].ToLower(), $Matches[1].ToLower()) }   # vendor:device
 'unknown'
}

# One row per display adapter, numbered 1..n in bus order.
function Get-CardTable {
 $smi = @(Get-SysNvidiaSmi)
 $rows = @(Get-SysAdapters | ForEach-Object {
  $i = ConvertTo-AdapterInfo $_
  $s = $smi | Where-Object { $_.Bus -eq $i.Bus } | Select-Object -First 1
  [pscustomobject]@{
   Number = 0; Name = $i.Name; Id = $i.Id; Subsystem = (ConvertFrom-SubsysId $_.InstanceId); Bus = $i.Bus
   VramMiB = $(if ($s) { $s.VramMiB } else { $null }); DrivingDisplay = $(if ($s) { $s.Display -eq 'Enabled' } else { $null })
   Verdict = $i.Verdict; Supported = $i.Supported
  }
 } | Sort-Object Bus)
 $n = 0
 foreach ($r in $rows) { $n++; $r.Number = $n }
 $rows
}

function Format-CardLine($Card) {
 $vram = if ($null -ne $Card.VramMiB) { '{0} MiB' -f $Card.VramMiB } else { 'memory unknown' }
 $disp = switch ($Card.DrivingDisplay) { $true { 'driving a display' } $false { 'no display in use' } default { 'display use unknown' } }
 ('{0}. {1}  [{2}, subsystem {3}]  bus {4}  {5}, {6}' -f $Card.Number, $Card.Name, $Card.Id, $Card.Subsystem, $Card.Bus, $vram, $disp) + [Environment]::NewLine + '      ' + $Card.Verdict
}

function ConvertTo-CardRecord($Card) { [ordered]@{ Name = $Card.Name; Id = $Card.Id; Subsystem = $Card.Subsystem; Bus = $Card.Bus; VramMiB = $Card.VramMiB } }

function Get-CardSetFingerprint($Cards) { (($Cards | ForEach-Object { '{0}|{1}|{2}' -f $_.Bus, $_.Id, $_.Subsystem } | Sort-Object) -join ';') }

# Returns @{ Target; Console; Fingerprint } or $null when the user declines or nothing is eligible.
# Nothing is picked silently, even with a single candidate; unsupported cards cannot be chosen; no override.
function Select-Cards {
 $cards = @(Get-CardTable)
 Write-Plain ''
 Write-Plain 'Graphics adapters found:'
 foreach ($c in $cards) { Write-Plain ('  ' + (Format-CardLine $c)) }
 Write-Plain ''

 $targets = @($cards | Where-Object Supported)
 if (-not $targets.Count) {
  Write-Plain 'None of these cards can be unlocked by this installer (no accepted RTX 30 series ID). Nothing was changed.'
  return $null
 }
 if ($targets.Count -eq 1) {
  $t = $targets[0]
  Write-Plain ('The card to unlock would be: {0} (bus {1}).' -f $t.Name, $t.Bus)
  if (-not (Ask-YesNo 'Use this card?')) { Write-Plain 'Nothing was changed.'; return $null }
 } else {
  Write-Plain 'More than one card can be unlocked. Cards are told apart by their bus address, so identical cards cannot be mixed up.'
  $n = Ask-Number 'Which card do you want to unlock? Type its number' $cards.Count
  if ($null -eq $n) { Write-Plain 'Nothing was changed.'; return $null }
  $t = $cards | Where-Object Number -eq $n
  if (-not $t.Supported) { Write-Plain 'That card is not supported and cannot be chosen. Nothing was changed.'; return $null }
 }

 $consoles = @($cards | Where-Object { $_.Bus -ne $t.Bus })
 if (-not $consoles.Count) {
  Write-Plain 'No second graphics adapter was found. Another adapter must keep your screen working while the unlock runs. Nothing was changed.'
  return $null
 }
 Write-Plain ''
 Write-Plain 'Another adapter must keep your screen working while the target card is set up. It is never touched.'
 if ($consoles.Count -eq 1) {
  $k = $consoles[0]
  Write-Plain ('Screen adapter: {0} (bus {1}).' -f $k.Name, $k.Bus)
  if (-not (Ask-YesNo 'Is this the adapter your monitor is plugged into?')) { Write-Plain 'Nothing was changed.'; return $null }
 } else {
  $n = Ask-Number 'Which adapter keeps your screen working? Type its number' $cards.Count
  if ($null -eq $n) { Write-Plain 'Nothing was changed.'; return $null }
  $k = $cards | Where-Object Number -eq $n
  if ($k.Bus -eq $t.Bus) { Write-Plain 'That is the card to unlock; it cannot also be the screen adapter. Nothing was changed.'; return $null }
 }
 [ordered]@{ Target = (ConvertTo-CardRecord $t); Console = (ConvertTo-CardRecord $k); Fingerprint = (Get-CardSetFingerprint $cards) }
}

# Re-checked at every phase: a moved or added card stops the installer instead of continuing with a stale choice.
function Test-CardsUnchanged($Saved) {
 $cards = @(Get-CardTable)
 $t = $cards | Where-Object { $_.Bus -eq $Saved.Target.Bus -and $_.Id -eq $Saved.Target.Id -and $_.Subsystem -eq $Saved.Target.Subsystem }
 $k = $cards | Where-Object { $_.Bus -eq $Saved.Console.Bus -and $_.Id -eq $Saved.Console.Id -and $_.Subsystem -eq $Saved.Console.Subsystem }
 $fp = Get-CardSetFingerprint $cards
 $ok = [bool]$t -and [bool]$k -and ($fp -ceq $Saved.Fingerprint)
 [pscustomobject]@{
  Ok = $ok
  Detail = $(if ($ok) { 'The chosen cards are where they were.' } else { 'The set of graphics cards, or a chosen card''s bus address or ID, changed since you chose. Choose again.' })
 }
}
