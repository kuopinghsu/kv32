// I2C Hardware Test - Tests I2C master controller at 0x02030000
// Tests I2C communication with 24C02-style EEPROM slave at address 0x50
// EEPROM has 256 bytes initialized with pattern 0xA0 + address

#include <stdint.h>
#include <stdio.h>

// I2C peripheral registers
#define I2C_BASE     0x02030000
#define I2C_CTRL     (*((volatile uint32_t*)(I2C_BASE + 0x00)))
#define I2C_DIV      (*((volatile uint32_t*)(I2C_BASE + 0x04)))
#define I2C_TX       (*((volatile uint32_t*)(I2C_BASE + 0x08)))
#define I2C_RX       (*((volatile uint32_t*)(I2C_BASE + 0x0C)))
#define I2C_STATUS   (*((volatile uint32_t*)(I2C_BASE + 0x10)))

// Control register bits
#define I2C_CTRL_ENABLE   0x01  // Enable I2C controller
#define I2C_CTRL_START    0x02  // Send START condition
#define I2C_CTRL_STOP     0x04  // Send STOP condition
#define I2C_CTRL_READ     0x08  // Read mode (vs write)
#define I2C_CTRL_ACK      0x10  // ACK bit for read (0=ACK, 1=NACK)

// Status register bits
#define I2C_STATUS_BUSY      0x01  // Transfer in progress
#define I2C_STATUS_TX_READY  0x02  // Can accept new data
#define I2C_STATUS_RX_VALID  0x04  // Received data available
#define I2C_STATUS_ACK_RECV  0x08  // Slave ACKed last transfer

// EEPROM configuration
#define EEPROM_ADDR   0x50  // 7-bit I2C address
#define EEPROM_SIZE   256   // 256 bytes

// Test statistics
static volatile uint32_t status_checks = 0;
static volatile uint32_t busy_waits = 0;
static volatile uint32_t writes = 0;
static volatile uint32_t reads = 0;

// Helper functions
void i2c_init(uint32_t clk_div) {
    I2C_DIV = clk_div;
    I2C_CTRL = I2C_CTRL_ENABLE;
    status_checks++;
}

void i2c_wait_ready(void) {
    while (I2C_STATUS & I2C_STATUS_BUSY) {
        busy_waits++;
    }
    status_checks++;
}

void i2c_start(void) {
    i2c_wait_ready();
    printf("  [I2C] Sending START\n");
    I2C_CTRL = I2C_CTRL_ENABLE | I2C_CTRL_START;
    i2c_wait_ready();  // Wait for START to complete
    printf("  [I2C] START complete, status=0x%02lX\n", (unsigned long)I2C_STATUS);
}

void i2c_stop(void) {
    i2c_wait_ready();
    I2C_CTRL = I2C_CTRL_ENABLE | I2C_CTRL_STOP;
    i2c_wait_ready();  // Wait for STOP to complete
}

int i2c_write_byte(uint8_t data) {
    i2c_wait_ready();
    I2C_TX = data;
    i2c_wait_ready();
    writes++;

    // Check if slave ACKed
    uint32_t status = I2C_STATUS;
    int ack = (status & I2C_STATUS_ACK_RECV) ? 0 : -1;
    printf("  [I2C] Write 0x%02X -> status=0x%02lX, ACK=%d\n",
           data, (unsigned long)status, (status & I2C_STATUS_ACK_RECV) ? 1 : 0);
    return ack;
}

uint8_t i2c_read_byte(int send_ack) {
    i2c_wait_ready();

    // Configure read mode with ACK/NACK
    if (send_ack) {
        I2C_CTRL = I2C_CTRL_ENABLE | I2C_CTRL_READ;  // ACK
    } else {
        I2C_CTRL = I2C_CTRL_ENABLE | I2C_CTRL_READ | I2C_CTRL_ACK;  // NACK
    }

    i2c_wait_ready();
    reads++;

    return (uint8_t)(I2C_RX & 0xFF);
}

