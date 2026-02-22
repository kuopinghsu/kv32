/*
 ****************************************************************************
 *
 *                   "DHRYSTONE" Benchmark Program
 *                   -----------------------------
 *
 *  Version:    C, Version 2.1
 *
 *  File:       dhry_1.c (part 2 of 3)
 *
 *  Date:       May 25, 1988
 *
 *  Author:     Reinhold P. Weicker
 *
 *  Adapted for RISC-V baremetal environment
 *
 ****************************************************************************
 */

#include "dhry.h"
#include <csr.h>

/* External functions */
extern void putc(char c);

/* Simple string functions for baremetal */
static char *mystrcpy(char *dest, const char *src) {
    char *d = dest;
    while ((*d++ = *src++));
    return dest;
}

/* Simple output functions */
static void puts(const char *s) {
    while (*s) {
        putc(*s++);
    }
}

static void print_uint_recursive(uint32_t val) {
    if (val >= 10) {
        print_uint_recursive(val / 10);
    }
    putc('0' + (val % 10));
}

static void print_uint(uint32_t val) {
    print_uint_recursive(val);
}

static void print_uint64_recursive(uint64_t val) {
    if (val >= 10) {
        print_uint64_recursive(val / 10);
    }
    putc('0' + (val % 10));
}

static void print_uint64(uint64_t val) {
    print_uint64_recursive(val);
}

/* Global Variables */
Rec_Pointer     Ptr_Glob, Next_Ptr_Glob;
int             Int_Glob;
Boolean         Bool_Glob;
char            Ch_1_Glob, Ch_2_Glob;
int             Arr_1_Glob[50];
int             Arr_2_Glob[50][50];

/* Number of runs - reduced for faster simulation */
#define NUMBER_OF_RUNS 100

