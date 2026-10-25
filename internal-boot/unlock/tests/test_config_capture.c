/* Host test: the target card's captured 256-byte PCI config must pass the structural
 * check (GuCheckConfig) under this machine's profile. Usage: test_config_capture CFG256.BIN
 * Reads a file only; no GPU or firmware access. */
#include "../checks.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
  UINT32 Config[64];
  GU_CAPS Caps;
  UINT32 Bad[64];
  FILE *f;
  if (argc != 2) { puts("usage: test_config_capture CFG256.BIN"); return 2; }
  f = fopen(argv[1], "rb");
  if (f == NULL || fread(Config, 1, sizeof(Config), f) != sizeof(Config)) { puts("FAIL cannot read 256-byte config"); return 1; }
  fclose(f);
  if (!GuCheckConfig(Config, 0, 1, 0, 0, &Caps)) { puts("FAIL captured config rejected by GuCheckConfig"); return 1; }
  printf("ok   captured config accepted: pm=0x%x msi=0x%x pcie=0x%x pcie_version=%u msix=0x%x\n",
         Caps.pm, Caps.msi, Caps.pcie, Caps.pcie_version, Caps.msix);
  /* A different card ID, a different subsystem and a set Bus Master bit must each be rejected. */
  memcpy(Bad, Config, sizeof(Bad)); Bad[0] ^= 0x10000U;
  if (GuCheckConfig(Bad, 0, 1, 0, 0, &Caps)) { puts("FAIL wrong device ID accepted"); return 1; }
  memcpy(Bad, Config, sizeof(Bad)); Bad[0x2c / 4] ^= 1U;
  if (GuCheckConfig(Bad, 0, 1, 0, 0, &Caps)) { puts("FAIL wrong subsystem accepted"); return 1; }
  memcpy(Bad, Config, sizeof(Bad)); Bad[1] |= 4U;
  if (GuCheckConfig(Bad, 0, 1, 0, 0, &Caps)) { puts("FAIL Bus Master set accepted"); return 1; }
  memcpy(Bad, Config, sizeof(Bad));
  if (GuCheckConfig(Bad, 0, 2, 0, 0, &Caps)) { puts("FAIL wrong bus accepted"); return 1; }
  /* Every single-bit change in the capability area must either stay valid or be rejected without crashing. */
  for (UINTN w = 16; w < 64; w++) for (UINTN b = 0; b < 32; b++) { memcpy(Bad, Config, sizeof(Bad)); Bad[w] ^= 1U << b; (void)GuCheckConfig(Bad, 0, 1, 0, 0, &Caps); }
  puts("PASS config structure check and negative cases");
  return 0;
}
