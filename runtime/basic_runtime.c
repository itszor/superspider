/* BBC BASIC V's statements for a program translated by tools/bas2c.py (see
 * basic_runtime.h): each does what the interpreter would, through the
 * emulated machine. (First written for Stunt Racer 2000; Chocks Away and
 * Saloon Cars added to it.) */
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include "basic_runtime.h"

int32_t A_I, B_I, C_I, D_I, E_I, F_I, G_I, H_I, I_I, J_I, K_I, L_I, M_I,
    N_I, O_I, P_I, Q_I, R_I, S_I, T_I, U_I, V_I, W_I, X_I, Y_I, Z_I;
int bas_dim_clear;
unsigned bas_sys_idle;

/* --- strings */
S s_(const char *c) { S r; snprintf(r.s, sizeof r.s, "%s", c); return r; }
S cat(S a, S b) { S r; snprintf(r.s, sizeof r.s, "%s%s", a.s, b.s); return r; }
S left(S a, int n) { if (n >= 0 && n < len(a)) a.s[n] = 0; return a; }
S right(S a, int n) { int l = len(a); return n >= l ? a : s_(a.s + l - (n < 0 ? 0 : n)); }
S mid(S a, int p, int n)
{
    int l = len(a);
    if (p < 1) p = 1;
    if (p > l) return s_("");
    S r = s_(a.s + p - 1);
    return n < 0 ? r : left(r, n);
}
S str(double v)
{
    S r;
    if (v == (int32_t)v) snprintf(r.s, sizeof r.s, "%d", (int32_t)v);
    else snprintf(r.s, sizeof r.s, "%.9G", v);
    return r;
}
S strx(int32_t v) { S r; snprintf(r.s, sizeof r.s, "%X", (uint32_t)v); return r; }
S chr(int c) { S r = {{(char)c, 0}}; return r; }
S string_n(int n, S s)
{
    S r = s_("");
    for (int k = 0; k < n && len(r) + len(s) <= 255; k++) r = cat(r, s);
    return r;
}
double val(S a) { return atof(a.s); }
int instr(S a, S b, int from)
{
    if (from < 1) from = 1;
    if (from > len(a) + 1) return 0;
    char *p = strstr(a.s + from - 1, b.s);
    return p ? (int)(p - a.s) + 1 : 0;
}
static S get_until(uint32_t a, int ctrl)
{
    S r;
    int n = 0;
    while (n < 255 && (ctrl ? MEM[a + n] >= 32 : MEM[a + n] != 13)) r.s[n] = MEM[a + n], n++;
    r.s[n] = 0;
    return r;
}
S get_s(uint32_t a) { return get_until(a, 0); }
S get_s0(uint32_t a) { return get_until(a, 1); }
void put_s(uint32_t a, S v) { int n = len(v); memcpy(MEM + a, v.s, n); MEM[a + n] = 13; }
S print_num(double v) { S r; snprintf(r.s, sizeof r.s, "%10s", str(v).s); return r; }
S mid_set(S a, int p, int n, S b)
{
    int l = len(a), m = len(b);
    if (p < 1 || p > l) return a;
    if (n < 0 || n > m) n = m;
    if (n > l - p + 1) n = l - p + 1;        /* (the string's length doesn't change) */
    memcpy(a.s + p - 1, b.s, n);
    return a;
}

/* --- arrays */
#define ARRAY(T, t)                                                             \
    void dim_##t(ARR_##t *a, int d1, int d2)                                    \
    {                                                                           \
        a->d1 = d1; a->d2 = d2;                                                 \
        a->p = calloc((size_t)(d1 + 1) * (d2 < 0 ? 1 : d2 + 1), sizeof(T));      \
    }                                                                           \
    T *el_##t(ARR_##t *a, int i, int j)                                         \
    {                                                                           \
        if (!a->p || i < 0 || i > a->d1 || (a->d2 >= 0 && (j < 0 || j > a->d2))) \
            bas_error(15, "Subscript out of range");                           \
        return a->p + (a->d2 < 0 ? i : i * (a->d2 + 1) + j);                    \
    }                                                                           \
    void all_##t(ARR_##t *a, T v)                                               \
    {                                                                           \
        int n = (a->d1 + 1) * (a->d2 < 0 ? 1 : a->d2 + 1);                      \
        for (int k = 0; k < n; k++) a->p[k] = v;                                \
    }
ARRAY(int32_t, i)
ARRAY(double, r)
ARRAY(S, s)

