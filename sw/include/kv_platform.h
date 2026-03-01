// ============================================================================
// File: kv_platform.h
// Project: KV32 RISC-V Processor
// Description: KV32 SoC memory map and peripheral register definitions
//
// Base addresses, register offsets, and bit-field constants for every
// peripheral in kv32_soc.sv.  Included by all peripheral drivers.
// ============================================================================

#ifndef KV_PLATFORM_H
#define KV_PLATFORM_H

#include <stdint.h>

/* ═══════════════════════════════════════════════════════════════════
 * System memory
 * ══════════════════════════════════════════════════════════════════ */
#define KV_ROM_BASE         0x00000000UL  /* Boot ROM                  */
#define KV_ROM_SIZE         0x00010000UL  /* 64 KB                     */
#define KV_RAM_BASE         0x80000000UL  /* Main SRAM                 */
#define KV_RAM_SIZE         0x00200000UL  /* 2 MB                      */

/* ═══════════════════════════════════════════════════════════════════
 * Core-Local Interrupt Controller (CLINT)
 * ══════════════════════════════════════════════════════════════════ */
#define KV_CLINT_BASE       0x02000000UL
#define KV_CLINT_SIZE       0x00010000UL
#define KV_CLINT_MSIP_OFF           0x00000UL  /* Machine software IRQ  */
#define KV_CLINT_MTIMECMP_LO_OFF    0x04000UL  /* Timer compare lo      */
#define KV_CLINT_MTIMECMP_HI_OFF    0x04004UL  /* Timer compare hi      */
#define KV_CLINT_MTIME_LO_OFF       0x0BFF8UL  /* Current time lo       */
#define KV_CLINT_MTIME_HI_OFF       0x0BFFCUL  /* Current time hi       */

/* ═══════════════════════════════════════════════════════════════════
 * Platform-Level Interrupt Controller (PLIC)
 * ══════════════════════════════════════════════════════════════════ */
#define KV_PLIC_BASE        0x0C000000UL
#define KV_PLIC_SIZE        0x04000000UL

/* PLIC register offsets (context 0 = hart 0, machine mode) */
#define KV_PLIC_PRIORITY_OFF    0x000000UL  /* Source priority[n] = base + n*4 */
#define KV_PLIC_PENDING_OFF     0x001000UL  /* Pending bits (one per source)   */
#define KV_PLIC_ENABLE_OFF      0x002000UL  /* Enable bits for context 0       */
#define KV_PLIC_THRESHOLD_OFF   0x200000UL  /* Priority threshold, context 0   */
#define KV_PLIC_CLAIM_OFF       0x200004UL  /* Claim / complete, context 0     */

/* PLIC IRQ source IDs (wired in kv32_soc.sv) */
#define KV_PLIC_SRC_UART    1
#define KV_PLIC_SRC_SPI     2
#define KV_PLIC_SRC_I2C     3
#define KV_PLIC_SRC_DMA     4
#define KV_PLIC_SRC_GPIO    5
#define KV_PLIC_SRC_TIMER   6

/* ═══════════════════════════════════════════════════════════════════
 * UART  (0x2000_0000)
 * ══════════════════════════════════════════════════════════════════ */
#define KV_UART_BASE        0x20000000UL
#define KV_UART_SIZE        0x00010000UL

/* Register offsets */
#define KV_UART_DATA_OFF    0x00UL  /* RX (read) / TX (write)           */
#define KV_UART_STATUS_OFF  0x04UL  /* Status flags                     */
#define KV_UART_IE_OFF      0x08UL  /* Interrupt Enable                 */
#define KV_UART_IS_OFF      0x0CUL  /* Interrupt Status (W1C)           */
#define KV_UART_LEVEL_OFF   0x10UL  /* Baud-rate divisor / FIFO level   */
#define KV_UART_CTRL_OFF    0x14UL  /* Control (loopback)               */
#define KV_UART_CAP_OFF     0x18UL  /* Capability register (read-only)  */
                                    /* [7:0] = TX_FIFO_DEPTH            */
                                    /* [15:8] = RX_FIFO_DEPTH           */
                                    /* [31:16] = VERSION (0x0001)       */