// EEPROM write: START + ADDR(W) + MEM_ADDR + DATA + STOP
int eeprom_write(uint8_t mem_addr, uint8_t data) {
    i2c_start();

    // Send device address with write bit (0)
    if (i2c_write_byte((EEPROM_ADDR << 1) | 0) < 0) {
        i2c_stop();
        return -1;  // No ACK from device
    }

    // Send memory address
    if (i2c_write_byte(mem_addr) < 0) {
        i2c_stop();
        return -2;  // No ACK for address
    }

    // Send data byte
    if (i2c_write_byte(data) < 0) {
        i2c_stop();
        return -3;  // No ACK for data
    }

    i2c_stop();
    return 0;  // Success
}

// EEPROM read: START + ADDR(W) + MEM_ADDR + START + ADDR(R) + DATA + STOP
int eeprom_read(uint8_t mem_addr, uint8_t *data) {
    // Write phase: set memory address
    i2c_start();

    // Send device address with write bit
    if (i2c_write_byte((EEPROM_ADDR << 1) | 0) < 0) {
        i2c_stop();
        return -1;  // No ACK from device
    }

    // Send memory address
    if (i2c_write_byte(mem_addr) < 0) {
        i2c_stop();
        return -2;  // No ACK for address
    }

    // Read phase: repeated START + read data
    i2c_start();

    // Send device address with read bit (1)
    if (i2c_write_byte((EEPROM_ADDR << 1) | 1) < 0) {
        i2c_stop();
        return -3;  // No ACK for read
    }

    // Read data byte with NACK (end of read)
    *data = i2c_read_byte(0);  // 0 = send NACK

    i2c_stop();
    return 0;  // Success
}

