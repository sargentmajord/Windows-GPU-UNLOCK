/* Full production app + stock core + compat + port; only EFI services mocked. */
#ifdef GU_ENTRY_LATCHED
#ifndef GU_STOCK_PROFILE_SS0
#define GU_STOCK_PROFILE_SS0 0x03100062U
#endif
#endif
#include "test_experimental.c"
#undef main
#ifndef GU_ENTRY_LATCHED
#error Explicit entry-latched profile required
#endif

static UINT32 changed_offset;
static const char *change_stage;
static BOOLEAN injected;
static UINTN writes_at_injection;
static EFI_STATUS EFIAPI mutate_report(EFI_FILE_PROTOCOL *f,UINTN *n,VOID *data) {
  EFI_STATUS result=file_write(f,n,data);
  if(!injected && change_stage && strstr(report_text,change_stage)) {
    registers[changed_offset/4]^=1;injected=TRUE;writes_at_injection=fake.mmio_writes;
  }
  return result;
}
static EFI_STATUS EFIAPI mutate_key(EFI_SIMPLE_TEXT_INPUT_PROTOCOL *p,EFI_INPUT_KEY *key) {
  EFI_STATUS result=read_key(p,key);
  if(!EFI_ERROR(result)){registers[changed_offset/4]^=1;injected=TRUE;}
  return result;
}
static EFI_STATUS EFIAPI mutate_disconnect(EFI_HANDLE h,EFI_HANDLE a,EFI_HANDLE c) {
  EFI_STATUS result=disconnect(h,a,c);registers[changed_offset/4]^=1;injected=TRUE;return result;
}
static UINT32 fail_offset;
static EFI_STATUS EFIAPI fail_read(EFI_PCI_IO_PROTOCOL *p,EFI_PCI_IO_PROTOCOL_WIDTH w,
    UINT8 bar,UINT64 offset,UINTN count,VOID *value) {
  if(offset==fail_offset)return EFI_DEVICE_ERROR;
  return read_memory(p,w,bar,offset,count,value);
}
static void entry_setup(enum app_case mode,UINT32 ss0,UINT32 ss1) {
  /* setup() installs a valid core-only fixture latch. efi_main/GuInit discards
     it before application validation; invalid app inputs must not fail setup. */
  test_entry_ss0=0x03100062;test_entry_ss1=6;exact_setup(mode);
  registers[SS0/4]=ss0;registers[SS1/4]=ss1;
  change_stage=NULL;injected=FALSE;writes_at_injection=0;
}
static void direct_setup(void) {
  entry_setup(APP_SUCCESS,0x03000062,7);
  /* No fixture-installed latch: emulate the start of an EFI invocation. */
  GuInit(&bs,&pci);Gu.bar_base=GU_BAR0_BASE;Gu.bar_size=sizeof(registers);
  Gu.display_ok=TRUE;Table=&st;CHECK(!EFI_ERROR(GuIoOpen(H(1),&st)));
}
static EFI_STATUS run_app(void) {
  EFI_STATUS result=EFI_ABORTED;
  if(!setjmp(escape_halt))result=efi_main(H(1),&st);
  return result;
}
static void assert_no_ss1_write(void) {
#ifdef GU_ENTRY_LATCHED_SS1_PRESERVE
  for(UINTN i=0;i<fake.trace_count;i++)CHECK(fake.write_trace[i][0] || fake.write_trace[i][2]!=SS1);
#endif
}
#ifdef GU_AUTOMATIC_BOOT
#define main manual_entry_fixture_main
#endif
int main(int argc,char **argv) {
  CHECK(argc==3 || argc==4);exact_load(argv[1],argv[2]);
  UINT32 a,b;
  /* Failed first checks cannot establish a latch, even with readable selectors. */
  const UINT32 cold_offsets[]={0,0x1183a4,0x118128,0x118234,0x110100,0x1fa828,PLM};
  for(unsigned i=0;i<sizeof(cold_offsets)/sizeof(cold_offsets[0]);i++) {
    direct_setup();Gu.prom_verified=TRUE;registers[cold_offsets[i]/4]^=1;
    CHECK(EFI_ERROR(ColdCheck()) && !Gu.profile_verified && !GuGetEntrySelectors(&a,&b));
    CHECK(!EFI_ERROR(GuIoClose()));dispose_host_fixture();
  }
  direct_setup();CHECK(EFI_ERROR(ColdCheck()) && !GuGetEntrySelectors(&a,&b));
  CHECK(!EFI_ERROR(PromCheck()) && !EFI_ERROR(ColdCheck()));
  CHECK(GuGetEntrySelectors(&a,&b) && a==0x03000062 && b==7);
  registers[SS0/4]^=1;CHECK(!EFI_ERROR(PromCheck()));
  CHECK(EFI_ERROR(ColdCheck()) && !Gu.profile_verified);
  CHECK(GuGetEntrySelectors(&a,&b) && a==0x03000062 && b==7);
  registers[SS0/4]^=1;registers[SS1/4]=6;
  CHECK(!EFI_ERROR(PromCheck()) && EFI_ERROR(ColdCheck()));
  CHECK(GuGetEntrySelectors(&a,&b) && b==7); /* no re-learning on PROM checks */
  registers[SS1/4]=7;CHECK(!EFI_ERROR(ColdCheck()));
  registers[0x300000/4]^=1;CHECK(EFI_ERROR(PromCheck()) && !Gu.profile_verified);
  CHECK(GuGetEntrySelectors(&a,&b) && b==7 && EFI_ERROR(ColdCheck()));
  CHECK(!EFI_ERROR(GuIoClose()));
  GuInit(&bs,&pci);CHECK(!GuGetEntrySelectors(&a,&b));dispose_host_fixture();
  const UINT32 valid1[]={0,0xf};
  for(unsigned i=0;i<sizeof(valid1)/sizeof(valid1[0]);i++) {
    direct_setup();registers[SS1/4]=valid1[i];CHECK(!EFI_ERROR(PromCheck()) && !EFI_ERROR(ColdCheck()));
    CHECK(GuGetEntrySelectors(&a,&b) && b==valid1[i]);
    fail_offset=SS1;pci.Mem.Read=fail_read;CHECK(EFI_ERROR(ColdCheck()) && !Gu.profile_verified);
    CHECK(GuGetEntrySelectors(&a,&b) && b==valid1[i]);
    CHECK(!EFI_ERROR(GuIoClose()));dispose_host_fixture();
  }
  puts("PASS first fully valid check only, immutable across PROM success/failure, reset only on GuInit");

  const UINT32 bad0[]={0xffffffffU,0xbadf0000U,0xbadf1234U,0x88888888U};
  const UINT32 bad1[]={0x10,0x16,0x80000007,0xffffffffU,0xbadf0007U};
  for(unsigned i=0;i<sizeof(bad0)/sizeof(bad0[0]);i++) {
    entry_setup(APP_SUCCESS,bad0[i],7);CHECK(EFI_ERROR(run_app()));no_effects();
    CHECK(!Gu.profile_verified && !GuGetEntrySelectors(&a,&b) && !key_calls);dispose_host_fixture();
  }
  for(unsigned i=0;i<sizeof(bad1)/sizeof(bad1[0]);i++) {
    entry_setup(APP_SUCCESS,0x03000062,bad1[i]);CHECK(EFI_ERROR(run_app()));no_effects();
    CHECK(!Gu.profile_verified && !GuGetEntrySelectors(&a,&b) && !key_calls);dispose_host_fixture();
  }
  const UINT32 read_offsets[]={SS0,SS1,0,0x1183a4,0x118128,0x118234,0x110100,0x1fa828,PLM,0x300000};
  for(unsigned i=0;i<sizeof(read_offsets)/sizeof(read_offsets[0]);i++) {
    entry_setup(APP_SUCCESS,0x03000062,7);fail_offset=read_offsets[i];pci.Mem.Read=fail_read;
    CHECK(EFI_ERROR(run_app()));no_effects();
    CHECK(Gu.fault && !Gu.profile_verified && !GuGetEntrySelectors(&a,&b) && !key_calls);dispose_host_fixture();
  }
  /* Exact board, identity, config, display, BAR, PROM and manual-input guards. */
  const enum app_case rejected[]={APP_SECUREBOOT,APP_DUPLICATE,APP_BAD_BAR,APP_BAD_GOP,
    APP_BAD_SIZE,APP_BAD_HASH,APP_WATCHDOG,APP_CONFIG,APP_BAD_PROM};
  for(unsigned i=0;i<sizeof(rejected)/sizeof(rejected[0]);i++) {
    entry_setup(rejected[i],0x03000062,7);CHECK(EFI_ERROR(run_app()));no_effects();dispose_host_fixture();
  }
  entry_setup(APP_SUCCESS,0x03000062,7);*(UINT32 *)(config+0x2c)^=1;
  CHECK(EFI_ERROR(run_app()));no_effects();CHECK(!GuGetEntrySelectors(&a,&b));dispose_host_fixture();
  entry_setup(APP_SUCCESS,0x03000062,7);registers[0x300000/4]^=1;
  CHECK(run_app()==EFI_CRC_ERROR);no_effects();CHECK(!GuGetEntrySelectors(&a,&b));dispose_host_fixture();
  puts("PASS inaccessible/sentinel/nibble, exact-board/PROM/read failures before effects");

  /* Core profile gate cannot be replaced by armed or a latch alone. */
  direct_setup();Gu.prom_verified=TRUE;CHECK(!EFI_ERROR(ColdCheck()));Gu.profile_verified=FALSE;
  Gu.armed=Gu.owned=TRUE;GuWrite32(SS0,0x88888888);CHECK(Gu.fault && !fake.mmio_writes);
  CHECK(!EFI_ERROR(GuIoClose()));dispose_host_fixture();
  if(argc!=4){puts("PARTIAL: missing actual stock assets for full integration");return 2;}
  load_fixture_assets(argv[1],argv[3]);memcpy(originals,GuAssets,sizeof(originals));

  for(unsigned perm=0;perm<4;perm++) {
    UINT32 ss0=perm&1?0x03000062:0x03100062,ss1=6+(perm>>1);
    const enum app_case modes[]={APP_SUCCESS,APP_HANDOFF,APP_HANDOFF_CONFIG,APP_ESCAPE,APP_TIMEOUT,APP_HANDOFF_ESCAPE,APP_HANDOFF_TIMEOUT,APP_DIRTY,APP_UNMAP,APP_SELECTOR};
    for(unsigned i=0;i<sizeof(modes)/sizeof(modes[0]);i++) {
      entry_setup(modes[i],ss0,ss1);EFI_STATUS result=run_app();assert_no_ss1_write();
      CHECK(GuGetEntrySelectors(&a,&b) && a==ss0 && b==ss1);
      if(i<3) {
        CHECK(result==EFI_SUCCESS && Gu.quiesced && !halted && !Gu.allocations && !fake.pool_live);
        CHECK(fake.gsp_starts==1 && fake.sec2_starts==1 && fake.flrs==1 && fake.radix_bytes==0x5053000);
         CHECK(registers[SS0/4]==0x88888888 && !(config[4]&4));
#ifdef GU_ENTRY_LATCHED_SS1_PRESERVE
         CHECK(registers[SS1/4]==ss1 && strstr(report_text,"SS1policy=preserve"));
#else
         CHECK(registers[SS1/4]==8 && strstr(report_text,"SS1policy=full"));
#endif
      } else if(i<7) {CHECK(EFI_ERROR(result));no_effects();}
      else {CHECK(EFI_ERROR(result) && halted && Gu.retained && Gu.allocations && !(config[4]&4));}
      dispose_host_fixture();
    }
  }
  puts("PASS both SS0 x SS1=6/7 full app stock transactions, cancellation, timeout, retention and post-FLR loss");

  /* Mutation windows: initial-to-second cold, U, handoff, final PROM, after final
     cold into core, core GFW logging, selector logging, and late pre-FLR logging. */
  const char *stages[]={"CHECK stage=diagnostic-cold-state status=0",NULL,NULL,
    "CHECK stage=armed-cold-state status=0","CHECK stage=final-prom status=0",
    "ARMED: one transaction", "entry: plm=", "selector intent:", "PCIe FLR begin:"};
  for(unsigned selector=0;selector<2;selector++)for(unsigned i=0;i<sizeof(stages)/sizeof(stages[0]);i++) {
    entry_setup(i==2?APP_HANDOFF:APP_SUCCESS,0x03000062,7);changed_offset=selector?SS1:SS0;
    if(i==1)conin.ReadKeyStroke=mutate_key;
    else if(i==2)bs.DisconnectController=mutate_disconnect;
    else {change_stage=stages[i];files[3].protocol.Write=mutate_report;}
    EFI_STATUS result=run_app();CHECK(injected && EFI_ERROR(result));assert_no_ss1_write();
    CHECK(GuGetEntrySelectors(&a,&b) && a==0x03000062 && b==7);
    CHECK(!fake.flrs);
    if(i<7) {
      CHECK(!Gu.started && !fake.mmio_writes && !fake.master_enables && !Gu.allocations);
      if(i==2)CHECK(halted && disconnect_calls==1);else CHECK(!halted);
    } else CHECK(halted && Gu.started && Gu.retained && Gu.allocations);
    dispose_host_fixture();
  }
  puts("PASS SS0/SS1 mutation at initial/U/handoff/final/core-entry/selector/late-FLR windows; no relatch");
  /* External report callbacks run after the core samples selectors. Verify
     rejection at the actual reset/DMA/quiescence boundaries, including SEC2
     before SS0 is changed and the separate post-FLR reset path after it is. */
  const char *boundary_stages[]={"Falcon reset begin: base=0x110000",
    "Falcon DMA: base=0x110000", "Falcon reset begin: base=0x840000",
    "Falcon DMA: base=0x840000", "post-FLR SEC2 reset released"};
  for(unsigned selector=0;selector<2;selector++)for(unsigned i=0;i<sizeof(boundary_stages)/sizeof(boundary_stages[0]);i++) {
    entry_setup(APP_SUCCESS,0x03000062,7);changed_offset=selector?SS1:SS0;
    change_stage=boundary_stages[i];files[3].protocol.Write=mutate_report;
    CHECK(EFI_ERROR(run_app()) && injected && halted);
    CHECK(Gu.started && !Gu.quiesced && Gu.retained && Gu.allocations);
    CHECK(fake.live_maps && fake.live_buffers && !fake.frees && !fake.unmaps && !(config[4]&4));
    CHECK(fake.mmio_writes==writes_at_injection);assert_no_ss1_write();
    CHECK(GuGetEntrySelectors(&a,&b) && a==0x03000062 && b==7);
    CHECK(fake.flrs==(UINTN)(i==4));
    if(i<2) {
      CHECK(!fake.gsp_starts && !fake.sec2_starts && !fake.dma_reads);
      /* DMA-log rejection permits only the preceding GSP reset and setup;
         no source/base/high/command register may have been published. */
      const UINT32 allowed[]={GSP+0x3c0,GSP+0x3c0,GSP+0x84,GSP+0x624,GSP+0x10c,GSP+0x600};
      UINTN count=0;
      for(UINTN j=0;j<fake.trace_count;j++)if(!fake.write_trace[j][0]) {
        CHECK(i==1 && count<sizeof(allowed)/sizeof(allowed[0]));
        CHECK(fake.write_trace[j][2]==allowed[count++]);
      }
      CHECK(count==(UINTN)(i==1?6:0));
    } else {
      CHECK(fake.gsp_starts==1 && fake.sec2_starts==(UINTN)(i==4));
    }
    printf("PASS report callback %s %s mutation: retained, no later MMIO writes\n",
      boundary_stages[i],selector?"SS1":"SS0");
    dispose_host_fixture();
  }
  direct_setup();Gu.prom_verified=TRUE;CHECK(!EFI_ERROR(ColdCheck()));Gu.armed=Gu.owned=TRUE;
   GuWrite32(SS1,7);CHECK(Gu.fault && !fake.mmio_writes);CHECK(!EFI_ERROR(GuIoClose()));dispose_host_fixture();
  for(unsigned i=0;i<5;i++)free((VOID *)originals[i].firmware.data);
  puts("PASS entry-latched production app/core full integration; hardware untested");return 0;
}
