/* Host check: parse a real captured 1 MiB video BIOS window (PROM.BIN from the diagnostic) with the project's
 * FWSEC parser and apply the DMEM alignment rule from upstream pull request #115. Reads the file only; no GPU or
 * firmware access. The file is the card's video BIOS image and must never be published.
 * Usage: test_real_prom PROM.BIN */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64;
#include "../vendor/vbios_610.h"

static bool dma_valid(u32 dest, u32 mem_off, u64 src, u32 size) {
  return size && !((size | dest | mem_off | (u32)src) & 255) && (u64)dest + size <= (1ull << 24);
}
int main(int argc, char **argv) {
  static u8 rom[1024 * 1024];
  struct gpu_unlock_fwsec fw;
  FILE *f;
  if (argc != 2) { puts("usage: test_real_prom PROM.BIN"); return 2; }
  f = fopen(argv[1], "rb");
  if (!f || fread(rom, 1, sizeof(rom), f) != sizeof(rom)) { puts("FAIL cannot read 1 MiB PROM.BIN"); return 1; }
  fclose(f);
  int ret = gpu_unlock_vbios_fwsec(rom, sizeof(rom), &fw);
  if (ret) { printf("FAIL FWSEC not found/parsed in this video BIOS (error %d)\n", ret); return 1; }
  printf("FWSEC: image_off=%#x image_size=%#x imem=%#x va=%#x pa=%#x dmem=%#x pa=%#x data_off=%#x pkc=%#x engine=%#x ucode=%u sigs=%u versions=%#x\n",
         fw.image_off, fw.image_size, fw.imem_size, fw.imem_va, fw.imem_pa, fw.dmem_size, fw.dmem_pa, fw.data_off, fw.pkc_off,
         fw.engine_mask, fw.ucode_id, fw.sig_count, fw.sig_versions);
  u32 dmem_dma = (fw.dmem_size + 255u) & ~255u;
  size_t alloc = fw.image_size;
  if ((size_t)fw.data_off + dmem_dma > alloc) alloc = (size_t)fw.data_off + dmem_dma;
  alloc = (alloc + 255u) & ~(size_t)255u;
  printf("dmem size %#x is %s a multiple of 256; transfer size becomes %#x; buffer %#zx (image %#x)\n",
         fw.dmem_size, (fw.dmem_size & 255) ? "NOT" : "already", dmem_dma, alloc, fw.image_size);
  bool old_ok = dma_valid(fw.dmem_pa, 0, 0x100000ull + fw.data_off, fw.dmem_size);
  bool new_ok = dma_valid(fw.dmem_pa, 0, 0x100000ull + fw.data_off, dmem_dma);
  bool imem_ok = dma_valid(fw.imem_pa, fw.imem_va, 0x100000ull + 0 - fw.imem_va, fw.imem_size);
  printf("falcon DMA geometry: unrounded DMEM %s, rounded DMEM %s, IMEM %s\n", old_ok ? "valid" : "REJECTED", new_ok ? "valid" : "REJECTED", imem_ok ? "valid" : "REJECTED");
  if (fw.engine_mask != 0x400) { puts("FAIL unexpected engine mask"); return 1; }
  if (!new_ok || !imem_ok) { puts("FAIL geometry still unloadable after rounding"); return 1; }
  if ((fw.dmem_size & 255) && old_ok) { puts("FAIL inconsistent: unaligned size reported valid"); return 1; }
  puts("PASS real video BIOS parses; rounded DMEM geometry is loadable");
  return 0;
}
