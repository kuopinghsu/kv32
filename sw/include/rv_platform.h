/*
 * rv_platform.h – RV32 SoC memory map and peripheral register definitions
 *
 * Base addresses, register offsets, and bit-field constants for every
 * peripheral in rv32_soc.sv.  All drivers include this header.
 */
#ifndef RV_PLATFORM_H
#define RV_PLATFORM_H

#include <stdint.h>

/* ═══════════════════════════════════════════════════════════════════
 * System memory
 * ══════════════════════════════════════════════════════════════════ */
#define RV_ROM_BASE         0x00000000UL  /* Boot ROM                  */
#define RV_ROM_SIZE         0x00010000UL  /* 64 KB                     */
#define RV_RAM_BASE         0x80000000UL  /* Main SRAM                 */
#define RV_RAM_SIZE         0x00200000UL  /* 2 MB                      */

/* ═══════════════════════════════════════════════════════════════════
 * Core-Local Interrupt Controller (CLINT)
 * ══════════════════════════════════════════════════════════════════ */
#define RV_CLINT_BASE       0x02000000UL
#define RV_CLINT_SIZE       0x00010000UL
#define RV_CLINT_MSIP_OFF           0x00000UL  /* Machine software IRQ  */
#define RV_CLINT_MTIMECMP_LO_OFF    0x04000UL  /* Timer compare lo      */
#define RV_CLINT_MTIMECMP_HI_OFF    0x04004UL  /* Timer compare hi      */
#define RV_CLINT_MTIME_LO_OFF       0x0BFF8UL  /* Current time lo       */
#define RV_CLINT_MTIME_HI_OFF       0x0BFFCUL  /* Current time hi       */

/* ═══════════════════════════════════════════════════════════════════
 * Platform-Level Interrupt Controller (PLIC)
 * ══════════════════════════════════════════════════════════════════ */
#define RV_PLIC_BASE        0x0C000000UL
#define RV_PLIC_SIZE        0x04000000UL

/* PLIC register offsets (context 0 = hart 0, machine mode) */
#define RV_PLIC_PRIORITY_OFF    0x000000UL  /* Source priority[n] = base + n*4 */
#define RV_PLIC_PENDING_OFF     0x001000UL  /* Pending bits (one per source)   */
#define RV_PLIC_ENABLE_OFF      0x002000UL  /* Enable bits for context 0       */
#define RV_PLIC_THRESHOLD_OFF   0x200000UL  /* Priority threshold, context 0   */
#define RV_PLIC_CLAIM_OFF       0x200004UL  /* Claim / complete, context 0     */

/* PLIC IRQ source IDs (wired in rv32_soc.sv) */
#define RV_PLIC_SRC_UART    1
#define RV_PLIC_SRC_SPI     2
#define RV_PLIC_SRC_I2C     3

/* ═══════════════════════════════════════════════════════════════════
 * UART  (0x2000_0000)
 * ══════════════════════════════════════════════════════════════════ */
#define RV_UART_BASE        0x20000000UL
#define RV_UART_SIZE        0x00010000UL

/* Register offsets */
#define RV_UART_DATA_OFF    0x00UL  /* RX (read) / TX (write)           */
#define RV_UART_STATUS_OFF  0x04UL  /* Status flags                     */
#define RV_UART_IE_OFF      0x08UL  /* Interrupt Enable                 */
#define RV_UART_IS_OFF      0x0CUL  /* Interrupt Status (W1C)           */
#define RV_UART_LEVEL_OFF   0x10UL  /* Baud-rate divisor / FIFO level   */
#define RV_UART_CTRL_OFF    0x14UL  /* Control (loopback)               */

/* STATUS bits */
#define RV_UART_ST_TX_BUSY  (1u << 0)  /* TX FIFO full – cannot write   */
#define RV_UART_ST_TX_FULL  (1u << 1)  /* TX FIFO full (alias)          */
#define RV_UART_ST_RX_READY (1u << 2)  /* RX data available             */
#define RV_UART_ST_RX_FULL  (1u << 3)  /* RX FIFO full                  */

