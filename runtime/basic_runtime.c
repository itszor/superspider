/* BBC BASIC V's statements for a program translated by tools/bas2c.py (see
 * basic_runtime.h): each does what the interpreter would, through the
 * emulated machine. (First written for Stunt Racer 2000; Chocks Away and
 * Saloon Cars added to it.) */
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include "basic_runtime.h"

int32_t A_I, B_I, C_I, D_I, E_I, F_I, G_I, H_I;
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

/* --- DATA */
int data_p;
static const char *read_item(void)
{
    if (!bas_data[data_p]) bas_error(42, "Out of DATA");
    return bas_data[data_p++];
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
uint32_t roger_scratch_n(int k, const char *s)
{
    static uint32_t buf[10];
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
    static uint32_t blk;
    if (!blk) blk = dim(16);
    return blk;
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
    static uint32_t out;
    if (!out) out = dim(64);
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
    static uint32_t stack;
    if (!stack) stack = dim(8192) + 8192;
    int32_t v[8] = {A_I, B_I, C_I, D_I, E_I, F_I, G_I, H_I};
    for (int k = 0; k < 8; k++) R[k] = v[k];
    R[13] = stack;
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
