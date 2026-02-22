# Copyright (c) 2026 kcore Project
# SPDX-License-Identifier: Apache-2.0

if(CONFIG_CONSOLE_KCORE)
  zephyr_library()
  zephyr_library_sources(console_kcore.c)
endif()
