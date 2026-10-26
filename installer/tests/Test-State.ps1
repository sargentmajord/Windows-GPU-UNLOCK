# State file, journal and prompt helper tests. Touches only a temporary folder.
$base = Split-Path -Parent $PSScriptRoot
. (Join-Path $base 'Ui.ps1'); . (Join-Path $base 'State.ps1')
. (Join-Path $PSScriptRoot 'Harness.ps1')

$t = New-TestRoot
try {
 # state round trip, atomic save leaves no temp file
 $s = Read-InstallerState
 Expect 'new state has phase new' $s.Phase 'new'
 $s.Phase = 'cards'; $s.Cards = [ordered]@{ Target = [ordered]@{ Bus = '01:00.0'; Id = '10de:2544' } }
 Save-InstallerState $s
 $r = Read-InstallerState
 Expect 'state phase round trips' $r.Phase 'cards'
 Expect 'nested state round trips' $r.Cards.Target.Bus '01:00.0'
 ExpectTrue 'no temp file left' (-not (Test-Path ((Get-StatePath) + '.tmp')))
 Set-Content -LiteralPath (Get-StatePath) -Value '{"x":1}'
 ExpectThrows 'state without Version is refused' { Read-InstallerState } '*not valid*'
 Remove-Item (Get-StatePath)

 # journal: planned then done; failed change; history is appended, never rewritten
 $ran = $false
 $id = Invoke-JournaledChange -Phase 'p' -Action 'make thing' -Target 'T' -Previous ([ordered]@{ Old = 5 }) -Undo 'remove thing' -Do { $script:ran = $true }
 ExpectTrue 'change ran' $script:ran
 $j = @(Read-Journal)
 Expect 'one journal entry' $j.Count 1
 Expect 'entry is done' $j[0].Status 'done'
 Expect 'previous value kept' $j[0].Previous.Old 5
 Expect 'undo text kept' $j[0].Undo 'remove thing'
 ExpectThrows 'failing change rethrows' { Invoke-JournaledChange -Phase 'p' -Action 'bad' -Target 'T2' -Do { throw 'boom' } } '*boom*'
 $j = @(Read-Journal)
 Expect 'two entries' $j.Count 2
 Expect 'failed entry marked failed' $j[1].Status 'failed'
 Expect 'journal file has one line per event' (@(Get-Content (Get-JournalPath)).Count) 4

 # the journal entry exists BEFORE the change runs
 $seen = $null
 [void](Invoke-JournaledChange -Phase 'p' -Action 'order' -Target 'T3' -Do { $script:seen = @(Read-Journal | Where-Object Target -eq 'T3')[0].Status })
 Expect 'entry is planned while the change runs' $script:seen 'planned'

 # a variable named like the function's own locals must still reach the -Do block (a real bug the capture tests found:
 # the block saw the journal id instead of the caller's firmware entry id)
 $id = 'caller-value'; $got = $null
 [void](Invoke-JournaledChange -Phase 'p' -Action 'scope' -Target 'T5' -Do { $script:got = $id })
 Expect 'the caller variable id reaches the block unchanged' $script:got 'caller-value'

 # dry run changes nothing
 $before = (Get-Content (Get-JournalPath)).Count
 $ran = $false
 [void](Invoke-JournaledChange -Phase 'p' -Action 'dry' -Target 'T4' -Do { $script:ran = $true } -DryRun)
 ExpectTrue 'dry run does not run the change' (-not $script:ran)
 Expect 'dry run writes no journal line' (Get-Content (Get-JournalPath)).Count $before

 # prompts
 Set-Answers @('maybe', '', 'y')
 ExpectTrue 'Y/N repeats until Y or N' (Ask-YesNo 'q')
 Expect 'three prompts were shown' $script:Asked.Count 3
 Set-Answers @('n'); ExpectTrue 'N is false' (-not (Ask-YesNo 'q'))
 Set-Answers @('0', '4', 'x', '3'); Expect 'number in range' (Ask-Number 'q' 3) 3
 Set-Answers @('none'); ExpectTrue 'NONE gives null' ($null -eq (Ask-Number 'q' 3))
 Set-Answers @('shrink'); ExpectTrue 'phrase is case sensitive' (-not (Ask-Phrase 'q' 'SHRINK'))
 Set-Answers @('SHRINK'); ExpectTrue 'exact phrase accepted' (Ask-Phrase 'q' 'SHRINK')
} finally { Remove-TestRoot $t }
Complete-Tests