/* STATUS bits */
#define KV_UART_ST_TX_BUSY  (1u << 0)  /* TX FIFO full – cannot write   */
#define KV_UART_ST_TX_FULL  (1u << 1)  /* TX FIFO full (alias)          */
#define KV_UART_ST_RX_READY (1u << 2)  /* RX data available             */
#define KV_UART_ST_RX_FULL  (1u << 3)  /* RX FIFO full                  */

/* IE / IS bits  (RTL: is_wire[0]=!rxf_empty, is_wire[1]=txf_empty) */
#define KV_UART_IE_RX_READY (1u << 0)  /* RX not-empty interrupt        */
#define KV_UART_IE_TX_EMPTY (1u << 1)  /* TX FIFO drained interrupt     */

/* CTRL bits */
#define KV_UART_CTRL_LOOPBACK (1u << 0) /* Internal TX→RX loopback       */

/* ═══════════════════════════════════════════════════════════════════
 * I2C master  (0x2001_0000)
 * ══════════════════════════════════════════════════════════════════ */
#define KV_I2C_BASE         0x20010000UL
#define KV_I2C_SIZE         0x00010000UL

/* Register offsets */
#define KV_I2C_CTRL_OFF     0x00UL
#define KV_I2C_DIV_OFF      0x04UL
#define KV_I2C_TX_OFF       0x08UL
#define KV_I2C_RX_OFF       0x0CUL
#define KV_I2C_STATUS_OFF   0x10UL
#define KV_I2C_IE_OFF       0x14UL
#define KV_I2C_IS_OFF       0x18UL
#define KV_I2C_CAP_OFF      0x1CUL  /* Capability register (read-only)  */
                                    /* [7:0] = TX_FIFO_DEPTH            */
                                    /* [15:8] = RX_FIFO_DEPTH           */
                                    /* [31:16] = VERSION (0x0001)       */

/* CTRL bits */
#define KV_I2C_CTRL_ENABLE  (1u << 0)  /* Enable controller             */
#define KV_I2C_CTRL_START   (1u << 1)  /* Issue START condition         */
#define KV_I2C_CTRL_STOP    (1u << 2)  /* Issue STOP condition          */
#define KV_I2C_CTRL_READ    (1u << 3)  /* Read byte (vs write)          */
#define KV_I2C_CTRL_NACK    (1u << 4)  /* Send NACK after read byte     */

/* STATUS bits */
#define KV_I2C_ST_BUSY      (1u << 0)  /* Transfer in progress          */
#define KV_I2C_ST_TX_READY  (1u << 1)  /* Can accept new TX data        */
#define KV_I2C_ST_RX_VALID  (1u << 2)  /* Received byte available       */
#define KV_I2C_ST_ACK_RECV  (1u << 3)  /* Slave ACKed last byte         */

/* IE / IS bits  (RTL: is[0]=!rxf_empty, is[1]=txf_empty, is[2]=stop_done) */
#define KV_I2C_IE_RX_READY  (1u << 0)  /* RX FIFO not-empty interrupt   */
#define KV_I2C_IE_TX_EMPTY  (1u << 1)  /* TX FIFO drained interrupt     */
#define KV_I2C_IE_STOP_DONE (1u << 2)  /* STOP condition completed      */

/* ═══════════════════════════════════════════════════════════════════
 * SPI master  (0x2002_0000)
 * ══════════════════════════════════════════════════════════════════ */
#define KV_SPI_BASE         0x20020000UL
#define KV_SPI_SIZE         0x00010000UL

