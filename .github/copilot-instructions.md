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
  The software simulator (rv32sim) is the golden reference implementation.
  To debug RTL issues, compare instruction traces:

  1. Run RTL and software simulator and compare the traces:
     make compare-<test>
  2. For detailed RTL internal behavior (state machines, AXI transactions):
     make DEBUG=2 rtl-<test>   # Enables verbose debug output
  3. Add custom debug messages in RTL when needed:
     - `ifdef DEBUG_LEVEL_1 for critical debug messages (exceptions, branches, etc.), use `DBG1 macro for these messages
     - `ifdef DEBUG_LEVEL_2 for verbose debug messages (pipeline details, state machines), use `DBG2 macro for these messages
     - Use `ifdef DEBUG for either level of debug messages
     - DEBUG_LEVEL_2 automatically includes all DEBUG_LEVEL_1 messages
     Example:
        `DBG1("[DEBUG] Exception @ PC=0x%h", pc);
        `DBG2("[DEBUG] Pipeline: state=%d data=0x%h", state, data);
        `ifdef DEBUG
        // Some debug code that runs when either DEBUG_LEVEL_1 or DEBUG_LEVEL_2 is enabled
        `endif
  4. Fix warnings and errors in the RTL code, as they can cause simulation issues.
  5. Use waveform dumps (make WAVE=1 rtl-<test>) to visually inspect signal behavior in GTKWave.
  6. Use assertions in the RTL code to catch invalid states and conditions early:
     - Use `assert to check for expected conditions (e.g., valid instruction, correct state transitions)
     - Assertions can help identify the root cause of issues by providing immediate feedback when an invariant is violated.
