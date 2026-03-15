#include <stdio.h>

#include "tx_api.h"
#include "kv_platform.h"

extern void tm_main(void);

void tx_application_define(void *first_unused_memory)
{
    (void)first_unused_memory;
    tm_main();
}

int main(void)
{
    printf("=== ThreadX Thread-Metric tm_basic ===\n");
    tx_kernel_enter();
    kv_magic_exit(1);
    while (1) {
    }
}