/* IE / IS bits  (RTL: is_wire[0]=!rxf_empty, is_wire[1]=txf_empty) */
#define RV_UART_IE_RX_READY (1u << 0)  /* RX not-empty interrupt        */
#define RV_UART_IE_TX_EMPTY (1u << 1)  /* TX FIFO drained interrupt     */

/* CTRL bits */
#define RV_UART_CTRL_LOOPBACK (1u << 0) /* Internal TX→RX loopback       */

/* ═══════════════════════════════════════════════════════════════════
 * I2C master  (0x2001_0000)
 * ══════════════════════════════════════════════════════════════════ */
#define RV_I2C_BASE         0x20010000UL
#define RV_I2C_SIZE         0x00010000UL

/* Register offsets */
#define RV_I2C_CTRL_OFF     0x00UL
#define RV_I2C_DIV_OFF      0x04UL
#define RV_I2C_TX_OFF       0x08UL
#define RV_I2C_RX_OFF       0x0CUL
#define RV_I2C_STATUS_OFF   0x10UL
#define RV_I2C_IE_OFF       0x14UL
#define RV_I2C_IS_OFF       0x18UL

/* CTRL bits */
#define RV_I2C_CTRL_ENABLE  (1u << 0)  /* Enable controller            */
#define RV_I2C_CTRL_START   (1u << 1)  /* Issue START condition         */
#define RV_I2C_CTRL_STOP    (1u << 2)  /* Issue STOP condition          */
#define RV_I2C_CTRL_READ    (1u << 3)  /* Read byte (vs write)          */
#define RV_I2C_CTRL_NACK    (1u << 4)  /* Send NACK after read byte     */

/* STATUS bits */
#define RV_I2C_ST_BUSY      (1u << 0)  /* Transfer in progress         */
#define RV_I2C_ST_TX_READY  (1u << 1)  /* Can accept new TX data        */
#define RV_I2C_ST_RX_VALID  (1u << 2)  /* Received byte available       */
#define RV_I2C_ST_ACK_RECV  (1u << 3)  /* Slave ACKed last byte         */

/* IE / IS bits  (RTL: is[0]=!rxf_empty, is[1]=txf_empty, is[2]=stop_done) */
#define RV_I2C_IE_RX_READY  (1u << 0)  /* RX FIFO not-empty interrupt   */
#define RV_I2C_IE_TX_EMPTY  (1u << 1)  /* TX FIFO drained interrupt     */
#define RV_I2C_IE_STOP_DONE (1u << 2)  /* STOP condition completed      */

/* ═══════════════════════════════════════════════════════════════════
 * SPI master  (0x2002_0000)
 * ══════════════════════════════════════════════════════════════════ */
#define RV_SPI_BASE         0x20020000UL
#define RV_SPI_SIZE         0x00010000UL

/* Register offsets */
#define RV_SPI_CTRL_OFF     0x00UL
#define RV_SPI_DIV_OFF      0x04UL
#define RV_SPI_TX_OFF       0x08UL  /* Write-only TX FIFO push         */
#define RV_SPI_RX_OFF       0x0CUL  /* Read-only  RX FIFO pop          */
#define RV_SPI_STATUS_OFF   0x10UL
#define RV_SPI_IE_OFF       0x14UL
#define RV_SPI_IS_OFF       0x18UL

/* CTRL bits */
#define RV_SPI_CTRL_ENABLE    (1u << 0)  /* Enable controller            */
#define RV_SPI_CTRL_CPOL      (1u << 1)  /* Clock idle polarity          */
#define RV_SPI_CTRL_CPHA      (1u << 2)  /* Clock phase                  */
#define RV_SPI_CTRL_LOOPBACK  (1u << 3)  /* Internal MOSI→MISO loopback  */
#define RV_SPI_CTRL_CS_ALL    (0xFu << 4)           /* All CS high (idle)*/
#define RV_SPI_CTRL_CS_BIT(n) (1u << (4u + (n)))  /* CS[n] bit         */

