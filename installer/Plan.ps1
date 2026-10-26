# The plan screen (plan requirements 14 and 30): one list of every change the installer will make, confirmed once.
# Items are built from the saved choices, so the list is exact for what is already decided and says "decided later" for the rest.

function New-PlanItem([string]$Phase, [string]$What, [string]$Undo, [bool]$Known = $true) {
 [pscustomobject]@{ Phase = $Phase; What = $What; Undo = $Undo; Known = $Known }
}

function Get-FullPlan($State) {
 $p = @()
 $p += New-PlanItem 'backup' 'Back up the boot configuration, firmware boot entries, partition table and Fast Startup value to the installer folder.' 'Backups are kept.'
 $p += New-PlanItem 'tools' 'Check for the build tools (LLVM 20.1.8, Python, Microsoft C++ Build Tools); offer to install any that are missing, each with its download size, only after you agree.' 'Tools you agreed to install stay installed; Roll back lists them.'
 $b = $State.BootPartition
 if ($b) {
  switch ($b.Kind) {
   'Existing' { $p += New-PlanItem 'partition' ('Use the existing boot partition (disk {0}, partition {1}). Nothing is resized or created.' -f $b.Disk, $b.Number) 'Nothing to undo.' }
   'Alternate' { $p += New-PlanItem 'partition' ('Create a 2 GiB FAT32 partition labelled GPUUNLOCK on disk {0}, in its unallocated space.' -f $b.Disk) 'Roll back offers to delete it (asks first).' }
   'Shrink' { $p += New-PlanItem 'partition' ('Shrink drive C: by {0:N2} GiB (from {1:N2} GiB) and create a 2 GiB FAT32 partition labelled GPUUNLOCK there.' -f ($b.ShrinkBytes / 1GB), ($b.CSizeBytes / 1GB)) 'Roll back offers to delete the partition and extend C: back (asks first, shows the sizes).' }
  }
 } else { $p += New-PlanItem 'partition' 'Boot partition: decided when you choose it.' '' $false }
 $p += New-PlanItem 'capture' 'Copy the read-only diagnostic to the boot partition (a file already there with the same name is first copied to the backup folder), queue one boot of it, and restart (you confirm each restart; the firmware may need one extra restart to notice the partition). The diagnostic reads the PC and writes only a log.' 'Roll back removes the files, puts back any file it replaced, and removes any queued boot.'
 $p += New-PlanItem 'profile' 'Create a profile for this PC from the capture and show you what it found.' 'Working files are removed by Roll back.'
  $p += New-PlanItem 'firmware' 'Generate NVIDIA firmware files locally (disclosed download, hashes checked, kept inside the installer folder).' 'Roll back asks whether to keep or delete them.'
 $p += New-PlanItem 'build' 'Build and test the boot programs for this PC against its own capture (no hardware access).' 'Working files are removed by Roll back.'
 $p += New-PlanItem 'stage' 'Copy the boot programs to the boot partition (files only; the permanent boot order and the Windows boot entry are never changed).' 'Roll back deletes files whose hash still matches.'
 $p += New-PlanItem 'benchmark' 'Optional benchmark before and after (about 489 MB download, you decide; strongly advised).' 'Benchmark files stay in the installer folder.' $false
 $p += New-PlanItem 'unlock' 'Queue one unlock for the next boot (you confirm the restart).' 'Roll back deletes any queued boot.'
 $p += New-PlanItem 'schedule' 'Offer a Start-menu shortcut "Unlock my GPU on next boot" for all users (an optional copy on the desktop; it asks for administrator approval each time and only queues one unlock). At the very end two optional extras are offered, each on its own screen: no key press (automatic mode) and no Esc countdown; running the unlock at every start, with a Windows startup task, is a separate opt-in that needs automatic mode.' 'Roll back deletes the shortcut and its script, removes any startup task and restores the saved Fast Startup value.' $false
 $p
}

function Show-Plan($Items) {
 Write-Plain ''
 Write-Plain 'This is everything the installer will change on your PC:'
 $i = 0
 foreach ($it in $Items) {
  $i++
  Write-Plain ('  {0,2}. {1}' -f $i, $it.What)
  if ($it.Undo) { Write-Plain ('      Undo: {0}' -f $it.Undo) }
 }
 Write-Plain ''
 Write-Plain 'It never changes the permanent boot order, the Windows boot entry, BIOS settings, your files, or the graphics card''s stored firmware.'
}

# One confirmation for the whole plan. Returns $true only for an explicit Y.
function Confirm-Plan($Items) {
 Show-Plan $Items
 Ask-YesNo 'Go ahead with this plan?'
}
