// ============================================================================
// File: printf.c
// Project: KV32 RISC-V Processor
// Description: Lightweight embedded printf implementation (no stdlib dependency)
//
// Supports %c, %s, %d/%i, %u, %x/%X, %o, %p, width/precision,
// length modifiers (hh/h/l/ll/z/t), and flags (-, +, 0, space, #).
// Float support can be disabled with -DPRINTF_DISABLE_FLOAT.
// ============================================================================

// Use optimized division-free implementation by default
#ifndef PRINTF_USE_HARDWARE_DIV
#define PRINTF_OPTIMIZE_DIV_MOD 1
#endif

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// External write function from syscall.c
extern int _write(int file, const void *ptr, size_t len);

// Buffer for number conversion
#define PRINTF_BUFFER_SIZE 64

// Format flags
#define FLAG_LEFT_JUSTIFY   (1 << 0)
#define FLAG_PLUS_SIGN      (1 << 1)
#define FLAG_SPACE          (1 << 2)
#define FLAG_ZERO_PAD       (1 << 3)
#define FLAG_ALTERNATE      (1 << 4)

// Length modifiers
typedef enum {
    LENGTH_NONE,
    LENGTH_HH,      // char
    LENGTH_H,       // short
    LENGTH_L,       // long
    LENGTH_LL,      // long long
    LENGTH_Z,       // size_t
    LENGTH_T        // ptrdiff_t
} length_modifier_t;

// Format specification
typedef struct {
    uint8_t flags;
    int width;
    int precision;
    length_modifier_t length;
    char specifier;
} format_spec_t;

// Output buffer for printf
static char printf_output_buffer[PRINTF_BUFFER_SIZE];
static size_t printf_buffer_pos = 0;

// sprintf mode state
static char *sprintf_dest = NULL;
static size_t sprintf_pos = 0;
static size_t sprintf_max = 0;

// Flush output buffer
static void printf_flush(void) {
    if (!sprintf_dest && printf_buffer_pos > 0) {
        _write(1, printf_output_buffer, printf_buffer_pos);
        printf_buffer_pos = 0;
    }
}

// Put a single character
static void printf_putchar(char c) {
    if (sprintf_dest) {
        // sprintf mode
        if (sprintf_pos < sprintf_max - 1) {
            sprintf_dest[sprintf_pos++] = c;
        }
    } else {
        // printf mode
        printf_output_buffer[printf_buffer_pos++] = c;
        if (printf_buffer_pos >= PRINTF_BUFFER_SIZE) {
            printf_flush();
        }
    }
}

// Put a string
static void printf_putstr(const char *str) {
    while (*str) {
        printf_putchar(*str++);
    }
}

// Put a string with width/precision
static void printf_putstr_formatted(const char *str, const format_spec_t *spec) {
    size_t len = 0;
    const char *s = str;

    // Calculate string length up to precision
    while (*s && (spec->precision < 0 || len < (size_t)spec->precision)) {
        len++;
        s++;
    }

    // Left padding
    if (!(spec->flags & FLAG_LEFT_JUSTIFY) && spec->width > (int)len) {
        for (int i = 0; i < spec->width - (int)len; i++) {
            printf_putchar(' ');
        }
    }

    // String content
    for (size_t i = 0; i < len; i++) {
        printf_putchar(str[i]);
    }

    // Right padding
    if ((spec->flags & FLAG_LEFT_JUSTIFY) && spec->width > (int)len) {
        for (int i = 0; i < spec->width - (int)len; i++) {
            printf_putchar(' ');
        }
    }
}

