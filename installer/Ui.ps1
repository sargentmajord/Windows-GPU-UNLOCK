# Console prompts. Every question goes through Read-Answer so tests can feed scripted answers.

function Read-Answer([string]$Prompt) { Read-Host $Prompt }

# Y or N only; anything else asks again. There is no default answer.
function Ask-YesNo([string]$Question) {
 while ($true) {
  $a = (Read-Answer "$Question (Y/N)").Trim().ToUpper()
  if ($a -eq 'Y') { return $true }
  if ($a -eq 'N') { return $false }
 }
}

# Returns the chosen number from 1..Max, or $null for the word NONE. Never has a default.
function Ask-Number([string]$Question, [int]$Max, [string]$NoneWord = 'NONE') {
 while ($true) {
  $a = (Read-Answer "$Question (1-$Max, or $NoneWord)").Trim()
  if ($a.ToUpper() -eq $NoneWord) { return $null }
  $n = 0
  if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Max) { return $n }
 }
}

# The user must type the exact phrase (case-sensitive). Used for steps that cannot be undone casually.
function Ask-Phrase([string]$Question, [string]$Phrase) {
 $a = Read-Answer "$Question Type $Phrase to confirm, or anything else to cancel"
 $a.Trim() -ceq $Phrase
}

function Write-Plain([string]$Text) { Write-Host $Text }
