// ============================================================================
// File: axi_timer.sv
// Project: KV32 RISC-V Processor
// Description: AXI4-Lite Timer/PWM Peripheral with 4 Timers
//
// Memory-mapped timer/PWM with AXI4-Lite interface. Provides four independent
// 32-bit timers. Each timer supports:
//   - Free-running counter mode
//   - Compare-match interrupts
//   - PWM output generation
//
// Register Map (relative to base 0x2004_0000):
//   Timer 0:
//   0x00: TIMER0_COUNT     - Counter value (read/write)
//   0x04: TIMER0_COMPARE1  - Compare 1 (timer interrupt / PWM set point)
//   0x08: TIMER0_COMPARE2  - Compare 2 (PWM clear point, resets counter in PWM mode)
//   0x0C: TIMER0_CTRL      - Control register
//
//   Timer 1:
//   0x20: TIMER1_COUNT
//   0x24: TIMER1_COMPARE1
//   0x28: TIMER1_COMPARE2
//   0x2C: TIMER1_CTRL
//
//   Timer 2:
//   0x40: TIMER2_COUNT
//   0x44: TIMER2_COMPARE1
//   0x48: TIMER2_COMPARE2
//   0x4C: TIMER2_CTRL
//
//   Timer 3:
//   0x60: TIMER3_COUNT
//   0x64: TIMER3_COMPARE1
//   0x68: TIMER3_COMPARE2
//   0x6C: TIMER3_CTRL
//
//   Global:
//   0x80: INT_STATUS       - Interrupt status (read: status, write-1-to-clear)
//   0x84: INT_ENABLE       - Interrupt enable
//
// Control Register (TIMERx_CTRL):
//   [0]: EN          - Timer enable (1=running, 0=stopped)
//   [1]: PWM_EN      - PWM enable (1=PWM mode, 0=timer mode)
//   [2]: Reserved
//   [3]: INT_EN      - Compare interrupt enable (fires on COMPARE1 or COMPARE2, gated by global INT_ENABLE)
//   [4]: PWM_POL     - PWM polarity (1=active high, 0=active low)
//   [31:16]: PRESCALE - Prescaler value (divides clock by PRESCALE+1)
//
// Interrupt Status/Enable (bits [3:0] for timers 3:0):
//   [0]: TIMER0_CMP  - Timer 0 compare match (COMPARE1 or COMPARE2)
//   [1]: TIMER1_CMP  - Timer 1 compare match (COMPARE1 or COMPARE2)
//   [2]: TIMER2_CMP  - Timer 2 compare match (COMPARE1 or COMPARE2)
//   [3]: TIMER3_CMP  - Timer 3 compare match (COMPARE1 or COMPARE2)
//
// PWM Mode:
//   - PWM output set to 1 when COUNT == COMPARE1 (rising edge)
//   - PWM output set to 0 when COUNT == COMPARE2 (falling edge)
//   - Counter resets to 0 when COUNT == COMPARE2 (defines PWM period)
//   - Polarity control inverts the output (PWM_POL bit)
//   - For standard PWM: set COMPARE1=duty_start, COMPARE2=period-1
//
// Timer Mode:
//   - COMPARE1 triggers interrupt (mid-period event)
//   - COMPARE2 triggers interrupt AND resets counter (period end)
//   - If COMPARE1 == COMPARE2, single interrupt at period end
//   - Use COMPARE1 < COMPARE2 for dual interrupts per period
//
// Features:
//   - 4 independent 32-bit timers
//   - Configurable prescaler per timer
//   - PWM output generation with configurable duty cycle and period
//   - Compare-match interrupts
//   - PLIC-compatible IRQ output
//
// ============================================================================

