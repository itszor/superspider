/* Dynamic ground truth for SuperSpider (PLAN.md, phase 0).
 *
 * Built into a static-recompilation runtime with -DRECOMP_COV ("make cov").
 * Records, per image tag:
 *   - every executed (reached) instruction address, with a hit count
 *   - every non-sequential control transfer src -> dst (direct and indirect;
 *     classified statically afterwards by decoding the word at src), and
 *     every entry from the runtime/OS (program start, interrupt and vector
 *     handlers, module calls: lines 'N tag ffffffff dst n')
 *   - every image word read or written as data, and every word executed
 *     after it was written (self-modified code, or code loaded over code)
 * and writes them out at exit to $RECOMP_COV (default "cov.out").
 *
 * Tags tell apart images that share addresses (LemBoot and LemProg both
 * load at &8000). The runtime sets cov_tag; addresses in the module window
 * (&1800000-&18fffff) are always tagged 'M'.
 *
 * Runtime-injected calls (interrupts, vector/handler calls made by the OS
 * emulation) must be bracketed with cov_async_enter()/cov_async_exit() so
 * they don't produce fake edges from whatever the program was doing.
 */
#ifndef COV_H
#define COV_H
#include <stdint.h>

extern int cov_tag;             /* tag for low-memory addresses, e.g. 'P' */
extern int cov_nofetch;         /* >0: reads are instruction fetches, don't record */

void cov_insn(uint32_t a);
void cov_read(uint32_t a, unsigned n);
void cov_write(uint32_t a, unsigned n);
void cov_async_enter(void);
void cov_async_exit(void);

#endif
