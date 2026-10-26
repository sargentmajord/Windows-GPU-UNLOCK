/* Windows GPU UNLOCK internal boot experiment, 2026-10-20. GPL-2.0-only.
 * Local exact-partition configuration; no ResetSystem. Full-test mode delegates
 * guarded driver release and PCI decode restoration to full-release.c. */
#include <Uefi.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Guid/FileInfo.h>
#include "../unlock/machine-profile.h"
#include "media.h"
#include "flow.h"
#ifdef GU_HEADLESS_RESEARCH
#include "build/headless/child-contract.h"
#elif defined(GU_AUTOMATIC_BOOT)
#include "build/automatic/child-contract.h"
#else
#include "generated.h"
#endif
#include "../unlock/sha256.h"
#ifdef GU_DIAGNOSTIC_ONLY
#include "diagnostic.h"
#endif
#ifdef GU_CONSOLE_PREPARE
#include "prepare-console.h"
#include "console-flow.h"
#ifdef GU_SINGLE_RTX_CONSOLE
#include "research-input.h"
#endif
#ifndef GU_DIAGNOSTIC_ONLY
#error Console prepare must not load the unlock application
#endif
#endif
#ifdef GU_FULL_UNLOCK
#include "diagnostic.h"
#include "full-release.h"
#include "full-flow.h"
#if defined(GU_DIAGNOSTIC_ONLY) || defined(GU_CONSOLE_PREPARE)
#error Full unlock and non-unlock experiments must remain separate builds
#endif
#endif
/* Release test: the full driver release and verification, then Windows. The unlock
 * application is neither loaded nor linked; nothing is written to the card. */
#ifdef GU_RELEASE_ONLY
#ifndef GU_FULL_UNLOCK
#error Release-only builds extend the full flow
#endif
#if defined(GU_EXPERIMENTAL_UNLOCK) || defined(GU_AUTOMATIC_BOOT) || defined(GU_HEADLESS_RESEARCH)
#error Release-only builds must not combine with any unlock mode
#endif
#endif
#if !defined(GU_DIAGNOSTIC_ONLY) && !defined(GU_RELEASE_ONLY)
#define GU_LOADS_UNLOCK 1
#endif

static EFI_GUID LoadedGuid=EFI_LOADED_IMAGE_PROTOCOL_GUID,FsGuid=EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
static EFI_GUID PathGuid=EFI_DEVICE_PATH_PROTOCOL_GUID;
#ifdef GU_LOADS_UNLOCK
static EFI_GUID InfoGuid=EFI_FILE_INFO_ID;
#endif
static EFI_SYSTEM_TABLE *Table;
static EFI_HANDLE Self,OwnDevice,WindowsImage;
#ifdef GU_LOADS_UNLOCK
static EFI_HANDLE UnlockImage;
#endif
static EFI_FILE_PROTOCOL *Root,*Log;
#ifdef GU_SINGLE_RTX_CONSOLE
static BOOLEAN ResearchOutputDisabled;
#endif