/* Register offsets */
#define KV_SPI_CTRL_OFF     0x00UL
#define KV_SPI_DIV_OFF      0x04UL
#define KV_SPI_TX_OFF       0x08UL  /* Write-only TX FIFO push         */
#define KV_SPI_RX_OFF       0x0CUL  /* Read-only  RX FIFO pop          */
#define KV_SPI_STATUS_OFF   0x10UL
#define KV_SPI_IE_OFF       0x14UL
#define KV_SPI_IS_OFF       0x18UL
#define KV_SPI_CAP_OFF      0x1CUL  /* Capability register (read-only)  */
                                    /* [7:0] = TX_FIFO_DEPTH            */
                                    /* [15:8] = RX_FIFO_DEPTH           */
                                    /* [23:16] = NUM_CS (chip selects)  */
                                    /* [31:24] = VERSION (0x01)         */

/* CTRL bits */
#define KV_SPI_CTRL_ENABLE    (1u << 0)  /* Enable controller            */
#define KV_SPI_CTRL_CPOL      (1u << 1)  /* Clock idle polarity          */
#define KV_SPI_CTRL_CPHA      (1u << 2)  /* Clock phase                  */
#define KV_SPI_CTRL_LOOPBACK  (1u << 3)  /* Internal MOSI→MISO loopback  */
#define KV_SPI_CTRL_CS_ALL    (0xFu << 4)           /* All CS high (idle)*/
#define KV_SPI_CTRL_CS_BIT(n) (1u << (4u + (n)))  /* CS[n] bit         */

/* MODE shortcuts */
#define KV_SPI_MODE0   0u  /* CPOL=0 CPHA=0 */
#define KV_SPI_MODE1   1u  /* CPOL=0 CPHA=1 */
#define KV_SPI_MODE2   2u  /* CPOL=1 CPHA=0 */
#define KV_SPI_MODE3   3u  /* CPOL=1 CPHA=1 */

/* STATUS bits */
#define KV_SPI_ST_BUSY      (1u << 0)  /* Transfer in progress         */
#define KV_SPI_ST_TX_READY  (1u << 1)  /* TX FIFO not full             */
#define KV_SPI_ST_RX_VALID  (1u << 2)  /* RX byte available            */
#define KV_SPI_ST_TX_EMPTY  (1u << 3)  /* TX FIFO empty                */
#define KV_SPI_ST_RX_FULL   (1u << 4)  /* RX FIFO full                 */

/* IE / IS bits  (RTL: is[0]=!rxf_empty, is[1]=txf_empty) */
#define KV_SPI_IE_RX_READY  (1u << 0)  /* RX FIFO not-empty interrupt   */
#define KV_SPI_IE_TX_EMPTY  (1u << 1)  /* TX FIFO drained interrupt     */

/* ═══════════════════════════════════════════════════════════════════
 * DMA controller  (0x2003_0000, 4 KB)
 * ═══════════════════════════════════════════════════════════════════
 *
 * Up to 8 independent channels.  Per-channel registers are at
 *   DMA_BASE + channel * 0x40.  Global registers at DMA_BASE + 0xF00.
 */
#define KV_DMA_BASE              0x20030000UL
#define KV_DMA_SIZE              0x00001000UL
#define KV_PLIC_SRC_DMA          4  /* PLIC interrupt source number */

/* Per-channel register offsets (relative to KV_DMA_BASE + ch*0x40) */
#define KV_DMA_CH_STRIDE         0x40UL
#define KV_DMA_CH_CTRL_OFF       0x00UL
#define KV_DMA_CH_STAT_OFF       0x04UL
#define KV_DMA_CH_SRC_OFF        0x08UL
#define KV_DMA_CH_DST_OFF        0x0CUL
#define KV_DMA_CH_XFER_OFF       0x10UL
#define KV_DMA_CH_SSTRIDE_OFF    0x14UL
#define KV_DMA_CH_DSTRIDE_OFF    0x18UL
#define KV_DMA_CH_ROWCNT_OFF     0x1CUL
#define KV_DMA_CH_SPSTRIDE_OFF   0x20UL
#define KV_DMA_CH_DPSTRIDE_OFF   0x24UL
#define KV_DMA_CH_PLANECNT_OFF   0x28UL
#define KV_DMA_CH_SGADDR_OFF     0x2CUL
#define KV_DMA_CH_SGCNT_OFF      0x30UL

