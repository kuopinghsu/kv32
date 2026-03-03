// ============================================================================
// File: ddr4_axi4_pkg.sv
// Project: KV32 RISC-V Processor
// Description: DDR4 AXI4 Slave Package
//
// Contains type definitions, constants, and utility functions shared by the
// DDR4 AXI4 slave simulation model.  Includes AXI4 burst/response enums,
// DDR4 timing constants, and address-translation helpers.
// ============================================================================

`ifndef DDR4_AXI4_PKG_SV
`define DDR4_AXI4_PKG_SV

/* verilator lint_off WIDTHEXPAND */

package ddr4_axi4_pkg;

    //=========================================================================
    // AXI4 Burst Types
    //=========================================================================
    typedef enum logic [1:0] {
        AXI_BURST_FIXED = 2'b00,
        AXI_BURST_INCR  = 2'b01,
        AXI_BURST_WRAP  = 2'b10,
        AXI_BURST_RSVD  = 2'b11
    } axi_burst_t;

    //=========================================================================
    // AXI4 Response Types
    //=========================================================================
    typedef enum logic [1:0] {
        AXI_RESP_OKAY   = 2'b00,
        AXI_RESP_EXOKAY = 2'b01,
        AXI_RESP_SLVERR = 2'b10,
        AXI_RESP_DECERR = 2'b11
    } axi_resp_t;

    //=========================================================================
    // AXI4 Size Encoding
    //=========================================================================
    typedef enum logic [2:0] {
        AXI_SIZE_1B   = 3'b000,   // 1 byte
        AXI_SIZE_2B   = 3'b001,   // 2 bytes
        AXI_SIZE_4B   = 3'b010,   // 4 bytes
        AXI_SIZE_8B   = 3'b011,   // 8 bytes
        AXI_SIZE_16B  = 3'b100,   // 16 bytes
        AXI_SIZE_32B  = 3'b101,   // 32 bytes
        AXI_SIZE_64B  = 3'b110,   // 64 bytes
        AXI_SIZE_128B = 3'b111    // 128 bytes
    } axi_size_t;

    //=========================================================================
    // DDR4 Speed Grades (MHz)
    //=========================================================================
    typedef enum int {
        DDR4_1600 = 1600,
        DDR4_1866 = 1866,
        DDR4_2133 = 2133,
        DDR4_2400 = 2400,
        DDR4_2666 = 2666,
        DDR4_2933 = 2933,
        DDR4_3200 = 3200
    } ddr4_speed_t;

    //=========================================================================
    // DDR4 Timing Parameters Structure
    //=========================================================================
    typedef struct {
        int tCK;      // Clock period (ps)
        int tRCD;     // RAS to CAS delay (ns)
        int tRP;      // Row precharge time (ns)
        int tRAS;     // Row active time (ns)
        int tRC;      // Row cycle time (ns)
        int tRFC;     // Refresh cycle time (ns)
        int tREFI;    // Refresh interval (ns)
        int tWR;      // Write recovery time (ns)
        int tRTP;     // Read to precharge (ns)
        int tWTR_S;   // Write to read (same bank group) (ns)
        int tWTR_L;   // Write to read (different bank group) (ns)
        int tFAW;     // Four activate window (ns)
        int tCCD_S;   // CAS to CAS (same bank group) (ns)
        int tCCD_L;   // CAS to CAS (different bank group) (ns)
        int CL;       // CAS latency (cycles)
        int CWL;      // CAS write latency (cycles)
    } ddr4_timing_t;

    //=========================================================================
    // DDR4 Timing Lookup Function
    //=========================================================================
    function automatic ddr4_timing_t get_ddr4_timing(ddr4_speed_t speed);
        ddr4_timing_t timing;

        case (speed)
            DDR4_1600: begin
                timing.tCK     = 1250;
                timing.tRCD    = 14;
                timing.tRP     = 14;
                timing.tRAS    = 35;
                timing.tRC     = 49;
                timing.tRFC    = 350;
                timing.tREFI   = 7800;
                timing.tWR     = 15;
                timing.tRTP    = 8;
                timing.tWTR_S  = 3;
                timing.tWTR_L  = 8;
                timing.tFAW    = 30;
                timing.tCCD_S  = 4;
                timing.tCCD_L  = 5;
                timing.CL      = 11;
                timing.CWL     = 9;
            end

            DDR4_2133: begin
                timing.tCK     = 937;
                timing.tRCD    = 14;
                timing.tRP     = 14;
                timing.tRAS    = 33;
                timing.tRC     = 47;
                timing.tRFC    = 350;
                timing.tREFI   = 7800;
                timing.tWR     = 15;
                timing.tRTP    = 8;
                timing.tWTR_S  = 3;
                timing.tWTR_L  = 8;
                timing.tFAW    = 25;
                timing.tCCD_S  = 4;
                timing.tCCD_L  = 5;
                timing.CL      = 15;
                timing.CWL     = 11;
            end

            DDR4_2400: begin
                timing.tCK     = 833;
                timing.tRCD    = 14;
                timing.tRP     = 14;
                timing.tRAS    = 32;
                timing.tRC     = 46;
                timing.tRFC    = 350;
                timing.tREFI   = 7800;
                timing.tWR     = 15;
                timing.tRTP    = 8;
                timing.tWTR_S  = 3;
                timing.tWTR_L  = 8;
                timing.tFAW    = 23;
                timing.tCCD_S  = 4;
                timing.tCCD_L  = 5;
                timing.CL      = 17;
                timing.CWL     = 12;
            end

            DDR4_2666: begin
                timing.tCK     = 750;
                timing.tRCD    = 14;
                timing.tRP     = 14;
                timing.tRAS    = 32;
                timing.tRC     = 46;
                timing.tRFC    = 350;
                timing.tREFI   = 7800;
                timing.tWR     = 15;
                timing.tRTP    = 8;
                timing.tWTR_S  = 3;
                timing.tWTR_L  = 8;
                timing.tFAW    = 21;
                timing.tCCD_S  = 4;
                timing.tCCD_L  = 6;
                timing.CL      = 19;
                timing.CWL     = 14;
            end

            DDR4_3200: begin
                timing.tCK     = 625;
                timing.tRCD    = 14;
                timing.tRP     = 14;
                timing.tRAS    = 32;
                timing.tRC     = 46;
                timing.tRFC    = 350;
                timing.tREFI   = 7800;
                timing.tWR     = 15;
                timing.tRTP    = 8;
                timing.tWTR_S  = 3;
                timing.tWTR_L  = 8;
                timing.tFAW    = 16;
                timing.tCCD_S  = 4;
                timing.tCCD_L  = 6;
                timing.CL      = 22;
                timing.CWL     = 16;
            end

            default: begin
                // Default to DDR4-2400
                timing.tCK     = 833;
                timing.tRCD    = 14;
                timing.tRP     = 14;
                timing.tRAS    = 32;
                timing.tRC     = 46;
                timing.tRFC    = 350;
                timing.tREFI   = 7800;
                timing.tWR     = 15;
                timing.tRTP    = 8;
                timing.tWTR_S  = 3;
                timing.tWTR_L  = 8;
                timing.tFAW    = 23;
                timing.tCCD_S  = 4;
                timing.tCCD_L  = 5;
                timing.CL      = 17;
                timing.CWL     = 12;
            end
        endcase

        return timing;
    endfunction

    //=========================================================================
    // Memory Density Parameters
    //=========================================================================
    typedef struct {
        int density_gb;
        int banks;
        int bank_groups;
        int rows;
        int columns;
        int page_size_bytes;
    } ddr4_density_t;

    function automatic ddr4_density_t get_ddr4_density(int density_gb, int dq_width);
        ddr4_density_t params;

        params.density_gb = density_gb;
        params.banks = 16;        // DDR4 has 16 banks (4 bank groups x 4 banks)
        params.bank_groups = 4;

        case (density_gb)
            1: begin
                params.rows = 32768;
                params.columns = 1024;
            end
            2: begin
                params.rows = 65536;
                params.columns = 1024;
            end
            4: begin
                params.rows = 65536;
                params.columns = 1024;
            end
            8: begin
                params.rows = 131072;
                params.columns = 1024;
            end
            16: begin
                params.rows = 131072;
                params.columns = 1024;
            end
            default: begin
                params.rows = 65536;
                params.columns = 1024;
            end
        endcase

        params.page_size_bytes = (params.columns * dq_width) / 8;

        return params;
    endfunction

    //=========================================================================
    // Utility Functions
    //=========================================================================

    // Convert nanoseconds to clock cycles
    function automatic int ns_to_cycles(int ns, int tck_ps);
        return (ns * 1000 + tck_ps - 1) / tck_ps;  // Round up
    endfunction

    // Calculate wrap boundary
    function automatic logic [31:0] calc_wrap_boundary(
        logic [31:0] addr,
        logic [2:0]  size,
        logic [7:0]  len
    );
        logic [31:0] wrap_size;
        wrap_size = (1 << size) * (len + 1);
        return (addr / wrap_size) * wrap_size;
    endfunction

    // Check if burst length is valid for WRAP
    function automatic logic is_valid_wrap_len(logic [7:0] len);
        return (len == 1 || len == 3 || len == 7 || len == 15);
    endfunction

    // Calculate number of bytes per beat from size
    function automatic int size_to_bytes(logic [2:0] size);
        return 1 << size;
    endfunction

endpackage

`endif // DDR4_AXI4_PKG_SV
