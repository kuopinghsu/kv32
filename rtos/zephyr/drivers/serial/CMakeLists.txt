# Copyright (c) 2026 kcore Project
# SPDX-License-Identifier: Apache-2.0

if(CONFIG_UART_KCORE)
  zephyr_library()
  zephyr_library_sources(uart_kcore.c)
endif()
