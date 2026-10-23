/* The BBC BASIC V runtime: what a BASIC program translated by SuperSpider's
 * tools/bas2c.py (a game's basic.c) needs from the interpreter - its
 * statements as calls into the emulated machine (VDU, SWIs, CALL), strings,
 * arrays, DIM'd memory, indirection, dynamically scoped variables and error
 * handlers - on libroger. basic_runtime.c implements it; one copy for every
 * game, which links it with its basic.c and game.c.
 *
 * The game supplies (game.c): bas_page and bas_lomem (where the program
 * was, and the heap above it), bas_main's caller, and bas_asm if the
 * program assembles. The settings below it may change before bas_main(). */
#ifndef BASIC_RUNTIME_H
#define BASIC_RUNTIME_H
#include <setjmp.h>
#include <stdint.h>
#include <string.h>
#include <roger.h>
#include <roger_cpu.h>

#define TRUE  (-1)
#define FALSE 0

/* --- strings: values, at most 255 characters as in BASIC */
typedef struct { char s[256]; } S;
typedef struct { double n; S s; } V;       /* an FN that returns either */
S s_(const char *c);
S cat(S a, S b);
S left(S a, int n);
S right(S a, int n);
S mid(S a, int p, int n);                  /* MID$(a,p,n); n < 0: the rest */
S str(double v);                           /* STR$ */
S strx(int32_t v);                         /* STR$~ */
S chr(int c);
S string_n(int n, S s);                    /* STRING$(n, s) */
static inline int len(S a) { return (int)strlen(a.s); }
static inline int asc(S a) { return a.s[0] ? (uint8_t)a.s[0] : -1; }
double val(S a);
int instr(S a, S b, int from);
S get_s(uint32_t a);                       /* $a: up to CR */
S get_s0(uint32_t a);                      /* a SWI's string: up to a control character */
void put_s(uint32_t a, S v);               /* $a = v (CR-terminated) */
S print_num(double v);                     /* a number as PRINT lays it out (@% = 10) */
S mid_set(S a, int p, int n, S b);         /* MID$(a,p,n) = b: a with b over it from p */

/* --- arrays: up to two dimensions (d2 < 0: one) */
typedef struct { int32_t *p; int d1, d2; } ARR_i;
typedef struct { double *p; int d1, d2; } ARR_r;
typedef struct { S *p; int d1, d2; } ARR_s;
void dim_i(ARR_i *a, int d1, int d2);
void dim_r(ARR_r *a, int d1, int d2);
void dim_s(ARR_s *a, int d1, int d2);
int32_t *el_i(ARR_i *a, int i, int j);
double *el_r(ARR_r *a, int i, int j);
S *el_s(ARR_s *a, int i, int j);
void all_i(ARR_i *a, int32_t v);
void all_r(ARR_r *a, double v);
void all_s(ARR_s *a, S v);

/* --- memory */
#define PK(a)      (*(int32_t *)(MEM + (uint32_t)(a)))        /* !a */
#define PB(a)      (MEM[(uint32_t)(a)])                       /* ?a */
uint32_t dim(int bytes);                   /* DIM x% bytes-1 */
void bas_clear(void);                      /* CLEAR: DIM's heap back where it started */
extern int32_t bas_page;                   /* PAGE (the game defines it) */
extern uint32_t bas_lomem;                 /* the heap DIM takes blocks from: its next free
                                              address, at first the program's TOP rounded up
                                              to a word, or where the program's own DIMs
                                              must land (the game defines it) */

/* --- settings (the game may change them before bas_main) */
extern int bas_dim_clear;                  /* DIM zeroes the block (BASIC doesn't: default 0) */
extern unsigned bas_sys_idle;              /* instructions' worth of time each SYS lets pass,
                                              standing in for the interpreter's own (a loop
                                              that polls a SWI waits on it); default 0 */

/* --- PROC/FN parameters and LOCALs: saved on entry, restored on exit */
void save_i(int32_t *p);
void save_r(double *p);
void save_s(S *p);
int undo_mark(void);
void undo_to(int mark);

/* --- errors */
typedef struct { jmp_buf jb; int undo; } HND;
extern HND *bas_h, bas_global;
extern int32_t bas_err, bas_erl, bas_line;
extern S bas_report;
void bas_error(int32_t err, const char *msg) __attribute__((noreturn));
#define L(n) (bas_line = (n))

/* --- DATA */
extern const char *const bas_data[];
extern int data_p;
int32_t read_i(void);
double read_r(void);
S read_s(void);

