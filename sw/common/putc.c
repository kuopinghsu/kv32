/*
 * putc() implementation for embedded systems
 * Outputs a single character to stdout
 */

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// External write function from syscall.c
extern int _write(int file, const void *ptr, size_t len);

int putc(int c, FILE *stream) {
    // Ignore stream parameter in bare-metal (always write to stdout)
    (void)stream;

    unsigned char ch = (unsigned char)c;
    int result = _write(1, &ch, 1);

    return (result == 1) ? c : EOF;
}

// putchar is typically a macro for putc(c, stdout), but provide a function too
int putchar(int c) {
    unsigned char ch = (unsigned char)c;
    int result = _write(1, &ch, 1);

    return (result == 1) ? c : EOF;
}

// fputc is an alias for putc
int fputc(int c, FILE *stream) {
    return putc(c, stream);
}

#ifdef __cplusplus
}
#endif
