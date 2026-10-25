/* GPL-2.0-only. Exercise real full handoff state machine with error injection. */
#include "full-flow.h"
#include <stdio.h>
#include <stdlib.h>
typedef struct {
  EFI_STATUS prepare,choose,before,release,after,verify,unlock,windows;
  BOOLEAN skip;
  int recordFail,records,captures,releases,verifies,unlocks,skipBoots,boots;
} TEST;
static int Checks;
static VOID Check(int ok,const char *name) {Checks++;if(!ok){fprintf(stderr,"FAIL %s\n",name);exit(1);}}
static EFI_STATUS Prepare(VOID *v){return ((TEST *)v)->prepare;}
static EFI_STATUS Choose(VOID *v,BOOLEAN *skip){TEST *t=v;*skip=t->skip;return t->choose;}
static EFI_STATUS Capture(VOID *v){TEST *t=v;return ++t->captures==1?t->before:t->after;}
static EFI_STATUS Release(VOID *v){TEST *t=v;t->releases++;return t->release;}
static EFI_STATUS Verify(VOID *v){TEST *t=v;t->verifies++;return t->verify;}
static EFI_STATUS Unlock(VOID *v){TEST *t=v;t->unlocks++;return t->unlock;}
static EFI_STATUS SkipWindows(VOID *v){TEST *t=v;t->skipBoots++;return t->windows;}
static EFI_STATUS Windows(VOID *v){TEST *t=v;t->boots++;return t->windows;}
static EFI_STATUS Record(VOID *v,const char *event,EFI_STATUS s){(void)event;(void)s;TEST *t=v;return ++t->records==t->recordFail?EFI_DEVICE_ERROR:EFI_SUCCESS;}
static EFI_STATUS Run(TEST *t){GU_FULL_FLOW_OPS o={t,Prepare,Choose,Capture,Release,Verify,Unlock,SkipWindows,Windows,Record};return GuFullFlow(&o);}
int main(void) {
  TEST t={0};Check(Run(&t)==EFI_ABORTED && t.releases==1 && t.verifies==1 && t.unlocks==1 && t.boots==1,"normal path invokes unlock and Windows exactly once");
  t=(TEST){.skip=TRUE};Check(Run(&t)==EFI_ABORTED && !t.releases && !t.unlocks && t.skipBoots==1 && !t.boots && !t.captures,"Esc uses only original Windows without mutation");
  EFI_STATUS bad[]={EFI_DEVICE_ERROR,EFI_ACCESS_DENIED,EFI_ABORTED,EFI_WARN_UNKNOWN_GLYPH};
  for(UINTN i=0;i<4;i++) {
    t=(TEST){.prepare=bad[i]};Check(Run(&t)==bad[i] && !t.releases && !t.unlocks && !t.boots,"load failure blocks all mutations");
    t=(TEST){.choose=bad[i]};Check(Run(&t)==bad[i] && !t.releases && !t.unlocks && !t.boots,"choice failure blocks all mutations");
    t=(TEST){.before=bad[i]};Check(Run(&t)==bad[i] && !t.releases && !t.unlocks && !t.boots,"capture failure blocks all mutations");
    t=(TEST){.release=bad[i]};Check(Run(&t)==bad[i] && t.releases==1 && t.captures==2 && !t.unlocks && !t.boots,"partial prepare failure has evidence but no unlock/Windows/retry");
    t=(TEST){.after=bad[i]};Check(Run(&t)==bad[i] && t.releases==1 && !t.unlocks && !t.boots,"post capture failure blocks unlock/Windows");
    t=(TEST){.verify=bad[i]};Check(Run(&t)==bad[i] && t.verifies==1 && !t.unlocks && !t.boots,"late target/console adapter drift blocks unlock/Windows");
    t=(TEST){.unlock=bad[i]};Check(Run(&t)==bad[i] && t.unlocks==1 && !t.boots,"original app failure/timeout/cancel/warning never boots Windows");
    t=(TEST){.windows=bad[i]};Check(Run(&t)==bad[i] && t.unlocks==1 && t.boots==1,"returned Windows status is preserved");
  }
  for(int i=1;i<=4;i++) {
    t=(TEST){.recordFail=i};Check(Run(&t)==EFI_DEVICE_ERROR && !t.boots && t.unlocks==(i>=3),"each durable log failure blocks following mutation/Windows");
  }
  Check(GuFullFlow(NULL)==EFI_INVALID_PARAMETER,"invalid ops rejected");
  printf("PASS full-handoff flow checks: %d; no EFI services executed\n",Checks);return 0;
}
