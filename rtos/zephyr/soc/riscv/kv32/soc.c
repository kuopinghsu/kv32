/*
 * Copyright (c) 2026 kv32 Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * SOC initialization for kv32
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/init.h>
#include <soc.h>

static int kv32_soc_init(void)
{
    return 0;
}

SYS_INIT(kv32_soc_init, PRE_KERNEL_2, 0);
