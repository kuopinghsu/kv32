// ============================================================================
// File: riscv_core_setting.sv
// Project: KV32 RISC-V Processor — riscv-dv target
// Description: Core-specific settings for Google riscv-dv random instruction
//              generator.  Describes the KV32 RV32IMAC core capabilities.
//
// This file is consumed by riscv-dv (via +incdir) and must not depend on any
// project-specific packages.
// ============================================================================

// --------------------------------------------------------------------------
// Supported Privilege Modes
// --------------------------------------------------------------------------
// KV32 supports Machine mode only.
privileged_mode_t supported_privileged_mode[] = {MACHINE_MODE};

// --------------------------------------------------------------------------
// Supported ISA Extensions
// --------------------------------------------------------------------------
// KV32 implements RV32IMAC:
//   I — Base integer instruction set
//   M — Integer multiply/divide
//   A — Atomic instructions (AMO + LR/SC)
//   C — 16-bit compressed instructions (Zca)
riscv_instr_group_t supported_isa[] = {RV32I, RV32M, RV32A, RV32C};

// --------------------------------------------------------------------------
// Register Descriptions
// --------------------------------------------------------------------------
// Number of GPRs = 32 (x0–x31)
parameter int NUM_GPR = 32;

// --------------------------------------------------------------------------
// Unsupported Instructions
// --------------------------------------------------------------------------
// KV32 does not implement any special unsupported instructions within the
// I/M/A sets.  List any instructions here that should be excluded from
// random generation.
riscv_instr_name_t unsupported_instr[] = {};

// --------------------------------------------------------------------------
// ISA Extension Setting
// --------------------------------------------------------------------------
// C (compressed/Zca) extension is supported.
parameter int XLEN = 32;

// --------------------------------------------------------------------------
// Vector Extension Settings (not supported)
// --------------------------------------------------------------------------
parameter int VECTOR_EXTENSION_ENABLE = 0;
parameter int VLEN = 512;

// --------------------------------------------------------------------------
// Number of Harts
// --------------------------------------------------------------------------
parameter int NUM_HARTS = 1;

// --------------------------------------------------------------------------
// Physical Memory Protection (not supported)
// --------------------------------------------------------------------------
parameter int PMP_NUM_REGIONS = 0;

// --------------------------------------------------------------------------
// Enhanced PMP (Smepmp, not supported)
// --------------------------------------------------------------------------
parameter int SMEPMP = 0;

// --------------------------------------------------------------------------
// Debug Mode Support
// --------------------------------------------------------------------------
parameter int SUPPORT_DEBUG_MODE = 0;

// --------------------------------------------------------------------------
// Supervisor Mode (not supported — M-mode only core)
// --------------------------------------------------------------------------
parameter int SUPPORT_SUPERVISOR_MODE = 0;

// --------------------------------------------------------------------------
// Max interrupt/exception ID used in cause register
// --------------------------------------------------------------------------
parameter int MAX_INTERRUPT_ID = 11;
parameter int MAX_EXCEPTION_ID = 11;

// --------------------------------------------------------------------------
// Custom CSR Addresses (none for KV32)
// --------------------------------------------------------------------------
// KV32 only implements standard M-mode CSRs.
// Add any implementation-specific CSRs here if needed.

// --------------------------------------------------------------------------
// Lots of interrupt sources to configure PLIC, etc. — not used in generation
// --------------------------------------------------------------------------
parameter int NUM_INTERRUPTS = 0;