module axi_timer (
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

    // PWM outputs
    output logic [3:0]  pwm_o
);

    // Capability register
    localparam logic [15:0] TIMER_VERSION   = 16'h0001;
    localparam logic [31:0] CAPABILITY_REG  = {TIMER_VERSION, 8'd4, 8'd32};  // 4 channels, 32-bit counters

    // AXI address range checks
    // Valid offsets (addr[7:2] word index):
    //   Timer 0: 0x00-0x0F (idx 0-3),  Timer 1: 0x20-0x2F (idx 8-11)
    //   Timer 2: 0x40-0x4F (idx 16-19), Timer 3: 0x60-0x6F (idx 24-27)
    //   Global:  INT_STATUS 0x80 (W1C), INT_ENABLE 0x84, CAPABILITY 0x88 (RO)
    wire wr_addr_valid = (axi_awaddr[7:2] <= 6'h03) ||
                         (axi_awaddr[7:2] >= 6'h08 && axi_awaddr[7:2] <= 6'h0B) ||
                         (axi_awaddr[7:2] >= 6'h10 && axi_awaddr[7:2] <= 6'h13) ||
                         (axi_awaddr[7:2] >= 6'h18 && axi_awaddr[7:2] <= 6'h1B) ||
                         (axi_awaddr[7:2] >= 6'h20 && axi_awaddr[7:2] <= 6'h21);
    wire rd_addr_valid = (axi_araddr[7:2] <= 6'h03) ||
                         (axi_araddr[7:2] >= 6'h08 && axi_araddr[7:2] <= 6'h0B) ||
                         (axi_araddr[7:2] >= 6'h10 && axi_araddr[7:2] <= 6'h13) ||
                         (axi_araddr[7:2] >= 6'h18 && axi_araddr[7:2] <= 6'h1B) ||
                         (axi_araddr[7:2] >= 6'h20 && axi_araddr[7:2] <= 6'h22);

    // ========================================================================
    // Timer Registers
    // ========================================================================
    logic [31:0] count_r     [0:3];     // Counter values
    logic [31:0] compare1_r  [0:3];     // Compare 1 values (timer interrupt / PWM set)
    logic [31:0] compare2_r  [0:3];     // Compare 2 values (PWM clear / period)
    logic [31:0] ctrl_r      [0:3];     // Control registers

    logic [3:0]  int_status_r;         // Interrupt status (W1C)
    logic [3:0]  int_enable_r;         // Interrupt enable

    // Control register unpacking
    logic [3:0]  timer_en;
    logic [3:0]  pwm_en;
    logic [3:0]  int_en;
    logic [3:0]  pwm_pol;
    logic [15:0] prescale [0:3];

    always_comb begin
        for (int i = 0; i < 4; i++) begin
            timer_en[i]    = ctrl_r[i][0];
            pwm_en[i]      = ctrl_r[i][1];
            int_en[i]      = ctrl_r[i][3];
            pwm_pol[i]     = ctrl_r[i][4];
            prescale[i]    = ctrl_r[i][31:16];
        end
    end

    // ========================================================================
    // Prescaler Counters
    // ========================================================================
    logic [15:0] prescale_cnt [0:3];
    logic [3:0]  timer_tick;           // Prescaled clock enable

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 4; i++) begin
                prescale_cnt[i] <= '0;
            end
        end else begin
            for (int i = 0; i < 4; i++) begin
                if (!timer_en[i]) begin
                    prescale_cnt[i] <= '0;
                end else if (prescale_cnt[i] >= prescale[i]) begin
                    prescale_cnt[i] <= '0;
                end else begin
                    prescale_cnt[i] <= prescale_cnt[i] + 1;
                end
            end
        end
    end

    always_comb begin
        for (int i = 0; i < 4; i++) begin
            timer_tick[i] = timer_en[i] && (prescale_cnt[i] == prescale[i]);
        end
    end

    // ========================================================================
    // Timer Counters and Compare Logic
    // ========================================================================
    logic [3:0] compare1_match;        // COMPARE1 match (interrupt/PWM set)
    logic [3:0] compare2_match;        // COMPARE2 match (PWM clear/period)
    logic [3:0] counter_reload;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 4; i++) begin
                count_r[i] <= '0;
            end
        end else begin
            for (int i = 0; i < 4; i++) begin
                if (counter_reload[i]) begin
                    count_r[i] <= '0;
                end else if (timer_tick[i]) begin
                    count_r[i] <= count_r[i] + 1;
                end
            end
        end
    end

    // Compare match and reload logic
    always_comb begin
        for (int i = 0; i < 4; i++) begin
            compare1_match[i] = timer_tick[i] && (count_r[i] == compare1_r[i]);
            compare2_match[i] = timer_tick[i] && (count_r[i] == compare2_r[i]);

            // Both PWM and timer modes: COMPARE2 reloads counter
            counter_reload[i] = compare2_match[i];
        end
    end

    // ========================================================================
    // PWM Output Generation
    // ========================================================================
    logic [3:0] pwm_output_raw;        // PWM output before polarity
    logic [3:0] pwm_output;

    // Set/Reset flip-flop for PWM output
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwm_output_raw <= '0;
        end else begin
            for (int i = 0; i < 4; i++) begin
                if (!pwm_en[i]) begin
                    pwm_output_raw[i] <= 1'b0;
                end else begin
                    // Set on COMPARE1 match, clear on COMPARE2 match
                    if (compare1_match[i]) begin
                        pwm_output_raw[i] <= 1'b1;
                    end else if (compare2_match[i]) begin
                        pwm_output_raw[i] <= 1'b0;
                    end
                    // Also clear on reload to ensure clean period start
                    if (counter_reload[i]) begin
                        pwm_output_raw[i] <= 1'b0;
                    end
                end
            end
        end
    end

    // Apply polarity
    always_comb begin
        for (int i = 0; i < 4; i++) begin
            pwm_output[i] = pwm_pol[i] ? pwm_output_raw[i] : !pwm_output_raw[i];
        end
    end

    assign pwm_o = pwm_output;

    // ========================================================================
    // Interrupt Logic
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int_status_r <= '0;
        end else begin
            // Set status bits on COMPARE1 or COMPARE2 match (if enabled)
            for (int i = 0; i < 4; i++) begin
                if ((compare1_match[i] || compare2_match[i]) && int_en[i]) begin
                    int_status_r[i] <= 1'b1;
                end
            end

            // Clear status bits on write-1-to-clear
            if (axi_awvalid && axi_wvalid && axi_awready && (axi_awaddr[7:2] == 6'h20)) begin
                int_status_r <= int_status_r & ~axi_wdata[3:0];
            end
        end
    end

    assign irq = |(int_status_r & int_enable_r);

    // ========================================================================
    // AXI4-Lite Interface
    // ========================================================================
    logic aw_hs, w_hs, ar_hs;
    assign aw_hs = axi_awvalid && axi_awready;
    assign w_hs  = axi_wvalid && axi_wready;
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
            end else if (axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Register Read Logic
    // ========================================================================
    always_comb begin
        rdata_next = 32'h0;
        case (axi_araddr[7:2])
            // Timer 0 (0x00-0x0F)
            6'h00: rdata_next = count_r[0];             // COUNT
            6'h01: rdata_next = compare1_r[0];          // COMPARE1
            6'h02: rdata_next = compare2_r[0];          // COMPARE2
            6'h03: rdata_next = ctrl_r[0];              // CTRL
            // Timer 1 (0x20-0x2F)
            6'h08: rdata_next = count_r[1];             // COUNT
            6'h09: rdata_next = compare1_r[1];          // COMPARE1
            6'h0A: rdata_next = compare2_r[1];          // COMPARE2
            6'h0B: rdata_next = ctrl_r[1];              // CTRL
            // Timer 2 (0x40-0x4F)
            6'h10: rdata_next = count_r[2];             // COUNT
            6'h11: rdata_next = compare1_r[2];          // COMPARE1
            6'h12: rdata_next = compare2_r[2];          // COMPARE2
            6'h13: rdata_next = ctrl_r[2];              // CTRL
            // Timer 3 (0x60-0x6F)
            6'h18: rdata_next = count_r[3];             // COUNT
            6'h19: rdata_next = compare1_r[3];          // COMPARE1
            6'h1A: rdata_next = compare2_r[3];          // COMPARE2
            6'h1B: rdata_next = ctrl_r[3];              // CTRL
            // Global interrupt (0x80-0x8F)
            6'h20: rdata_next = {28'h0, int_status_r};  // INT_STATUS
            6'h21: rdata_next = {28'h0, int_enable_r};  // INT_ENABLE
            6'h22: rdata_next = CAPABILITY_REG;         // CAPABILITY (RO)
            default: rdata_next = 32'h0;
        endcase
    end

    // ========================================================================
    // Register Write Logic
    // ========================================================================
    // wstrb_mask: expand each strobe bit to a full byte mask for byte-enable writes on 32-bit registers
    wire [31:0] wstrb_mask = {{8{axi_wstrb[3]}}, {8{axi_wstrb[2]}}, {8{axi_wstrb[1]}}, {8{axi_wstrb[0]}}};
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 4; i++) begin
                compare1_r[i] <= '0;
                compare2_r[i] <= 32'hFFFF_FFFF;     // Default: max period
                ctrl_r[i]     <= '0;
            end
            int_enable_r <= '0;
        end else begin
            if (aw_hs && w_hs) begin
                case (axi_awaddr[7:2])
                    // Timer 0 (0x00-0x0F)
                    6'h00: count_r[0]     <= (count_r[0]    & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COUNT
                    6'h01: compare1_r[0]  <= (compare1_r[0] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COMPARE1
                    6'h02: compare2_r[0]  <= (compare2_r[0] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COMPARE2
                    6'h03: ctrl_r[0]      <= (ctrl_r[0]     & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // CTRL
                    // Timer 1 (0x20-0x2F)
                    6'h08: count_r[1]     <= (count_r[1]    & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COUNT
                    6'h09: compare1_r[1]  <= (compare1_r[1] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COMPARE1
                    6'h0A: compare2_r[1]  <= (compare2_r[1] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COMPARE2
                    6'h0B: ctrl_r[1]      <= (ctrl_r[1]     & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // CTRL
                    // Timer 2 (0x40-0x4F)
                    6'h10: count_r[2]     <= (count_r[2]    & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COUNT
                    6'h11: compare1_r[2]  <= (compare1_r[2] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COMPARE1
                    6'h12: compare2_r[2]  <= (compare2_r[2] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COMPARE2
                    6'h13: ctrl_r[2]      <= (ctrl_r[2]     & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // CTRL
                    // Timer 3 (0x60-0x6F)
                    6'h18: count_r[3]     <= (count_r[3]    & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COUNT
                    6'h19: compare1_r[3]  <= (compare1_r[3] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COMPARE1
                    6'h1A: compare2_r[3]  <= (compare2_r[3] & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // COMPARE2
                    6'h1B: ctrl_r[3]      <= (ctrl_r[3]     & ~wstrb_mask) | (axi_wdata & wstrb_mask);  // CTRL
                    // Global interrupt (0x80-0x8F) - INT_STATUS is handled above for W1C
                    6'h21: if (axi_wstrb[0]) int_enable_r <= axi_wdata[3:0];  // INT_ENABLE
                    default: ;
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    // Lint sink (debug only): upper and sub-word address bits decoded by
    // crossbar; not used within this word-wide register file.
    logic _unused_ok;
    assign _unused_ok = &{1'b0, axi_awaddr[31:8], axi_awaddr[1:0],
                                axi_araddr[31:8], axi_araddr[1:0]};
`endif // SYNTHESIS

endmodule

