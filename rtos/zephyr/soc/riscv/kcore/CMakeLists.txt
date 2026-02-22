# Copyright (c) 2026 kcore Project
# SPDX-License-Identifier: Apache-2.0

zephyr_library()

zephyr_library_include_directories(.)

zephyr_library_sources(reset.S)

# Include SOC linker script fragment (required by Zephyr build system)
zephyr_linker_sources(ROM_START SORT_KEY 0 linker.ld)
