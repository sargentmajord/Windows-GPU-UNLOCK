// Copyright (C) Windows GPU UNLOCK contributors. GPL-2.0-only.
/*
 * Machine profile selector. Every write-enabled build compiles for exactly one machine, whose
 * constants live in a single "profile.h". A build passes -I <profile folder> to use a profile
 * generated for another PC (installer\build workspace); without it the reference machine's
 * profile is used, so the existing build scripts and host tests are unchanged.
 */
#pragma once
#if defined(__has_include)
# if __has_include("profile.h")
#  include "profile.h"
# else
#  include "profiles/z790-3060/profile.h"
# endif
#else
# include "profiles/z790-3060/profile.h"
#endif

/* Wide-string form of a profile string literal: GU_W(GU_TARGET_SHORT) is L"RTX 3060". */
#define GU_W2(x) L##x
#define GU_W(x) GU_W2(x)
