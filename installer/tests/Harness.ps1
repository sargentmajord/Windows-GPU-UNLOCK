# Shared test helpers. Dot-source this first. Tests never touch the real PC: every Get-Sys*/Invoke-Sys* is replaced,
# prompts come from a scripted answer queue, and state lives in a temporary folder.
$ErrorActionPreference = 'Stop'
# the secure-folder helpers (used by the state module and the generated scripts); tests never protect a real folder
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'internal-boot\SecureFolder.ps1')
$script:Failures = 0
$script:Passes = 0

function Expect([string]$Name, $Actual, $Wanted) {
 if ($Actual -ceq $Wanted) { $script:Passes++; Write-Host "ok   $Name" }
 else { $script:Failures++; Write-Host "FAIL $Name : got '$Actual', wanted '$Wanted'" -ForegroundColor Red }
}
function ExpectTrue([string]$Name, $Condition) { Expect $Name ([bool]$Condition) $true }
function ExpectThrows([string]$Name, [scriptblock]$Do, [string]$Like = '*') {
 $msg = $null
 try { & $Do } catch { $msg = $_.Exception.Message }
 if ($null -ne $msg -and $msg -like $Like) { $script:Passes++; Write-Host "ok   $Name" }
 else { $script:Failures++; Write-Host "FAIL $Name : expected an error like '$Like', got '$msg'" -ForegroundColor Red }
}

# Scripted prompts. Running out of answers is a test failure (an unexpected question).
$script:Answers = New-Object System.Collections.Queue
$script:Asked = New-Object System.Collections.ArrayList
$script:Out = New-Object System.Collections.ArrayList
function Set-Answers([string[]]$List) { $script:Answers = New-Object System.Collections.Queue; foreach ($a in $List) { $script:Answers.Enqueue($a) }; $script:Asked.Clear(); $script:Out.Clear() }
function Read-Answer([string]$Prompt) {
 [void]$script:Asked.Add($Prompt)
 if (-not $script:Answers.Count) { throw ("UNEXPECTED QUESTION: $Prompt (questions so far: " + (($script:Asked | Select-Object -SkipLast 1) -join ' | ') + ")") }
 $script:Answers.Dequeue()
}
function Write-Plain([string]$Text) { [void]$script:Out.Add($Text) }
function OutText { $script:Out -join "`n" }

function New-TestRoot {
 $p = Join-Path ([IO.Path]::GetTempPath()) ('gpuunlock-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
 [void](New-Item -ItemType Directory -Path $p)
 Set-InstallerRoot (Join-Path $p 'installer')
 $p
}
function Remove-TestRoot([string]$Path) { if ($Path -and $Path.StartsWith([IO.Path]::GetTempPath()) -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Recurse -Force } }

# The automatic-resume entry (a real current-user scheduled task) and the choice window are replaced: tests never touch Task Scheduler or show a window.
$script:FakeResumeTask = $null
function Get-SysResumeTask { $script:FakeResumeTask }
function Set-SysResumeTask([string]$ScriptPath) { $script:FakeResumeTask = (Get-ResumeCommand $ScriptPath) }
function Remove-SysResumeTask { $script:FakeResumeTask = $null }
function Show-SysChoiceDialog([string]$Title, [string]$Text, [string[]]$Buttons) { $null }

function Complete-Tests {
 Write-Host ("{0} passed, {1} failed" -f $script:Passes, $script:Failures)
 if ($script:Failures) { exit 1 }
}
