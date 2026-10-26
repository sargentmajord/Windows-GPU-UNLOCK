// Copyright (C) Windows GPU UNLOCK contributors. GPL-2.0-only.
/*
 * Recovery drill image. Does nothing except stop: it prints one line, turns the firmware watchdog off
 * and loops forever, the same visible behavior as a failed safety check. It writes no file, no firmware
 * variable and touches no GPU. Recovery: hold the power button, then power on.
 */
#include <Uefi.h>

static CHAR16 *volatile Message=L"RECOVERY DRILL: this test image hangs on purpose.\r\nHold the power button until the PC turns off, then power on.\r\n";

EFI_STATUS EFIAPI efi_main(EFI_HANDLE Image,EFI_SYSTEM_TABLE *Table){
  (VOID)Image;
  Table->BootServices->SetWatchdogTimer(0,0,0,NULL);
  if(Table->ConOut)Table->ConOut->OutputString(Table->ConOut,Message);
  for(;;){__asm__ volatile("pause");}
  return EFI_SUCCESS;
}
