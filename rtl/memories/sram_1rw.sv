// =============================================================================
// sram_1rw.sv – Single-Port 1R/1W SRAM Macro Wrapper
//
// Interface
//   clk   – rising-edge clock
//   ce    – chip enable (active-high).  All inputs are ignored when low.
//   we    – write enable (active-high).
//             we=1 → write wdata to mem[addr] on the rising edge
//             we=0 → read  mem[addr]; output registered on the same edge
//   addr  – word address, $clog2(DEPTH) bits wide
//   wdata – write data
//   rdata – read data (registered, valid one cycle after ce=1, we=0)
//
// Read-during-write behaviour
//   Simulation / ASIC  : rdata is 'x on a write cycle (undefined / no-change).
//   Xilinx FPGA        : NO_CHANGE mode – rdata is not updated on write cycles.
//                        This gives the best timing and lowest power for BRAM.
//
// Target selection (define exactly one before including this file,
// or pass it on the command line):
//
//   `define XILINX_FPGA   – Xilinx 7-series / UltraScale / UltraScale+
//                           Infers Block RAM (RAMB36/RAMB18) in NO_CHANGE mode.
//                           (* ram_style = "block" *) forces BRAM (not LUTRAM).
//
//   `define INTEL_FPGA    – Intel (Altera) Cyclone / Arria / Stratix
//                           Instantiates altsyncram configured as M20K/MLAB
//                           single-port RAM in NO_CHANGE read-during-write mode.
//
//   (default)             – Behavioural model for simulation.
//                           For ASIC tapeout replace the translate_off/on body
//                           with the foundry memory-compiler macro.  Four
//                           example templates are provided in the comments.
// =============================================================================

module sram_1rw #(
    parameter int DEPTH = 256,  // number of words
    parameter int WIDTH = 32    // bits per word
) (
    input  logic                     clk,
    input  logic                     ce,    // chip enable
    input  logic                     we,    // write enable
    input  logic [$clog2(DEPTH)-1:0] addr,
    input  logic [WIDTH-1:0]         wdata,
    output logic [WIDTH-1:0]         rdata
);

