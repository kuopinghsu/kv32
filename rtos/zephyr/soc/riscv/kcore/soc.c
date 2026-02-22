/*
 * Copyright (c) 2026 kcore Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * SOC initialization for kcore
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/init.h>
#include <soc.h>

static int kcore_soc_init(void)
{
    return 0;
}

SYS_INIT(kcore_soc_init, PRE_KERNEL_2, 0);
