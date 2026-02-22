/*
 ****************************************************************************
 *
 *                   "DHRYSTONE" Benchmark Program
 *                   -----------------------------
 *
 *  Version:    C, Version 2.1
 *
 *  File:       dhry.h (part 1 of 3)
 *
 *  Date:       May 25, 1988
 *
 *  Author:     Reinhold P. Weicker
 *              Siemens AG, E STE 35
 *              Postfach 3240
 *              8520 Erlangen
 *              Germany (West)
 *                      Phone:  [+49]-9131-7-20330
 *                              (8-17 Central European Time)
 *                      UUCP:   ..!mcsun!unido!estevax!weicker
 *
 *              Original Version (in Ada) published in
 *              "Communications of the ACM" vol. 27., no. 10 (Oct. 1984),
 *              pp. 1013 - 1030, together with the statistics
 *              on which the distribution of statements etc. is based.
 *
 *              In this C version, the following C library functions are used:
 *              - strcpy, strcmp (inside the measurement loop)
 *              - printf, scanf (outside the measurement loop)
 *
 ****************************************************************************
 */

#ifndef DHRY_H
#define DHRY_H

#include <stdint.h>

/* For baremetal RISC-V */
#define NOENUM

/* Type definitions */
typedef enum {Ident_1, Ident_2, Ident_3, Ident_4, Ident_5} Enumeration;

typedef int     One_Thirty;
typedef int     One_Fifty;
typedef char    Capital_Letter;
typedef int     Boolean;
typedef char    Str_30[31];
typedef int     Arr_1_Dim[50];
typedef int     Arr_2_Dim[50][50];

typedef struct record {
    struct record *Ptr_Comp;
    Enumeration    Discr;
    union {
        struct {
            Enumeration Enum_Comp;
            int         Int_Comp;
            char        Str_Comp[31];
        } var_1;
        struct {
            Enumeration E_Comp_2;
            char        Str_2_Comp[31];
        } var_2;
        struct {
            char        Ch_1_Comp;
            char        Ch_2_Comp;
        } var_3;
    } variant;
} Rec_Type, *Rec_Pointer;

/* Constants */
#define Null 0

#define true  1
#define false 0

/* Procedure declarations */
extern void Proc_1(Rec_Pointer Ptr_Val_Par);
extern void Proc_2(One_Fifty *Int_Par_Ref);
extern void Proc_3(Rec_Pointer *Ptr_Ref_Par);
extern void Proc_4(void);
extern void Proc_5(void);
extern void Proc_6(Enumeration Enum_Val_Par, Enumeration *Enum_Ref_Par);
extern void Proc_7(One_Fifty Int_1_Par_Val, One_Fifty Int_2_Par_Val, One_Fifty *Int_Par_Ref);
extern void Proc_8(Arr_1_Dim Arr_1_Par_Ref, Arr_2_Dim Arr_2_Par_Ref, int Int_1_Par_Val, int Int_2_Par_Val);
extern Enumeration Func_1(Capital_Letter Ch_1_Par_Val, Capital_Letter Ch_2_Par_Val);
extern Boolean Func_2(Str_30 Str_1_Par_Ref, Str_30 Str_2_Par_Ref);
extern Boolean Func_3(Enumeration Enum_Par_Val);

/* Global variables */
extern Rec_Pointer Ptr_Glob, Next_Ptr_Glob;
extern int Int_Glob;
extern Boolean Bool_Glob;
extern char Ch_1_Glob, Ch_2_Glob;
extern int Arr_1_Glob[50];
extern int Arr_2_Glob[50][50];

/* For compatibility with different C compilers */
#define REG

#endif /* DHRY_H */
