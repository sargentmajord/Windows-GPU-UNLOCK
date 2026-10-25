/* Host test: display-path classification for this machine. The console adapter is the
 * RTX 5070 (root port 00:01.1, ADR 0x80010390) and the target is the RTX 3060
 * (root port 00:01.0, ADR 0x80010370). Paths are copied from read-only diagnostic
 * captures. No GPU or firmware access. */
#include "../checks.h"
#include <stdio.h>
#include <string.h>

static int Failures;
static void Expect(const char *name, const UINT8 *path, UINTN len, int want) {
  int got = GuDisplayPath((const EFI_DEVICE_PATH_PROTOCOL *)path, len);
  if (got != want) { printf("FAIL %-48s got=%d want=%d\n", name, got, want); Failures++; }
  else printf("ok   %-48s -> %d\n", name, got);
}

int main(void) {
  /* ACPI PciRoot(0) | Pci(dev1,fn1) | Pci(0,0) | ADR 0x80010390 | END   (RTX 5070) */
  static const UINT8 Gpu5070[36] = {2,1,12,0,0xd0,0x41,3,10,0,0,0,0, 1,1,6,0,1,1, 1,1,6,0,0,0, 2,3,8,0,0x90,3,1,128, 127,255,4,0};
  /* Same with the 3060's endpoint: Pci(dev1,fn0) | Pci(0,0) | ADR 0x80010370 */
  static const UINT8 Gpu3060[36] = {2,1,12,0,0xd0,0x41,3,10,0,0,0,0, 1,1,6,0,0,1, 1,1,6,0,0,0, 2,3,8,0,0x70,3,1,128, 127,255,4,0};
  /* A path behind some other root port must be rejected. */
  static const UINT8 Foreign[36] = {2,1,12,0,0xd0,0x41,3,10,0,0,0,0, 1,1,6,0,1,8, 1,1,6,0,0,0, 2,3,8,0,0,3,1,128, 127,255,4,0};
  UINT8 P[36];
  Expect("5070 console adapter path", Gpu5070, 36, 1);
  Expect("3060 target path", Gpu3060, 36, 2);
  Expect("path behind another root port rejected", Foreign, 36, 0);
  memcpy(P, Gpu5070, 36); P[28] = 0x91; Expect("5070 with wrong ADR rejected", P, 36, 0);
  memcpy(P, Gpu5070, 36); P[16] = 2;    Expect("5070 root port function 2 rejected", P, 36, 0);
  memcpy(P, Gpu5070, 36); P[17] = 2;    Expect("5070 root port device 2 rejected", P, 36, 0);
  for (UINTN n = 0; n < 36; n++) { char name[64]; snprintf(name, sizeof name, "5070 truncated to %u bytes rejected", (unsigned)n); Expect(name, Gpu5070, n, 0); }
  printf(Failures ? "FAILED: %d\n" : "PASS: all display-path cases\n", Failures);
  return Failures != 0;
}
