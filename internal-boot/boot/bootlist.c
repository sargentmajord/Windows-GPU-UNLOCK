// Copyright (C) Windows GPU UNLOCK contributors. GPL-2.0-only.
/*
 * Read-only boot list logger. Copies the firmware's boot variables (BootCurrent, BootNext,
 * BootOrder and each Boot#### entry's flag and description) to \RTX3060-UNLOCK\BOOTLIST.TXT
 * on the partition it was started from, then restarts so the normal boot order runs.
 * It never writes a firmware variable and never touches a GPU.
 */
#include <Uefi.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Guid/GlobalVariable.h>

static EFI_GUID ImageGuid=EFI_LOADED_IMAGE_PROTOCOL_GUID;
static EFI_GUID FsGuid=EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
static EFI_GUID GlobalGuid=EFI_GLOBAL_VARIABLE;
static char Text[16384];
static UINTN Used;
static UINT8 Data[1024];

static VOID Put(const char *s){while(*s&&Used<sizeof(Text)-1)Text[Used++]=*s++;}
static VOID Hex(UINT64 v,UINTN digits){
  static const char d[]="0123456789ABCDEF";
  for(UINTN i=digits;i>0&&Used<sizeof(Text)-1;i--)Text[Used++]=d[(v>>((i-1)*4))&15];
}
EFI_STATUS EFIAPI efi_main(EFI_HANDLE Image,EFI_SYSTEM_TABLE *Table){
  EFI_RUNTIME_SERVICES *rt=Table->RuntimeServices;
  EFI_TIME t;
  Put("BOOTLIST read-only boot variable copy\r\n");
  if(rt->GetTime(&t,NULL)==EFI_SUCCESS){
    Put("time ");Hex(t.Year,4);Put("-");Hex(t.Month,2);Put("-");Hex(t.Day,2);Put(" ");
    Hex(t.Hour,2);Put(":");Hex(t.Minute,2);Put(":");Hex(t.Second,2);Put("\r\n");
  }
  static const CHAR16 *single[]={L"BootCurrent",L"BootNext"};
  for(UINTN i=0;i<2;i++){
    UINTN size=sizeof(Data);UINT32 attr;
    EFI_STATUS s=rt->GetVariable((CHAR16*)single[i],&GlobalGuid,&attr,&size,Data);
    Put(i?"BootNext ":"BootCurrent ");
    if(s==EFI_SUCCESS&&size>=2){Hex(*(UINT16*)Data,4);}else{Put("absent status ");Hex((UINT64)s,16);}
    Put("\r\n");
  }
  {
    UINTN size=sizeof(Data);UINT32 attr;
    EFI_STATUS s=rt->GetVariable(L"BootOrder",&GlobalGuid,&attr,&size,Data);
    Put("BootOrder");
    if(s==EFI_SUCCESS){for(UINTN i=0;i+1<size;i+=2){Put(" ");Hex(*(UINT16*)(Data+i),4);}}
    else{Put(" absent status ");Hex((UINT64)s,16);}
    Put("\r\n");
  }
  for(UINT16 n=0;n<0x40;n++){
    CHAR16 w[]={'B','o','o','t',0,0,0,0,0};
    for(UINTN i=0;i<4;i++){UINT16 x=(n>>((3-i)*4))&15;w[4+i]=(CHAR16)(x<10?'0'+x:'A'+x-10);}
    UINTN size=sizeof(Data);UINT32 attr;
    EFI_STATUS s=rt->GetVariable(w,&GlobalGuid,&attr,&size,Data);
    if(s==EFI_NOT_FOUND)continue;
    Put("Boot");Hex(n,4);Put(" ");
    if(s!=EFI_SUCCESS||size<6){Put("unreadable status ");Hex((UINT64)s,16);Put("\r\n");continue;}
    Put("flags ");Hex(*(UINT32*)Data,8);Put(" ");
    for(CHAR16 *d=(CHAR16*)(Data+6);(UINT8*)d+1<Data+size&&*d;d++)
      if(Used<sizeof(Text)-1)Text[Used++]=(*d<0x80)?(char)*d:'?';
    Put("\r\n");
  }
  EFI_LOADED_IMAGE_PROTOCOL *li=NULL;EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs=NULL;
  EFI_FILE_PROTOCOL *root=NULL,*dir=NULL,*file=NULL;
  if(Table->BootServices->HandleProtocol(Image,&ImageGuid,(VOID**)&li)==EFI_SUCCESS&&
     Table->BootServices->HandleProtocol(li->DeviceHandle,&FsGuid,(VOID**)&fs)==EFI_SUCCESS&&
     fs->OpenVolume(fs,&root)==EFI_SUCCESS&&
     root->Open(root,&dir,L"RTX3060-UNLOCK",EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE,0)==EFI_SUCCESS){
    if(dir->Open(dir,&file,L"BOOTLIST.TXT",EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE,0)==EFI_SUCCESS)file->Delete(file);
    file=NULL;
    if(dir->Open(dir,&file,L"BOOTLIST.TXT",EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE|EFI_FILE_MODE_CREATE,0)==EFI_SUCCESS){
      UINTN n=Used;file->Write(file,&n,Text);file->Flush(file);file->Close(file);
    }
    dir->Close(dir);root->Close(root);
  }
  rt->ResetSystem(EfiResetCold,EFI_SUCCESS,0,NULL);
  return EFI_SUCCESS;
}
