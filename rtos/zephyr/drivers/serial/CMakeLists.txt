# Copyright (c) 2026 kv32 Project
# SPDX-License-Identifier: Apache-2.0

if(CONFIG_UART_KV32)
  zephyr_library()
  zephyr_library_sources(uart_kv32.c)
endif()