// Convert unsigned integer to string
static char* uint_to_str(uint64_t value, char *buf, const int base, bool uppercase) {
    const char *digits = uppercase ? "0123456789ABCDEF" : "0123456789abcdef";
    char *ptr = buf + PRINTF_BUFFER_SIZE - 1;
    *ptr = '\0';

    if (value == 0) {
        *(--ptr) = '0';
        return ptr;
    }

#ifdef PRINTF_OPTIMIZE_DIV_MOD
    // Optimized division/modulo for common bases without hardware divider
    if (base == 16) {
        // Base 16: use bit operations
        while (value > 0) {
            *(--ptr) = digits[value & 0xF];  // value % 16 = value & 0xF
            value >>= 4;                     // value /= 16 = value >> 4
        }
    } else if (base == 8) {
        // Base 8: use bit operations
        while (value > 0) {
            *(--ptr) = digits[value & 0x7];  // value % 8 = value & 0x7
            value >>= 3;                     // value /= 8 = value >> 3
        }
    } else if (base == 10) {
        // Base 10: use optimized division without hardware divider
        // Uses the multiply-by-reciprocal method
        while (value > 0) {
            uint64_t q, r;

            // For small values, use simple subtraction
            if (value < 10) {
                *(--ptr) = digits[value];
                break;
            }

            // Optimized division by 10 using multiplication
            // q = (value * 0x1999999999999999ULL + value) >> 64;
            // This works because 0x1999999999999999 ≈ 2^64 / 10

            // Alternative: use shift and subtract method
            // q ≈ (value >> 1) + (value >> 2) + (value >> 5) + (value >> 6) + ...
            // Simplified: q ≈ value * 0.1

            // Method: q = ((value >> 1) + (value >> 2)) >> 2 for approximation
            q = value >> 1;           // value / 2
            q += value >> 2;          // + value / 4
            q += q >> 4;              // + value / 16
            q += q >> 8;              // + value / 256
            q += q >> 16;             // + value / 65536
            q += q >> 32;             // + value / 4294967296 (for 64-bit)
            q >>= 3;                  // divide by 8 to get approximately value/10

            // Calculate remainder and adjust if needed
            r = value - (q << 3) - (q << 1); // r = value - q*10 = value - q*8 - q*2
            if (r >= 10) {
                q++;
                r -= 10;
            }

            *(--ptr) = digits[r];
            value = q;
        }
    } else {
        // Fallback for other bases (should rarely be used)
        while (value > 0) {
            *(--ptr) = digits[value % base];
            value /= base;
        }
    }
#else
    // Standard implementation using hardware division/modulo
    while (value > 0) {
        *(--ptr) = digits[value % base];
        value /= base;
    }
#endif

    return ptr;
}

// Print formatted integer
static void printf_print_int(int64_t value, const format_spec_t *spec, const int base, bool uppercase) {
    char buffer[PRINTF_BUFFER_SIZE];
    char sign = 0;
    uint64_t uvalue;

    // Handle sign
    if (spec->specifier == 'd' || spec->specifier == 'i') {
        if (value < 0) {
            sign = '-';
            uvalue = (uint64_t)(-value);
        } else {
            if (spec->flags & FLAG_PLUS_SIGN) {
                sign = '+';
            } else if (spec->flags & FLAG_SPACE) {
                sign = ' ';
            }
            uvalue = (uint64_t)value;
        }
    } else {
        uvalue = (uint64_t)value;
    }

    // Convert to string
    char *str = uint_to_str(uvalue, buffer, base, uppercase);
    size_t len = buffer + PRINTF_BUFFER_SIZE - 1 - str;

    // Add prefix for alternate form
    int prefix_len = 0;
    if (spec->flags & FLAG_ALTERNATE) {
        if (base == 16 && uvalue != 0) {
            prefix_len = 2; // "0x" or "0X"
        } else if (base == 8 && uvalue != 0) {
            prefix_len = 1; // "0"
        }
    }

    // Calculate padding
    int sign_len = sign ? 1 : 0;
    int num_len = len + sign_len + prefix_len;
    int precision_pad = 0;

    if (spec->precision >= 0 && spec->precision > (int)len) {
        precision_pad = spec->precision - len;
    }

    num_len += precision_pad;

    // Print with padding
    char pad_char = (spec->flags & FLAG_ZERO_PAD) && spec->precision < 0 ? '0' : ' ';

    // Left padding (space)
    if (!(spec->flags & FLAG_LEFT_JUSTIFY) && pad_char == ' ' && spec->width > num_len) {
        for (int i = 0; i < spec->width - num_len; i++) {
            printf_putchar(' ');
        }
    }

    // Sign and prefix
    if (sign) printf_putchar(sign);
    if (spec->flags & FLAG_ALTERNATE) {
        if (base == 16 && uvalue != 0) {
            printf_putchar('0');
            printf_putchar(uppercase ? 'X' : 'x');
        } else if (base == 8 && uvalue != 0 && *str != '0') {
            printf_putchar('0');
        }
    }

    // Left padding (zero)
    if (!(spec->flags & FLAG_LEFT_JUSTIFY) && pad_char == '0' && spec->width > num_len) {
        for (int i = 0; i < spec->width - num_len; i++) {
            printf_putchar('0');
        }
    }

    // Precision padding
    for (int i = 0; i < precision_pad; i++) {
        printf_putchar('0');
    }

    // Number
    printf_putstr(str);

    // Right padding
    if ((spec->flags & FLAG_LEFT_JUSTIFY) && spec->width > num_len) {
        for (int i = 0; i < spec->width - num_len; i++) {
            printf_putchar(' ');
        }
    }
}

