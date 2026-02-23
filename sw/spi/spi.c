// SPI Hardware Test - Tests SPI master controller at 0x02020000
// Tests SPI communication with simulated flash memory devices
// 4 flash memories (one per CS line), each 4KB initialized with pattern 0xF0 + CS number

#include <stdint.h>
#include <stdio.h>

// SPI peripheral registers
#define SPI_BASE     0x02020000
#define SPI_CTRL     (*((volatile uint32_t*)(SPI_BASE + 0x00)))
#define SPI_DIV      (*((volatile uint32_t*)(SPI_BASE + 0x04)))
#define SPI_TX       (*((volatile uint32_t*)(SPI_BASE + 0x08)))
#define SPI_RX       (*((volatile uint32_t*)(SPI_BASE + 0x0C)))
#define SPI_STATUS   (*((volatile uint32_t*)(SPI_BASE + 0x10)))

// Control register bits
#define SPI_CTRL_ENABLE   0x01  // Enable SPI controller
#define SPI_CTRL_CPOL     0x02  // Clock polarity (0=idle low, 1=idle high)
#define SPI_CTRL_CPHA     0x04  // Clock phase (0=sample on leading, 1=trailing)
#define SPI_CTRL_CS0      0x10  // Chip select 0 (active low in HW)
#define SPI_CTRL_CS1      0x20  // Chip select 1
#define SPI_CTRL_CS2      0x40  // Chip select 2
#define SPI_CTRL_CS3      0x80  // Chip select 3

// Status register bits
#define SPI_STATUS_BUSY      0x01  // Transfer in progress
#define SPI_STATUS_TX_READY  0x02  // Can accept new data
#define SPI_STATUS_RX_VALID  0x04  // Received data available

// Flash commands
#define FLASH_CMD_READ    0x03  // Read data
#define FLASH_CMD_WRITE   0x02  // Write data (not fully implemented in sim)
#define FLASH_CMD_RDID    0x9F  // Read ID

// Test statistics
static volatile uint32_t status_checks = 0;
static volatile uint32_t busy_waits = 0;
static volatile uint32_t transfers = 0;

// Helper functions
void spi_init(uint32_t clk_div, uint8_t mode) {
    uint32_t ctrl = SPI_CTRL_ENABLE;

    // Set clock polarity and phase based on SPI mode
    // Mode 0: CPOL=0, CPHA=0
    // Mode 1: CPOL=0, CPHA=1
    // Mode 2: CPOL=1, CPHA=0
    // Mode 3: CPOL=1, CPHA=1
    if (mode & 0x01) ctrl |= SPI_CTRL_CPHA;
    if (mode & 0x02) ctrl |= SPI_CTRL_CPOL;

    SPI_DIV = clk_div;
    SPI_CTRL = ctrl | 0xF0;  // All CS high (inactive)
    status_checks++;
}

void spi_wait_ready(void) {
    while (SPI_STATUS & SPI_STATUS_BUSY) {
        busy_waits++;
    }
    status_checks++;
}

void spi_cs_select(uint8_t cs) {
    // CS is active low, so clear the bit for the selected CS
    uint32_t ctrl = SPI_CTRL;
    ctrl |= 0xF0;  // Set all CS high first
    if (cs < 4) {
        ctrl &= ~(0x10 << cs);  // Clear the selected CS bit (make it low/active)
    }
    SPI_CTRL = ctrl;
}

void spi_cs_deselect(void) {
    uint32_t ctrl = SPI_CTRL;
    ctrl |= 0xF0;  // Set all CS high (inactive)
    SPI_CTRL = ctrl;
}

uint8_t spi_transfer(uint8_t data) {
    spi_wait_ready();
    SPI_TX = data;
    // Wait until the controller has accepted the TX data and gone busy,
    // then wait until the transfer is complete (BUSY clears).
    while (!(SPI_STATUS & SPI_STATUS_BUSY)) {
        busy_waits++;
    }
    while (SPI_STATUS & SPI_STATUS_BUSY) {
        busy_waits++;
    }
    transfers++;

    // Read received data
    uint8_t rx = (uint8_t)(SPI_RX & 0xFF);
    return rx;
}

// Flash read: CS_LOW + CMD(0x03) + ADDR + DATA... + CS_HIGH
int flash_read(uint8_t cs, uint8_t addr, uint8_t *buf, uint32_t len) {
    if (cs >= 4 || len == 0) return -1;

    spi_cs_select(cs);

    // Send read command
    spi_transfer(FLASH_CMD_READ);

    // Send address (1 byte for simplified flash)
    spi_transfer(addr);

    // Read data bytes
    for (uint32_t i = 0; i < len; i++) {
        buf[i] = spi_transfer(0xFF);  // Send dummy byte to clock out data
    }

    spi_cs_deselect();
    return 0;
}

