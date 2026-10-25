// Copyright (C) Windows GPU UNLOCK contributors. GPL-2.0-only.
// Machine profile converted to the RTX 3060 / MSI MEG Z790 GODLIKE PC by Sargentmajord
// (with assistance from Claude, an AI coding assistant), 2026-10-25. The profiles
// of the original author's machines were removed from this copy; the project
// history and credits are kept in CHANGES.md and THIRD_PARTY_NOTICES.md.
/*
 * Single-machine profile. Every write-enabled build compiles for exactly this
 * machine: all hardware identities, display topology and driver fingerprints
 * below are immutable, build-time constants and are never read from a
 * user-editable file.
 *
 * Machine: MSI MEG Z790 GODLIKE (MS-7D85), BIOS 1.I0, Intel Core i9-14900KF
 *          (no iGPU).
 * Target:  NVIDIA GeForce RTX 3060 12 GB (GA106, 10de:2544, subsystem 1462:397d)
 *          at 0000:01:00.0 behind root port 00:01.0.
 * Console: NVIDIA GeForce RTX 5070 (10de:2f04, subsystem 1043:89f2) at
 *          0000:02:00.0 behind root port 00:01.1 keeps the console while the
 *          target is released.
 * Every value was read from diagnostic captures of this machine
 * (captures/profile-constants-z790-3060.md).
 */
#pragma once

#define GU_PROFILE_Z790_3060 1

/* Production (freestanding firmware) builds that can write to the card:
 *  - headless research stays blocked for this profile (it needs a card with no display);
 *  - the manual flow is allowed: the unlock program changes nothing until U is pressed
 *    once after the driver release, and Esc or its 30-second timeout cancels. It was
 *    verified on this machine's hardware on 2026-10-25 (see CHANGES.md);
 *  - the automatic flow is allowed after that manual success: Esc cancels in the first
 *    5 seconds and again for 3 seconds after the driver release, then one guarded unlock;
 *  - the release-only test (GU_FULL_UNLOCK + GU_RELEASE_ONLY) loads no unlock program.
 * Host tests (hosted builds) and the read-only diagnostic are unaffected. */
#if !__STDC_HOSTED__ && defined(GU_HEADLESS_RESEARCH)
#error Headless firmware builds are blocked for this profile
#endif
#if !__STDC_HOSTED__ && defined(GU_RELEASE_ONLY) && defined(GU_EXPERIMENTAL_UNLOCK)
#error The release-only test must not be combined with an unlock build
#endif

/* 1 = the AMI combo splitter owns the console on top of the target GPU; 0 = the
 * firmware's own console drivers own each GPU's GOP directly (this machine). */
#define GU_CONSOLE_AGGREGATE 0

#define GU_PROFILE_NAME "MSI-MEG-Z790-GODLIKE-1.I0-RTX3060"

/* ---- Target card (RTX 3060 12 GB) ---- */
#define GU_BOARD_ID 0x254410deU
#define GU_BOARD_SUBSYSTEM 0x397d1462U
#define GU_BAR0_BASE 0x85000000ULL
#define GU_BAR0_END 0x85ffffffULL
#define GU_CHIP_ID 0xb76000a1U
#define GU_DEVICE_MEMORY_SIZE 0x3000U
#define GU_PROM_SHA256 "5630f3a825e52a225fcead26663288fa6c2017ad46dde6335388a01e7f03a38d"
#define GU_ROOT_PORT_DEVICE 1U
#define GU_ROOT_PORT_FUNCTION 0U
/* 36-byte display path of the 3060: PciRoot(0)/Pci(1,0)/Pci(0,0)/ADR 0x80010370/END */
#define GU_RTX_PATH_BYTES \
  2,1,12,0,0xd0,0x41,3,10,0,0,0,0,1,1,6,0,0,1,1,1,6,0,0,0,2,3,8,0,112,3,1,128,127,255,4,0

/* ---- Console adapter (RTX 5070) ---- */
#define GU_OTHER_GPU_BUS 2
#define GU_OTHER_GPU_ID 0x2f0410deU
#define GU_OTHER_GPU_SUBSYSTEM 0x89f21043U
#define GU_OTHER_GPU_ROOT_DEVICE 1U
#define GU_OTHER_GPU_ROOT_FUNCTION 1U
#define GU_OTHER_GPU_ADR 0x80010390U
#define GU_OTHER_GPU_PATH_BYTES \
  2,1,12,0,0xd0,0x41,3,10,0,0,0,0,1,1,6,0,1,1,1,1,6,0,0,0,2,3,8,0,0x90,3,1,128,127,255,4,0

/* ---- MSI (AMI) firmware console drivers; the same two own BOTH GPUs' outputs.
 * Firmware file IDs match prepare-console.c (OutFile 628a497d-..., GfxFile 43e7abdd-...). */
#define GU_CONSOLE_TEXT_SIZE 0x6420U
#define GU_CONSOLE_TEXT_STOP 0x1584U
#define GU_CONSOLE_TEXT_VERSION 0x10U
#define GU_CONSOLE_GFX_SIZE 0x3ba0U
#define GU_CONSOLE_GFX_STOP 0xcb0U
#define GU_CONSOLE_GFX_VERSION 0x10U

/* ---- NVIDIA GOP driver for the 3060 ("nvgop-ga1xx", capture IMG34.BIN) ---- */
#define GU_NVGOP_VERSION 0x6001fU
#define GU_NVGOP_IMAGE_SIZE 0x269e0U
#define GU_NVGOP_STOP 0x678U
#define GU_NVGOP_TEXT_BYTES 0x20c0fU
#define GU_NVGOP_TEXT_SHA256 "48f7530cc4633720370cb0b4e9105ea2c66f75a76dece106b57b5a233a47c15e"

/* This firmware has NO EDID/mouse driver bound to the display handles: the EDID
 * Discovered protocol is only read passively by nvgop. The EDID/combo values below
 * exist only so shared code that mentions them still compiles; they are never
 * matched on this machine. */
#define GU_NO_EDID_DRIVER 1
#define GU_EDID_IMAGE_SIZE 0U
#define GU_EDID_STOP 0U
#define GU_EDID_TEXT_BYTES 0U
#define GU_EDID_TEXT_SHA256 ""
#define GU_COMBO_SIZE 0U
#define GU_COMBO_STOP 0U
#define GU_COMBO_VERSION 0U