int main(void) {
    One_Fifty       Int_1_Loc;
    REG One_Fifty   Int_2_Loc;
    One_Fifty       Int_3_Loc;
    REG char        Ch_Index;
    Enumeration     Enum_Loc;
    Str_30          Str_1_Loc;
    Str_30          Str_2_Loc;
    REG int         Run_Index;

    /* Allocate records on stack (no malloc in baremetal) */
    Rec_Type Rec_1, Rec_2;

    puts("\n");
    puts("======================================\n");
    puts("  Dhrystone Benchmark v2.1 (RISC-V)\n");
    puts("======================================\n\n");

    /* Initialize */
    Next_Ptr_Glob = &Rec_1;
    Ptr_Glob = &Rec_2;

    Ptr_Glob->Ptr_Comp                  = Next_Ptr_Glob;
    Ptr_Glob->Discr                     = Ident_1;
    Ptr_Glob->variant.var_1.Enum_Comp   = Ident_3;
    Ptr_Glob->variant.var_1.Int_Comp    = 40;
    mystrcpy(Ptr_Glob->variant.var_1.Str_Comp, "DHRYSTONE PROGRAM, SOME STRING");
    mystrcpy(Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING");

    Arr_2_Glob[8][7] = 10;

    puts("Execution starts, ");
    print_uint(NUMBER_OF_RUNS);
    puts(" runs through Dhrystone\n\n");

    /* Read start time */
    uint64_t start_cycles = read_csr_cycle64();
    uint64_t start_instret = read_csr_instret64();

    /***************/
    /* Start timer */
    /***************/

    for (Run_Index = 1; Run_Index <= NUMBER_OF_RUNS; ++Run_Index) {
        Proc_5();
        Proc_4();
        Int_1_Loc = 2;
        Int_2_Loc = 3;
        mystrcpy(Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING");
        Enum_Loc = Ident_2;
        Bool_Glob = ! Func_2(Str_1_Loc, Str_2_Loc);

        while (Int_1_Loc < Int_2_Loc) {
            Int_3_Loc = 5 * Int_1_Loc - Int_2_Loc;
            Proc_7(Int_1_Loc, Int_2_Loc, &Int_3_Loc);
            Int_1_Loc += 1;
        }

        Proc_8(Arr_1_Glob, Arr_2_Glob, Int_1_Loc, Int_3_Loc);
        Proc_1(Ptr_Glob);

        for (Ch_Index = 'A'; Ch_Index <= Ch_2_Glob; ++Ch_Index) {
            if (Enum_Loc == Func_1(Ch_Index, 'C')) {
                Proc_6(Ident_1, &Enum_Loc);
                mystrcpy(Str_2_Loc, "DHRYSTONE PROGRAM, 3'RD STRING");
                Int_2_Loc = Run_Index;
                Int_Glob = Run_Index;
            }
        }

        Int_2_Loc = Int_2_Loc * Int_1_Loc;
        Int_1_Loc = Int_2_Loc / Int_3_Loc;
        Int_2_Loc = 7 * (Int_2_Loc - Int_3_Loc) - Int_1_Loc;
        Proc_2(&Int_1_Loc);
    }

    /**************/
    /* Stop timer */
    /**************/

    uint64_t end_cycles = read_csr_cycle64();
    uint64_t end_instret = read_csr_instret64();

    puts("Execution ends\n\n");

    /* Calculate results */
    uint64_t total_cycles = end_cycles - start_cycles;
    uint64_t total_instret = end_instret - start_instret;

    puts("Final values of the variables used in the benchmark:\n\n");
    puts("Int_Glob:            ");
    print_uint(Int_Glob);
    puts(" (should be 5)\n");

    puts("Bool_Glob:           ");
    print_uint(Bool_Glob);
    puts(" (should be 1)\n");

    puts("Ch_1_Glob:           ");
    putc(Ch_1_Glob);
    puts(" (should be A)\n");

    puts("Ch_2_Glob:           ");
    putc(Ch_2_Glob);
    puts(" (should be B)\n");

    puts("Arr_1_Glob[8]:       ");
    print_uint(Arr_1_Glob[8]);
    puts(" (should be 7)\n");

    puts("Arr_2_Glob[8][7]:    ");
    print_uint(Arr_2_Glob[8][7]);
    puts(" (should be ");
    print_uint(NUMBER_OF_RUNS + 10);
    puts(")\n");

    puts("Ptr_Glob->Discr:     ");
    print_uint(Ptr_Glob->Discr);
    puts(" (should be 0)\n");

    puts("Ptr_Glob->Enum_Comp: ");
    print_uint(Ptr_Glob->variant.var_1.Enum_Comp);
    puts(" (should be 2)\n");

    puts("Ptr_Glob->Int_Comp:  ");
    print_uint(Ptr_Glob->variant.var_1.Int_Comp);
    puts(" (should be 17)\n");

    puts("Ptr_Glob->Str_Comp:  ");
    puts(Ptr_Glob->variant.var_1.Str_Comp);
    puts("\n  (should be DHRYSTONE PROGRAM, SOME STRING)\n");

    puts("Next_Ptr_Glob->Discr:     ");
    print_uint(Next_Ptr_Glob->Discr);
    puts(" (should be 0)\n");

    puts("Next_Ptr_Glob->Enum_Comp: ");
    print_uint(Next_Ptr_Glob->variant.var_1.Enum_Comp);
    puts(" (should be 1)\n");

    puts("Next_Ptr_Glob->Int_Comp:  ");
    print_uint(Next_Ptr_Glob->variant.var_1.Int_Comp);
    puts(" (should be 18)\n");

    puts("Next_Ptr_Glob->Str_Comp:  ");
    puts(Next_Ptr_Glob->variant.var_1.Str_Comp);
    puts("\n  (should be DHRYSTONE PROGRAM, SOME STRING)\n");

    puts("Int_1_Loc:           ");
    print_uint(Int_1_Loc);
    puts(" (should be 5)\n");

    puts("Int_2_Loc:           ");
    print_uint(Int_2_Loc);
    puts(" (should be 13)\n");

    puts("Int_3_Loc:           ");
    print_uint(Int_3_Loc);
    puts(" (should be 7)\n");

    puts("Enum_Loc:            ");
    print_uint(Enum_Loc);
    puts(" (should be 1)\n");

    puts("Str_1_Loc:           ");
    puts(Str_1_Loc);
    puts("\n  (should be DHRYSTONE PROGRAM, 1'ST STRING)\n");

    puts("Str_2_Loc:           ");
    puts(Str_2_Loc);
    puts("\n  (should be DHRYSTONE PROGRAM, 2'ND STRING)\n");

    puts("\n");
    puts("Performance Metrics:\n");
    puts("--------------------\n");
    puts("Runs:        ");
    print_uint(NUMBER_OF_RUNS);
    puts("\n");

    puts("Cycles:      ");
    print_uint64(total_cycles);
    puts("\n");

    puts("Instructions: ");
    print_uint64(total_instret);
    puts("\n");

    uint32_t cycles_per_run = (uint32_t)(total_cycles / NUMBER_OF_RUNS);
    uint32_t instret_per_run = (uint32_t)(total_instret / NUMBER_OF_RUNS);

    puts("Cycles/Run:   ");
    print_uint(cycles_per_run);
    puts("\n");

    puts("Instrs/Run:   ");
    print_uint(instret_per_run);
    puts("\n");

    /* Assuming 100 MHz clock */
    #define MHZ 100
    uint32_t usec_per_run = cycles_per_run / MHZ;
    if (usec_per_run > 0) {
        uint32_t dhrystones_per_sec = 1000000 / usec_per_run;
        uint32_t dmips = dhrystones_per_sec / 1757;  /* 1757 is 1 DMIPS @ 1 MIPS VAX */

        puts("Time/Run:     ");
        print_uint(usec_per_run);
        puts(" us @ 100 MHz\n");

        puts("Dhrystones/s: ");
        print_uint(dhrystones_per_sec);
        puts("\n");

        puts("DMIPS:        ");
        print_uint(dmips);
        puts("\n");

        puts("DMIPS/MHz:    ");
        print_uint(dmips * 100 / MHZ);  /* *100 for decimal point simulation */
        puts(".");
        print_uint((dmips * 100 / MHZ) % 100);
        puts("\n");
    }

    puts("\n======================================\n");
    puts("  Dhrystone Benchmark Complete\n");
    puts("======================================\n\n");

    return 0;
}

void Proc_1(Rec_Pointer Ptr_Val_Par) {
    REG Rec_Pointer Next_Record = Ptr_Val_Par->Ptr_Comp;

    *Ptr_Val_Par->Ptr_Comp = *Ptr_Glob;
    Ptr_Val_Par->variant.var_1.Int_Comp = 5;
    Next_Record->variant.var_1.Int_Comp = Ptr_Val_Par->variant.var_1.Int_Comp;
    Next_Record->Ptr_Comp = Ptr_Val_Par->Ptr_Comp;
    Proc_3(&Next_Record->Ptr_Comp);

    if (Next_Record->Discr == Ident_1) {
        Next_Record->variant.var_1.Int_Comp = 6;
        Proc_6(Ptr_Val_Par->variant.var_1.Enum_Comp, &Next_Record->variant.var_1.Enum_Comp);
        Next_Record->Ptr_Comp = Ptr_Glob->Ptr_Comp;
        Proc_7(Next_Record->variant.var_1.Int_Comp, 10, &Next_Record->variant.var_1.Int_Comp);
    } else {
        *Ptr_Val_Par = *Ptr_Val_Par->Ptr_Comp;
    }
}

void Proc_2(One_Fifty *Int_Par_Ref) {
    One_Fifty Int_Loc;
    Enumeration Enum_Loc;

    Int_Loc = *Int_Par_Ref + 10;
    do {
        if (Ch_1_Glob == 'A') {
            Int_Loc -= 1;
            *Int_Par_Ref = Int_Loc - Int_Glob;
            Enum_Loc = Ident_1;
        }
    } while (Enum_Loc != Ident_1);
}

void Proc_3(Rec_Pointer *Ptr_Ref_Par) {
    if (Ptr_Glob != Null) {
        *Ptr_Ref_Par = Ptr_Glob->Ptr_Comp;
    }
    Proc_7(10, Int_Glob, &Ptr_Glob->variant.var_1.Int_Comp);
}

void Proc_4(void) {
    Boolean Bool_Loc;

    Bool_Loc = Ch_1_Glob == 'A';
    Bool_Glob = Bool_Loc | Bool_Glob;
    Ch_2_Glob = 'B';
}

void Proc_5(void) {
    Ch_1_Glob = 'A';
    Bool_Glob = false;
}
