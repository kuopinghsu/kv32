// ============================================================================
// File: axi_gpio.sv
// Project: KV32 RISC-V Processor
// Description: AXI4-Lite GPIO Peripheral with Configurable Pins and IRQ
//
// Memory-mapped GPIO with AXI4-Lite interface. Provides general-purpose
// input/output with configurable pin count (up to 128 pins).
//
// Register Map (relative to base 0x2004_0000):
//   0x00: DATA_OUT0    - GPIO output data [31:0] (read/write)
//   0x04: DATA_OUT1    - GPIO output data [63:32] (read/write)
//   0x08: DATA_OUT2    - GPIO output data [95:64] (read/write)
//   0x0C: DATA_OUT3    - GPIO output data [127:96] (read/write)
//   0x10: SET0         - GPIO output set [31:0] (write-1-to-set, read: current DATA_OUT)
//   0x14: SET1         - GPIO output set [63:32] (write-1-to-set)
//   0x18: SET2         - GPIO output set [95:64] (write-1-to-set)
//   0x1C: SET3         - GPIO output set [127:96] (write-1-to-set)
//   0x20: CLEAR0       - GPIO output clear [31:0] (write-1-to-clear, read: current DATA_OUT)
//   0x24: CLEAR1       - GPIO output clear [63:32] (write-1-to-clear)
//   0x28: CLEAR2       - GPIO output clear [95:64] (write-1-to-clear)
//   0x2C: CLEAR3       - GPIO output clear [127:96] (write-1-to-clear)
//   0x30: DATA_IN0     - GPIO input data [31:0] (read-only)
//   0x34: DATA_IN1     - GPIO input data [63:32] (read-only)
//   0x38: DATA_IN2     - GPIO input data [95:64] (read-only)
//   0x3C: DATA_IN3     - GPIO input data [127:96] (read-only)
//   0x40: DIR0         - GPIO direction [31:0] (1=output, 0=input)
//   0x44: DIR1         - GPIO direction [63:32]
//   0x48: DIR2         - GPIO direction [95:64]
//   0x4C: DIR3         - GPIO direction [127:96]
//   0x50: IE0          - Interrupt Enable [31:0]
//   0x54: IE1          - Interrupt Enable [63:32]
//   0x58: IE2          - Interrupt Enable [95:64]
//   0x5C: IE3          - Interrupt Enable [127:96]
//   0x60: TRIGGER0     - Trigger mode [31:0] (1=edge, 0=level)
//   0x64: TRIGGER1     - Trigger mode [63:32]
//   0x68: TRIGGER2     - Trigger mode [95:64]
//   0x6C: TRIGGER3     - Trigger mode [127:96]
//   0x70: POLARITY0    - Polarity [31:0] (edge: 1=rising, 0=falling; level: 1=high, 0=low)
//   0x74: POLARITY1    - Polarity [63:32]
//   0x78: POLARITY2    - Polarity [95:64]
//   0x7C: POLARITY3    - Polarity [127:96]
//   0x80: IS0          - Interrupt Status [31:0] (read: status, write-1-to-clear)
//   0x84: IS1          - Interrupt Status [63:32]
//   0x88: IS2          - Interrupt Status [95:64]
//   0x8C: IS3          - Interrupt Status [127:96]
//   0x90: LOOPBACK0    - Loopback enable [31:0] (1=loopback output to input, 0=normal)
//   0x94: LOOPBACK1    - Loopback enable [63:32]
//   0x98: LOOPBACK2    - Loopback enable [95:64]
//   0x9C: LOOPBACK3    - Loopback enable [127:96]
//
// Features:
//   - Configurable pin count (parameter NUM_PINS, default 4, max 128)
//   - Individual pin direction control (input/output)
//   - Edge and level triggered interrupts per pin
//   - PLIC-compatible IRQ output (asserted when any enabled interrupt fires)
//   - Atomic SET/CLEAR operations (write-1-to-set, write-1-to-clear)
//   - Loopback mode for software testing (routes outputs back to inputs internally)
//   - Register banks auto-generated based on NUM_PINS:
//     * NUM_PINS 1-32:   Only Bank 0 (registers 0x00-0x20)
//     * NUM_PINS 33-64:  Bank 0-1 (registers 0x00-0x21)
//     * NUM_PINS 65-96:  Bank 0-2 (registers 0x00-0x22)
//     * NUM_PINS 97-128: Bank 0-3 (registers 0x00-0x23)
//
// ============================================================================

