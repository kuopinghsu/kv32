// ============================================================================
// File: axi_magic.sv
// Project: RV32 RISC-V Processor
// Description: AXI4-Lite Magic Device for Simulation Control
//
// Provides special memory-mapped registers for simulation and testing.
// Base address: 0xFFFF0000
//
// Magic Addresses:
//   0xFFFFFFF0: EXIT_MAGIC_ADDR - Exit simulation
//   0xFFFFFFF4: CONSOLE_MAGIC_ADDR - Output character
//
// This device is typically used only in simulation/testbench environments
// and not synthesized for FPGA/ASIC implementations.
// ============================================================================

`ifndef SYNTHESIS
// DPI-C import for exit notification
import "DPI-C" function void sim_request_exit(input int exit_code);
`endif

module axi_magic (
    input  logic        clk,
    input  logic        rst_n,

    // AXI4-Lite Slave Interface
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
    input  logic        axi_rready
);

`ifdef SYNTHESIS
    assign axi_awready      = 1'b1;
    assign axi_wready       = 1'b1;
    assign axi_bresp[1:0]   = 2'b00;  // RESP_OKAY
    assign axi_bvalid       = 1'b1;
    assign axi_arready      = 1'b1;
    assign axi_rdata[31:0]  = 32'b0;
    assign axi_rresp[1:0]   = 2'b00;  // RESP_OKAY
    assign axi_rvalid       = 1'b1;
`else // SYNTHESIS
    // Magic addresses
    localparam EXIT_MAGIC_ADDR    = 32'hFFFFFFF0;
    localparam CONSOLE_MAGIC_ADDR = 32'hFFFFFFF4;

    // State machine for write transactions
    typedef enum logic [1:0] {
        IDLE,
        WRITE_DATA,
        WRITE_RESP
    } write_state_t;

    write_state_t write_state;
    logic [31:0] write_addr_reg;

    // State machine for read transactions
    typedef enum logic [1:0] {
        READ_IDLE,
        READ_RESP
    } read_state_t;

    read_state_t read_state;

    // Write data extraction variables
    logic is_byte_write;
    logic [7:0] write_byte;

    // Combinational logic to extract write byte based on strobe
    always_comb begin
        // Determine if this is a byte or word write based on axi_wstrb
        is_byte_write = (axi_wstrb == 4'b0001) ||
                       (axi_wstrb == 4'b0010) ||
                       (axi_wstrb == 4'b0100) ||
                       (axi_wstrb == 4'b1000);

        // Extract the correct byte based on axi_wstrb or address[1:0]
        if (is_byte_write) begin
            // Byte write: select byte based on which strobe bit is set
            case (axi_wstrb)
                4'b0001: write_byte = axi_wdata[7:0];
                4'b0010: write_byte = axi_wdata[15:8];
                4'b0100: write_byte = axi_wdata[23:16];
                4'b1000: write_byte = axi_wdata[31:24];
                default: write_byte = axi_wdata[7:0];
            endcase
        end else begin
            // Word write: always use lower byte for char operations
            write_byte = axi_wdata[7:0];
        end
    end

    // Write channel handling
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_state <= IDLE;
            write_addr_reg <= 32'h0;
            axi_awready <= 1'b0;
            axi_wready <= 1'b0;
            axi_bresp <= 2'b00;
            axi_bvalid <= 1'b0;
        end else begin
            case (write_state)
                IDLE: begin
                    axi_awready <= 1'b1;
                    axi_wready <= 1'b0;
                    axi_bvalid <= 1'b0;

                    if (axi_awvalid && axi_awready) begin
                        write_addr_reg <= axi_awaddr;
                        axi_awready <= 1'b0;
                        write_state <= WRITE_DATA;
                    end
                end

                WRITE_DATA: begin
                    axi_wready <= 1'b1;

                    if (axi_wvalid && axi_wready) begin
                        axi_wready <= 1'b0;

                        // Handle magic address writes
                        case (write_addr_reg & ~32'h3)  // Align to 4-byte boundary
                            EXIT_MAGIC_ADDR: begin
                                if (is_byte_write) begin
                                    // Exit simulation - decode HTIF: exit_code = value >> 1
                                    `DEBUG1(("[MAGIC] Exit simulation with code %0d", write_byte >> 1));
                                    sim_request_exit(write_byte >> 1);
                                end else begin
                                    // Exit simulation - decode HTIF: exit_code = value >> 1
                                    `DEBUG1(("[MAGIC] Exit simulation with code %0d", axi_wdata >> 1));
                                    sim_request_exit(axi_wdata >> 1);
                                end
                            end
                            CONSOLE_MAGIC_ADDR: begin
                                // Output character to console, disable output on debug mode
                                `ifndef DEBUG
                                $write("%c", write_byte);
                                $fflush();
                                `endif
                            end
                            default: begin
                                // Ignore other addresses
                            end
                        endcase

                        axi_bresp <= 2'b00;  // OKAY
                        axi_bvalid <= 1'b1;
                        write_state <= WRITE_RESP;
                    end
                end

                WRITE_RESP: begin
                    if (axi_bvalid && axi_bready) begin
                        axi_bvalid <= 1'b0;
                        write_state <= IDLE;
                    end
                end

                default: write_state <= IDLE;
            endcase
        end
    end

    // Read channel handling (return 0 for reads)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_state <= READ_IDLE;
            axi_arready <= 1'b0;
            axi_rdata <= 32'h0;
            axi_rresp <= 2'b00;
            axi_rvalid <= 1'b0;
        end else begin
            case (read_state)
                READ_IDLE: begin
                    axi_arready <= 1'b1;
                    axi_rvalid <= 1'b0;

                    if (axi_arvalid && axi_arready) begin
                        axi_arready <= 1'b0;
                        axi_rdata  <= 32'h0;
                        axi_rresp  <= 2'b00;  // OKAY
                        axi_rvalid <= 1'b1;
                        read_state <= READ_RESP;
                    end
                end

                READ_RESP: begin
                    if (axi_rvalid && axi_rready) begin
                        axi_rvalid <= 1'b0;
                        read_state <= READ_IDLE;
                    end
                end

                default: read_state <= READ_IDLE;
            endcase
        end
    end

    // ========================================================================
    // AXI4-Lite Protocol Assertions
    // ========================================================================
    // Define ASSERTION by default (can be disabled with +define+NO_ASSERTION)
`ifndef NO_ASSERTION
`ifndef ASSERTION
`define ASSERTION
`endif
`endif // NO_ASSERTION

`ifdef ASSERTION

    // AXI4-Lite Write Address Channel Assertions
    property p_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_awvalid && !axi_awready) |=> $stable(axi_awvalid);
    endproperty
    assert property (p_awvalid_stable)
        else $error("[AXI_MAGIC] AWVALID must remain stable until AWREADY");

    property p_awaddr_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_awvalid && !axi_awready) |=> $stable(axi_awaddr);
    endproperty
    assert property (p_awaddr_stable)
        else $error("[AXI_MAGIC] AWADDR must remain stable while AWVALID is high");

    // AXI4-Lite Write Data Channel Assertions
    property p_wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_wvalid && !axi_wready) |=> $stable(axi_wvalid);
    endproperty
    assert property (p_wvalid_stable)
        else $error("[AXI_MAGIC] WVALID must remain stable until WREADY");

    property p_wdata_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_wvalid && !axi_wready) |=> $stable(axi_wdata);
    endproperty
    assert property (p_wdata_stable)
        else $error("[AXI_MAGIC] WDATA must remain stable while WVALID is high");

    property p_wstrb_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_wvalid && !axi_wready) |=> $stable(axi_wstrb);
    endproperty
    assert property (p_wstrb_stable)
        else $error("[AXI_MAGIC] WSTRB must remain stable while WVALID is high");

    // AXI4-Lite Write Response Channel Assertions
    property p_bvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_bvalid && !axi_bready) |=> $stable(axi_bvalid);
    endproperty
    assert property (p_bvalid_stable)
        else $error("[AXI_MAGIC] BVALID must remain stable until BREADY");

    property p_bresp_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_bvalid && !axi_bready) |=> $stable(axi_bresp);
    endproperty
    assert property (p_bresp_stable)
        else $error("[AXI_MAGIC] BRESP must remain stable while BVALID is high");

    property p_bvalid_after_write;
        @(posedge clk) disable iff (!rst_n)
        (axi_awvalid && axi_awready && axi_wvalid && axi_wready) |=> axi_bvalid;
    endproperty
    assert property (p_bvalid_after_write)
        else $error("[AXI_MAGIC] BVALID must be asserted 1 cycle after write data handshake");

    // AXI4-Lite Read Address Channel Assertions
    property p_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_arvalid && !axi_arready) |=> $stable(axi_arvalid);
    endproperty
    assert property (p_arvalid_stable)
        else $error("[AXI_MAGIC] ARVALID must remain stable until ARREADY");

    property p_araddr_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_arvalid && !axi_arready) |=> $stable(axi_araddr);
    endproperty
    assert property (p_araddr_stable)
        else $error("[AXI_MAGIC] ARADDR must remain stable while ARVALID is high");

    // AXI4-Lite Read Data Channel Assertions
    property p_rvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_rvalid && !axi_rready) |=> $stable(axi_rvalid);
    endproperty
    assert property (p_rvalid_stable)
        else $error("[AXI_MAGIC] RVALID must remain stable until RREADY");

    property p_rdata_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_rvalid && !axi_rready) |=> $stable(axi_rdata);
    endproperty
    assert property (p_rdata_stable)
        else $error("[AXI_MAGIC] RDATA must remain stable while RVALID is high");

    property p_rresp_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_rvalid && !axi_rready) |=> $stable(axi_rresp);
    endproperty
    assert property (p_rresp_stable)
        else $error("[AXI_MAGIC] RRESP must remain stable while RVALID is high");

    property p_rvalid_after_read;
        @(posedge clk) disable iff (!rst_n)
        (axi_arvalid && axi_arready) |=> axi_rvalid;
    endproperty
    assert property (p_rvalid_after_read)
        else $error("[AXI_MAGIC] RVALID must be asserted 1 cycle after read address handshake");

    // X/Z Detection on Critical Signals (synthesis checks)
    property p_no_x_awvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(axi_awvalid);
    endproperty
    assert property (p_no_x_awvalid)
        else $error("[AXI_MAGIC] X/Z detected on axi_awvalid");

    property p_no_x_wvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(axi_wvalid);
    endproperty
    assert property (p_no_x_wvalid)
        else $error("[AXI_MAGIC] X/Z detected on axi_wvalid");

    property p_no_x_arvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(axi_arvalid);
    endproperty
    assert property (p_no_x_arvalid)
        else $error("[AXI_MAGIC] X/Z detected on axi_arvalid");

    property p_no_x_bready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(axi_bready);
    endproperty
    assert property (p_no_x_bready)
        else $error("[AXI_MAGIC] X/Z detected on axi_bready");

    property p_no_x_rready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(axi_rready);
    endproperty
    assert property (p_no_x_rready)
        else $error("[AXI_MAGIC] X/Z detected on axi_rready");

    // Response value checks
    property p_bresp_valid;
        @(posedge clk) disable iff (!rst_n)
        axi_bvalid |-> (axi_bresp == 2'b00 || axi_bresp == 2'b10 || axi_bresp == 2'b11);
    endproperty
    assert property (p_bresp_valid)
        else $error("[AXI_MAGIC] Invalid BRESP value: %b", axi_bresp);

    property p_rresp_valid;
        @(posedge clk) disable iff (!rst_n)
        axi_rvalid |-> (axi_rresp == 2'b00 || axi_rresp == 2'b10 || axi_rresp == 2'b11);
    endproperty
    assert property (p_rresp_valid)
        else $error("[AXI_MAGIC] Invalid RRESP value: %b", axi_rresp);

`endif // ASSERTION
`endif // SYNTHESIS

endmodule
