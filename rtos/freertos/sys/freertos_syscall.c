/*
 * FreeRTOS Syscall stubs for newlib
 */

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/times.h>
#include <errno.h>
#include <stdint.h>
#include "kv_platform.h"

#undef errno
extern int errno;

/* Memory management */
extern char __heap_start[];
extern char __heap_end[];
static char *heap_ptr = NULL;

void *_sbrk(int incr)
{
    char *prev_heap_ptr;

    if (heap_ptr == NULL) {
        heap_ptr = __heap_start;
    }

    prev_heap_ptr = heap_ptr;

    if ((heap_ptr + incr) > __heap_end) {
        errno = ENOMEM;
        return (void *)-1;
    }

    heap_ptr += incr;
    return prev_heap_ptr;
}

int _close(int file)
{
    return -1;
}

int _fstat(int file, struct stat *st)
{
    st->st_mode = S_IFCHR;
    return 0;
}

int _isatty(int file)
{
    return 1;
}

int _lseek(int file, int offset, int whence)
{
    return 0;
}

int _read(int file, char *ptr, int len)
{
    return 0;
}

int _write(int file, char *ptr, int len)
{
    for (int i = 0; i < len; i++) {
        if (ptr[i] == '\n')
            kv_magic_putc('\r');
        kv_magic_putc(ptr[i]);
    }
    return len;
}

/* _exit is defined in freertos_start.S */

int _kill(int pid, int sig)
{
    errno = EINVAL;
    return -1;
}

int _getpid(void)
{
    return 1;
}

int _open(const char *name, int flags, int mode)
{
    return -1;
}

int _wait(int *status)
{
    errno = ECHILD;
    return -1;
}

int _unlink(const char *name)
{
    errno = ENOENT;
    return -1;
}

int _times(struct tms *buf)
{
    return -1;
}

int _stat(const char *file, struct stat *st)
{
    st->st_mode = S_IFCHR;
    return 0;
}

int _link(const char *old, const char *new)
{
    errno = EMLINK;
    return -1;
}

int _fork(void)
{
    errno = EAGAIN;
    return -1;
}

int _execve(const char *name, char *const *argv, char *const *env)
{
    errno = ENOMEM;
    return -1;
}
