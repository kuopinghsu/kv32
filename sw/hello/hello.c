// Hello World test - Tests console output using _write() and standard C library
// Demonstrates the use of syscall.c _write() implementation and C library functions

#include <stdio.h>

// Declare _write from syscall.c
extern int _write(int file, char *ptr, int len);

// Helper function to get string length
static unsigned int strlen(const char *str) {
    int len = 0;
    while (str[len]) len++;
    return len;
}

// Main function
int main() {
    const char *msg1 = "Hello, World!\n";
    const char *msg2 = "Console output test using _write() syscall successful.\n";

    // Test 1: Use _write() to output to stdout (file descriptor 1)
    _write(1, (char*)msg1, strlen(msg1));
    _write(1, (char*)msg2, strlen(msg2));

    // Test 2: Use puts() for simple string output
    puts("Testing puts: Hello from C library!");

    // Test 3: Use printf() with string only (no formatting)
    printf("Testing printf: Hello from printf!\n");
    fflush(stdout);

    // Test 4: Use printf() with parameters
    int a = 5, b = 3;
    printf("Integer test: %d + %d = %d\n", a, b, a + b);
    fflush(stdout);
    printf("Hex test: 0x%x\n", 0xDEAD);
    fflush(stdout);
    printf("String test: %s\n", "Success!");
    fflush(stdout);

    // Return to start.S which will handle proper tohost exit
    return 0;
}