#ifndef PRINTF_DISABLE_FLOAT

// Simple floating point to string conversion
static void printf_print_float(double value, const format_spec_t *spec) {
    char buffer[PRINTF_BUFFER_SIZE];
    int precision = spec->precision < 0 ? 6 : spec->precision;
    bool negative = false;

    // Handle special cases
    if (value != value) { // NaN
        printf_putstr_formatted("nan", spec);
        return;
    }

    if (value < 0) {
        negative = true;
        value = -value;
    }

    // Check for infinity
    if (value > 1e38) {
        printf_putstr_formatted(negative ? "-inf" : "inf", spec);
        return;
    }

    // Build the string
    char *ptr = buffer;

    // Sign
    if (negative) {
        *ptr++ = '-';
    } else if (spec->flags & FLAG_PLUS_SIGN) {
        *ptr++ = '+';
    } else if (spec->flags & FLAG_SPACE) {
        *ptr++ = ' ';
    }

    // Integer part
    uint64_t int_part = (uint64_t)value;
    double frac_part = value - (double)int_part;

    char temp[PRINTF_BUFFER_SIZE];
    char *int_str = uint_to_str(int_part, temp, 10, false);
    while (*int_str) {
        *ptr++ = *int_str++;
    }

    // Decimal point
    if (precision > 0 || (spec->flags & FLAG_ALTERNATE)) {
        *ptr++ = '.';
    }

    // Fractional part
    for (int i = 0; i < precision; i++) {
        frac_part *= 10;
        int digit = (int)frac_part;
        *ptr++ = '0' + digit;
        frac_part -= digit;
    }

    // Round last digit
    if (frac_part >= 0.5 && precision > 0) {
        char *round_ptr = ptr - 1;
        while (round_ptr >= buffer) {
            if (*round_ptr == '.') {
                round_ptr--;
                continue;
            }
            if (*round_ptr < '9') {
                (*round_ptr)++;
                break;
            }
            *round_ptr = '0';
            round_ptr--;
        }
    }

    *ptr = '\0';

    // Output with width formatting
    size_t len = ptr - buffer;
    if (!(spec->flags & FLAG_LEFT_JUSTIFY) && spec->width > (int)len) {
        char pad = (spec->flags & FLAG_ZERO_PAD) ? '0' : ' ';
        for (int i = 0; i < spec->width - (int)len; i++) {
            printf_putchar(pad);
        }
    }

    printf_putstr(buffer);

    if ((spec->flags & FLAG_LEFT_JUSTIFY) && spec->width > (int)len) {
        for (int i = 0; i < spec->width - (int)len; i++) {
            printf_putchar(' ');
        }
    }
}

