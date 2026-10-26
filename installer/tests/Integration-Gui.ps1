# Opens the REAL window and runs the real installer session in DRY RUN (real read-only queries on this PC, nothing is changed or saved),
# answering every question by script and measuring the layout at each question.
# Run by hand from an administrator PowerShell; it shows a window for a short time. Usage: Integration-Gui.ps1 [-Seconds 90]
param([int]$Seconds = 90)
$base = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $base
$ErrorActionPreference = 'Stop'
. (Join-Path $repo 'internal-boot\SecureFolder.ps1')
foreach ($m in 'Ui', 'State', 'Resume', 'Main', 'Gui') { . (Join-Path $base "$m.ps1") }
$script:ShotCount = 0; $script:Layout = @()
$answer = {
 param($msg)
 $ui = $script:GuiUi
 $script:ShotCount++
 # no pictures are taken (a screen copy could show other windows on the desktop): the layout is checked by measuring the controls
 [System.Windows.Forms.Application]::DoEvents()
 $client = $ui.Form.ClientRectangle
 $bad = @($ui.Buttons.Controls | Where-Object { $_.Right -gt $client.Width -or $_.Bottom -gt $client.Height })
 $script:Layout += ('{0}: answer panel {1}x{2} at y={3} of client height {4}; buttons outside the window: {5}; prompt: {6}' -f $msg.Type, $ui.Answer.Width, $ui.Answer.Height, $ui.Answer.Top, $client.Height, $bad.Count, [string]$msg.Prompt)
 switch ($msg.Type) { 'yesno' { $true } 'number' { 1 } 'confirm' { $true } default { '' } }
}
Start-GuiInstaller $repo @{ DryRun = $true; CaptureFolder = ''; Rollback = $false; Confirmed = $false } $answer $Seconds
Write-Host ('questions answered: ' + $script:ShotCount)
$script:Layout
