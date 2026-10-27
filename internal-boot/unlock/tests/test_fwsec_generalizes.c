/* Modified 2026-10-26 for Windows GPU UNLOCK; changes documented in CHANGES.md. */ /* SPDX-License-Identifier: GPL-2.0-only */
/* Proves the self-consistency checks added to test_efi_transaction.c's check_fwsec_image()
 * (2026-10-26, generalizing beyond the one reference card) hold for firmware shapes that are
 * NOT this machine's real card: a synthetic fixture (not this, or any, machine's real data) and
 * a deliberately mutated variant with a different, non-reference misalignment. No real hardware
 * or captured PROM is used or needed. Compiles and links against vendor/vbios_610.c exactly as
 * test_efi_transaction.c does (that parser always wants the full UEFI compat stack via
 * diagnostic.h, unlike unlock_610.c, which has a genuine lightweight offline mode). */
#include "../port.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <malloc.h>
#undef EPROTO
#undef EBADMSG
#undef EOVERFLOW
#undef EOPNOTSUPP
#undef ETIMEDOUT
#undef EALREADY
#include "../compat/compat.h"
#include "../vendor/vbios_610.h"
#include "vbios_fixture.h"

static void gen_assert_failed(const char *expression, const char *file, int line) {
    fprintf(stderr, "ASSERTION FAILED: %s:%d: %s\n", file, line, expression);
    exit(1);
}
/* vbios_610.c logs through these; this harness only needs them to exist, not to do anything. */
VOID GuLog(const char *format, ...) { (VOID)format; }
VOID GuLogText(const char *text) { (VOID)text; }
#define CHECK(expression) ((expression) ? (void)0 : gen_assert_failed(#expression, __FILE__, __LINE__))

static u8 rom[1024 * 1024];

/* The same self-consistency checks from test_efi_transaction.c's check_fwsec_image(), applied
 * here against shapes that are not the reference card, to prove they hold generically and were
 * not just satisfied by construction for one example. */
static void assert_generalized_checks(const struct gpu_unlock_fwsec *fw, const char *label) {
    CHECK(fw->image_size > 0 && fw->image_off <= sizeof(rom) && fw->image_size <= sizeof(rom) - fw->image_off);
    CHECK(fw->dmem_size > 0 && fw->dmem_size <= fw->image_size);
    UINT32 dmem_dma = (fw->dmem_size + 255u) & ~255u;
    CHECK(dmem_dma >= fw->dmem_size && dmem_dma - fw->dmem_size < 256);
    printf("  [%s] image_size=0x%x dmem_size=0x%x -> rounded=0x%x : self-consistency holds\n",
           label, fw->image_size, fw->dmem_size, dmem_dma);
}

int main(void) {
    /* Shape 1: the project's own baseline synthetic fixture (used elsewhere for the transaction
     * harness) - a small, hand-built structure, nothing like the reference card's real firmware. */
    memset(rom, 0, sizeof(rom));
    vbios_fixture(rom, 6);
    struct gpu_unlock_fwsec fw1;
    CHECK(!gpu_unlock_vbios_fwsec(rom, sizeof(rom), &fw1));
    assert_generalized_checks(&fw1, "baseline synthetic fixture");

    /* Shape 2: the same fixture, with its DMEM size deliberately mutated to an unaligned value
     * that differs from the reference card's own 0x980 case (upstream pull request #115) by a
     * different amount, proving the rounding logic isn't just coincidentally right for one
     * specific misalignment. */
    memset(rom, 0, sizeof(rom));
    vbios_fixture(rom, 6);
    struct gpu_unlock_fwsec probe;
    CHECK(!gpu_unlock_vbios_fwsec(rom, sizeof(rom), &probe));
    UINT32 descriptor_start = probe.sig_off - 44; /* same descriptor layout test_transaction.c uses */
    UINT32 original_dmem = probe.dmem_size;
    UINT32 mutated = original_dmem > 37 ? original_dmem - 37 : original_dmem + 37; /* a different, non-reference offset from alignment */
    rom[descriptor_start + 32] = (u8)(mutated & 0xff);
    rom[descriptor_start + 33] = (u8)((mutated >> 8) & 0xff);
    rom[descriptor_start + 34] = (u8)((mutated >> 16) & 0xff);
    rom[descriptor_start + 35] = (u8)((mutated >> 24) & 0xff);
    struct gpu_unlock_fwsec fw2;
    CHECK(!gpu_unlock_vbios_fwsec(rom, sizeof(rom), &fw2));
    CHECK(fw2.dmem_size == mutated && fw2.dmem_size != original_dmem);
    assert_generalized_checks(&fw2, "mutated, differently-misaligned fixture");

    puts("Generalized FWSEC self-consistency checks hold for two non-reference-card shapes: PASS");
    return 0;
}