/* --- DIM x% n: a block from the heap above the program (bas_lomem) */
uint32_t dim(int bytes)
{
    uint32_t a = bas_lomem;
    bas_lomem = (bas_lomem + bytes + 3) & ~3u;
    if (bas_dim_clear) memset(MEM + a, 0, bytes);
    return a;
}

/* --- the undo stack of saved variables */
static struct { char t; void *p; union { int32_t i; double r; S s; } v; } undo[2048];
static int nundo;
static void *push(char t, void *p)
{
    if (nundo == 2048) bas_error(0, "No room for LOCALs");
    undo[nundo].t = t; undo[nundo].p = p;
    return &undo[nundo++].v;
}
void save_i(int32_t *p) { *(int32_t *)push('i', p) = *p; }
void save_r(double *p) { *(double *)push('r', p) = *p; }
void save_s(S *p) { *(S *)push('s', p) = *p; }
int undo_mark(void) { return nundo; }
void undo_to(int mark)
{
    while (nundo > mark) {
        nundo--;
        switch (undo[nundo].t) {
        case 'i': *(int32_t *)undo[nundo].p = undo[nundo].v.i; break;
        case 'r': *(double *)undo[nundo].p = undo[nundo].v.r; break;
        default: *(S *)undo[nundo].p = undo[nundo].v.s;
        }
    }
}

/* --- errors */
HND *bas_h, bas_global;
int32_t bas_err, bas_erl, bas_line;
S bas_report;
void bas_error(int32_t err, const char *msg)
{
    bas_err = err; bas_erl = bas_line; bas_report = s_(msg);
    roger_log("basic_error", "iis", err, bas_line, msg, (int)strlen(msg));
    if (!bas_h) {
        fprintf(stderr, "BASIC error %d at line %d: %s\n", err, bas_line, msg);
        roger_finish("BASIC error");
    }
    undo_to(bas_h->undo);
    longjmp(bas_h->jb, 1);
}

/* --- DATA: the program's (bas_data, or the CHAINed program's) */
int data_p;
extern const char *const bas_data[] __attribute__((weak));
static const char *const *datap;
static const char *read_item(void)
{
    const char *const *d = datap ? datap : bas_data;
    if (!d[data_p]) bas_error(42, "Out of DATA");
    return d[data_p++];
}
int32_t read_i(void) { return (int32_t)atof(read_item()); }
double read_r(void) { return atof(read_item()); }
S read_s(void) { return s_(read_item()); }

/* --- SWIs */
void sys_call(uint32_t swi, uint32_t *out)
{
    if (bas_sys_idle) roger_idle(bas_sys_idle);    /* the interpreter's time */
    roger_swi(swi | 0x20000);                  /* the X form: errors come back in VF */
    for (int k = 0; k < 10; k++) out[k] = R[k];
    if (VF && !(swi & 0x20000))
        bas_error(RD32(R[0]), (const char *)MEM + R[0] + 4);
}
static void swi_regs(uint32_t swi, uint32_t r0, uint32_t r1, uint32_t r2)
{
    R[0] = r0; R[1] = r1; R[2] = r2;
    roger_swi(swi);
}
uint32_t swi_number(const char *name)
{
    R[1] = roger_scratch(name);
    roger_swi(0x20039);                        /* XOS_SWINumberFromString */
    if (VF) { fprintf(stderr, "SWI %s not known\n", name); bas_error(486, "SWI name not known"); }
    return R[0];
}
/* blocks the runtime DIMs for itself when first needed (dropped with the
 * heap when a program CHAINs another) */
static uint32_t scratch_buf[10], osword_blk, time_out, call_stack;
uint32_t roger_scratch_n(int k, const char *s)
{
    uint32_t *buf = scratch_buf;
    if (!buf[k]) buf[k] = dim(256);
    snprintf((char *)MEM + buf[k], 256, "%s", s);
    return buf[k];
}

