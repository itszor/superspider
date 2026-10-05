Phase 1: census of indirect control flow
========================================

Tool: census.py (data/<image>.census.json); show.py for hand review.

For every PC-writing instruction other than b/bl/swi in the shipped code plus
everything executed, census.py walks backwards (static CFG + observed jumps,
stopping at merges/loops and function entries) to find where the target
value comes from. Values are constants, LR-relative ("live-in r14 + k"),
stack pops, table loads or memory loads. This is a small prototype of the
backward trace in NOTES.md, without path conditions and without a solver.

Then every executed word that a baseline misses is attributed to how
control first left baseline code to reach it (following chains of missed
regions back to baseline code, or to an entry from the runtime/OS).

Results (11 sessions, see RESULTS.md)
-------------------------------------
PC-writing sites (static, whole shipped code), and how many ran:

  image     sites  returns  other indirect   executed
  galdan     296     271        25             136
  lemprog    281     279         2             204
  lemboot     40      37         3              31
  musmod     127     124         3              76

  "returns" = ret-lr / ret-lr+4 / ret-stack. census.py derives ret-lr+4
  (the literal thunks: "returns 4 bytes past its link") purely from LR
  tracking through bic lr / ldr rX,[lr],#4, with no idiom knowledge.

What lies behind the code each baseline misses (executed words; a region
reachable several ways counts under each):

  galdan, missed by B0_auto (870 words)
    684  indirect call through an object-handler table (&164f8)
    103  indirect calls through 16-byte-record call tables (&1560c etc.)
     83  2 runtime/OS-called handlers (&1a8f0, &1a9bc)

  lemprog, missed by B0_auto = patched spider (1196 words)
    758  2 runtime/OS-called handlers (&8530 IRQ via &100, &2a70c Event_V)
    438  1 address table (&9434)
  lemprog, missed by B0_generic = Galactic Dan's spider (5946 of 5973 words)
   5625  returns to call site + 8 (literal thunks)
   2588  the two handlers above

  lemboot (543 words, both spiders)
    543  1 constant jump into its relocated copy (&802c -> &402c0)
    128  1 runtime-called handler (&880c)

  musmod, missed by B0_auto (634 words)
    634  1 runtime-called voice generator (&2ed0)
  musmod, missed by B0_generic (1063 words)
    970  runtime-called handlers
    520  fall-through past the push-pc + NV-filler idiom

Baseline totals (code words found, and executed words missed):

               B0_generic      B0_auto        B1_generic      B1 (shipped)
  lemprog       29 / 5946     8577 / 1196     4445 / 2903     9900 / 1 (SMC)
  lemboot        9 /  543        9 /  543      351 /  307      654 / 0
  musmod       756 / 1063     1273 /  630     2002 /  277     2533 / 0
  galdan          (same spider)  14198 / 870       -          18678 / 0