/* --- the machine */
void vdu(int n, ...);                      /* VDU bytes, ending -1 */
void vduw(int v);                          /* VDU v; (16 bits) */
void print_s(S s);
void print_tab(int x, int y);              /* TAB(x,y); y < 0: TAB(x) */
void plot(int k, int x, int y);
void gcol(int a, int c);
void colour(int c);
void colour_rgb(int c, int r, int g, int b);   /* COLOUR c,r,g,b */
void tint(int which, int t);               /* TINT: 0/1 text fg/bg, 2/3 graphics fg/bg */
void rectangle(int x, int y, int w, int h);
void rectangle_fill(int x, int y, int w, int h);
void rectangle_copy(int move, int x, int y, int w, int h, int tx, int ty);
void line(int x1, int y1, int x2, int y2);
void cls(void);
void mode(int m);
int bas_mode(void);
int bas_vpos(void);                        /* VPOS, POS: the text cursor */
int bas_pos(void);
void origin(int x, int y);
void off(void);
void oscli(S c);
void oscli_c(const char *c);
extern int (*bas_cli)(const char *c);      /* the game's first look at a * command: 1 if done */
void mouse(int32_t *x, int32_t *y, int32_t *b);
void mouse_to(int x, int y);
void mouse_step(int n);
void mouse_rect(int x, int y, int w, int h);
int inkey(int n);                          /* INKEY(n): n < 0 a key test */
S inkey_s(int n);
int get(void);
int32_t time_get(void);
void time_set(int32_t t);
S time_s(void);                            /* TIME$ */
void wait_(void);                          /* WAIT */
int rnd(int n);                            /* RND(n): 1..n */
double rnd1(void);                         /* RND(1) */
int32_t rnd32(void);                       /* RND */
#define RADf(x) ((x) * 3.14159265358979 / 180)
#define DEGf(x) ((x) * 180 / 3.14159265358979)
void sound(int ch, int amp, int pitch, int dur);
void sound_on(int on);
void voices(int n);
void call(uint32_t addr);                  /* CALL: R0-R7 from A%-H% */
int32_t usr(uint32_t addr);
void sys_call(uint32_t swi, uint32_t *out);    /* SYS: R[] set; out = R0-R9 after */
uint32_t swi_number(const char *name);
uint32_t roger_scratch_n(int k, const char *s);   /* a SYS string argument (one buffer per register) */
void bas_asm(const char *text);            /* an assembler statement bas2c.py couldn't translate:
                                              the game's own (game.c) */

/* --- the assembler (tools/basasm.py's code): at P% (O% with OPT 4-7) */
extern int bas_opt;                        /* OPT: bit 1 errors, bit 2 offset assembly */
void asm_opt(int v);
void asm_w(uint32_t w);                    /* EQUD, an instruction */
void asm_h(int v);                         /* EQUW */
void asm_b(int v);                         /* EQUB */
void asm_s(S s);                           /* EQUS */
void asm_align(void);
uint32_t asm_imm(int32_t v);               /* #v as an operand 2: I, rotation, 8 bits */
uint32_t asm_shift(int type, int32_t n);   /* a shift by #n */
uint32_t asm_branch(int32_t to);           /* B/BL's offset from P% */
uint32_t asm_off12(int32_t off);           /* LDR/STR's #offset: U and 12 bits */
uint32_t asm_pcrel(int32_t to);            /* LDR/STR of a label: from P% + 8 */
void asm_adr(int cond, int rd, int32_t to);    /* ADR: ADD or SUB from PC */

/* --- files */
int32_t bas_open(int how, S name);
void bas_close(int32_t h);
int bas_eof(int32_t h);
int bas_bget(int32_t h);
void bas_bput(int32_t h, int c);
void bas_bput_s(int32_t h, S v, int nl);   /* BPUT#h, string (+ LF unless nl is 0) */
int32_t bas_ext(int32_t h);                /* EXT#h */
int32_t bas_ptr(int32_t h);                /* PTR#h */
void bas_ptr_set(int32_t h, int32_t p);    /* PTR#h = p */
void bas_print_i(int32_t h, int32_t v);
void bas_print_r(int32_t h, double v);
void bas_print_s(int32_t h, S v);
int32_t bas_input_i(int32_t h);
double bas_input_r(int32_t h);
S bas_input_s(int32_t h);

void quit(void) __attribute__((noreturn));
void bas_main(void);                       /* the program (basic.c) */

/* --- several programs that CHAIN one another (bas2c.py --name N: basic_N.c
 * defines bas_prog_N): bas_run runs one, at PAGE (bas_page) with its heap
 * from its TOP; CHAIN looks the name up among them (its last components:
 * "REALM2.X" is <Disc2>.X with Disc2 set to ADFS::0.$.REALM2) and starts
 * it afresh, keeping only A%-Z% (and PAGE, as a PAGE= before it left it) */
struct bas_program {
    const char *name;                      /* RISC OS path, its last components (e.g. "$.!Realm.Loader") */
    void (*main)(void);
    const char *const *data;
    void (*clear)(void);                   /* its variables unset */
    uint32_t size;                         /* the tokenised program's length: TOP - PAGE */
};
void bas_run(const struct bas_program *const *programs, const struct bas_program *first)
    __attribute__((noreturn));
void bas_chain(S name) __attribute__((noreturn));
extern const struct bas_program *bas_current;
/* the game's hook: the program a CHAIN names (NULL: look it up as above) */
extern const struct bas_program *(*bas_chain_hook)(const char *name);
/* GOTO from a PROC/FN into the main program: the PROC is left (its LOCALs
 * as they are), and the main program goes on at the line */
extern jmp_buf bas_main_jb;
extern int bas_main_line, bas_main_undo;
void bas_goto_main(int line) __attribute__((noreturn));

/* the resident integer variables, A%-Z%: kept across CHAIN; P% (and O%)
 * the assembler's */
extern int32_t A_I, B_I, C_I, D_I, E_I, F_I, G_I, H_I, I_I, J_I, K_I, L_I, M_I,
    N_I, O_I, P_I, Q_I, R_I, S_I, T_I, U_I, V_I, W_I, X_I, Y_I, Z_I;
#endif /* BASIC_RUNTIME_H */
