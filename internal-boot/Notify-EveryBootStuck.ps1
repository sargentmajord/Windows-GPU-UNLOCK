# Runs at logon, as the signed-in user (not SYSTEM - only the interactive session can show a notification to
# the person actually at the keyboard). Read-only: it only looks at arm.log, it never changes anything itself.
# If every-boot mode's own startup task (which runs as SYSTEM, separately) has stopped queuing because a
# previous run left no report, this shows a toast with three choices and exits. Safe to run every logon: if
# everything is fine it does nothing and exits immediately.
param([string]$DataRoot = (Join-Path $env:ProgramData 'WindowsGPUUnlock'), [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$log = Join-Path $DataRoot 'arm.log'

function Test-Stuck {
 if (-not (Test-Path -LiteralPath $log)) { return $false }
 $last = Get-Content -LiteralPath $log -Tail 1 -ErrorAction SilentlyContinue
 return [bool]($last -match 'not armed: the previously queued unlock left no report')
}

if (-not (Test-Stuck)) { exit 0 }
if ($DryRun) { Write-Output 'DRYRUN: would show the every-boot-stuck notification (Repair / Ignore / No)'; exit 0 }

try {
 [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
 [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType=WindowsRuntime] | Out-Null
 $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
 $xml.LoadXml(@'
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>GPU unlock: every-boot mode stopped</text>
      <text>A queued unlock left no report (a freeze, a power loss, or a test), so it has stopped queuing new ones to be safe.</text>
    </binding>
  </visual>
  <actions>
    <action content="Repair" arguments="gpuunlock-action:repair" activationType="protocol"/>
    <action content="Ignore" arguments="gpuunlock-action:ignore" activationType="protocol"/>
    <action content="No, turn it off" arguments="gpuunlock-action:no" activationType="protocol"/>
  </actions>
</toast>
'@)
 $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
 # Standard unpackaged-PowerShell AppUserModelID; shown under "Windows PowerShell" with no extra install needed.
 $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
 [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
} catch {
 Add-Content -LiteralPath $log -Value ("{0:s} [notify] could not show the toast notification: {1}" -f (Get-Date), $_.Exception.Message)
}