/* Global register offsets */
#define KV_DMA_IRQ_STAT_OFF      0xF00UL  /* Channel done/err flags (W1C) */
#define KV_DMA_IRQ_EN_OFF        0xF04UL  /* Per-channel IRQ global enable */
#define KV_DMA_ID_OFF            0xF08UL  /* ID register: 0xD4A00100 (RO) */
#define KV_DMA_CAP_OFF           0xF0CUL  /* Capability register (read-only) */
                                          /* [7:0] = NUM_CHANNELS */
                                          /* [15:8] = MAX_BURST_LEN */
                                          /* [31:16] = VERSION (0x0001) */

/* Performance counter register offsets (global, BASE + offset) */
#define KV_DMA_PERF_CTRL_OFF     0xF10UL  /* [0]=enable; write [1]=1 to reset all */
#define KV_DMA_PERF_CYCLES_OFF   0xF14UL  /* cycles elapsed while CTRL[0]=1       */
#define KV_DMA_PERF_RD_BYTES_OFF 0xF18UL  /* DMA read bytes (S_RD_DATA × BPB)     */
#define KV_DMA_PERF_WR_BYTES_OFF 0xF1CUL  /* DMA write bytes (W-channel × BPB)    */

/* CTRL register bits */
#define KV_DMA_CTRL_EN           (1u << 0)  /* Enable channel */
#define KV_DMA_CTRL_START        (1u << 1)  /* Arm transfer (auto-clears) */
#define KV_DMA_CTRL_STOP         (1u << 2)  /* Abort transfer (auto-clears) */
#define KV_DMA_CTRL_MODE_1D      (0u << 3)  /* 1-D flat transfer */
#define KV_DMA_CTRL_MODE_2D      (1u << 3)  /* 2-D strided transfer */
#define KV_DMA_CTRL_MODE_3D      (2u << 3)  /* 3-D planar transfer */
#define KV_DMA_CTRL_MODE_SG      (3u << 3)  /* Scatter-Gather */
#define KV_DMA_CTRL_SRC_INC      (1u << 5)  /* Increment source address */
#define KV_DMA_CTRL_DST_INC      (1u << 6)  /* Increment destination address */
#define KV_DMA_CTRL_IE           (1u << 7)  /* Interrupt enable for channel */

/* STAT register bits */
#define KV_DMA_STAT_BUSY         (1u << 0)  /* Transfer in progress (RO) */
#define KV_DMA_STAT_DONE         (1u << 1)  /* Transfer complete (W1C)   */
#define KV_DMA_STAT_ERR          (1u << 2)  /* AXI error (W1C)           */

/* Convenience accessors */
#define KV_DMA_CH_REG(ch, off) \
    KV_REG32(KV_DMA_BASE, (ch) * KV_DMA_CH_STRIDE + (off))
#define KV_DMA_GLB_REG(off)    KV_REG32(KV_DMA_BASE, (off))

/* ═══════════════════════════════════════════════════════════════════
 * GPIO  (0x2004_0000, 64 KB)
 * ══════════════════════════════════════════════════════════════════ */
#define KV_GPIO_BASE              0x20040000UL
#define KV_GPIO_SIZE              0x00010000UL

/* Register offsets (per bank: 0-3, each bank controls 32 pins) */
#define KV_GPIO_DATA_OUT0_OFF     0x00UL
#define KV_GPIO_DATA_OUT1_OFF     0x04UL
#define KV_GPIO_DATA_OUT2_OFF     0x08UL
#define KV_GPIO_DATA_OUT3_OFF     0x0CUL

#define KV_GPIO_SET0_OFF          0x10UL  /* Write-1-to-set */
#define KV_GPIO_SET1_OFF          0x14UL
#define KV_GPIO_SET2_OFF          0x18UL
#define KV_GPIO_SET3_OFF          0x1CUL

