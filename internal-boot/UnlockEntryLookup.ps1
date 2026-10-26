# The firmware-entry lookup, in ONE place. Set-UnlockSchedule.ps1 loads it and pastes the same text into the generated startup script,
# and the installer pastes it into the 'Unlock my GPU on next boot' script, so the entry is found again every time and never stored.
# Expects $label (the boot partition's volume label) to be set by the caller.
function Find-UnlockEntry {
 $t=(& bcdedit.exe /enum firmware 2>&1|Out-String)
 if($LASTEXITCODE -ne 0){throw "bcdedit /enum firmware failed: $t"}
 $hits=@()
 foreach($b in ($t -split '(?:\r?\n){2,}')){
  $id=$null;$dev=$null
  if($b -match '(?mi)^identifier\s+(\{[0-9a-f-]{36}\})'){$id=$Matches[1]}
  if($b -match '(?mi)^device\s+partition=(\S+)'){$dev=$Matches[1]}
  if($id -and $dev -and $b -match '(?mi)^path\s+\\EFI\\BOOT\\BOOTX64\.EFI\s*$'){
   $ok=$false
   if($dev -match '^([A-Za-z]):$'){$v=Get-Volume -DriveLetter $Matches[1] -ErrorAction SilentlyContinue;$ok=($v -and $v.FileSystemLabel -ceq $label)}
   if($ok){$hits+=$id}
  }
 }
 if($hits.Count -ne 1){throw "Expected exactly one firmware entry on the $label partition, found $($hits.Count)."}
 return $hits[0]
}
