/* See cov.h. */
#include "cov.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int cov_tag = 'P';
int cov_nofetch;

/* Address windows we keep per-word state for. */
#define LOW_END   0x100000u
#define MOD_BASE  0x1800000u
#define MOD_END   0x1900000u
#define NWORDS    ((LOW_END >> 2) + ((MOD_END - MOD_BASE) >> 2))
#define NTAGS     8

struct img {
    int tag;
    uint32_t *exec;             /* hit counts (saturating) */
    uint8_t *rw;                /* bit 0 read, bit 1 written, bit 2 executed after a write */
    uint32_t prev;              /* last executed address, or NONE */
};
#define NONE 0xFFFFFFFFu

static struct img imgs[NTAGS];
static int nimgs, inited;

static long word_index(uint32_t a)
{
    a &= 0x3FFFFFC;
    if (a < LOW_END) return a >> 2;
    if (a >= MOD_BASE && a < MOD_END) return (LOW_END >> 2) + ((a - MOD_BASE) >> 2);
    return -1;
}

static int tag_of(uint32_t a)
{
    a &= 0x3FFFFFC;
    return a >= MOD_BASE && a < MOD_END ? 'M' : cov_tag;
}

static void dump(void);
static void on_signal(int s) { (void)s; exit(0); }

static void init(void)
{
    inited = 1;
    atexit(dump);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
}

static struct img *img_for(int tag)
{
    for (int k = 0; k < nimgs; k++)
        if (imgs[k].tag == tag) return &imgs[k];
    if (nimgs == NTAGS) { fprintf(stderr, "cov: too many tags\n"); exit(1); }
    struct img *m = &imgs[nimgs++];
    m->tag = tag;
    m->exec = calloc(NWORDS, sizeof *m->exec);
    m->rw = calloc(NWORDS, 1);
    m->prev = NONE;
    if (!m->exec || !m->rw) { fprintf(stderr, "cov: out of memory\n"); exit(1); }
    return m;
}

/* ---- edges: open-addressed hash of (tag, src, dst) -> count ---- */
#define EBITS 20
#define ESIZE (1u << EBITS)
static struct edge { uint32_t src, dst; int tag; uint64_t n; } *edges;
static unsigned nedges;

static void add_edge(int tag, uint32_t src, uint32_t dst)
{
    if (!edges) edges = calloc(ESIZE, sizeof *edges);
    uint32_t h = (src * 0x9E3779B1u ^ dst * 0x85EBCA77u ^ (uint32_t)tag) >> (32 - EBITS);
    for (;;) {
        struct edge *e = &edges[h];
        if (!e->n) {
            if (nedges > ESIZE / 2) return;         /* full: dump reports it */
            e->src = src; e->dst = dst; e->tag = tag; e->n = 1; nedges++;
            return;
        }
        if (e->src == src && e->dst == dst && e->tag == tag) { e->n++; return; }
        h = (h + 1) & (ESIZE - 1);
    }
}

void cov_insn(uint32_t a)
{
    if (!inited) init();
    a &= 0x3FFFFFC;
    struct img *m = img_for(tag_of(a));
    long i = word_index(a);
    if (i >= 0 && m->exec[i] != 0xFFFFFFFFu) m->exec[i]++;
    if (i >= 0 && (m->rw[i] & 2)) m->rw[i] |= 4;
    if (m->prev == NONE) add_edge(m->tag, NONE, a);   /* entered from the runtime/OS */
    else if (a != m->prev + 4) add_edge(m->tag, m->prev, a);
    m->prev = a;
}

static void note_rw(uint32_t a, unsigned n, int bit)
{
    if (!inited) init();
    for (uint32_t x = a & ~3u; x < a + n; x += 4) {
        long i = word_index(x);
        if (i >= 0) img_for(tag_of(x))->rw[i] |= bit;
    }
}

void cov_read(uint32_t a, unsigned n) { if (!cov_nofetch) note_rw(a, n, 1); }
void cov_write(uint32_t a, unsigned n) { note_rw(a, n, 2); }

/* ---- async brackets: save and clear every image's prev ---- */
#define ADEPTH 16
static uint32_t saved[ADEPTH][NTAGS];
static int depth;

void cov_async_enter(void)
{
    if (depth < ADEPTH)
        for (int k = 0; k < NTAGS; k++) saved[depth][k] = k < nimgs ? imgs[k].prev : NONE;
    depth++;
    for (int k = 0; k < nimgs; k++) imgs[k].prev = NONE;
}

void cov_async_exit(void)
{
    if (depth == 0) return;
    depth--;
    for (int k = 0; k < nimgs; k++)
        imgs[k].prev = depth < ADEPTH && k < NTAGS ? saved[depth][k] : NONE;
}

static uint32_t addr_of(long i)
{
    return i < (long)(LOW_END >> 2) ? (uint32_t)i << 2
                                    : MOD_BASE + ((uint32_t)(i - (LOW_END >> 2)) << 2);
}

static void dump(void)
{
    const char *path = getenv("RECOMP_COV");
    if (!path || !*path) path = "cov.out";
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); return; }
    fprintf(f, "# recomp coverage v1\n");
    if (nedges > ESIZE / 2) fprintf(f, "# WARNING edge table full, some edges dropped\n");
    for (int k = 0; k < nimgs; k++) {
        struct img *m = &imgs[k];
        for (long i = 0; i < (long)NWORDS; i++) {
            if (m->exec[i]) fprintf(f, "X %c %08x %u\n", m->tag, addr_of(i), m->exec[i]);
            if (m->rw[i] & 1) fprintf(f, "R %c %08x\n", m->tag, addr_of(i));
            if (m->rw[i] & 2) fprintf(f, "W %c %08x\n", m->tag, addr_of(i));
            if (m->rw[i] & 4) fprintf(f, "S %c %08x\n", m->tag, addr_of(i));
        }
    }
    if (edges)
        for (unsigned h = 0; h < ESIZE; h++)
            if (edges[h].n)
                fprintf(f, "%c %c %08x %08x %llu\n", edges[h].src == NONE ? 'N' : 'E', edges[h].tag,
                        edges[h].src, edges[h].dst, (unsigned long long)edges[h].n);
    fclose(f);
    fprintf(stderr, "cov: wrote %s (%u edges)\n", path, nedges);
}
