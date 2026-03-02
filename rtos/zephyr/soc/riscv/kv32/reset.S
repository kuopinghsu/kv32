/*
 * Copyright (c) 2026 kv32 Project
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/toolchain.h>

/* Reset entry point */
GTEXT(__reset)
SECTION_FUNC(reset, __reset)
    /* Initialize stack pointer to top of RAM (2MB at 0x80000000) */
    /* Stack grows down, so set SP to end of RAM */
    lui sp, %hi(0x80200000)
    addi sp, sp, %lo(0x80040000)

    /* Jump to Zephyr initialization */
    tail z_prep_c
