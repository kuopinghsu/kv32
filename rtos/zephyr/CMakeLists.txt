# Copyright (c) 2026 kcore Project
# SPDX-License-Identifier: Apache-2.0

# Zephyr module CMakeLists.txt
# Board and SOC files are sourced through board_root and soc_root

# Add drivers if any driver configs are enabled
if(CONFIG_CONSOLE_KCORE OR CONFIG_UART_KCORE)
    add_subdirectory(drivers)
endif()
