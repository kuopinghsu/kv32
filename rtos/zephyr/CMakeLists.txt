# Copyright (c) 2026 kv32 Project
# SPDX-License-Identifier: Apache-2.0

# Zephyr module CMakeLists.txt
# Board and SOC files are sourced through board_root and soc_root

# Add drivers if any driver configs are enabled
if(CONFIG_CONSOLE_KV32 OR CONFIG_UART_KV32)
    add_subdirectory(drivers)
endif()