/* MODE shortcuts */
#define RV_SPI_MODE0   0u  /* CPOL=0 CPHA=0 */
#define RV_SPI_MODE1   1u  /* CPOL=0 CPHA=1 */
#define RV_SPI_MODE2   2u  /* CPOL=1 CPHA=0 */
#define RV_SPI_MODE3   3u  /* CPOL=1 CPHA=1 */

/* STATUS bits */
#define RV_SPI_ST_BUSY      (1u << 0)  /* Transfer in progress         */
#define RV_SPI_ST_TX_READY  (1u << 1)  /* TX FIFO not full             */
#define RV_SPI_ST_RX_VALID  (1u << 2)  /* RX byte available            */
#define RV_SPI_ST_TX_EMPTY  (1u << 3)  /* TX FIFO empty                */
#define RV_SPI_ST_RX_FULL   (1u << 4)  /* RX FIFO full                 */

/* IE / IS bits  (RTL: is[0]=!rxf_empty, is[1]=txf_empty) */
#define RV_SPI_IE_RX_READY  (1u << 0)  /* RX FIFO not-empty interrupt   */
#define RV_SPI_IE_TX_EMPTY  (1u << 1)  /* TX FIFO drained interrupt     */

/* ═══════════════════════════════════════════════════════════════════
 * Register accessor macro  (firmware only; not used by simulator)
 * ══════════════════════════════════════════════════════════════════ */
#define RV_REG32(base, off) \
    (*(volatile uint32_t *)((uintptr_t)(base) + (uintptr_t)(off)))

/* ═══════════════════════════════════════════════════════════════════
 * Magic device  (0xFFFF_0000)  –  simulator / RTL testbench only
 *
 * Two memory-mapped registers let bare-metal firmware communicate
 * with the host environment without a real peripheral:
 *
 *   RV_MAGIC_CONSOLE  (0xFFFFFFF4)  write low byte → host console
 *   RV_MAGIC_EXIT     (0xFFFFFFF0)  write exit code (tohost encoding)
 *
 * Exit encoding (matches HTIF/Spike tohost convention):
 *   pass (code 0): write 1
 *   fail (code N): write (N << 1) | 1
 * ══════════════════════════════════════════════════════════════════ */
#define RV_MAGIC_BASE           0xFFFF0000UL
#define RV_MAGIC_SIZE           0x00010000UL
#define RV_MAGIC_EXIT_OFF       0xFFF0UL  /* offset from RV_MAGIC_BASE  */
#define RV_MAGIC_CONSOLE_OFF    0xFFF4UL  /* offset from RV_MAGIC_BASE  */

/* Absolute addresses (derived; match RTL axi_magic.sv and rv32sim) */
#define RV_MAGIC_EXIT_ADDR      (RV_MAGIC_BASE + RV_MAGIC_EXIT_OFF)
#define RV_MAGIC_CONSOLE_ADDR   (RV_MAGIC_BASE + RV_MAGIC_CONSOLE_OFF)

/* Register accessors (firmware) */
#define RV_MAGIC_EXIT    RV_REG32(RV_MAGIC_BASE, RV_MAGIC_EXIT_OFF)
#define RV_MAGIC_CONSOLE RV_REG32(RV_MAGIC_BASE, RV_MAGIC_CONSOLE_OFF)

/* Inline API ------------------------------------------------------- */

/* Write one character to the simulator/testbench console. */
static inline void rv_magic_putc(char c)
{
    RV_MAGIC_CONSOLE = (uint32_t)(unsigned char)c;
}

/* Signal program exit to the simulator/testbench and spin forever.
 * Uses the HTIF tohost encoding so the host receives the correct
 * exit code regardless of whether HTIF or the magic address is used:
 *   code == 0  →  write 1        (PASS)
 *   code != 0  →  write (code<<1)|1  (FAIL, non-zero exit code) */
static inline void rv_magic_exit(int code)
{
    RV_MAGIC_EXIT = (code == 0) ? 1u : (((uint32_t)code << 1) | 1u);
    while (1) { __asm__ volatile ("nop"); }  /* halt; simulator stops here */
}

#endif /* RV_PLATFORM_H */
