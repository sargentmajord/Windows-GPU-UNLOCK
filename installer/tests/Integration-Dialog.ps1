# The real resume window, shown for a moment and clicked by the script (reversible, needs no restart). Run by hand; it flashes a window.
# Usage: Integration-Dialog.ps1 [-Png <path>]   (the picture is only for looking at the layout)
param([string]$Png)
$base = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Harness.ps1')
foreach ($m in 'Ui', 'State', 'Resume') { . (Join-Path $base "$m.ps1") }
Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
$script:PhaseOrder = @('checks', 'cards', 'tools', 'partition', 'plan', 'backup', 'make-partition', 'diag-build', 'diag-stage', 'diag-entry', 'diag-queue', 'diag-collect', 'profile', 'firmware', 'build', 'hosttests', 'benchmark-offer', 'benchmark-prepare', 'benchmark-before', 'stage', 'unlock-queue', 'unlock-collect', 'benchmark-after', 'verdict', 'schedule')
$text = "Windows GPU Unlock installer: $(Get-StepText @{ Phase = 'unlock-collect' }) is ready.`r`n`r`nContinue now? Windows will ask you to approve administrator rights. Nothing changes until you click Continue."

foreach ($want in 'Continue', 'Not now', 'Roll back') {
 $form = New-ChoiceForm 'Windows GPU Unlock installer' $text @('Continue', 'Not now', 'Roll back')
 $form.Add_Shown({
  param($s, $e)
  if ($Png -and $want -eq 'Continue') { $bmp = New-Object System.Drawing.Bitmap($s.Width, $s.Height); $s.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height))); $bmp.Save($Png); $bmp.Dispose() }
  $b = @($s.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq $want })[0]
  $b.PerformClick()
 })
 [void]$form.ShowDialog()
 Expect "the shown window returns '$want' when that button is clicked" ([string]$form.Tag) $want
 $form.Dispose()
}
# closing with the X (no click) counts as Not now
$form = New-ChoiceForm 'Windows GPU Unlock installer' $text @('Continue', 'Not now', 'Roll back')
$form.Add_Shown({ param($s, $e) $s.Close() })
[void]$form.ShowDialog()
Expect 'closing the window records no choice (the caller treats that as Not now)' ([string]$form.Tag) ''
$form.Dispose()
Complete-Tests
