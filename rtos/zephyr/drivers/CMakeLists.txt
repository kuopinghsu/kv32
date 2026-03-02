# Copyright (c) 2026 kv32 Project
# SPDX-License-Identifier: Apache-2.0

add_subdirectory_ifdef(CONFIG_CONSOLE_KV32 console)
add_subdirectory_ifdef(CONFIG_UART_KV32 serial)
