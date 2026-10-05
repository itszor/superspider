Phase 3: return-address and stack abstract interpretation (S1)
==============================================================

Code: src/s1.ml (`superspider s1 IMAGE BASE [--module] [--entry A]...`).
Evaluation: phase2/score.py --stage=s1, phase2/eval_s1.py (output in
phase3/eval_s1.txt). Regression test: test/test_arm2.ml "s1 derives thunk and
push-pc returns".

Design
------
- Values: small constant sets (up to 32), symbolic "entry value + k"
  (LR0+4, SP0-8, any entry register), the caller's stack word at SP0+n, the
  word at (entry register)+k (e.g. the literal after a call site, read
  through LR0), or Top.
- State: registers; the stack as SP0-relative slots; stack memory at
  absolute addresses when SP is a known constant (LemProg sets SP with a
  thunk); flag knowledge after conditional instructions (so a conditional
  push and a branch on the same condition don't mix paths).
- Functions: entry points and bl targets, analysed separately from a
  symbolic entry state; b and constant-target jumps are followed inline.
  Each function's summary lists its exits: the PC value and the
  register/SP state there, relative to entry.
- Calls: the caller substitutes its own state into the callee's summary.
  No calling convention is assumed: a callee exiting via LR0+4 returns to
  call site + 8, one exiting via "caller slot 0" returns to whatever the
  caller pushed. Summaries start empty (the call doesn't return) and grow;
  callees are analysed depth-first before their callers continue.
- Shared routines: a jump target reached again with a different SP or
  different return addresses waiting in the frame becomes a function, so
  each context gets its own return (this is how push-pc "calls" resolve).
- Widening after 4 changes at an address; whole run ~1 s per image.

Explicit assumptions (counted in the output)
--------------------------------------------
1. Hand-linked calls: an unresolved jump made with lr = this instruction + 4,
   or with a code address pushed on top of the stack, calls something that
   returns there. (Galactic Dan: 4 sites, all its call tables; LemProg: 1;
   musmod: the voice-generator dispatch at &1802f18, which returns to
   &1802f1c.)
2. Stack balance: where SP has become unknown (a loop popping a
   data-dependent number of words), a PC popped off the stack is the single
   saved return value in the frame; a callee whose exit SP is unknown
   restores the caller's SP. (Galactic Dan: 14 sites; LemProg: 0.)
Also: stores through unknown pointers are assumed not to alias the stack;
processor modes (banked SP/LR) are not modelled.

Pass criterion
--------------
"Literal thunks, stmdb sp!,{pc} + NV filler, mov rN,pc ; b,
add r0,pc,#k ; push and OS_WriteS fall out with zero idiom code, and the
call graph matches the observed call/return sites."

- Literal thunks: derived. 14 LemProg functions get the summary
  "returns to LR+4"; 348 call sites resolve to call site + 8.
- Push-pc calls: derived. 100 LemProg routines exit through a caller
  stack slot ("caller-slot+n"), each resolving to its pusher's return site.
- add r0,pc,#&c ; push (musmod &2f1c): derived as the return of the
  dispatch at &1802f18 (via assumption 1, since the generator table is
  filled at run time).
- mov rN,pc ; b: handled by inline following (no separate case needed).
- OS_WriteS: OS knowledge, as in S0.
- Observed returns whose call site S1 reached, landing in S1's code:
  Galactic Dan 173/173, LemProg 507/507, musmod 8/8 (with its hand seeds:
  107/107).

Results (code words found / executed words among them; 11 sessions)
-------------------------------------------------------------------
  image     executed  B0_generic   S0           S1           B0 (patched)  B1 shipped
  galdan      7867    14198/6997   7530/5597    7690/5601    14198/6997    18678/7867
  lemprog     5973       29/27       29/27      8553/4777     8577/4777     9900/5972
  lemboot      552        9/9         9/9         9/9           9/9         654/552
  musmod      1366      756/303     195/130     195/130      1273/732      2533/1366

- LemProg: S1 (no idiom code) finds exactly the executed code the
  hand-patched Lemmings spider finds, from 27 words for the generic one.
  Everything S1 finds is also in the patched spider's set; the 24 words the
  patched spider has and S1 doesn't are not code: the &9434 table's first
  two entries and inline strings after add r8,pc,#0 ; b (e.g. "WALK::" at
  &25a04). So S1 is strictly more precise here.
- Galactic Dan: S1 > S0 by the indirect calls with hand-built links; the
  6624 words B0_generic has beyond S1 are the bodies after its Duff's-device
  jumps (phase 4).
- LemBoot: needs the relocation model (phase 3c).
- musmod: what's missing sits behind the SWI dispatch table (phase 4) and
  runtime-registered handlers (phase 3b); with the hand seeds S1 reaches
  1906 words and all observed returns.

Kill/redirect point after phase 3: passed. Return-address tracking removes
the need for the idiom patches (literal thunks, push-pc + NV filler) that
the Lemmings project had to hand-write, at no loss of recall and with better
precision.
