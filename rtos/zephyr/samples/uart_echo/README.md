# UART Echo Test Sample

This sample demonstrates UART driver TX and RX functionality on the kcore board. It receives characters from UART RX and echoes them back via TX.

## Building and Running

```bash
make zephyr-uart_echo
```

## Testing in RTL Simulation

```bash
make zephyr-rtl-uart_echo
```

The sample will:
1. Initialize UART0 at 115200 baud (note: RTL uses 12.5 Mbaud internally)
2. Wait for incoming characters on UART RX
3. Echo each received character back via UART TX
4. Display received characters on console with hex values
5. Exit after receiving newline or 20 characters

## Configuration

The UART is configured via devicetree and uses:
- Base address: 0x10000000
- Clock: 50 MHz
- Baud rate: 12.5 Mbaud (RTL hardware, driver configured for 115200)
- Full-duplex TX/RX support

## Expected Output

The testbench sends "ABC\n" to the UART RX, and the sample echoes it back:
- Console shows: "Waiting for UART input...", "RX: 0x41 ('A')", "TX: 0x41 (echoed)"
- UART TX pin outputs the echoed characters
- Test completes when newline is received