/* --- output */
void vdu(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    for (int c = n; c >= 0; c = va_arg(ap, int)) swi_regs(0x00, c & 255, 0, 0);
    va_end(ap);
}
void vduw(int v) { vdu(v & 255, (v >> 8) & 255, -1); }
void print_s(S s) { for (int k = 0; s.s[k]; k++) vdu((uint8_t)s.s[k], -1); }
void print_tab(int x, int y) { if (y < 0) vdu(31, x, 0, -1); else vdu(31, x, y, -1); }   /* (TAB(x) alone: approximately) */
void plot(int k, int x, int y) { vdu(25, k, -1); vduw(x); vduw(y); }
void gcol(int a, int c) { vdu(18, a, c, -1); }
void colour(int c) { vdu(17, c, -1); }
void colour_rgb(int c, int r, int g, int b) { vdu(19, c, 16, r, g, b, -1); }
void tint(int which, int t) { vdu(23, 17, which, t, 0, 0, 0, 0, 0, 0, -1); }
void rectangle(int x, int y, int w, int h)
{
    plot(4, x, y); plot(1, w, 0); plot(1, 0, h); plot(1, -w, 0); plot(1, 0, -h);
}
void rectangle_fill(int x, int y, int w, int h) { plot(4, x, y); plot(96 + 1, w, h); }
void rectangle_copy(int move, int x, int y, int w, int h, int tx, int ty)
{
    plot(4, x, y); plot(4, x + w, y + h); plot(move ? 190 - 4 : 190, tx, ty);
}
void line(int x1, int y1, int x2, int y2) { plot(4, x1, y1); plot(5, x2, y2); }
void cls(void) { vdu(12, -1); }
void mode(int m) { vdu(22, m, -1); }
int bas_mode(void) { swi_regs(0x06, 135, 0, 0); return R[2]; }
int bas_pos(void) { swi_regs(0x06, 134, 0, 0); return R[1]; }      /* OS_Byte 134: the text cursor */
int bas_vpos(void) { swi_regs(0x06, 134, 0, 0); return R[2]; }
void origin(int x, int y) { vdu(29, -1); vduw(x); vduw(y); }
void off(void) { vdu(23, 1, 0, 0, 0, 0, 0, 0, 0, 0, -1); }
int (*bas_cli)(const char *c);
void oscli_c(const char *c) { if (!bas_cli || !bas_cli(c)) roger_cli(c); }
void oscli(S c) { oscli_c(c.s); }

/* --- input */
void mouse(int32_t *x, int32_t *y, int32_t *b)
{
    roger_idle(2000);
    roger_swi(0x1C);                           /* OS_Mouse */
    *x = R[0]; *y = R[1]; *b = R[2];
}
static uint32_t osword_block(void)
{
    if (!osword_blk) osword_blk = dim(16);
    return osword_blk;
}
void mouse_to(int x, int y)
{
    uint32_t b = osword_block();               /* OS_Word 21,3: set the mouse position */
    PB(b) = 3; PB(b + 1) = x; PB(b + 2) = x >> 8; PB(b + 3) = y; PB(b + 4) = y >> 8;
    swi_regs(0x07, 21, b, 0);
}
void mouse_step(int n)
{
    uint32_t b = osword_block();               /* OS_Word 21,2: the mouse multipliers */
    PB(b) = 2; PB(b + 1) = n; PB(b + 2) = n;
    swi_regs(0x07, 21, b, 0);
}
void mouse_rect(int x, int y, int w, int h)
{
    uint32_t b = osword_block();               /* OS_Word 21,1: the bounding box */
    int v[4] = {x, y, x + w, y + h};
    PB(b) = 1;
    for (int k = 0; k < 4; k++) PB(b + 1 + 2 * k) = v[k], PB(b + 2 + 2 * k) = v[k] >> 8;
    swi_regs(0x07, 21, b, 0);
}
int inkey(int n)
{
    roger_idle(500);
    if (n < 0) { swi_regs(0x06, 129, n & 255, 255); return R[1] == 255 ? TRUE : FALSE; }
    swi_regs(0x06, 129, n & 255, (n >> 8) & 255);
    return R[2] == 0 ? (int)R[1] : -1;
}
S inkey_s(int n) { int c = inkey(n); return c < 0 ? s_("") : chr(c); }
int get(void) { roger_swi(0x04); return R[0]; }

/* TIME: BASIC's own clock, kept from the OS's monotonic time */
static int32_t time_base;
static int32_t monotonic(void) { roger_swi(0x42); return R[0]; }   /* OS_ReadMonotonicTime */
int32_t time_get(void) { roger_idle(2000); return monotonic() - time_base; }
void time_set(int32_t t) { time_base = monotonic() - t; }
S time_s(void)
{
    if (!time_out) time_out = dim(64);
    uint32_t out = time_out;
    uint32_t b = osword_block();               /* OS_Word 14,3: the 5-byte real time */
    PB(b) = 3;
    swi_regs(0x07, 14, b, 0);
    R[0] = b; R[1] = out; R[2] = 64; R[3] = roger_scratch("%W3,%DY %M3 %CE%YR.%24:%MI:%SE");
    roger_swi(0x20000 | 0xC1);                 /* XOS_ConvertDateAndTime */
    return VF ? s_("Thu,01 Jan 1970.00:00:00") : get_s0(out);
}
void wait_(void) { swi_regs(0x06, 19, 0, 0); }
int rnd(int n) { return n <= 0 ? 0 : 1 + rand() % n; }
double rnd1(void) { return rand() / (RAND_MAX + 1.0); }
int32_t rnd32(void) { return (int32_t)((uint32_t)rand() << 16 ^ (uint32_t)rand()); }
void sound(int ch, int amp, int pitch, int dur)
{
    R[0] = ch; R[1] = amp; R[2] = pitch; R[3] = dur;
    roger_swi(0x20000 | 0x40189);              /* XSound_Control */
}
void sound_on(int on) { R[0] = on ? 2 : 1; roger_swi(0x20000 | 0x40141); }   /* XSound_Enable */
void voices(int n) { R[0] = n; R[1] = R[2] = R[3] = R[4] = 0; roger_swi(0x20000 | 0x40140); }   /* XSound_Configure */

