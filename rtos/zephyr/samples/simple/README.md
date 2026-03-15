# Zephyr Simple 4-Task Test

This sample runs four basic RTOS behavior checks:

1. Context switch / yield thread
2. Semaphore give/take thread pair behavior
3. Mutex lock/unlock protection of shared counter
4. Event bit ping/ack synchronization

The loop count is controlled by `SIMPLE_TEST_ITERATIONS` in `src/main.c`.