module axi_gpio #(
    parameter int unsigned NUM_PINS = 4          // Number of GPIO pins (1-128)
)(
    input  logic        clk,
    input  logic        rst_n,

    // AXI4-Lite interface
    input  logic [31:0] axi_awaddr,
    input  logic        axi_awvalid,
    output logic        axi_awready,

    input  logic [31:0] axi_wdata,
    input  logic [3:0]  axi_wstrb,
    input  logic        axi_wvalid,
    output logic        axi_wready,

    output logic [1:0]  axi_bresp,
    output logic        axi_bvalid,
    input  logic        axi_bready,

    input  logic [31:0] axi_araddr,
    input  logic        axi_arvalid,
    output logic        axi_arready,

    output logic [31:0] axi_rdata,
    output logic [1:0]  axi_rresp,
    output logic        axi_rvalid,
    input  logic        axi_rready,

    // Interrupt output
    output logic        irq,

    // GPIO pins (tri-state control)
    output logic [NUM_PINS-1:0] gpio_o,      // Output data
    input  logic [NUM_PINS-1:0] gpio_i,      // Input data
    output logic [NUM_PINS-1:0] gpio_oe      // Output enable (1=output, 0=input)
);

    // ========================================================================
    // Parameter Calculations
    // ========================================================================
    // Determine how many 32-bit register banks are needed
    localparam int NUM_REG_BANKS = (NUM_PINS + 31) / 32;  // Ceiling division
    localparam int BANK_BITS      = $clog2(NUM_REG_BANKS > 1 ? NUM_REG_BANKS : 2);  // bits to address all banks

    // Capability register (read-only)
    localparam logic [15:0] GPIO_VERSION = 16'h0001;       // Version 0.1
    localparam logic [31:0] CAPABILITY_REG = {GPIO_VERSION, 8'(NUM_REG_BANKS), 8'(NUM_PINS)};

    // AXI address range checks
    // addr[7:4] = register-type select (0-9 per-bank, 0xA capability)
    // addr[3:2] = bank select (0..NUM_REG_BANKS-1)
    // Write: reg_sel 0-9, valid bank only (capability 0xA is read-only → SLVERR on write)
    // Read:  reg_sel 0-9 with valid bank, OR reg_sel 0xA (capability, bank-independent)
    wire wr_addr_valid = (axi_awaddr[7:4] <= 4'h9) &&
                         (axi_awaddr[3:2] < 2'(NUM_REG_BANKS));
    wire rd_addr_valid = (axi_araddr[7:4] == 4'hA) ||
                         ((axi_araddr[7:4] <= 4'h9) &&
                          (axi_araddr[3:2] < 2'(NUM_REG_BANKS)));

    // ========================================================================
    // Internal Registers (Per-Bank Arrays)
    // ========================================================================
    logic [31:0] data_out_r [NUM_REG_BANKS];       // Output data registers
    logic [31:0] dir_r      [NUM_REG_BANKS];       // Direction registers (1=output, 0=input)
    logic [31:0] ie_r       [NUM_REG_BANKS];       // Interrupt enable
    logic [31:0] trigger_r  [NUM_REG_BANKS];       // Trigger mode (1=edge, 0=level)
    logic [31:0] polarity_r [NUM_REG_BANKS];       // Polarity control
    logic [31:0] is_r       [NUM_REG_BANKS];       // Interrupt status (edge-triggered: sticky, level: live)
    logic [31:0] loopback_r [NUM_REG_BANKS];       // Loopback enable (1=loopback, 0=normal)

    // Input synchronization (2-stage for metastability)
    logic [31:0] gpio_i_sync1 [NUM_REG_BANKS];
    logic [31:0] gpio_i_sync2 [NUM_REG_BANKS];
    logic [31:0] gpio_i_prev  [NUM_REG_BANKS];     // Previous cycle input for edge detection

    // Extend gpio_i to register banks (unused pins = 0)
    logic [31:0] gpio_i_padded [NUM_REG_BANKS];

    // ========================================================================
    // Per-Bank Input Synchronization and Loopback (using generate)
    // ========================================================================
    genvar bank;
    generate
        for (bank = 0; bank < NUM_REG_BANKS; bank++) begin : gen_banks
            localparam int BANK_LOW  = bank * 32;
            localparam int BANK_HIGH = ((bank+1) * 32 <= NUM_PINS) ? (bank+1) * 32 - 1 : NUM_PINS - 1;
            localparam int BANK_PINS = BANK_HIGH - BANK_LOW + 1;

            // Pad gpio_i for this bank
            always_comb begin
                gpio_i_padded[bank] = {{(32-BANK_PINS){1'b0}}, gpio_i[BANK_HIGH:BANK_LOW]};
            end

            // Apply loopback and synchronize inputs
            logic [31:0] gpio_i_ext;
            always_comb begin
                for (int i = 0; i < 32; i++) begin
                    gpio_i_ext[i] = loopback_r[bank][i] ? data_out_r[bank][i] : gpio_i_padded[bank][i];
                end
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    gpio_i_sync1[bank] <= '0;
                    gpio_i_sync2[bank] <= '0;
                    gpio_i_prev[bank]  <= '0;
                end else begin
                    gpio_i_sync1[bank] <= gpio_i_ext;
                    gpio_i_sync2[bank] <= gpio_i_sync1[bank];
                    gpio_i_prev[bank]  <= gpio_i_sync2[bank];
                end
            end
        end
    endgenerate

    // ========================================================================
    // Per-Bank Interrupt Detection (using generate)
    // ========================================================================
    logic [31:0] edge_detected [NUM_REG_BANKS];
    logic [31:0] int_pending   [NUM_REG_BANKS];

    generate
        for (bank = 0; bank < NUM_REG_BANKS; bank++) begin : gen_interrupts
            // Edge detection
            always_comb begin
                for (int i = 0; i < 32; i++) begin
                    edge_detected[bank][i] = trigger_r[bank][i] && (polarity_r[bank][i] ?
                                                (gpio_i_sync2[bank][i] && !gpio_i_prev[bank][i]) :  // rising
                                                (!gpio_i_sync2[bank][i] && gpio_i_prev[bank][i]));  // falling
                end
            end

            // Interrupt pending: edge-triggered (sticky) or level-triggered (live)
            always_comb begin
                for (int i = 0; i < 32; i++) begin
                    if (trigger_r[bank][i]) begin
                        int_pending[bank][i] = is_r[bank][i];
                    end else begin
                        int_pending[bank][i] = (polarity_r[bank][i] ? gpio_i_sync2[bank][i] : !gpio_i_sync2[bank][i]);
                    end
                end
            end
        end
    endgenerate

    // IRQ output: any enabled interrupt pending across all banks
    logic [NUM_REG_BANKS-1:0] bank_irq;
    generate
        for (bank = 0; bank < NUM_REG_BANKS; bank++) begin : gen_bank_irq
            assign bank_irq[bank] = |(ie_r[bank] & int_pending[bank]);
        end
    endgenerate
    assign irq = |bank_irq;

    `ifdef DEBUG
    // Debug IRQ changes
    logic irq_prev;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_prev <= 1'b0;
        end else begin
            irq_prev <= irq;
            if (irq && !irq_prev) begin
                `DEBUG2(`DBG_GRP_GPIO, ("IRQ asserted"));
                for (int b = 0; b < NUM_REG_BANKS; b++) begin
                    if (|(ie_r[b] & int_pending[b])) begin
                        `DEBUG2(`DBG_GRP_GPIO, ("Bank%0d: ie=0x%h pending=0x%h is=0x%h", b, ie_r[b], int_pending[b], is_r[b]));
                    end
                end
            end else if (!irq && irq_prev) begin
                `DEBUG2(`DBG_GRP_GPIO, ("IRQ deasserted"));
            end
        end
    end
    `endif

    // ========================================================================
    // AXI4-Lite Interface
    // ========================================================================
    logic aw_hs, w_hs, ar_hs;
    assign aw_hs = axi_awvalid && axi_awready;
    assign w_hs  = axi_wvalid  && axi_wready;
    assign ar_hs = axi_arvalid && axi_arready;

    // Write address and data arrive together
    assign axi_awready = axi_awvalid && axi_wvalid && !axi_bvalid;
    assign axi_wready  = axi_awvalid && axi_wvalid && !axi_bvalid;

    // Write response
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b00;
        end else begin
            if (aw_hs && w_hs && !axi_bvalid) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= wr_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
                `DEBUG2(`DBG_GRP_GPIO, ("Write complete: addr=0x%h", axi_awaddr));
            end else if (axi_bready) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // Read address
    assign axi_arready = axi_arvalid && !axi_rvalid;

    // Read data
    logic [31:0] rdata_next;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_rvalid <= 1'b0;
            axi_rdata  <= 32'h0;
            axi_rresp  <= 2'b00;
        end else begin
            if (ar_hs && !axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rdata  <= rdata_next;
                axi_rresp  <= rd_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
                `DEBUG2(`DBG_GRP_GPIO, ("Read: addr=0x%h data=0x%h", axi_araddr, rdata_next));
            end else if (axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Register Read Logic (using generate)
    // ========================================================================
    // Register address decoding
    wire [1:0] bank_sel = axi_araddr[3:2];  // Which bank (0-3)
    wire [3:0] reg_sel  = axi_araddr[7:4];  // Which register type (0-9)

    always_comb begin
        rdata_next = 32'h0;

        // Capability register is global, not per-bank
        if (reg_sel == 4'hA) begin
            rdata_next = CAPABILITY_REG;  // 0xA0: CAPABILITY
        end
        // Check if bank is valid for per-bank registers
        else if (bank_sel < 2'(NUM_REG_BANKS)) begin
            case (reg_sel)
                4'h0: rdata_next = data_out_r[BANK_BITS'(bank_sel)];       // DATA_OUT
                4'h1: rdata_next = data_out_r[BANK_BITS'(bank_sel)];       // SET (reads current output)
                4'h2: rdata_next = data_out_r[BANK_BITS'(bank_sel)];       // CLEAR (reads current output)
                4'h3: rdata_next = gpio_i_sync2[BANK_BITS'(bank_sel)];     // DATA_IN
                4'h4: rdata_next = dir_r[BANK_BITS'(bank_sel)];            // DIR
                4'h5: rdata_next = ie_r[BANK_BITS'(bank_sel)];             // IE
                4'h6: rdata_next = trigger_r[BANK_BITS'(bank_sel)];        // TRIGGER
                4'h7: rdata_next = polarity_r[BANK_BITS'(bank_sel)];       // POLARITY
                4'h8: rdata_next = is_r[BANK_BITS'(bank_sel)];             // IS
                4'h9: rdata_next = loopback_r[BANK_BITS'(bank_sel)];       // LOOPBACK
                default: rdata_next = 32'h0;
            endcase
        end
    end

    // Debug register type names as localparam strings
    `ifdef DEBUG
    localparam string REG_NAMES[10] = '{
        "DATA_OUT", "SET", "CLEAR", "DATA_IN", "DIR",
        "IE", "TRIGGER", "POLARITY", "IS", "LOOPBACK"
    };
    `endif

    // ========================================================================
    // Register Write Logic (using generate)
    // ========================================================================
    // wstrb_mask: expand each strobe bit to a full byte mask for byte-enable writes
    wire [31:0] wstrb_mask = {{8{axi_wstrb[3]}}, {8{axi_wstrb[2]}}, {8{axi_wstrb[1]}}, {8{axi_wstrb[0]}}};
    wire [1:0] wr_bank_sel = axi_awaddr[3:2];  // Which bank (0-3)
    wire [3:0] wr_reg_sel  = axi_awaddr[7:4];  // Which register type (0-9)

    generate
        for (bank = 0; bank < NUM_REG_BANKS; bank++) begin : gen_reg_write
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    data_out_r[bank]  <= '0;
                    dir_r[bank]       <= '0;       // Default: all inputs
                    ie_r[bank]        <= '0;
                    trigger_r[bank]   <= '0;       // Default: level-triggered
                    polarity_r[bank]  <= '0;       // Default: falling/low
                    is_r[bank]        <= '0;
                    loopback_r[bank]  <= '0;       // Default: loopback disabled
                end else begin
                    // Edge detection updates status register
                    if (|edge_detected[bank]) begin
                        `DEBUG2(`DBG_GRP_GPIO, ("Bank%0d Edge detected: edges=0x%h is_old=0x%h is_new=0x%h",
                                bank, edge_detected[bank], is_r[bank], is_r[bank] | edge_detected[bank]));
                    end
                    is_r[bank] <= is_r[bank] | edge_detected[bank];

                    // Register writes (only for matching bank)
                    if (aw_hs && w_hs && (wr_bank_sel == bank)) begin
                        if (wr_reg_sel < 10) begin
                            `DEBUG2(`DBG_GRP_GPIO, ("Bank%0d Write reg%0d (%s): wdata=0x%h", bank, wr_reg_sel, REG_NAMES[wr_reg_sel], axi_wdata));
                        end else begin
                            `DEBUG2(`DBG_GRP_GPIO, ("Bank%0d Write reg%0d: wdata=0x%h", bank, wr_reg_sel, axi_wdata));
                        end
                        case (wr_reg_sel)
                            4'h0: data_out_r[bank] <= (data_out_r[bank] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // DATA_OUT
                            4'h1: data_out_r[bank] <= data_out_r[bank] | (axi_wdata & wstrb_mask);                   // SET (W1S)
                            4'h2: data_out_r[bank] <= data_out_r[bank] & ~(axi_wdata & wstrb_mask);                  // CLEAR (W1C)
                            4'h4: dir_r[bank]      <= (dir_r[bank]      & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // DIR
                            4'h5: ie_r[bank]       <= (ie_r[bank]       & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // IE
                            4'h6: trigger_r[bank]  <= (trigger_r[bank]  & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // TRIGGER
                            4'h7: polarity_r[bank] <= (polarity_r[bank] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // POLARITY
                            4'h8: is_r[bank]       <= is_r[bank] & ~(axi_wdata & wstrb_mask);                        // IS (W1C)
                            4'h9: loopback_r[bank] <= (loopback_r[bank] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // LOOPBACK
                            default: ;
                        endcase
                    end
                end
            end
        end
    endgenerate

    // ========================================================================
    // GPIO Output Assignment (flatten bank arrays to output ports)
    // ========================================================================
    generate
        for (bank = 0; bank < NUM_REG_BANKS; bank++) begin : gen_gpio_output
            localparam int BANK_LOW  = bank * 32;
            localparam int BANK_HIGH = ((bank+1) * 32 <= NUM_PINS) ? (bank+1) * 32 - 1 : NUM_PINS - 1;
            localparam int BANK_PINS = BANK_HIGH - BANK_LOW + 1;

            assign gpio_o[BANK_HIGH:BANK_LOW]  = data_out_r[bank][BANK_PINS-1:0];
            assign gpio_oe[BANK_HIGH:BANK_LOW] = dir_r[bank][BANK_PINS-1:0];
        end
    endgenerate

`ifndef SYNTHESIS
    // Lint sink (debug only): upper and sub-word address bits are decoded by
    // the crossbar; not needed within this word-wide register file.
    logic _unused_ok;
    assign _unused_ok = &{1'b0, axi_awaddr[31:8], axi_awaddr[1:0],
                                axi_araddr[31:8], axi_araddr[1:0]};
`endif // SYNTHESIS

endmodule