/* --- CALL: R0-R7 = A%-H%, a stack of BASIC's own, back through R14 */
void call(uint32_t addr)
{
    if (!call_stack) call_stack = dim(8192) + 8192;
    int32_t v[8] = {A_I, B_I, C_I, D_I, E_I, F_I, G_I, H_I};
    for (int k = 0; k < 8; k++) R[k] = v[k];
    R[13] = call_stack;
    roger_call_program(addr, ROGER_HANDLER_RET);
}
int32_t usr(uint32_t addr) { call(addr); return R[0]; }

/* --- files: OS_Find, OS_BGet/BPut; PRINT#/INPUT# in BASIC's own format */
int32_t bas_open(int how, S name)
{
    R[0] = how | 8; R[1] = roger_scratch(name.s);      /* (8: an error if it's a directory) */
    roger_swi(0x2000D);
    return VF ? 0 : (int32_t)R[0];
}
void bas_close(int32_t h) { R[0] = 0; R[1] = h; roger_swi(0x2000D); }
int bas_eof(int32_t h) { R[0] = 5; R[1] = h; roger_swi(0x20009); return R[2] ? TRUE : FALSE; }   /* OS_Args 5 */
int bas_bget(int32_t h) { R[1] = h; roger_swi(0x2000A); return CF ? -1 : (int)(R[0] & 255); }
static void bput(int32_t h, int c) { R[0] = c & 255; R[1] = h; roger_swi(0x2000B); }
void bas_bput(int32_t h, int c) { bput(h, c); }
void bas_bput_s(int32_t h, S v, int nl)
{
    for (int k = 0; v.s[k]; k++) bput(h, v.s[k]);
    if (nl) bput(h, 10);
}
int32_t bas_ext(int32_t h) { R[0] = 2; R[1] = h; roger_swi(0x20009); return (int32_t)R[2]; }   /* OS_Args 2 */
void bas_print_i(int32_t h, int32_t v) { bput(h, 0x40); for (int k = 24; k >= 0; k -= 8) bput(h, v >> k); }
void bas_print_r(int32_t h, double v) { bas_print_i(h, (int32_t)v); }   /* (not BASIC's 5-byte reals) */
void bas_print_s(int32_t h, S v)
{
    int n = len(v);
    bput(h, 0); bput(h, n);
    for (int k = n - 1; k >= 0; k--) bput(h, v.s[k]);
}
int32_t bas_input_i(int32_t h)
{
    int t = bas_bget(h);
    if (t == 0) { S s = bas_input_s(h); (void)s; return 0; }
    uint32_t v = 0;
    for (int k = 0; k < 4; k++) v = v << 8 | (bas_bget(h) & 255);
    return (int32_t)v;
}
double bas_input_r(int32_t h) { return bas_input_i(h); }
S bas_input_s(int32_t h)
{
    S r;
    int t = bas_bget(h), n = 0;
    if (t != 0) return s_("");
    n = bas_bget(h) & 255;
    for (int k = n - 1; k >= 0; k--) r.s[k] = (char)bas_bget(h);
    r.s[n] = 0;
    return r;
}

void quit(void) { roger_finish("QUIT"); }

/* --- the assembler: what depends on the operands' values. Errors only
 * with OPT's bit 1 (a first pass meets labels not yet set) */
