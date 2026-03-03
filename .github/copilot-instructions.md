Makefile Examples:

  make rtl-hello    # Run hello test with RTL
  make sim-uart     # Run uart test with software sim
  make clean        # Clean all build files

Debug Options:
  make DEBUG=1 rtl-simple  # Enable basic debug messages (rebuilds RTL)
  make DEBUG=2 rtl-simple  # Enable verbose debug messages (rebuilds RTL)
  make TRACE=1 rtl-simple  # Enable instruction trace
  make WAVE=1 rtl-simple   # Enable waveform dump

Debugging RTL:
  The software simulator (kv32sim) is the golden reference implementation.
  To debug RTL issues, compare instruction traces:

  1. Run RTL and software simulator and compare the traces:
     make compare-<test>
  2. For detailed RTL internal behavior (state machines, AXI transactions):
     make DEBUG=2 rtl-<test>   # Enables verbose debug output for all groups
     make DEBUG=2 DEBUG_GROUP=<mask> rtl-<test>   # Filter to specific groups only

     DEBUG_GROUP is a 32-bit bitmask selecting which debug groups to display.
     Default is 0xFFFFFFFF (all groups). Each bit corresponds to one group:

       Bit  0  (0x00001)  FETCH   — Instruction fetch, PC tracking, IB
       Bit  1  (0x00002)  PIPE    — Pipeline stalls and stage flushes
       Bit  2  (0x00004)  EX      — Execute stage (ALU, branch, forward)
       Bit  3  (0x00008)  MEM     — Memory stage (load/store, AMO, LR/SC)
       Bit  4  (0x00010)  CSR     — CSR read/write
       Bit  5  (0x00020)  IRQ     — Interrupts and exceptions
       Bit  6  (0x00040)  WFI     — WFI / power management
       Bit  7  (0x00080)  AXI     — AXI bus transactions (core side)
       Bit  8  (0x00100)  REG     — Register file write-back and forwarding
       Bit  9  (0x00200)  JTAG    — JTAG / DTM / debug module
       Bit 10  (0x00400)  CLINT   — CLINT timer/software interrupt
       Bit 11  (0x00800)  GPIO    — GPIO peripheral
       Bit 12  (0x01000)  I2C     — I2C peripheral
       Bit 13  (0x02000)  ICACHE  — I-Cache state machine
       Bit 14  (0x04000)  ALU     — ALU operations
       Bit 15  (0x08000)  SB      — Store buffer
       Bit 16  (0x10000)  AXIMEM  — AXI memory slave (testbench)

     Examples:
       make DEBUG=2 DEBUG_GROUP=0x40    rtl-wfi    # WFI only
       make DEBUG=2 DEBUG_GROUP=0x60    rtl-wfi    # WFI + IRQ
       make DEBUG=2 DEBUG_GROUP=0x10000 rtl-hello  # AXI memory slave only
       make DEBUG=2 DEBUG_GROUP=0x10060 rtl-wfi    # WFI + IRQ + AXI memory slave
       make DEBUG=2 DEBUG_GROUP=0x400   rtl-timer  # CLINT only
  3. Add custom debug messages in RTL when needed:
     - `ifdef DEBUG_LEVEL_1 for critical debug messages (exceptions, branches, etc.), use `DEBUG1 macro for these messages
     - `ifdef DEBUG_LEVEL_2 for verbose debug messages (pipeline details, state machines), use `DEBUG2(grp, msg) macro for these messages
     - Use `ifdef DEBUG for either level of debug messages
     - DEBUG_LEVEL_2 automatically includes all DEBUG_LEVEL_1 messages
     - DEBUG2 takes a group bit index (e.g. `DBG_GRP_WFI) as first argument; the
       message is only printed when that group's bit is set in DEBUG_GROUP
     Example:
        `DEBUG1(("[DEBUG] Exception @ PC=0x%h", pc));
        `DEBUG2(`DBG_GRP_WFI,   ("[WFI] wfi_stall=%b irq_pending=%b", wfi_stall, irq_pending));
        `DEBUG2(`DBG_GRP_FETCH, ("[FETCH] pc=0x%h outstanding=%0d", pc, outstanding));
        `ifdef DEBUG
        // Some debug code that runs when either DEBUG_LEVEL_1 or DEBUG_LEVEL_2 is enabled
        `endif
  4. Fix warnings and errors in the RTL code, as they can cause simulation issues.
  5. Use waveform dumps (make WAVE=1 rtl-<test>) to visually inspect signal behavior in GTKWave.
  6. Use assertions in the RTL code to catch invalid states and conditions early:
     - Use `assert to check for expected conditions (e.g., valid instruction, correct state transitions)
     - Assertions can help identify the root cause of issues by providing immediate feedback when an invariant is violated.
