Phase 4: bounded indirect jumps
===============================

Code: src/s1.ml (Range/Tab values, refine, table scanning, follow).
Evaluation: phase3/eval_s1b.py (phase3/eval_s1b.txt) - `superspider s1b`
now includes everything through phase 4. Test: "s1 bounded tables".

Domain additions
----------------
- Range (lo, hi, step): from and/bic with a constant mask (the step comes
  from the low bits the mask clears), ldrb (0..255), and guard
  comparisons; carried through lsl/lsr, add/sub/rsb of constants, add of
  two ranges and multiplication by a constant. An unknown value shifted
  left by n is "some multiple of 2^n" (an unbounded range).
- Guard comparisons: cmp rN,#imm (or a constant register) is remembered
  while its flags are current; on a path where a condition is known to hold
  or not, rN is narrowed (unsigned lower / lower-or-same, equal; signed
  less-than only for an already non-negative range).
- Table loads: a word load through a range of addresses inside the image
  gives a table value (base, stride, limit). Byte tables of at most 32
  entries are read directly.
- Jumps: a range of targets is enumerated; a table value is scanned entry by
  entry, keeping entries that give a plausible code target (inside the
  image, a plausible non-NV instruction, not data). With a tight bound (at
  most 32 entries) invalid entries are skipped (null slots); with a looser
  or no bound the table ends at its first invalid entry. Accepted entries
  are marked as data ("jump table").
- One counted assumption: add pc,pc,rX with rX unknown is a computed jump
  into the code that follows (Duff's device), with rX >= 0 (9 sites, all in
  Galactic Dan's unrolled plotters).
- No solver: nothing in these images needed one (see phase 1).

Tables resolved
---------------
  image    site       how                      targets  observed  observed within inferred
  lemprog  &9434      and #7 (scanned, <= 8)        8         8      yes
  musmod   &1800574   cmp r11,#&11 ; addlo          17         7      yes
  galdan   &164f8     scanned, <= 256 (byte idx)    19         4      yes
  galdan   &22de4     bic #&83, <= 32               13         3      yes
  galdan   &1560c &1659c &16f74 (call tables)  12/12/14       0      -
  galdan   &19658 &19544, small ones           7/1, 2-4       0      -
Every observed target of every resolved site is among the inferred ones.

Results (code words found / executed words among them)
-----------------------------------------------------
  image    executed   S1b (all phases)   B0 patched   B1 shipped   B2 shipped
  galdan     7867       18372/7867       14198/6997   18678/7867   18704/7864
  lemprog    5973        9763/5972        8577/4777    9900/5972    9887/5961
  lemboot     552         566/552          444/430      654/552      653/552
  musmod     1366        2012/1366        2375/1366    2533/1366    2532/1366

SuperSpider now finds every executed word in all four images except one in
LemProg (&2a5e0) - the same recall as the shipped classification, which used
hand seeds, speculative gap filling, Ghidra and gen_c.py extensions - with
no hand seeds and no speculation.

Precision proxies:
- Code words read as data and never executed: galdan 2 (voice-generator
  blocks, which are code the runtime reads), lemprog 0, musmod 0; the
  shipped spider (B1) had 141, 40 and 53.
- Code words outside the shipped codemap: lemprog 14 (all self-modified
  instructions, which the recompiler leaves to its interpreter), galdan 8
  (3 self-modified, 2 voice blocks, 3 fragments reached as table targets
  that never ran: &18c74, &19900, &19904), musmod 0.
- 0 problems (invalid instructions reached) on all images.

Still unresolved (code behind them is found by other routes in every case
that ran): jumps through run-time variables (phase 5: galdan 7, lemprog 1,
lemboot 1) and pops in self-modifying code.

Run time: ~3 s for LemProg, <1 s for the others.