#endif // !PRINTF_DISABLE_FLOAT

// Parse format specification
static const char* parse_format_spec(const char *format, format_spec_t *spec, va_list *args) {
    spec->flags = 0;
    spec->width = 0;
    spec->precision = -1;
    spec->length = LENGTH_NONE;
    spec->specifier = 0;

    // Parse flags
    bool parsing_flags = true;
    while (parsing_flags) {
        switch (*format) {
            case '-': spec->flags |= FLAG_LEFT_JUSTIFY; format++; break;
            case '+': spec->flags |= FLAG_PLUS_SIGN; format++; break;
            case ' ': spec->flags |= FLAG_SPACE; format++; break;
            case '0': spec->flags |= FLAG_ZERO_PAD; format++; break;
            case '#': spec->flags |= FLAG_ALTERNATE; format++; break;
            default: parsing_flags = false; break;
        }
    }

    // Parse width
    if (*format == '*') {
        spec->width = va_arg(*args, int);
        if (spec->width < 0) {
            spec->flags |= FLAG_LEFT_JUSTIFY;
            spec->width = -spec->width;
        }
        format++;
    } else {
        while (*format >= '0' && *format <= '9') {
            spec->width = spec->width * 10 + (*format - '0');
            format++;
        }
    }

    // Parse precision
    if (*format == '.') {
        format++;
        spec->precision = 0;
        if (*format == '*') {
            spec->precision = va_arg(*args, int);
            format++;
        } else {
            while (*format >= '0' && *format <= '9') {
                spec->precision = spec->precision * 10 + (*format - '0');
                format++;
            }
        }
    }

    // Parse length modifier
    if (*format == 'h') {
        format++;
        if (*format == 'h') {
            spec->length = LENGTH_HH;
            format++;
        } else {
            spec->length = LENGTH_H;
        }
    } else if (*format == 'l') {
        format++;
        if (*format == 'l') {
            spec->length = LENGTH_LL;
            format++;
        } else {
            spec->length = LENGTH_L;
        }
    } else if (*format == 'z') {
        spec->length = LENGTH_Z;
        format++;
    } else if (*format == 't') {
        spec->length = LENGTH_T;
        format++;
    }

    // Parse specifier
    spec->specifier = *format;
    if (*format) format++;

    return format;
}