#define KV_GPIO_CLEAR0_OFF        0x20UL  /* Write-1-to-clear */
#define KV_GPIO_CLEAR1_OFF        0x24UL
#define KV_GPIO_CLEAR2_OFF        0x28UL
#define KV_GPIO_CLEAR3_OFF        0x2CUL

#define KV_GPIO_DATA_IN0_OFF      0x30UL  /* Read-only input data */
#define KV_GPIO_DATA_IN1_OFF      0x34UL
#define KV_GPIO_DATA_IN2_OFF      0x38UL
#define KV_GPIO_DATA_IN3_OFF      0x3CUL

#define KV_GPIO_DIR0_OFF          0x40UL  /* Direction: 1=output, 0=input */
#define KV_GPIO_DIR1_OFF          0x44UL
#define KV_GPIO_DIR2_OFF          0x48UL
#define KV_GPIO_DIR3_OFF          0x4CUL

#define KV_GPIO_IE0_OFF           0x50UL  /* Interrupt enable */
#define KV_GPIO_IE1_OFF           0x54UL
#define KV_GPIO_IE2_OFF           0x58UL
#define KV_GPIO_IE3_OFF           0x5CUL

#define KV_GPIO_TRIGGER0_OFF      0x60UL  /* 1=edge, 0=level */
#define KV_GPIO_TRIGGER1_OFF      0x64UL
#define KV_GPIO_TRIGGER2_OFF      0x68UL
#define KV_GPIO_TRIGGER3_OFF      0x6CUL

#define KV_GPIO_POLARITY0_OFF     0x70UL  /* edge: 1=rising, 0=falling; level: 1=high, 0=low */
#define KV_GPIO_POLARITY1_OFF     0x74UL
#define KV_GPIO_POLARITY2_OFF     0x78UL
#define KV_GPIO_POLARITY3_OFF     0x7CUL

#define KV_GPIO_IS0_OFF           0x80UL  /* Interrupt status (W1C) */
#define KV_GPIO_IS1_OFF           0x84UL
#define KV_GPIO_IS2_OFF           0x88UL
#define KV_GPIO_IS3_OFF           0x8CUL

#define KV_GPIO_LOOPBACK0_OFF     0x90UL  /* Loopback enable (1=loopback, 0=normal) */
#define KV_GPIO_LOOPBACK1_OFF     0x94UL
#define KV_GPIO_LOOPBACK2_OFF     0x98UL
#define KV_GPIO_LOOPBACK3_OFF     0x9CUL

#define KV_GPIO_CAP_OFF           0xA0UL  /* Read-only capability register */
                                          /* [7:0] = NUM_PINS (number of GPIO pins) */
                                          /* [15:8] = NUM_BANKS (number of register banks) */
                                          /* [31:16] = VERSION (0x0001) */

/* ═══════════════════════════════════════════════════════════════════
 * Timer/PWM  (0x2005_0000, 64 KB)
 * ══════════════════════════════════════════════════════════════════ */
#define KV_TIMER_BASE             0x20050000UL
#define KV_TIMER_SIZE             0x00010000UL

/* Per-channel register offsets (4 timers, channel stride = 0x20) */
#define KV_TIMER_CH_STRIDE        0x20UL
#define KV_TIMER_COUNT_OFF        0x00UL  /* Counter value (R/W) */
#define KV_TIMER_COMPARE1_OFF     0x04UL  /* Compare 1: interrupt / PWM rise */
#define KV_TIMER_COMPARE2_OFF     0x08UL  /* Compare 2: PWM fall + reload */
#define KV_TIMER_CTRL_OFF         0x0CUL  /* Control register */

/* Global interrupt registers */
#define KV_TIMER_INT_STATUS_OFF   0x80UL  /* Interrupt status (W1C) */
#define KV_TIMER_INT_ENABLE_OFF   0x84UL  /* Interrupt enable */
#define KV_TIMER_CAP_OFF          0x88UL  /* Capability register (read-only) */
                                          /* [7:0]  = COUNTER_WIDTH (bits)   */
                                          /* [15:8] = NUM_CHANNELS (timers)  */
                                          /* [31:16] = VERSION (0x0001) */