Every runtime/OS-called handler entry (all four images) has its address
formed in code B0 already finds: by ADR (add rX,pc,#k) in Lemmings, by
ldr rX,[pc,#k] ; add rX,pc,rX (pc-relative offset literal) in Galactic Dan
(&25e34, &25e48). Forward constant propagation over found code finds them;
no backward trace needed.

Conclusions for the plan
------------------------
1. Return-address tracking (phase 3) is the biggest lever for Lemmings.
   Without the hand-written thunk/push-pc patches a generic spider finds
   29 of LemProg's code words; with speculation it still misses 2903 of the
   5973 executed ones. The census walker already derives "returns to LR+4"
   for the thunks with no idiom code - promising for phase 3's pass test.
2. Add "address-taken" entry discovery (not in NOTES.md): code addresses
   materialised in found code (ADR, pc-relative offset literals) are entry
   candidates. This alone covers every handler: 758 (lemprog) + 634
   (musmod) + 128 (lemboot) + 83 (galdan) words, and replaces most hand
   seeds. It's forward constant propagation, cheap.
3. Backward fact gathering (phase 4) matters for discovery at exactly one
   site in these images: LemProg &9434 (438 words), bounded by an and-mask -
   a known-bits domain suffices. Galactic Dan's Duff jumps need path
   conditions but don't affect discovery; its call tables (787 words) take
   their index from other calls or object data, so no backward trace
   (including the NOTES.md disjunction over callers) can bound them - only
   scanning the table contents can.
   => Deprioritise Z3. Plan phase 4 as intervals + known bits + simple path
   conditions from guard branches, and a content scan for data-bounded
   tables, reporting them as such.
4. Relocation (LemBoot) needs its own small model: recognise the copy loop
   (&8000 -> &40000, &2000 bytes) and map jumps into the copy back.
5. Precision: spider.py treats &9434's ldr pc,[...] as a call and continues
   at +4, putting table words &9438/&943c into the shipped codemap as code.
   SuperSpider's table handling should mark table words as data.
6. Coverage caveat: only 9-16% of the two main images ran. The static census
   covers all sites, but the attribution only covers code that ran.


Hand review of the table / computed-jump sites
----------------------------------------------
Every indexed or computed jump in the four images (returns and constant
jumps excluded):

  site       image    shape                                      bound comes from              needs
  &9434      lemprog  and r4,#7 ... add fp,pc,#0 ;               and-mask 8 instructions back   known-bits (local)
                      ldr pc,[fp,r4,lsl#2]  (address table)
  &1800574   musmod   cmp r11,#17 ; addlo pc,pc,r11,lsl#2        adjacent cmp                   local (spider handles)
  &19544     galdan   ldrb ; bic #&c0 ; ldr [adr,r0,lsl#2] ;      byte with 2 bits cleared        known-bits (local)
                      add pc,pc,r1  (relative offsets)
  &19658     galdan   same, index popped off the stack            value pushed earlier           stack model + known-bits
  &8a30      galdan   (64-r3)*24 ; add pc,pc,r3  (Duff)           guard branch on the path        intervals + path condition
  &9328      galdan   (32-r3)*16 ; add pc,pc,r3  (Duff)           guard branch on the path        intervals + path condition
  &9040      galdan   add pc,pc,r2,lsl#3  (Duff)                  guard branch on the path        path condition
  &9538      galdan   add pc,pc,r2,lsl#3  (Duff)                  guard branch on the path        path condition
  &aa8c      galdan   subs fp,r3,r2 ; bgt ; fp*4+&3fc (Duff)      bgt not taken => fp <= 0;       path condition (relational),
                                                                  lower bound not local           lower bound open
  &d360,&e7c0 galdan  r5*-20 (or -24) + k ; add pc,pc,r5 (Duff)   r5 from caller / loop           interprocedural / loop
  &fff0,&11418
  &1560c,&1659c galdan ldr r2,[r1,r0,lsl#4]! ; add r2,pc,r2 ;     r0 = result of another call     data-bounded only
  &16f74,&22de4         add lr,pc,#0 ; mov pc,r2  (call tables     or object field                 (table length from contents)
  &164f8                 of 16-byte records)
  &1802f18   musmod   add r0,pc,#&c ; push {r0,..} ;              run-time-filled table of voice  memory-carried targets +
                      ldr r0,[sb,r7,lsl#2] ; orrs pc,r0,#2        generators (sb = pc-&58)        return-address tracking
                      (call; returns to &2f1c; the orrs sets                                      (+ 26-bit mode bits)
                      SVC mode bits as it jumps)

Notes:
- Galactic Dan's Duff jumps don't matter for *finding* code: the unrolled
  bodies directly follow the jump and spider.py keeps tracing linearly
  past it. They matter for the recompiler (which entry offsets are legal).
- The call tables' indices are not constants at the call sites (checked:
  they are other functions' results or object fields), so NOTES.md's
  "disjunction over call traces" would not bound them. Only the table's own
  contents can (scan entries while they are valid targets) - what spider.py
  already does heuristically.
- LemProg &9434 is the one table whose targets matter most for coverage
  (438 executed words behind it). spider.py misses it twice over: its bound
  is 8 instructions back (outside the 4-instruction window) and the
  add fp,pc,#0 ; ldr pc,[fp,r4,lsl#2] shape isn't one it recognises. It
  then treats the jump as a call, continues at +4, and puts the first two
  table words (&9438, &943c) into the shipped codemap as code.