// Main printf implementation
int vprintf(const char *format, va_list args) {
    int count = 0;

    while (*format) {
        if (*format == '%') {
            format++;

            // Handle %%
            if (*format == '%') {
                printf_putchar('%');
                format++;
                count++;
                continue;
            }

            // Parse format specification
            format_spec_t spec;
            format = parse_format_spec(format, &spec, &args);

            // Process based on specifier
            switch (spec.specifier) {
                case 'c': {
                    char c = (char)va_arg(args, int);
                    printf_putchar(c);
                    count++;
                    break;
                }

                case 's': {
                    const char *s = va_arg(args, const char*);
                    if (!s) s = "(null)";
                    printf_putstr_formatted(s, &spec);
                    break;
                }

                case 'd':
                case 'i': {
                    int64_t value;
                    switch (spec.length) {
                        case LENGTH_HH: value = (signed char)va_arg(args, int); break;
                        case LENGTH_H:  value = (short)va_arg(args, int); break;
                        case LENGTH_L:  value = va_arg(args, long); break;
                        case LENGTH_LL: value = va_arg(args, long long); break;
                        case LENGTH_Z:  value = va_arg(args, size_t); break;
                        case LENGTH_T:  value = va_arg(args, ptrdiff_t); break;
                        default:        value = va_arg(args, int); break;
                    }
                    printf_print_int(value, &spec, 10, false);
                    break;
                }

                case 'u': {
                    uint64_t value;
                    switch (spec.length) {
                        case LENGTH_HH: value = (unsigned char)va_arg(args, unsigned int); break;
                        case LENGTH_H:  value = (unsigned short)va_arg(args, unsigned int); break;
                        case LENGTH_L:  value = va_arg(args, unsigned long); break;
                        case LENGTH_LL: value = va_arg(args, unsigned long long); break;
                        case LENGTH_Z:  value = va_arg(args, size_t); break;
                        case LENGTH_T:  value = va_arg(args, ptrdiff_t); break;
                        default:        value = va_arg(args, unsigned int); break;
                    }
                    printf_print_int(value, &spec, 10, false);
                    break;
                }

                case 'x':
                case 'X': {
                    uint64_t value;
                    switch (spec.length) {
                        case LENGTH_HH: value = (unsigned char)va_arg(args, unsigned int); break;
                        case LENGTH_H:  value = (unsigned short)va_arg(args, unsigned int); break;
                        case LENGTH_L:  value = va_arg(args, unsigned long); break;
                        case LENGTH_LL: value = va_arg(args, unsigned long long); break;
                        case LENGTH_Z:  value = va_arg(args, size_t); break;
                        case LENGTH_T:  value = va_arg(args, ptrdiff_t); break;
                        default:        value = va_arg(args, unsigned int); break;
                    }
                    printf_print_int(value, &spec, 16, spec.specifier == 'X');
                    break;
                }

                case 'o': {
                    uint64_t value;
                    switch (spec.length) {
                        case LENGTH_HH: value = (unsigned char)va_arg(args, unsigned int); break;
                        case LENGTH_H:  value = (unsigned short)va_arg(args, unsigned int); break;
                        case LENGTH_L:  value = va_arg(args, unsigned long); break;
                        case LENGTH_LL: value = va_arg(args, unsigned long long); break;
                        case LENGTH_Z:  value = va_arg(args, size_t); break;
                        case LENGTH_T:  value = va_arg(args, ptrdiff_t); break;
                        default:        value = va_arg(args, unsigned int); break;
                    }
                    printf_print_int(value, &spec, 8, false);
                    break;
                }

                case 'p': {
                    void *ptr = va_arg(args, void*);
                    spec.flags |= FLAG_ALTERNATE;
                    printf_print_int((uint64_t)(uintptr_t)ptr, &spec, 16, false);
                    break;
                }

#ifndef PRINTF_DISABLE_FLOAT
                case 'f':
                case 'F': {
                    double value = va_arg(args, double);
                    printf_print_float(value, &spec);
                    break;
                }

                case 'e':
                case 'E':
                case 'g':
                case 'G':
                    // Simplified: treat as %f for now
                    {
                        double value = va_arg(args, double);
                        printf_print_float(value, &spec);
                    }
                    break;
#endif

                default:
                    // Unknown specifier, just print it
                    printf_putchar('%');
                    printf_putchar(spec.specifier);
                    break;
            }
        } else {
            printf_putchar(*format);
            format++;
            count++;
        }
    }

    printf_flush();
    return count;
}

int printf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = vprintf(format, args);
    va_end(args);
    return result;
}

// sprintf implementation
static int vsprintf_impl(char *str, size_t size, const char *format, va_list args) {
    // Set sprintf mode
    char *saved_dest = sprintf_dest;
    size_t saved_pos = sprintf_pos;
    size_t saved_max = sprintf_max;

    sprintf_dest = str;
    sprintf_pos = 0;
    sprintf_max = size;

    vprintf(format, args);

    // Get result before restoring
    int result = sprintf_pos;

    // Restore state
    sprintf_dest = saved_dest;
    sprintf_pos = saved_pos;
    sprintf_max = saved_max;

    // Null terminate
    if (result < (int)size) {
        str[result] = '\0';
    } else if (size > 0) {
        str[size - 1] = '\0';
    }

    return result;
}

int sprintf(char *str, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = vsprintf_impl(str, (size_t)-1, format, args);
    va_end(args);
    return result;
}

int snprintf(char *str, size_t size, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = vsprintf_impl(str, size, format, args);
    va_end(args);
    return result;
}

#ifdef __cplusplus
}
#endif
