// System call implementations for newlib
// Provides minimal syscall support for console output

#include <sys/stat.h>
#include <errno.h>

#include "csr.h"
#include "kv_platform.h"

// HTIF tohost/fromhost symbols (defined in linker script / crt0)
#ifdef __cplusplus
extern "C" {
#endif
extern volatile unsigned long long tohost;
extern volatile unsigned long long fromhost;
#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Magic console address - write character to output (for RTL/kv32sim)
// Use KV_MAGIC_CONSOLE_ADDR from kv_platform.h (= KV_MAGIC_BASE + KV_MAGIC_CONSOLE_OFF)

// Memory-mapped console magic address
volatile unsigned int* const console_putc = (unsigned int*)KV_MAGIC_CONSOLE_ADDR;

// HTIF device numbers
#define HTIF_DEV_SYSCALL 0
#define HTIF_DEV_CONSOLE 1

// HTIF console commands
#define HTIF_CONSOLE_CMD_PUTC 1

// Simple console output function
void console_putchar(char c) {
#ifdef USE_HTIF
    // HTIF protocol: tohost = (dev << 56) | (cmd << 48) | payload
    // Use explicit pointer writes to avoid compiler optimization issues on KV32
    volatile unsigned int *tohost_ptr = (volatile unsigned int *)&tohost;

    // Note: Spike doesn't acknowledge via fromhost for console output
    // Just write to tohost and continue
    tohost_ptr[0] = (unsigned char)c;
    tohost_ptr[1] = 0x01010000;  // (1 << 24) | (1 << 16) = dev 1, cmd 1 in upper 32 bits

    // Give Spike time to process by reading tohost back (acts as memory barrier)
    (void)tohost_ptr[0];
#else
    // Magic address for RTL testbench and kv32sim
    *console_putc = (unsigned int)c;
#endif
}

// Write system call - outputs to console
// Used by printf, puts, write, etc.
int _write(int file, char *ptr, int len) {
    int i;

    // Only support stdout (1) and stderr (2)
    if (file != 1 && file != 2) {
        errno = EBADF;
        return -1;
    }

    // Write each character to console
    for (i = 0; i < len; i++) {
        console_putchar(ptr[i]);
    }

    return len;
}

// Stubs for other syscalls that newlib might need
int _close(int file) {
    UNUSED(file);
    return -1;
}

int _fstat(int file, struct stat *st) {
    UNUSED(file);
    st->st_mode = S_IFCHR;
    return 0;
}

int _isatty(int file) {
    UNUSED(file);
    return 1;
}

int _lseek(int file, int ptr, int dir) {
    UNUSED(file);
    UNUSED(ptr);
    UNUSED(dir);
    return 0;
}

int _read(int file, char *ptr, int len) {
    UNUSED(file);
    UNUSED(ptr);
    UNUSED(len);
    return 0;
}

void *_sbrk(int incr) {
    extern char __heap_start;  // Defined in linker script
    static char *heap_end = 0;
    char *prev_heap_end;

    if (heap_end == 0) {
        heap_end = &__heap_start;
    }

    prev_heap_end = heap_end;
    heap_end += incr;

    return (void *)prev_heap_end;
}

// Exit program by writing to tohost
void _exit(int status) {
    // Also write to magic exit address as fallback (for testbenches without tohost support)
    // Encoding: (status << 1) | 1  matches HTIF and kv_magic_exit() in kv_platform.h
    volatile unsigned int* exit_addr = (volatile unsigned int*)KV_MAGIC_EXIT_ADDR;
    *exit_addr = (status == 0) ? 1u : (((unsigned int)status << 1) | 1u);

    // tohost protocol: write (exit_code << 1) | 1
    // For exit, we write (status << 1) | 1
    tohost = ((unsigned long long)status << 1) | 1;

    // Hang forever after exit
    while (1) {
        __asm__ volatile ("nop");
    }
}

// Wrapped fflush to handle NULL FILE pointers safely
// Use -Wl,--wrap=fflush to enable this wrapper
int __real_fflush(void *stream);
int __wrap_fflush(void *stream) {
    // In our freestanding environment, printf uses _write directly (unbuffered)
    // so fflush is always a no-op. Just return success.
    (void)stream;
    (void)__real_fflush;
    return 0;
}

#ifdef __cplusplus
}
#endif
