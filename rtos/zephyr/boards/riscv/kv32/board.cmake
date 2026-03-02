# Copyright (c) 2026 KV32 Project
# SPDX-License-Identifier: Apache-2.0

# Board configuration for kv32

# Use Zephyr's common RISC-V linker script
set(LINKER_SCRIPT ${ZEPHYR_BASE}/include/zephyr/arch/riscv/common/linker.ld)

board_runner_args(openocd "--config=${BOARD_DIR}/support/openocd.cfg")

include(${ZEPHYR_BASE}/boards/common/openocd.board.cmake)
