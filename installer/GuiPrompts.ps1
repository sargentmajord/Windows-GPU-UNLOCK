# The prompt functions of the graphical front end. They run in the installer's worker (a separate runspace) and talk to the window
# through $script:Bridge; they replace the console versions in Ui.ps1 and nothing else: the phases, the state, the journal and every
# safety rule are the shared modules. The window side is Gui.ps1.
#
# $script:Bridge is a synchronized hashtable made by the window: Queue (ConcurrentQueue of messages), Answer, AnswerReady
# (ManualResetEventSlim) and Closed. Messages: @{ Kind = 'text'; Text; Color } | @{ Kind = 'ask'; Type = yesno|number|confirm|text; ... } | @{ Kind = 'phase'; Text } | @{ Kind = 'done' }.

function Send-Ui($Message) { $script:Bridge.Queue.Enqueue([pscustomobject]$Message) }

# Waits for the window's answer. If the window was closed there is nobody to answer: stop the session.
function Wait-UiAnswer {
 $script:Bridge.AnswerReady.Reset()
 while (-not $script:Bridge.AnswerReady.Wait(200)) { if ($script:Bridge.Closed) { throw 'The window was closed.' } }
 if ($script:Bridge.Closed) { throw 'The window was closed.' }
 $script:Bridge.Answer
}

function Write-Plain([string]$Text) { Send-Ui @{ Kind = 'text'; Text = $Text; Color = '' } }

# Replaces the Write-Host cmdlet inside the worker, so every message the modules print reaches the window (with its colour).
function Write-Host {
 param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, $ForegroundColor, $BackgroundColor, [switch]$NoNewline, $Separator = ' ')
 $text = if ($null -eq $Object) { '' } else { (@($Object) | ForEach-Object { [string]$_ }) -join [string]$Separator }
 Send-Ui @{ Kind = 'text'; Text = $text; Color = $(if ($ForegroundColor) { [string]$ForegroundColor } else { '' }) }
}

function Read-Answer([string]$Prompt) {
 Send-Ui @{ Kind = 'ask'; Type = 'text'; Prompt = $Prompt }
 [string](Wait-UiAnswer)
}
# Yes or No buttons. There is no default and no button has the focus when the question appears.
function Ask-YesNo([string]$Question) {
 Send-Ui @{ Kind = 'ask'; Type = 'yesno'; Prompt = $Question }
 (Wait-UiAnswer) -eq $true
}
# One button per option (the options themselves were printed above the question), plus a button for the none word. Returns 1..Max or $null.
function Ask-Number([string]$Question, [int]$Max, [string]$NoneWord = 'NONE') {
 Send-Ui @{ Kind = 'ask'; Type = 'number'; Prompt = $Question; Max = $Max; NoneWord = $NoneWord }
 $a = Wait-UiAnswer
 if ($null -eq $a -or $a -eq '') { return $null }
 [int]$a
}
# A real confirmation: the window shows the question (which already carries the exact sizes or consequences) and a check box
# "I confirm: <phrase>"; the answer is true only if the box is ticked and Confirm is pressed.
function Ask-Phrase([string]$Question, [string]$Phrase) {
 Send-Ui @{ Kind = 'ask'; Type = 'confirm'; Prompt = $Question; Phrase = $Phrase }
 (Wait-UiAnswer) -eq $true
}

# Called by the phase loop before each phase; shows "step N of M (what it is)" and keeps the busy bar running.
function Set-UiPhase([string]$Phase) {
 $text = if ($script:PhaseOrder -contains $Phase) { Get-StepText @{ Phase = $Phase } } elseif ($Phase -eq 'rollback') { 'rolling back' } else { $Phase }
 Send-Ui @{ Kind = 'phase'; Text = $text }
}
