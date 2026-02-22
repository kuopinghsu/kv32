#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern int printf(const char *format, ...);
extern int sprintf(char *str, const char *format, ...);
extern int snprintf(char *str, size_t size, const char *format, ...);

int main(void) {
    printf("\n========================================\n");
    printf("  Printf/Puts/Putc Comprehensive Test\n");
    printf("========================================\n\n");

    // Test puts and putc functions
    printf("=== Testing puts/putc Functions ===\n");
    puts("puts: This is a line with automatic newline");
    fputs("fputs: This line has no auto newline", stdout);
    printf("\n");
    putchar('X');
    putchar('\n');
    putc('Y', stdout);
    putc('\n', stdout);

    // Character test
    printf("\n=== Character Tests ===\n");
    printf("Single char: %c\n", 'A');
    printf("Multiple: %c %c %c\n", 'X', 'Y', 'Z');
    printf("Escape sequences: '\\n' '\\t' '\\r'\n");

    // String tests
    printf("\n=== String Tests ===\n");
    printf("Hello: %s\n", "World");
    printf("Empty string: '%s'\n", "");
    printf("Width right: '%10s'\n", "test");
    printf("Width left: '%-10s'\n", "test");
    printf("Precision: '%.3s' from 'Testing'\n", "Testing");
    printf("Width+Prec: '%10.3s'\n", "Testing");

    // Integer tests
    printf("\n=== Integer Tests ===\n");
    printf("Decimal: %d, %i\n", 42, -42);
    printf("Unsigned: %u\n", 42);
    printf("Hex lower: 0x%x\n", 255);
    printf("Hex upper: 0x%X\n", 255);
    printf("Octal: %o\n", 64);
    printf("Pointer: %p\n", (void*)0x80000000);
    printf("Zero: %d\n", 0);
    printf("Max int: %d\n", 2147483647);
    printf("Min int: %ld\n", (long)-2147483648);

    // Width and precision
    printf("\n=== Width/Precision Tests ===\n");
    printf("Width 5 right: '%5d'\n", 42);
    printf("Width 5 left: '%-5d'\n", 42);
    printf("Width 10: '%10d'\n", 123);
    printf("Zero pad: '%05d'\n", 42);
    printf("Zero pad neg: '%05d'\n", -42);
    printf("Plus sign: '%+d' '%+d'\n", 42, -42);
    printf("Space: '% d' '% d'\n", 42, -42);
    printf("Precision: '%.5d'\n", 42);

    // Alternate form
    printf("\n=== Alternate Form Tests ===\n");
    printf("Hex with #: '%#x' '%#X'\n", 255, 255);
    printf("Hex zero: '%#x'\n", 0);
    printf("Octal with #: '%#o'\n", 64);
    printf("Octal zero: '%#o'\n", 0);

    // Length modifiers
    printf("\n=== Length Modifier Tests ===\n");
    printf("char (hh): %hhd\n", (signed char)-128);
    printf("short (h): %hd\n", (short)32767);
    printf("long (l): %ld\n", (long)2147483647L);
    printf("long long (ll): %lld\n", (long long)9223372036854775807LL);
    printf("unsigned char: %hhu\n", (unsigned char)255);
    printf("unsigned short: %hu\n", (unsigned short)65535);
    printf("unsigned long: %lu\n", (unsigned long)4294967295UL);
    printf("unsigned ll hex: %llx\n", (unsigned long long)0xDEADBEEFCAFEBABEULL);

    // Edge cases
    printf("\n=== Edge Cases ===\n");
    printf("Percent sign: %%\n");
    printf("Multiple %%: %%%% = %%%%\n");
    printf("Empty string: '%s'\n", "");
    printf("Very long string: '%s'\n", "This is a somewhat longer string to test buffer handling in printf implementation");

    // Combined formatting
    printf("\n=== Combined Format Tests ===\n");
    printf("Mix: %d %s %x %c\n", 42, "test", 255, 'A');
    printf("Complex: %+05d %-10s %#x\n", 123, "align", 255);
    printf("Table:\n");
    printf("  %-10s | %5s | %8s\n", "Name", "Value", "Hex");
    printf("  %-10s | %5d | %#8x\n", "Alpha", 100, 100);
    printf("  %-10s | %5d | %#8x\n", "Beta", 200, 200);
    printf("  %-10s | %5d | %#8x\n", "Gamma", 300, 300);

#ifndef PRINTF_DISABLE_FLOAT
    // Float tests
    printf("\n=== Float/Double Tests ===\n");
    printf("Basic float: %f\n", 3.14159);
    printf("Precision .2f: %.2f\n", 3.14159);
    printf("Precision .0f: %.0f\n", 3.14159);
    printf("Width: '%10.2f'\n", 3.14159);
    printf("Negative: %f\n", -123.456);
    printf("Large: %f\n", 123456.789);
    printf("Small: %f\n", 0.001234);
    printf("Zero: %f\n", 0.0);
    printf("Plus sign: %+f\n", 3.14);
    printf("Space: % f\n", 3.14);
#else
    printf("\n=== Float Support ===\n");
    printf("DISABLED (compile without -DPRINTF_DISABLE_FLOAT)\n");
#endif

    // sprintf tests
    printf("\n=== sprintf/snprintf Tests ===\n");
    char buffer[64];
    sprintf(buffer, "sprintf: %d + %d = %d", 10, 20, 30);
    printf("Result: %s\n", buffer);

    snprintf(buffer, sizeof(buffer), "snprintf: %s %d", "test", 123);
    printf("Result: %s\n", buffer);

    // Test truncation
    snprintf(buffer, 10, "This is a very long string");
    printf("Truncated (10 chars): '%s'\n", buffer);

    // Stress test with many arguments
    printf("\n=== Stress Test ===\n");
    printf("Many args: %d %d %d %d %d %d %d %d\n", 1, 2, 3, 4, 5, 6, 7, 8);

    printf("\n========================================\n");
    printf("  All Tests Complete - %d Total\n", 50);
    printf("========================================\n\n");

    return 0;
}