/* CTRL register bits */
#define KV_TIMER_CTRL_EN_BIT      0       /* [0]: Timer enable */
#define KV_TIMER_CTRL_PWM_EN_BIT  1       /* [1]: PWM mode */
#define KV_TIMER_CTRL_INT_EN_BIT  3       /* [3]: Interrupt enable */
#define KV_TIMER_CTRL_PWM_POL_BIT 4       /* [4]: PWM polarity */
/* [31:16]: Prescaler value */

/* ═══════════════════════════════════════════════════════════════════
 * Register accessor macro  (firmware only; not used by simulator)
 * ══════════════════════════════════════════════════════════════════ */
#define KV_REG32(base, off) \
    (*(volatile uint32_t *)((uintptr_t)(base) + (uintptr_t)(off)))

/* ═══════════════════════════════════════════════════════════════════
 * Magic device  (0xFFFF_0000)  –  simulator / RTL testbench only
 *
 * Two memory-mapped registers let bare-metal firmware communicate
 * with the host environment without a real peripheral:
 *
 *   KV_MAGIC_CONSOLE  (0xFFFFFFF4)  write low byte → host console
 *   KV_MAGIC_EXIT     (0xFFFFFFF0)  write exit code (tohost encoding)
 *
 * Exit encoding (matches HTIF/Spike tohost convention):
 *   pass (code 0): write 1
 *   fail (code N): write (N << 1) | 1
 * ══════════════════════════════════════════════════════════════════ */
#define KV_MAGIC_BASE           0xFFFF0000UL
#define KV_MAGIC_SIZE           0x00010000UL
#define KV_MAGIC_EXIT_OFF       0xFFF0UL  /* offset from KV_MAGIC_BASE  */
#define KV_MAGIC_CONSOLE_OFF    0xFFF4UL  /* offset from KV_MAGIC_BASE  */

/* Absolute addresses (derived; match RTL axi_magic.sv and kv32sim) */
#define KV_MAGIC_EXIT_ADDR      (KV_MAGIC_BASE + KV_MAGIC_EXIT_OFF)
#define KV_MAGIC_CONSOLE_ADDR   (KV_MAGIC_BASE + KV_MAGIC_CONSOLE_OFF)

/* Register accessors (firmware) */
#define KV_MAGIC_EXIT    KV_REG32(KV_MAGIC_BASE, KV_MAGIC_EXIT_OFF)
#define KV_MAGIC_CONSOLE KV_REG32(KV_MAGIC_BASE, KV_MAGIC_CONSOLE_OFF)

/* Inline API ------------------------------------------------------- */
/* Define KV_PLATFORM_NO_INLINE_HELPERS before including this file     *
 * to suppress the inline helpers that dereference volatile MMIO       *
 * addresses (useful when building host-side code such as Spike plugins). */
#ifndef KV_PLATFORM_NO_INLINE_HELPERS

/* Write one character to the simulator/testbench console. */
static inline void kv_magic_putc(char c)
{
    KV_MAGIC_CONSOLE = (uint32_t)(unsigned char)c;
}

/* Signal program exit to the simulator/testbench and spin forever.
 * Uses the HTIF tohost encoding so the host receives the correct
 * exit code regardless of whether HTIF or the magic address is used:
 *   code == 0  →  write 1        (PASS)
 *   code != 0  →  write (code<<1)|1  (FAIL, non-zero exit code) */
static inline void kv_magic_exit(int code)
{
    KV_MAGIC_EXIT = (code == 0) ? 1u : (((uint32_t)code << 1) | 1u);
    while (1) { __asm__ volatile ("nop"); }  /* halt; simulator stops here */
}

#endif /* KV_PLATFORM_NO_INLINE_HELPERS */

#endif /* KV_PLATFORM_H */
