/*
 * Copyright (c) 2026 kv32 Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Extended linker definitions to support sub-priority initialization.
 * This is a workaround for Zephyr 4.x where CREATE_OBJ_LEVEL doesn't
 * handle _SUB_ priority patterns created by DEVICE_DT_DEFINE.
 */

#ifndef ZEPHYR_SOC_KV32_LINKER_DEFS_SUB_H_
#define ZEPHYR_SOC_KV32_LINKER_DEFS_SUB_H_

/* Redefine CREATE_OBJ_LEVEL to include SUB priority patterns */
#undef CREATE_OBJ_LEVEL
#define CREATE_OBJ_LEVEL(object, level)                          \
    PLACE_SYMBOL_HERE(__##object##_##level##_start);     \
    KEEP(*(SORT(.z_##object##_##level##_P_?_*)));        \
    KEEP(*(SORT(.z_##object##_##level##_P_??_*)));       \
    KEEP(*(SORT(.z_##object##_##level##_P_???_*)));      \
    KEEP(*(SORT(.z_##object##_##level##_P_*_SUB_*)));

#endif /* ZEPHYR_SOC_KV32_LINKER_DEFS_SUB_H_ */