static VOID Say(const CHAR16 *Text) {
#ifdef GU_SINGLE_RTX_CONSOLE
  if(ResearchOutputDisabled)return;
#endif
  if(Table && Table->ConOut)Table->ConOut->OutputString(Table->ConOut,(CHAR16 *)Text);
}
#ifdef GU_FULL_UNLOCK
static VOID ScreenStatus(const char *Event,EFI_STATUS Status) {
  CHAR16 text[160];UINTN n=0;
  while(*Event && n<100)text[n++]=(CHAR16)*Event++;
  const char *label=" status=0x";while(*label)text[n++]=(CHAR16)*label++;
  for(int i=15;i>=0;i--)text[n++]=(CHAR16)"0123456789abcdef"[((UINT64)Status>>(i*4))&15];
  text[n++]='\r';text[n++]='\n';text[n]=0;Say(text);
}
#endif
static VOID Stop(VOID) {
  Say(L"\r\nHANDOFF STOPPED. No reset or automatic retry. Hold the power button until the PC turns off, then power on; Windows starts normally.\r\n");
  if(Table && Table->BootServices) {
    if(Table->BootServices->SetWatchdogTimer(0,0,0,NULL)!=EFI_SUCCESS)
      Say(L"WARNING: firmware watchdog could not be disabled.\r\n");
  }
  for(;;)__asm__ volatile("pause");
}
static EFI_STATUS PathFor(EFI_HANDLE Device,EFI_DEVICE_PATH_PROTOCOL **Out) {
  *Out=NULL;
  EFI_STATUS s=Table->BootServices->HandleProtocol(Device,&PathGuid,(VOID **)Out);
  return s==EFI_SUCCESS && *Out?EFI_SUCCESS:EFI_UNSUPPORTED;
}
static EFI_STATUS FindPartition(const EFI_GUID *Guid,EFI_HANDLE *Out) {
  EFI_HANDLE *handles=NULL;UINTN count=0,matches=0;*Out=NULL;
  EFI_STATUS s=Table->BootServices->LocateHandleBuffer(ByProtocol,&FsGuid,NULL,&count,&handles);
  if(s!=EFI_SUCCESS)return s;
  for(UINTN i=0;i<count;i++) {
    EFI_DEVICE_PATH_PROTOCOL *p=NULL;
    if(PathFor(handles[i],&p)==EFI_SUCCESS && GuPathIsPartition(p,Guid)){matches++;*Out=handles[i];}
  }
  if(handles)Table->BootServices->FreePool(handles);
  return matches==1?EFI_SUCCESS:matches?EFI_COMPROMISED_DATA:EFI_NOT_FOUND;
}
static EFI_STATUS FilePath(EFI_HANDLE Device,const CHAR16 *Name,EFI_DEVICE_PATH_PROTOCOL **Out) {
  EFI_DEVICE_PATH_PROTOCOL *base=NULL;UINTN baseBytes=0,chars=0;*Out=NULL;
  EFI_STATUS s=PathFor(Device,&base);
  if(s!=EFI_SUCCESS || !GuInspectPath(base,NULL,&baseBytes,NULL,NULL))return EFI_UNSUPPORTED;
  while(Name[chars] && chars<256)chars++;
  if(!chars || chars==256)return EFI_INVALID_PARAMETER;
  UINTN nodeBytes=4+(chars+1)*sizeof(CHAR16),total=baseBytes-4+nodeBytes+4;
  UINT8 *data=NULL;s=Table->BootServices->AllocatePool(EfiBootServicesData,total,(VOID **)&data);
  if(s!=EFI_SUCCESS || !data)return EFI_OUT_OF_RESOURCES;
  for(UINTN i=0;i<baseBytes-4;i++)data[i]=((UINT8 *)base)[i];
  EFI_DEVICE_PATH_PROTOCOL *node=(VOID *)(data+baseBytes-4);
  node->Type=MEDIA_DEVICE_PATH;node->SubType=MEDIA_FILEPATH_DP;
  node->Length[0]=(UINT8)nodeBytes;node->Length[1]=(UINT8)(nodeBytes>>8);
  for(UINTN i=0;i<(chars+1)*sizeof(CHAR16);i++)((UINT8 *)node)[4+i]=((const UINT8 *)Name)[i];
  EFI_DEVICE_PATH_PROTOCOL *end=(VOID *)((UINT8 *)node+nodeBytes);
  end->Type=END_DEVICE_PATH_TYPE;end->SubType=END_ENTIRE_DEVICE_PATH_SUBTYPE;end->Length[0]=4;end->Length[1]=0;
  *Out=(VOID *)data;return EFI_SUCCESS;
}
static EFI_STATUS OpenLog(VOID) {
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs=NULL;
  EFI_STATUS s=Table->BootServices->HandleProtocol(OwnDevice,&FsGuid,(VOID **)&fs);
  if(s!=EFI_SUCCESS || !fs)return EFI_UNSUPPORTED;
  s=fs->OpenVolume(fs,&Root);if(s!=EFI_SUCCESS || !Root)return EFI_DEVICE_ERROR;
#ifdef GU_AUTOMATIC_BOOT
  for(UINTN i=0;i<1000000;i++) {
#ifdef GU_HEADLESS_RESEARCH
    CHAR16 name[]=L"\\RTX3060-UNLOCK\\HLS000000.TXT";
#else
    CHAR16 name[]=L"\\RTX3060-UNLOCK\\BOOT000000.TXT";
#endif
#else
  for(UINTN i=0;i<100;i++) {
#ifdef GU_RELEASE_ONLY
    CHAR16 name[]=L"\\RTX3060-UNLOCK\\REL00.TXT";
#elif defined(GU_FULL_UNLOCK)
    CHAR16 name[]=L"\\RTX3060-UNLOCK\\FULL00.TXT";
#elif defined(GU_CONSOLE_PREPARE)
#ifdef GU_SINGLE_RTX_CONSOLE
    CHAR16 name[]=L"\\RTX3060-UNLOCK\\R2C00.TXT";
#else
    CHAR16 name[]=L"\\RTX3060-UNLOCK\\PREP00.TXT";
#endif
#elif defined(GU_DIAGNOSTIC_ONLY)
    CHAR16 name[]=L"\\RTX3060-UNLOCK\\DIAG00.TXT";
#else
    CHAR16 name[]=L"\\RTX3060-UNLOCK\\HANDOFF00.TXT";
#endif
#endif
    UINTN n=0;while(name[n])n++;
#ifdef GU_AUTOMATIC_BOOT
    UINTN number=i;for(UINTN digit=0;digit<6;digit++){name[n-5-digit]=(CHAR16)('0'+number%10);number/=10;}
#else
    name[n-6]=(CHAR16)('0'+i/10);name[n-5]=(CHAR16)('0'+i%10);
#endif
    EFI_FILE_PROTOCOL *existing=NULL;
    s=Root->Open(Root,&existing,name,EFI_FILE_MODE_READ,0);
    if(s==EFI_SUCCESS){if(existing)existing->Close(existing);continue;}
    if(s!=EFI_NOT_FOUND)return s;
    s=Root->Open(Root,&Log,name,EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE|EFI_FILE_MODE_CREATE,0);
    return s==EFI_SUCCESS && Log?EFI_SUCCESS:EFI_DEVICE_ERROR;
  }
  return EFI_VOLUME_FULL;
}
static EFI_STATUS Record(VOID *Context,const char *Event,EFI_STATUS Status) {
  (void)Context;char text[160];UINTN n=0;
#ifdef GU_FULL_UNLOCK
  if(Status!=EFI_SUCCESS)ScreenStatus(Event,Status);
#endif
  if(!Log)return EFI_DEVICE_ERROR;
  while(*Event && n<100)text[n++]=*Event++;
  const char *label=" status=0x";while(*label)text[n++]=*label++;
  for(int i=15;i>=0;i--)text[n++]="0123456789abcdef"[((UINT64)Status>>(i*4))&15];
  text[n++]='\r';text[n++]='\n';UINTN written=n;
  EFI_STATUS s=Log->Write(Log,&written,text);
  if(s!=EFI_SUCCESS || written!=n)return EFI_DEVICE_ERROR;
  return Log->Flush(Log);
}
#ifdef GU_LOADS_UNLOCK
static EFI_STATUS LoadUnlock(VOID) {
  EFI_FILE_PROTOCOL *file=NULL;
#ifdef GU_HEADLESS_RESEARCH
  EFI_STATUS s=Root->Open(Root,&file,L"\\EFI\\WindowsGPUUnlock\\UNLOCK-HEADLESS.EFI",EFI_FILE_MODE_READ,0);
#elif defined(GU_AUTOMATIC_BOOT)
  EFI_STATUS s=Root->Open(Root,&file,L"\\EFI\\WindowsGPUUnlock\\UNLOCK-AUTO.EFI",EFI_FILE_MODE_READ,0);
#else
  EFI_STATUS s=Root->Open(Root,&file,L"\\EFI\\WindowsGPUUnlock\\UNLOCK.EFI",EFI_FILE_MODE_READ,0);
#endif
  if(s!=EFI_SUCCESS || !file)return EFI_NOT_FOUND;
  union {EFI_FILE_INFO info;UINT8 bytes[512];} metadata;UINTN bytes=sizeof(metadata);
  s=file->GetInfo(file,&InfoGuid,&bytes,&metadata);
  UINT8 *data=NULL;
  if(s==EFI_SUCCESS && (bytes<sizeof(EFI_FILE_INFO) || bytes>sizeof(metadata) ||
     metadata.info.Size<sizeof(EFI_FILE_INFO) || metadata.info.Size>bytes ||
     metadata.info.FileSize!=GU_UNLOCK_BYTES || (metadata.info.Attribute&EFI_FILE_DIRECTORY)))s=EFI_BAD_BUFFER_SIZE;
  if(s==EFI_SUCCESS)s=Table->BootServices->AllocatePool(EfiBootServicesData,GU_UNLOCK_BYTES,(VOID **)&data);
  if(s==EFI_SUCCESS && !data)s=EFI_OUT_OF_RESOURCES;
  if(s==EFI_SUCCESS) {
    bytes=GU_UNLOCK_BYTES;s=file->Read(file,&bytes,data);
    if(s==EFI_SUCCESS && bytes!=GU_UNLOCK_BYTES)s=EFI_END_OF_FILE;
  }
  EFI_STATUS closed=file->Close(file);if(s==EFI_SUCCESS)s=closed;
  if(s==EFI_SUCCESS && !GuHashMatches(data,GU_UNLOCK_BYTES,GU_UNLOCK_SHA256))s=EFI_CRC_ERROR;
  EFI_DEVICE_PATH_PROTOCOL *path=NULL;
#ifdef GU_HEADLESS_RESEARCH
  if(s==EFI_SUCCESS)s=FilePath(OwnDevice,L"\\EFI\\WindowsGPUUnlock\\UNLOCK-HEADLESS.EFI",&path);
#else
  if(s==EFI_SUCCESS)s=FilePath(OwnDevice,L"\\EFI\\WindowsGPUUnlock\\UNLOCK.EFI",&path);
#endif
  /* Execute the verified in-memory bytes; never re-open between hash and load. */
  if(s==EFI_SUCCESS)s=Table->BootServices->LoadImage(FALSE,Self,path,data,GU_UNLOCK_BYTES,&UnlockImage);
  if(path)Table->BootServices->FreePool(path);
  if(data)Table->BootServices->FreePool(data);
  if(s!=EFI_SUCCESS)return s;
  EFI_LOADED_IMAGE_PROTOCOL *loaded=NULL;
  s=Table->BootServices->HandleProtocol(UnlockImage,&LoadedGuid,(VOID **)&loaded);
  if(s!=EFI_SUCCESS || !loaded || loaded->DeviceHandle!=OwnDevice)return EFI_COMPROMISED_DATA;
  return EFI_SUCCESS;
}
#endif
static EFI_STATUS Prepare(VOID *Context) {
  (void)Context;EFI_HANDLE own=NULL,windows=NULL;
  EFI_STATUS s=FindPartition(&GuInternalPartition,&own);
  if(s!=EFI_SUCCESS || own!=OwnDevice)return EFI_COMPROMISED_DATA;
  s=FindPartition(&GuWindowsPartition,&windows);
  if(s!=EFI_SUCCESS || windows==own)return EFI_COMPROMISED_DATA;
  s=OpenLog();if(s!=EFI_SUCCESS)return s;
  s=Record(NULL,"internal-handoff-v1",EFI_SUCCESS);if(s!=EFI_SUCCESS)return s;
#ifdef GU_LOADS_UNLOCK
  s=LoadUnlock();if(s!=EFI_SUCCESS)return s;
#endif
  EFI_DEVICE_PATH_PROTOCOL *path=NULL;
  s=FilePath(windows,L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi",&path);
  if(s==EFI_SUCCESS)s=Table->BootServices->LoadImage(FALSE,Self,path,NULL,0,&WindowsImage);
  if(path)Table->BootServices->FreePool(path);
  if(s!=EFI_SUCCESS)return s;
  EFI_LOADED_IMAGE_PROTOCOL *loaded=NULL;
  s=Table->BootServices->HandleProtocol(WindowsImage,&LoadedGuid,(VOID **)&loaded);
  return s==EFI_SUCCESS && loaded && loaded->DeviceHandle==windows?EFI_SUCCESS:EFI_COMPROMISED_DATA;
}
#ifndef GU_DIAGNOSTIC_ONLY
#ifndef GU_FULL_UNLOCK
static EFI_STATUS Select(VOID *Context,BOOLEAN *Skip) {
  (void)Context;*Skip=FALSE;
  if(!Table->ConIn)return EFI_UNSUPPORTED;
  EFI_STATUS s=Table->ConIn->Reset(Table->ConIn,FALSE);if(s!=EFI_SUCCESS)return s;
  Say(L"Windows GPU UNLOCK: press Esc within 5 seconds for Windows only.\r\nOtherwise the unlock application opens and still requires U once.\r\n");
  for(UINTN i=0;i<50;i++) {
    EFI_INPUT_KEY key;s=Table->ConIn->ReadKeyStroke(Table->ConIn,&key);
    if(s==EFI_SUCCESS && (key.ScanCode==0x17 || key.UnicodeChar==27)){*Skip=TRUE;return EFI_SUCCESS;}
    if(s!=EFI_SUCCESS && s!=EFI_NOT_READY)return s;
    s=Table->BootServices->Stall(100000);if(s!=EFI_SUCCESS)return s;
  }
  return EFI_SUCCESS;
}
#endif
static EFI_STATUS Unlock(VOID *Context) {
  (void)Context;
#ifdef GU_RELEASE_ONLY
  Say(L"Release test: no unlock application in this build. Nothing is written to the card.\r\n");
  return Record(NULL,"release-only-no-unlock",EFI_SUCCESS);
#else
  return Table->BootServices->StartImage(UnlockImage,NULL,NULL);
#endif
}
#endif
#ifdef GU_FULL_UNLOCK
static EFI_STATUS FullChoice(VOID *Context,BOOLEAN *Skip) {
  (void)Context;*Skip=FALSE;
  if(!Table->ConIn || !Table->ConIn->ReadKeyStroke)return EFI_UNSUPPORTED;
#ifdef GU_RELEASE_ONLY
  Say(GU_W(GU_TARGET_SHORT) L" DRIVER RELEASE TEST. NO UNLOCK, nothing is written to the card.\r\nThe " GU_W(GU_TARGET_DISPLAY_NUMBER) L" display may go blank; the " GU_W(GU_CONSOLE_SHORT) L" console stays. Then Windows starts by itself.\r\nEsc within 5 seconds skips all changes and starts Windows.\r\nOn failure there is no reset or retry: hold the power button until the PC turns off, then power on.\r\n");
#elif defined(GU_HEADLESS_RESEARCH)
  Say(L"SINGLE RTX HEADLESS UNLOCK RESEARCH: one guarded attempt, then Windows.\r\nNo key required. Esc within 5 seconds skips all changes.\r\nScreen may stop updating. Errors stop without reset/retry; hold the power button until the PC turns off, then power on.\r\n");
#elif defined(GU_AUTOMATIC_BOOT)
  Say(L"Windows GPU UNLOCK AUTO: Esc within 5 seconds boots Windows only.\r\nOtherwise one guarded unlock, then Windows. No U required.\r\nKeep the " GU_W(GU_CONSOLE_SHORT) L" display/keyboard connected. Firmware mouse/cursor may pause.\r\n");
#else
  Say(L"GPU UNLOCK TEST: driver release + original IO/MEM restore.\r\nFirmware mouse/cursor may pause. " GU_W(GU_CONSOLE_SHORT) L" display/keyboard must remain connected.\r\nEsc within 5 seconds skips all changes. Otherwise press U later in the original unlock app.\r\n");
#endif
  for(UINTN i=0;i<50;i++) {
    EFI_INPUT_KEY key;EFI_STATUS s=Table->ConIn->ReadKeyStroke(Table->ConIn,&key);
    if(s==EFI_SUCCESS && (key.ScanCode==0x17 || key.UnicodeChar==27)){*Skip=TRUE;return EFI_SUCCESS;}
    if(s!=EFI_SUCCESS && s!=EFI_NOT_READY)return s;
    s=Table->BootServices->Stall(100000);if(s!=EFI_SUCCESS)return s;
  }
  return EFI_SUCCESS;
}
static EFI_STATUS FullCapture(VOID *Context) {(void)Context;return GuCaptureGraph(Table,Log);}
static EFI_STATUS FullRelease(VOID *Context) {
#ifdef GU_HEADLESS_RESEARCH
  ResearchOutputDisabled=TRUE;
#endif
  (void)Context;EFI_STATUS s=GuPrepareConsole(Table,Record,NULL);
  return s==EFI_SUCCESS?GuReleaseGop(Table,Self,Record,NULL):s;
}
static EFI_STATUS FullVerifyCold(VOID *Context) {(void)Context;return GuVerifyReleased(Table,TRUE);}
static EFI_STATUS ReportVerification(EFI_STATUS s) {
  const GU_VERIFY_DIAGNOSTIC *d=GuLastVerifyDiagnostic();
  if(d->ConfigDiff) {
    ScreenStatus("PCI config mismatch byte offset",d->Offset);
    ScreenStatus("PCI config expected DWORD",d->Expected);
    ScreenStatus("PCI config observed DWORD",d->Observed);
    if(Log) {
      (void)Record(NULL,"verify-config-byte-offset",d->Offset);
      (void)Record(NULL,"verify-config-expected-dword",d->Expected);
      (void)Record(NULL,"verify-config-observed-dword",d->Observed);
    }
  }
  EFI_STATUS written=Record(NULL,d->Stage,s);
  return s==EFI_SUCCESS?written:s;
}
static EFI_STATUS FullWindows(VOID *Context) {
#ifdef GU_RELEASE_ONLY
  (void)Context;Say(L"Release test finished. Checking Windows handoff, no reset.\r\n");
#else
  (void)Context;Say(L"Unlock returned success. Checking Windows handoff, no reset.\r\n");
#endif
  EFI_STATUS s=Record(NULL,"windows-preclose-verify-begin",EFI_SUCCESS);if(s!=EFI_SUCCESS)return s;
  s=GuVerifyReleased(Table,FALSE);
  s=ReportVerification(s);if(s!=EFI_SUCCESS)return s;
  s=Record(NULL,"windows-close-files-next-then-final-verify-and-StartImage",EFI_SUCCESS);if(s!=EFI_SUCCESS)return s;
  s=Log->Close(Log);Log=NULL;
  ScreenStatus("windows-close-log",s);if(s!=EFI_SUCCESS)return s;
  s=Root->Close(Root);Root=NULL;
  ScreenStatus("windows-close-root",s);if(s!=EFI_SUCCESS)return s;
  Say(L"Final fresh verification, then Windows StartImage. Failures below identify the stopping stage.\r\n");
  s=GuVerifyReleased(Table,FALSE);
  if(s!=EFI_SUCCESS){ScreenStatus("windows-final-verify",s);return ReportVerification(s);}
  /* No file/console IO between the final graph check and StartImage. */
  s=Table->BootServices->StartImage(WindowsImage,NULL,NULL);
  ScreenStatus("windows-StartImage-returned",s);return s;
}
#endif
#ifndef GU_CONSOLE_PREPARE
static EFI_STATUS Windows(VOID *Context) {
  (void)Context;
  Say(L"Starting Windows Boot Manager directly. No reset.\r\n");
  EFI_STATUS s=Log->Close(Log);Log=NULL;if(s!=EFI_SUCCESS)return s;
  s=Root->Close(Root);Root=NULL;if(s!=EFI_SUCCESS)return s;
  return Table->BootServices->StartImage(WindowsImage,NULL,NULL);
}
#endif
#ifdef GU_CONSOLE_PREPARE
static EFI_STATUS ReadyConsoleWindows(VOID *Context) {
  (void)Context;
  Say(L"Console test recorded. Verifying final state, then starting Windows directly.\r\n");
  EFI_STATUS s=Log->Close(Log);Log=NULL;if(s!=EFI_SUCCESS)return s;
  s=Root->Close(Root);Root=NULL;return s;
}
static EFI_STATUS VerifyConsole(VOID *Context) {
  (void)Context;return GuVerifyPreparedConsole(Table);
}
static EFI_STATUS StartConsoleWindows(VOID *Context) {
  (void)Context;return Table->BootServices->StartImage(WindowsImage,NULL,NULL);
}
static EFI_STATUS PrepareChoice(VOID *Context,BOOLEAN *Skip) {
  (void)Context;*Skip=FALSE;
  if(!Table->ConIn || !Table->ConIn->ReadKeyStroke)return EFI_UNSUPPORTED;
#ifdef GU_SINGLE_RTX_CONSOLE
  Say(L"R2 AUTO CONSOLE TEST: NO UNLOCK, NVIDIA GOP RETAINED.\r\nNo key required: console detach, state verification, then Windows.\r\nEsc within 5 seconds skips all changes and starts Windows.\r\nOn failure there is no reset or retry: hold the power button until the PC turns off, then power on.\r\n");
  return GuResearchChooseInput(Table,Skip);
#else
  Say(L"RTX console detach TEST. No unlock. Keep the " GU_W(GU_CONSOLE_SHORT) L" display connected.\r\nPress Esc within 5 seconds to skip the test and start Windows.\r\n");
  for(UINTN i=0;i<50;i++) {
    EFI_INPUT_KEY key;EFI_STATUS s=Table->ConIn->ReadKeyStroke(Table->ConIn,&key);
    if(s==EFI_SUCCESS && (key.ScanCode==0x17 || key.UnicodeChar==27)){*Skip=TRUE;return EFI_SUCCESS;}
    if(s!=EFI_SUCCESS && s!=EFI_NOT_READY)return s;
    s=Table->BootServices->Stall(100000);if(s!=EFI_SUCCESS)return s;
  }
  return EFI_SUCCESS;
#endif
}
static EFI_STATUS CaptureConsole(VOID *Context) {
  (void)Context;return GuCaptureGraph(Table,Log);
}
static EFI_STATUS DetachConsole(VOID *Context) {
#ifdef GU_SINGLE_RTX_CONSOLE
  (void)Context;ResearchOutputDisabled=TRUE;
  EFI_STATUS s=GuPrepareConsole(Table,Record,NULL);
  return s==EFI_SUCCESS?GuResearchConfirmInput(Table,Record,NULL):s;
#else
  (void)Context;return GuPrepareConsole(Table,Record,NULL);
#endif
}
#endif
EFI_STATUS EFIAPI efi_main(EFI_HANDLE Image,EFI_SYSTEM_TABLE *St) {
  Table=St;Self=Image;
  if(!St || !St->BootServices)Stop();
  if(St->BootServices->SetWatchdogTimer(0,0,0,NULL)!=EFI_SUCCESS)Stop();
  EFI_LOADED_IMAGE_PROTOCOL *loaded=NULL;
  EFI_STATUS s=St->BootServices->HandleProtocol(Image,&LoadedGuid,(VOID **)&loaded);
  if(s!=EFI_SUCCESS || !loaded)Stop();
  OwnDevice=loaded->DeviceHandle;
#ifdef GU_FULL_UNLOCK
  GU_FULL_FLOW_OPS ops={NULL,Prepare,FullChoice,FullCapture,FullRelease,FullVerifyCold,Unlock,Windows,FullWindows,Record};
  s=GuFullFlow(&ops);
#elif defined(GU_CONSOLE_PREPARE)
  GU_CONSOLE_FLOW_OPS ops={NULL,Prepare,PrepareChoice,CaptureConsole,DetachConsole,ReadyConsoleWindows,VerifyConsole,StartConsoleWindows,Record};
  s=GuConsoleFlow(&ops);
#elif defined(GU_DIAGNOSTIC_ONLY)
  Say(L"GPU console diagnostic only. No unlock or driver detach. Collecting graph...\r\n");
  s=Prepare(NULL);
  if(s==EFI_SUCCESS) {
    s=GuCaptureGraph(Table,Log);
    /* Partial observations never authorize unlock. Normal Windows boot is
     * permitted because this separate image has not touched GPU state. */
    EFI_STATUS recorded=Record(NULL,"diagnostic-result",s);
    if(recorded==EFI_SUCCESS)s=Windows(NULL);
    else s=recorded;
  }
#else
  GU_HANDOFF_OPS ops={NULL,Prepare,Select,Record,Unlock,Windows};
  s=GuHandoffFlow(&ops);
#endif
  (void)Record(NULL,"handoff-stopped",s);
#ifdef GU_FULL_UNLOCK
  ScreenStatus("full-flow-returned",s);
#endif
  Stop();
  return EFI_ABORTED; /* unreachable: do not fall through firmware BootOrder */
}