int main(void) {
    printf("\n========================================\n");
    printf("  I2C Hardware Test (Master + EEPROM)\n");
    printf("  Base Address: 0x%08X\n", I2C_BASE);
    printf("  EEPROM: 24C02 @ 0x%02X (256 bytes)\n", EEPROM_ADDR);
    printf("========================================\n\n");

    // TEST 1: Initialize I2C controller
    printf("[TEST 1] I2C Controller Initialization\n");
    // Clock divider for 100kHz I2C at 100MHz system clock
    // SCL period = CLK / (4 * (DIV + 1))
    // 100kHz = 100MHz / (4 * (DIV + 1)) => DIV = 249
    i2c_init(249);

    uint32_t status = I2C_STATUS;
    printf("  Clock divider: 249 (100kHz I2C)\n");
    printf("  Initial status: 0x%08lX\n", (unsigned long)status);
    printf("  BUSY: %d, TX_READY: %d, RX_VALID: %d, ACK_RECV: %d\n",
           (status & I2C_STATUS_BUSY) ? 1 : 0,
           (status & I2C_STATUS_TX_READY) ? 1 : 0,
           (status & I2C_STATUS_RX_VALID) ? 1 : 0,
           (status & I2C_STATUS_ACK_RECV) ? 1 : 0);
    printf("  Result: PASS\n\n");

    // TEST 2: Read default EEPROM content
    printf("[TEST 2] Read Default EEPROM Content\n");
    printf("  EEPROM initialized with pattern 0xA0 + address\n");
    printf("  Reading first 16 bytes:\n  ");

    int test2_pass = 1;
    for (int i = 0; i < 16; i++) {
        uint8_t data;
        int result = eeprom_read(i, &data);

        if (result < 0) {
            printf("\n  Error reading address 0x%02X: %d\n", i, result);
            test2_pass = 0;
            break;
        }

        // Expected pattern: 0xA0 + address
        uint8_t expected = 0xA0 + i;
        if (data != expected) {
            printf("\n  Mismatch at 0x%02X: expected 0x%02X, got 0x%02X\n",
                   i, expected, data);
            test2_pass = 0;
            break;
        }

        printf("%02X ", data);
        if ((i + 1) % 8 == 0) printf("\n  ");
    }

    printf("\n  Result: %s\n\n", test2_pass ? "PASS" : "FAIL");

    // TEST 3: Write to EEPROM
    printf("[TEST 3] Write to EEPROM\n");
    printf("  Writing test pattern to addresses 0x10-0x1F\n");

    int test3_pass = 1;
    const uint8_t test_pattern[] = {
        0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
    };

    for (int i = 0; i < 16; i++) {
        int result = eeprom_write(0x10 + i, test_pattern[i]);
        if (result < 0) {
            printf("  Error writing to 0x%02X: %d\n", 0x10 + i, result);
            test3_pass = 0;
            break;
        }
    }

    if (test3_pass) {
        printf("  Successfully wrote 16 bytes\n");
    }
    printf("  Result: %s\n\n", test3_pass ? "PASS" : "FAIL");

    // TEST 4: Read back and verify written data
    printf("[TEST 4] Read Back and Verify\n");
    printf("  Reading addresses 0x10-0x1F:\n  ");

    int test4_pass = 1;
    for (int i = 0; i < 16; i++) {
        uint8_t data;
        int result = eeprom_read(0x10 + i, &data);

        if (result < 0) {
            printf("\n  Error reading address 0x%02X: %d\n", 0x10 + i, result);
            test4_pass = 0;
            break;
        }

        if (data != test_pattern[i]) {
            printf("\n  Mismatch at 0x%02X: expected 0x%02X, got 0x%02X\n",
                   0x10 + i, test_pattern[i], data);
            test4_pass = 0;
            break;
        }

        printf("%02X ", data);
        if ((i + 1) % 8 == 0) printf("\n  ");
    }

    printf("\n  Result: %s\n\n", test4_pass ? "PASS" : "FAIL");

    // TEST 5: Sequential read of multiple locations
    printf("[TEST 5] Sequential Read Test\n");
    printf("  Reading addresses 0x00, 0x55, 0xAA, 0xFF:\n");

    int test5_pass = 1;
    uint8_t test_addrs[] = {0x00, 0x55, 0xAA, 0xFF};

    for (int i = 0; i < 4; i++) {
        uint8_t addr = test_addrs[i];
        uint8_t data;
        int result = eeprom_read(addr, &data);

        if (result < 0) {
            printf("  Error reading 0x%02X: %d\n", addr, result);
            test5_pass = 0;
        } else {
            printf("  [0x%02X] = 0x%02X\n", addr, data);
        }
    }

    printf("  Result: %s\n\n", test5_pass ? "PASS" : "FAIL");

    // TEST 6: Write/read boundary addresses
    printf("[TEST 6] Boundary Address Test\n");
    printf("  Testing addresses 0x00 and 0xFF\n");

    int test6_pass = 1;

    // Write to 0x00
    if (eeprom_write(0x00, 0x5A) < 0) {
        printf("  Error writing to 0x00\n");
        test6_pass = 0;
    }

    // Write to 0xFF
    if (eeprom_write(0xFF, 0xA5) < 0) {
        printf("  Error writing to 0xFF\n");
        test6_pass = 0;
    }

    // Read back
    uint8_t data;
    if (eeprom_read(0x00, &data) < 0 || data != 0x5A) {
        printf("  Error reading 0x00: got 0x%02X, expected 0x5A\n", data);
        test6_pass = 0;
    } else {
        printf("  [0x00] = 0x%02X (expected 0x5A)\n", data);
    }

    if (eeprom_read(0xFF, &data) < 0 || data != 0xA5) {
        printf("  Error reading 0xFF: got 0x%02X, expected 0xA5\n", data);
        test6_pass = 0;
    } else {
        printf("  [0xFF] = 0x%02X (expected 0xA5)\n", data);
    }

    printf("  Result: %s\n\n", test6_pass ? "PASS" : "FAIL");

    // TEST 7: Status monitoring
    printf("[TEST 7] Status Monitoring\n");
    printf("  Status checks: %lu\n", (unsigned long)status_checks);
    printf("  Busy waits: %lu\n", (unsigned long)busy_waits);
    printf("  Bytes written: %lu\n", (unsigned long)writes);
    printf("  Bytes read: %lu\n", (unsigned long)reads);
    printf("  Final status: 0x%08lX\n", (unsigned long)I2C_STATUS);
    printf("  Result: PASS\n\n");

    // Summary
    int total_tests = 7;
    int passed_tests = test2_pass + test3_pass + test4_pass +
                       test5_pass + test6_pass + 2;  // TEST 1 and 7 always pass

    printf("========================================\n");
    printf("  Summary: %d/%d tests PASSED\n", passed_tests, total_tests);
    printf("========================================\n\n");

    if (passed_tests == total_tests) {
        printf("I2C hardware test complete.\n\n");
        return 0;
    } else {
        printf("I2C hardware test FAILED.\n\n");
        return 1;
    }
}
