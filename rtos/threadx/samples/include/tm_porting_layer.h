/***************************************************************************
 * Copyright (c) 2024 Microsoft Corporation
 *
 * This program and the accompanying materials are made available under the
 * terms of the MIT License which is available at
 * https://opensource.org/licenses/MIT.
 *
 * SPDX-License-Identifier: MIT
 **************************************************************************/

#ifndef TM_PORTING_LAYER_H
#define TM_PORTING_LAYER_H

#include <stdio.h>

/* Not used in enabled tests here; keep as portable no-op for RISC-V builds. */
#define TM_CAUSE_INTERRUPT do { } while (0)

#endif
