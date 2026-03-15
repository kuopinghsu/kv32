/***************************************************************************
 * Copyright (c) 2024 Microsoft Corporation
 *
 * This program and the accompanying materials are made available under the
 * terms of the MIT License which is available at
 * https://opensource.org/licenses/MIT.
 *
 * SPDX-License-Identifier: MIT
 **************************************************************************/

#ifndef TM_API_H
#define TM_API_H

#include "tm_porting_layer.h"

#ifdef __cplusplus
extern "C" {
#endif

#define TM_SUCCESS  0
#define TM_ERROR    1

/* Keep duration short for practical RTL turnaround. */
#ifndef TM_TEST_DURATION
#define TM_TEST_DURATION 1
#endif

void tm_initialize(void (*test_initialization_function)(void));
int  tm_thread_create(int thread_id, int priority, void (*entry_function)(void));
int  tm_thread_resume(int thread_id);
int  tm_thread_suspend(int thread_id);
void tm_thread_relinquish(void);
void tm_thread_sleep(int seconds);
int  tm_queue_create(int queue_id);
int  tm_queue_send(int queue_id, unsigned long *message_ptr);
int  tm_queue_receive(int queue_id, unsigned long *message_ptr);
int  tm_semaphore_create(int semaphore_id);
int  tm_semaphore_get(int semaphore_id);
int  tm_semaphore_put(int semaphore_id);
int  tm_memory_pool_create(int pool_id);
int  tm_memory_pool_allocate(int pool_id, unsigned char **memory_ptr);
int  tm_memory_pool_deallocate(int pool_id, unsigned char *memory_ptr);

#ifdef __cplusplus
}
#endif

#endif