// Test functions
int test1_init(void) {
    printf("\n[TEST 1] SPI Controller Initialization\n");

    // Initialize SPI: Mode 0 (CPOL=0, CPHA=0), 1MHz (div=49 at 100MHz)
    spi_init(49, 0);

    uint32_t ctrl = SPI_CTRL;
    uint32_t div = SPI_DIV;
    uint32_t status = SPI_STATUS;

    printf("  Control: 0x%02lX (ENABLE=%ld, CPOL=%ld, CPHA=%ld, CS=0x%lX)\n",
           (unsigned long)ctrl,
           (unsigned long)(ctrl & SPI_CTRL_ENABLE) ? 1UL : 0UL,
           (unsigned long)(ctrl & SPI_CTRL_CPOL) ? 1UL : 0UL,
           (unsigned long)(ctrl & SPI_CTRL_CPHA) ? 1UL : 0UL,
           (unsigned long)((ctrl >> 4) & 0xF));
    printf("  Clock divider: %lu (1MHz SPI)\n", (unsigned long)div);
    printf("  Initial status: 0x%02lX\n", (unsigned long)status);
    printf("  BUSY: %ld, TX_READY: %ld, RX_VALID: %ld\n",
           (unsigned long)(status & SPI_STATUS_BUSY) ? 1UL : 0UL,
           (unsigned long)(status & SPI_STATUS_TX_READY) ? 1UL : 0UL,
           (unsigned long)(status & SPI_STATUS_RX_VALID) ? 1UL : 0UL);

    if (!(ctrl & SPI_CTRL_ENABLE)) {
        printf("  Result: FAIL - Enable bit not set\n");
        return -1;
    }

    if (status & SPI_STATUS_BUSY) {
        printf("  Result: FAIL - Should not be busy\n");
        return -1;
    }

    printf("  Result: PASS\n");
    return 0;
}

int test2_read_flash0(void) {
    printf("\n[TEST 2] Read Default Flash 0 Content\n");
    printf("  Flash 0 initialized with address pattern\n");
    printf("  Reading first 16 bytes:\n");

    uint8_t buf[16];
    if (flash_read(0, 0x00, buf, 16) < 0) {
        printf("  Error reading flash\n");
        printf("  Result: FAIL\n");
        return -1;
    }

    printf("  Data: ");
    for (int i = 0; i < 16; i++) {
        printf("%02X ", buf[i]);
        if ((i + 1) % 8 == 0) printf("\n        ");
    }

    // Verify pattern (should be sequential: 00, 01, 02... based on address after flash read command)
    // After sending READ command (0x03) and address (0x00), we read sequential data
    // The testbench increments address after each read
    int errors = 0;
    for (int i = 0; i < 16; i++) {
        uint8_t expected = (i & 0xFF);
        if (buf[i] != expected) {
            printf("  Mismatch at offset %d: got 0x%02X, expected 0x%02X\n", i, buf[i], expected);
            errors++;
        }
    }

    if (errors > 0) {
        printf("  Result: FAIL\n");
        return -1;
    }

    printf("  Result: PASS\n");
    return 0;
}

int test3_read_multiple_cs(void) {
    printf("\n[TEST 3] Read from Multiple Flash Devices\n");
    printf("  Each flash initialized with address pattern\n");

    int errors = 0;
    for (uint8_t cs = 0; cs < 4; cs++) {
        uint8_t buf[4];

        if (flash_read(cs, 0x00, buf, 4) < 0) {
            printf("  Error reading flash CS%d\n", cs);
            errors++;
            continue;
        }

        printf("  CS%d: ", cs);
        for (int i = 0; i < 4; i++) {
            printf("%02X ", buf[i]);
        }

        // Verify pattern (addresses 0,1,2,3)
        int cs_errors = 0;
        for (int i = 0; i < 4; i++) {
            if (buf[i] != (uint8_t)i) {
                cs_errors++;
            }
        }

        if (cs_errors > 0) {
            printf("(FAIL - expected 00 01 02 03)\n");
            errors++;
        } else {
            printf("(PASS)\n");
        }
    }

    if (errors > 0) {
        printf("  Result: FAIL\n");
        return -1;
    }

    printf("  Result: PASS\n");
    return 0;
}

