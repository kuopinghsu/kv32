#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#if __riscv_xlen == 64
#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                        \
        .align 8; .global tohost; tohost: .dword 0;                 \
        .align 8; .global fromhost; fromhost: .dword 0;             \
        .popsection;                                                \
        .align 8; .global begin_regstate; begin_regstate:           \
        .word 128;                                                  \
        .align 8; .global end_regstate; end_regstate:               \
        .word 4;
#else
#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                        \
        .align 4; .global tohost; tohost: .word 0;                  \
        .align 4; .global fromhost; fromhost: .word 0;              \
        .popsection;                                                \
        .align 8; .global begin_regstate; begin_regstate:           \
        .word 128;                                                  \
        .align 8; .global end_regstate; end_regstate:               \
        .word 4;
#endif

#if __riscv_xlen == 64
#define RVMODEL_HALT                                                \
        li t1, 1;                                                   \
        la t0, tohost;                                              \
        sd t1, (t0);                                                \
        j .;
#else
#define RVMODEL_HALT                                                \
        li x1, 1;                                                   \
write_tohost:                                                       \
        sw x1, tohost, t5;                                          \
        j write_tohost;
#endif

// see https://github.com/riscv-non-isa/riscv-arch-test/issues/659
// get rid of compressed instructions
#define RVMODEL_BOOT                                                \
        .option norelax;

#define RVMODEL_DATA_BEGIN                                          \
  .align 4; .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                            \
  .align 4; .global end_signature; end_signature:                   \
  RVMODEL_DATA_SECTION

#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif
