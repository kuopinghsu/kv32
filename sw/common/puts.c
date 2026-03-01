// ============================================================================
// File: puts.c
// Project: KV32 RISC-V Processor
// Description: puts() stub for embedded systems: routes string + newline to stdout
// ============================================================================

#include <stdio.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// External write function from syscall.c
extern int _write(int file, const void *ptr, size_t len);

int puts(const char *s) {
    // Calculate string length
    size_t len = 0;
    const char *ptr = s;
    while (*ptr++) {
        len++;
    }

    // Write string
    if (len > 0) {
        int result = _write(1, s, len);
        if (result < 0) {
            return EOF;
        }
    }

    // Write newline
    int result = _write(1, "\n", 1);
    if (result < 0) {
        return EOF;
    }

    return 0;  // Success (non-negative value)
}

// fputs doesn't add newline (unlike puts)
int fputs(const char *s, FILE *stream) {
    // Ignore stream parameter in bare-metal
    (void)stream;

    // Calculate string length
    size_t len = 0;
    const char *ptr = s;
    while (*ptr++) {
        len++;
    }

    if (len == 0) {
        return 0;
    }

    // Write string (no newline for fputs)
    int result = _write(1, s, len);

    return (result == (int)len) ? 0 : EOF;
}

#ifdef __cplusplus
}
#endif