int test4_sequential_read(void) {
    printf("\n[TEST 4] Sequential Read from Flash 0\n");
    printf("  Reading addresses 0x00, 0x10, 0x20, 0x30:\n");

    uint8_t addrs[] = {0x00, 0x10, 0x20, 0x30};
    int errors = 0;

    for (int i = 0; i < 4; i++) {
        uint8_t buf[8];
        if (flash_read(0, addrs[i], buf, 8) < 0) {
            printf("  Error reading address 0x%02X\n", addrs[i]);
            errors++;
            continue;
        }

        printf("  [0x%02X]: ", addrs[i]);
        for (int j = 0; j < 8; j++) {
            printf("%02X ", buf[j]);
        }

        // Verify pattern (address+j)
        int addr_errors = 0;
        for (int j = 0; j < 8; j++) {
            uint8_t expected = (addrs[i] + j) & 0xFF;
            if (buf[j] != expected) {
                addr_errors++;
            }
        }

        if (addr_errors > 0) {
            printf("(FAIL)\n");
            errors++;
        } else {
            printf("(PASS)\n");
        }
    }

    if (errors > 0) {
        printf("  Result: FAIL\n");
        return -1;
    }

    printf("  Result: PASS\n");
    return 0;
}

int test5_single_byte_transfers(void) {
    printf("\n[TEST 5] Single Byte Transfer Test\n");
    printf("  Testing individual byte transfers with different data:\n");

    spi_cs_select(1);  // Select Flash 1

    uint8_t test_bytes[] = {0x00, 0x55, 0xAA, 0xFF};
    for (int i = 0; i < 4; i++) {
        uint8_t tx = test_bytes[i];
        uint8_t rx = spi_transfer(tx);
        printf("  TX: 0x%02X -> RX: 0x%02X\n", tx, rx);
    }

    spi_cs_deselect();

    printf("  Result: PASS\n");
    return 0;
}

int test6_mode_test(void) {
    printf("\n[TEST 6] SPI Mode Configuration Test\n");

    uint8_t modes[] = {0, 1, 2, 3};
    const char *mode_names[] = {"Mode 0 (CPOL=0,CPHA=0)",
                                 "Mode 1 (CPOL=0,CPHA=1)",
                                 "Mode 2 (CPOL=1,CPHA=0)",
                                 "Mode 3 (CPOL=1,CPHA=1)"};

    for (int i = 0; i < 4; i++) {
        spi_init(49, modes[i]);
        uint32_t ctrl = SPI_CTRL;

        uint8_t cpol = (ctrl & SPI_CTRL_CPOL) ? 1 : 0;
        uint8_t cpha = (ctrl & SPI_CTRL_CPHA) ? 1 : 0;

        printf("  %s: CPOL=%d, CPHA=%d ", mode_names[i], cpol, cpha);

        // Verify mode settings
        uint8_t expected_cpol = (modes[i] & 0x02) ? 1 : 0;
        uint8_t expected_cpha = (modes[i] & 0x01) ? 1 : 0;

        if (cpol == expected_cpol && cpha == expected_cpha) {
            printf("(PASS)\n");
        } else {
            printf("(FAIL)\n");
            return -1;
        }
    }

    // Restore default mode
    spi_init(49, 0);

    printf("  Result: PASS\n");
    return 0;
}

int test7_statistics(void) {
    printf("\n[TEST 7] Statistics Summary\n");
    printf("  Status checks: %lu\n", (unsigned long)status_checks);
    printf("  Busy waits: %lu\n", (unsigned long)busy_waits);
    printf("  SPI transfers: %lu\n", (unsigned long)transfers);
    printf("  Final status: 0x%02lX\n", (unsigned long)SPI_STATUS);

    printf("  Result: PASS\n");
    return 0;
}

int main(void) {
    printf("\n========================================\n");
    printf("  SPI Hardware Test (Master + Flash)\n");
    printf("  Base Address: 0x%08lX\n", (unsigned long)SPI_BASE);
    printf("  Flash: 4x 4KB devices @ CS0-CS3\n");
    printf("========================================\n");

    int passed = 0;
    int failed = 0;

    // Run all tests
    if (test1_init() == 0) passed++; else failed++;
    if (test2_read_flash0() == 0) passed++; else failed++;
    if (test3_read_multiple_cs() == 0) passed++; else failed++;
    if (test4_sequential_read() == 0) passed++; else failed++;
    if (test5_single_byte_transfers() == 0) passed++; else failed++;
    if (test6_mode_test() == 0) passed++; else failed++;
    if (test7_statistics() == 0) passed++; else failed++;

    printf("\n========================================\n");
    printf("  Summary: %d/%d tests PASSED\n", passed, passed + failed);
    printf("========================================\n");

    if (failed > 0) {
        printf("\nSPI hardware test FAILED.\n\n");
        return 1;
    } else {
        printf("\nSPI hardware test PASSED!\n\n");
        return 0;
    }
}