int bas_opt;
void asm_opt(int v) { bas_opt = v; }
static void asm_out(uint32_t v, int n)
{
    uint32_t a = bas_opt & 4 ? (uint32_t)O_I : (uint32_t)P_I;
    for (int k = 0; k < n; k++) MEM[a + k] = (uint8_t)(v >> 8 * k);
    P_I += n;
    if (bas_opt & 4) O_I += n;
}
static void asm_err(int n, const char *msg) { if (bas_opt & 2) bas_error(n, msg); }
void asm_w(uint32_t w) { asm_out(w, 4); }
void asm_h(int v) { asm_out((uint32_t)v, 2); }
void asm_b(int v) { asm_out((uint32_t)v, 1); }
void asm_s(S s) { for (int k = 0; s.s[k]; k++) asm_out((uint8_t)s.s[k], 1); }
void asm_align(void) { while (P_I & 3) asm_out(0, 1); }
uint32_t asm_imm(int32_t v)
{
    uint32_t u = (uint32_t)v;
    for (int r = 0; r < 16; r++) {               /* v = imm8 ROR 2r */
        uint32_t x = r ? (u << 2 * r | u >> (32 - 2 * r)) : u;
        if (x < 256) return 1u << 25 | (uint32_t)r << 8 | x;
    }
    asm_err(1, "Bad immediate constant");
    return 1u << 25;
}
uint32_t asm_shift(int type, int32_t n)
{
    if (n == 32 && (type == 1 || type == 2)) n = 0;  /* LSR/ASR #32 */
    if (n < 0 || n > 31) { asm_err(1, "Bad shift"); n = 0; }
    return (uint32_t)n << 7;
}
uint32_t asm_branch(int32_t to)
{
    int32_t off = to - (P_I + 8);
    if (off & 3 || off < -(1 << 25) || off >= 1 << 25) asm_err(1, "Branch out of range");
    return (uint32_t)(off >> 2) & 0xFFFFFF;
}
uint32_t asm_off12(int32_t off)
{
    uint32_t u = off < 0 ? 0 : 1u << 23, a = (uint32_t)(off < 0 ? -off : off);
    if (a > 4095) { asm_err(1, "Bad address offset"); a &= 4095; }
    return u | a;
}
uint32_t asm_pcrel(int32_t to) { return asm_off12(to - (P_I + 8)); }
void asm_adr(int cond, int rd, int32_t to)
{
    int32_t off = to - (P_I + 8);
    uint32_t op = off < 0 ? 2 : 4;                   /* SUB or ADD rd, PC, #|off| */
    asm_w((uint32_t)cond << 28 | op << 21 | 15 << 16 | (uint32_t)rd << 12 | asm_imm(off < 0 ? -off : off));
}

/* --- programs that CHAIN one another */
const struct bas_program *bas_current;
const struct bas_program *(*bas_chain_hook)(const char *name);
static const struct bas_program *const *programs;
static jmp_buf chain_jb;
jmp_buf bas_main_jb;
int bas_main_line, bas_main_undo;

/* does RISC OS name n end with the components in tail? (any case) */
static int ends_with(const char *n, const char *tail)
{
    size_t ln = strlen(n), lt = strlen(tail);
    return ln >= lt && !strcasecmp(n + ln - lt, tail) && (ln == lt || strchr(".:", n[ln - lt - 1]));
}

void bas_chain(S name)
{
    char n[256];
    uint32_t b = dim(256), out = dim(256);           /* (the heap goes with the program) */
    put_s(b, name);
    R[0] = b; R[1] = out; R[2] = 255;
    roger_swi(0x20027);                              /* XOS_GSTrans: <Disc2>.X */
    snprintf(n, sizeof n, "%s", VF ? name.s : get_s0(out).s);
    const struct bas_program *p = bas_chain_hook ? bas_chain_hook(n) : NULL;
    for (int k = 0; !p && programs && programs[k]; k++)
        if (ends_with(n, programs[k]->name)) p = programs[k];
    roger_log("basic_chain", "s", n, (int)strlen(n));
    if (!p) bas_error(214, "File not found");
    bas_current = p;
    longjmp(chain_jb, 1);
}

void bas_run(const struct bas_program *const *progs, const struct bas_program *first)
{
    programs = progs;
    bas_current = first;
    setjmp(chain_jb);
    /* NEW, LOAD, RUN: the program at PAGE, its heap from TOP; A%-Z% kept */
    nundo = 0;                                       /* (LOCALs aren't restored) */
    bas_h = NULL;
    data_p = 0;
    datap = bas_current->data;
    bas_lomem = ((uint32_t)bas_page + bas_current->size + 3) & ~3u;
    memset(scratch_buf, 0, sizeof scratch_buf);
    osword_blk = time_out = call_stack = 0;
    bas_line = 0;
    bas_current->clear();
    bas_current->main();
    roger_finish("program ended");
}

void bas_goto_main(int line)
{
    nundo = bas_main_undo;                           /* the PROC's frame dropped, not undone */
    bas_main_line = line;
    longjmp(bas_main_jb, 1);
}
