// C++ test program - Tests global constructors and C library integration
// Demonstrates C++ features in embedded environment

// C library functions
extern "C" {
    int printf(const char *format, ...);
    int puts(const char *s);
    int putchar(int c);
}

// Declare _write from syscall.c (for backward compatibility)
extern "C" int _write(int file, char *ptr, int len);

// Helper function to get string length
static int strlen_local(const char* str) {
    int len = 0;
    while (str[len]) len++;
    return len;
}

// Simple integer to string conversion
static void int_to_str(int val, char* buf) {
    if (val == 0) {
        buf[0] = '0';
        buf[1] = '\0';
        return;
    }

    int i = 0;
    int is_negative = 0;

    if (val < 0) {
        is_negative = 1;
        val = -val;
    }

    // Convert digits in reverse
    char temp[16];
    while (val > 0) {
        temp[i++] = '0' + (val % 10);
        val /= 10;
    }

    // Add negative sign if needed
    int j = 0;
    if (is_negative) {
        buf[j++] = '-';
    }

    // Reverse the digits
    while (i > 0) {
        buf[j++] = temp[--i];
    }
    buf[j] = '\0';
}

// Test class with constructor
class TestClass {
private:
    int value;
    const char* name;

public:
    TestClass(const char* n, int v) : value(v), name(n) {
        // Constructor is called - output via _write
        const char* msg = "Constructor called for: ";
        _write(1, (char*)msg, strlen_local(msg));
        _write(1, (char*)name, strlen_local(name));
        const char* newline = "\n";
        _write(1, (char*)newline, 1);
    }

    void display() {
        const char* msg1 = "Object: ";
        const char* msg2 = ", Value: ";
        char num_str[16];

        _write(1, (char*)msg1, strlen_local(msg1));
        _write(1, (char*)name, strlen_local(name));
        _write(1, (char*)msg2, strlen_local(msg2));

        int_to_str(value, num_str);
        _write(1, num_str, strlen_local(num_str));
        _write(1, (char*)"\n", 1);
    }
};

// Global objects - constructors should be called before main()
TestClass global_obj1("GlobalObject1", 42);
TestClass global_obj2("GlobalObject2", 99);

// Another test - static object in function
TestClass& get_static_obj() {
    static TestClass static_obj("StaticObject", 777);
    return static_obj;
}

int main() {
    puts("\n=== ENTERING MAIN ===");

    printf("\n=== C++ Test Program ===\n");

    puts("\nGlobal constructors executed before main():");

    // Display global objects
    global_obj1.display();
    global_obj2.display();

    puts("\nCreating local object:");
    TestClass local_obj("LocalObject", 123);
    local_obj.display();

    puts("\nAccessing static local object (guard variable test):");
    get_static_obj().display();

    puts("\nCalling again (should not reconstruct):");
    get_static_obj().display();

    // Test C library integration
    puts("\n=== Testing C Library Integration ===");
    printf("printf test: %d + %d = %d\n", 10, 20, 30);
    printf("hex: 0x%x, string: %s\n", 255, "test");
    putchar('A');
    putchar('\n');
    // Test C library integration
    puts("\n=== Testing C Library Integration ===");
    printf("printf test: %d + %d = %d\n", 10, 20, 30);
    printf("hex: 0x%x, string: %s\n", 255, "test");
    putchar('A');
    putchar('\n');

    puts("\n=== C++ Test Complete ===");

    return 0;
}
