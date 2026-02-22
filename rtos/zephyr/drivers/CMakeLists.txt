# Copyright (c) 2026 kcore Project
# SPDX-License-Identifier: Apache-2.0

add_subdirectory_ifdef(CONFIG_CONSOLE_KCORE console)
add_subdirectory_ifdef(CONFIG_UART_KCORE serial)