`ifdef XILINX_FPGA

    // =========================================================================
    // Xilinx FPGA – Block RAM inference
    //
    // Coding style follows Xilinx UG901 (Vivado Design Suite: HDL Coding
    // Guidelines) §"Single-Port Block RAM with No-Change Read-During-Write".
    //
    // (* ram_style = "block" *) forces Vivado to map to RAMB36/RAMB18 hard
    // macros rather than distributed (LUT) RAM.  Remove the attribute to
    // allow the tool to choose automatically.
    //
    // NO_CHANGE mode: rdata register hold its value when we=1.  The cache
    // controller never issues a read on the same cycle as a write, so this
    // is safe and yields the best BRAM timing closure.
    // =========================================================================

    (* ram_style = "block" *)
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (ce) begin
            if (we) begin
                mem[addr] <= wdata;
                // NO_CHANGE: rdata is NOT updated on write cycles.
                // (Vivado infers NO_CHANGE mode when the else-read clause
                //  is absent inside the write branch.)
            end else begin
                rdata <= mem[addr];
            end
        end
    end

`elsif INTEL_FPGA

    // =========================================================================
    // Intel FPGA – altsyncram (Cyclone IV/V/10, Arria, Stratix)
    //
    // altsyncram is the portable MegaCore for all Intel FPGA on-chip memories.
    // OPERATION_MODE = "SINGLE_PORT" maps to M20K (Cyclone V+) or MLAB.
    // READ_DURING_WRITE_MODE_PORT_A = "DONT_CARE" gives the best timing;
    // use "NEW_DATA_NO_NBE_READ" for Stratix 10 NO_CHANGE equivalence.
    //
    // Quartus Pro / Standard both accept this instantiation.  The MegaWizard
    // GUI generates equivalent code – this hand-instantiation avoids the .qip
    // dependency and is portable across Quartus versions.
    // =========================================================================

    altsyncram #(
        .operation_mode              ("SINGLE_PORT"),
        .width_a                     (WIDTH),
        .widthad_a                   ($clog2(DEPTH)),
        .numwords_a                  (DEPTH),
        .outdata_reg_a               ("CLOCK0"),       // registered output
        .read_during_write_mode_port_a ("DONT_CARE"),  // best timing
        .init_file                   ("UNUSED"),
        .intended_device_family      ("Cyclone V")
    ) u_altsyncram (
        .clock0    (clk),
        .address_a (addr),
        .wren_a    (ce & we),
        .data_a    (wdata),
        .q_a       (rdata),
        .clocken0  (ce),
        // unused ports
        .aclr0     (1'b0),  .aclr1   (1'b0),
        .addressstall_a (1'b0),
        .byteena_a (1'b1),
        .clocken1  (1'b1),
        .rden_a    (~we)     // optional read-enable for power saving
    );

`else

    // =========================================================================
    // Default – behavioural model (simulation) / ASIC hard-macro placeholder
    //
    // This block is used for Verilator / functional simulation as-is.
    //
    // ── ASIC tapeout – how to swap in a memory-compiler macro ────────────────
    //
    // 1. Remove the two "synthesis translate_off/on" pragmas and the
    //    behavioural logic between them.
    //
    // 2. Instantiate the foundry SRAM macro in their place, mapping:
    //      clk   → clock pin
    //      ce    → chip-enable pin  (active-high)
    //      we    → write-enable pin (active-high)
    //      addr  → address bus      ($clog2(DEPTH) bits)
    //      wdata → data-in bus      (WIDTH bits)
    //      rdata → data-out bus     (WIDTH bits, registered)
    //
    // 3. Keep the module port list and parameter declarations unchanged so
    //    the icache wrapper requires no edits.
    //
    // Four concrete examples are given below for common SRAM compilers and
    // cache configurations produced by icache.sv.  Un-comment the relevant
    // block and delete the behavioural section.
    //
    // ── icache.sv SRAM dimensions ────────────────────────────────────────────
    //
    //  Instance        | DEPTH          | WIDTH
    //  ────────────────┼────────────────┼──────────────────────────────────────
    //  tag_sram[way]   | NUM_SETS       | TAG_BITS = 32-INDEX_BITS-OFF_BITS
    //  data_sram[way]  | NUM_SETS×WPL   | 32 (one instruction word per entry)
    //
    //  Example: 4 KB / 64 B line / 2-way → NUM_SETS=32, TAG_BITS=21, WPL=16
    //    tag_sram:  DEPTH=32,  WIDTH=21
    //    data_sram: DEPTH=512, WIDTH=32
    //
    //  Example: 16 KB / 128 B line / 4-way → NUM_SETS=32, TAG_BITS=19, WPL=32
    //    tag_sram:  DEPTH=32,   WIDTH=19
    //    data_sram: DEPTH=1024, WIDTH=32
    //
    // =========================================================================

    // synthesis translate_off
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (ce) begin
            if (we) begin
                mem[addr] <= wdata;
                rdata     <= {WIDTH{1'bx}};  // undefined during write (no-change)
            end else begin
                rdata <= mem[addr];
            end
        end
    end
    // synthesis translate_on

    // =========================================================================
    // Example A – ARM Artisan / Synopsys DesignWare generic SRAM
    //
    // Most foundry-licensed Artisan SRAMs follow this port convention.
    // The macro name encodes geometry: SP = single-port, HD = high-density.
    // Replace "SP_HD_<DEPTH>x<WIDTH>" with the actual macro name from the
    // memory characterisation library (e.g. ts28hpc_sphd_128x32m4).
    //
    // Compile-time: pass +define+ASIC_ARTISAN on the synthesis command line.
    // =========================================================================
    //
    // `ifdef ASIC_ARTISAN
    // SP_HD_array #(
    //     .Words (DEPTH),
    //     .Bits  (WIDTH)
    // ) u_sram (
    //     .CLK   (clk),
    //     .CEN   (~ce),          // chip-enable, active-LOW in Artisan convention
    //     .WEN   (~we),          // write-enable, active-LOW
    //     .A     (addr),
    //     .D     (wdata),
    //     .Q     (rdata)
    // );
    // `endif

    // =========================================================================
    // Example B – TSMC standard-cell memory compiler (e.g. tcbn28hpcp)
    //
    // TSMC 28 nm HPC+ SP SRAM port map.  Timing derating and power domains
    // are handled in the Liberty (.lib) and LEF files supplied by TSMC.
    // Replace macro name with the output of your memory-compiler invocation,
    // e.g.: tsmc28_sp_<DEPTH>x<WIDTH>_m4 or tsmc28_sphd_<DEPTH>x<WIDTH>.
    //
    // Compile-time: pass +define+ASIC_TSMC on the synthesis command line.
    // =========================================================================
    //
    // `ifdef ASIC_TSMC
    // tsmc28_sphd u_sram (
    //     .CLK   (clk),
    //     .CSB   (~ce),          // chip-select, active-LOW
    //     .WEB   (~we),          // write-enable, active-LOW
    //     .A     (addr),
    //     .D     (wdata),
    //     .Q     (rdata),
    //     .RTSEL (2'b01),        // read timing select – set per PVT corner
    //     .WTSEL (2'b01)         // write timing select
    // );
    // `endif

    // =========================================================================
    // Example C – Samsung / GF / SMIC generic compiler (CE-active-high style)
    //
    // Many SMIC and GF memory compilers use active-high CE/WE matching this
    // wrapper's convention directly, making the mapping one-to-one.
    //
    // Compile-time: pass +define+ASIC_GENERIC on the synthesis command line.
    // =========================================================================
    //
    // `ifdef ASIC_GENERIC
    // smic55_sp_<DEPTH>x<WIDTH> u_sram (
    //     .CLK   (clk),
    //     .CE    (ce),           // chip-enable, active-high
    //     .WE    (we),           // write-enable, active-high
    //     .ADDR  (addr),
    //     .DIN   (wdata),
    //     .DOUT  (rdata)
    // );
    // `endif

    // =========================================================================
    // Example D – Intel / Lattice ECP5 – manually instantiated EBR
    //             (fallback when altsyncram / `INTEL_FPGA is not available)
    //
    // Lattice EBR (Embedded Block RAM) on ECP5/ECP5-5G uses PDPW16KD or
    // DP16KD.  For simple single-port use, instantiate PDP16KD with WCK=RCK.
    // Parameters: DATA_WIDTH_W / DATA_WIDTH_R must be equal for SP operation.
    //
    // Compile-time: pass +define+LATTICE_ECP5 on the synthesis command line.
    // =========================================================================
    //
    // `ifdef LATTICE_ECP5
    // PDP16KD #(
    //     .DATA_WIDTH_W (WIDTH <= 9  ? 9  :
    //                    WIDTH <= 18 ? 18 : 36),
    //     .DATA_WIDTH_R (WIDTH <= 9  ? 9  :
    //                    WIDTH <= 18 ? 18 : 36),
    //     .INITVAL_00   ("0x00000000000000000000000000000000000000000000000000"),
    //     .ASYNC_RESET_RELEASE ("SYNC"),
    //     .RESETMODE ("SYNC")
    // ) u_sram (
    //     // Write port
    //     .CLKW  (clk),
    //     .CEW   (ce & we),
    //     .WE    (1'b1),
    //     .ADW   (addr),
    //     .DI    (wdata),
    //     // Read port (share clock for SP behaviour)
    //     .CLKR  (clk),
    //     .CER   (ce & ~we),
    //     .ADR   (addr),
    //     .DO    (rdata),
    //     // Tie-offs
    //     .OCER  (1'b1), .RST (1'b0),
    //     .BE    ({(WIDTH/8){1'b1}})
    // );
    // `endif

`endif  // INTEL_FPGA / default

endmodule
