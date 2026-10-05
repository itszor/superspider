SuperSpider: feasibility and evaluation plan
============================================

Goal: find out whether the approach in NOTES.md (spidering b/bl, tracking LR
from stack save to PC load, backward fact gathering + solver for indirect
jumps) is workable, how far it gets, and how much it improves on the ad-hoc
techniques in ~/games/galactic dan and ~/games/lemmings.

What the existing projects do
-----------------------------
Lemmings' spider.py is Galactic Dan's with patches. Roughly in order of
how much they matter:

1. Recursive descent plus a short-lived constant tracker (AgeRegs: values
   expire after 6 instructions and at calls). Enough for PC-relative
   literals and ADR.
2. Hard-coded call/return conventions: bl returns to +4, returns are
   mov pc,rN or ldm {..pc}. Codebases that break this get special cases:
     - literal thunks (bl consumes an inline word, returns to +8)
     - stmdb sp!,{pc} + NV filler + b (returns to +12)
     - mov rN,pc ; b
     - OS_WriteS inline strings
     - non-returning SWIs
   Each special case also had to be mirrored in gen_c.py. One such fix took
   LemProg coverage from 12% to 19.6%; three more commits fixed the same
   class of bug.
3. Jump tables: a cmp rX,#n within the previous 4 instructions, otherwise
   scan forward while words look like b.
4. Speculative gap filling: try every unclassified word as an entry point;
   keep it if it hits no invalid instructions, runs >= 8 instructions and
   is >= 60% AL-conditioned. Brute force (~4 min). This is why NV words are
   treated as invalid.
5. Jumps through inline variables: collect every constant ever stored to a
   variable that is later loaded into PC.
6. External patching:
     - Ghidra-only code regions merged in
     - entry points seeded by hand when a dynamic run hits a gap
       (&19388, &2a3a0, &82c0)
     - --trace-gaps / untranslated.log report those gaps
     - gen_c.py makes every code address dispatchable as a safety net

The NOTES.md approach targets 2, 3 and 5 directly. The most interesting test
is 2: LR save -> PC load tracking should *derive* the thunk and fake-return
idioms instead of special-casing them.

Already available: Z3 OCaml bindings (z3 4.16.0), sptracking.ml in the
decompiler. decode_arm.ml is ARMv7-flavoured (decodes NV space as
unconditional extensions, has movw/movt) and needs an ARM2 mode.

Phase 0: build the measuring stick
----------------------------------
STATUS: done (2026-10-04) - see phase0/README.md and phase0/RESULTS.md.

- Dynamic ground truth. Add a hook to both recompiled runtimes that dumps
  every executed address and every indirect-jump (site -> target) pair. Run
  the existing scripted/headless sessions (menu, game start, a level) for
  Galactic Dan, LemProg, LemBoot and musmod. Gives:
    - a lower bound on true code
    - the observed target set for each indirect jump
    - observed returns to sites other than +4
- Static references: spider pickles (firm vs speculative code), the final
  byte-identical .s files, the Ghidra-only lists.
- Regression list of hand-found facts from the READMEs: &19388, &2a3a0,
  &82c0, &27a60, the 14 literal thunks, &8600/&dc28, etc.
- Baselines:
    B0 = spider.py --no-spec
    B1 = full spider
    B2 = what finally shipped (B1 + Ghidra + seeds + gen_c extensions)

Phase 1: census of indirect control flow
----------------------------------------
STATUS: done (2026-10-04) - see phase0/PHASE1.md. Outcome: the kill/redirect
point applies. Phase 3 (return addresses) and a new address-taken entry pass
carry almost all the gain; phase 4 shrinks to intervals + known bits + simple
path conditions, with Z3 deprioritised.

Classify every PC-writing instruction in the final code (mostly by script,
some hand review):
  - return
  - table with a local bound
  - table with a distant bound
  - target loaded from an inline/global variable
  - function pointer passed in a register from the caller
  - runtime-built dispatch table
  - computed jump into unrolled code (Duff's-device style)
  - self-modified instruction
Join with the Phase 0 dynamic targets. This sets the ceiling for the
backward-trace idea: if most unresolved cases are runtime-built tables
(like &19388), backward trace + Z3 can't recover them and the payoff lies
elsewhere.

Phase 2: ARM2 front end and plain spider (S0)
---------------------------------------------
STATUS: done (2026-10-04) - see phase2/PHASE2.md.

- ARM2/ARM3 mode for decode_arm: NV = never-execute; no v4+ encodings;
  26-bit r15 holding PC and PSR (bic lr,lr,#0xfc000003, movs pc,lr,
  ldm ...^, orrs pc,r0,#2, teqp).
- Cross-check the decoder against capstone and valid_arm2 on every word of
  all four images.
- b/bl-only spider; check it roughly reproduces B0_generic (Galactic Dan's
  spider without speculation: no idiom knowledge).

Phase 3: return-address and stack abstract interpretation (S1)
--------------------------------------------------------------
STATUS: done (2026-10-04) - see phase3/PHASE3.md. Pass criterion met.

Phase 1 says this is the main lever: without the hand-written idiom patches
a generic spider finds 29 of LemProg's code words, and 5625 of the 5946
executed words it misses sit behind literal-thunk returns (bl+8); musmod
loses 520 more behind push-pc + NV filler.
- Value domain: const | RetAddr(site, +k) / live-in reg + k | SP0 + k |
  interval/known-bits | T
- Stack slots modelled via sptracking (needed for push-pc returns, the
  add r0,pc,#k ; push return addresses in musmod, and indices popped off
  the stack such as Galactic Dan &19658).
- Per-function summary: "returns to LR+k", "returns to a value popped from
  caller stack slot n", or "does not return".
- Pass criterion: literal thunks, stmdb sp!,{pc} + NV filler, mov rN,pc ; b,
  add r0,pc,#k ; push (musmod &2f1c) and OS_WriteS fall out with zero idiom
  code, and the call graph matches B2's call/return-site set. phase0's
  census walker already derives ret-lr+4 for the thunks from LR tracking
  alone.

Phase 3b: address-taken entry points (new, from phase 1)
---------------------------------------------------------
STATUS: done (2026-10-04) - see phase3/PHASE3B.md.

Every runtime/OS-called handler in all four images has its address formed
in code that is already found: ADR (add rX,pc,#k) in Lemmings, a pc-relative
offset literal (ldr rX,[pc,#k] ; add rX,pc,rX) in Galactic Dan. Forward
constant propagation over found code, treating code addresses that reach a
SWI argument, a store, or a register live at a call as entry candidates,
would recover 758 (lemprog) + 634 (musmod) + 128 (lemboot) + 83 (galdan)
missed words and replace most hand seeds.
- Rank candidates (SWI argument to OS_Claim / Sound / vector installs and
  stores to kernel slots such as &100 first; a bare ADR to data last) and
  validate each as code before accepting it.
- Module header and *command table entries (offsets from the module base)
  belong here too.

Phase 3c: relocation
--------------------
STATUS: done (2026-10-04) - see phase3/PHASE3C.md.

LemBoot copies &2000 bytes from &8000 to &40000 and jumps into the copy
(543 words). Recognise copy loops with constant source, destination and
length, and map jumps into the destination back onto the source image.

Phase 4: bounded indirect jumps (S2) - reduced
----------------------------------------------
STATUS: done (2026-10-04) - see phase4/PHASE4.md. Recall equals the shipped
classification without hand seeds or speculation; no solver needed.

Only one table affects discovery in these images (LemProg &9434, 438 words,
and-mask 8 instructions back). Galactic Dan's Duff jumps need guard-branch
path conditions but don't affect discovery. Its call tables (787 words) take
their index from other calls' results or object data, so no backward trace,
including NOTES.md's disjunction over callers, can bound them.
- Domain: intervals + known bits, with simple path conditions taken from
  guard branches (cmp/subs + conditional branch) on the way back.
- Tables bounded only by their data: scan entries while they are valid
  targets, and report the site as data-bounded (not proved).
- Mark table words as data (spider.py currently puts &9438/&943c into the
  shipped codemap as code).
- Z3: deprioritised. Revisit only if a held-out game shows sites the cheap
  domain can't bound but disjunctive facts could.
- Precision per site: inferred target set vs dynamically observed set.

Phase 5: memory-carried targets and conflicts (S3)
--------------------------------------------------
STATUS: done (2026-10-05) - see phase5/PHASE5.md.

- Stores of targets to inline variables (compare with existing var_vals;
  Galactic Dan &1688c, LemProg &852c, musmod's run-time-filled voice table
  at &2f14).
- Detect code/data overlaps and flag them rather than silently picking one.
- Report self-modifying code; don't try to solve it.

Phase 6: end-to-end swap
------------------------
STATUS: done (2026-10-05) - see phase6/PHASE6.md. 0 untranslated jumps in all
sessions; deterministic run byte-identical.

Emit the spider's JSON/pickle shape so export_ghidra.py and gen_c.py consume
SuperSpider output unchanged. Rebuild both recompilations without manual
seeds and without the "every address is dispatchable" fallback; count
untranslated.log gaps over the same scripted runs.

Metrics (SuperSpider S0-S3 vs B0_generic/B0/B1/B2)
---------------------------------------
- Recall: dynamically executed code classified as code without speculation.
- Precision: words claimed as code that are read as data at runtime or
  overlap data.
- Indirect sites: resolved exactly / bounded / unresolved; inferred vs
  observed target set size.
- Hand-written knowledge removed: idiom special cases, seeds and Ghidra
  merges no longer needed. This is the real "how much does it help" number.
- Runtime gaps in Phase 6; analysis time vs the spider's ~4 min.
- Generalisation: run on a third RISC OS game neither project has touched.

Kill / redirect points
----------------------
- After Phase 1 (taken): backward-trace-addressable sites barely affect
  discovery here, so effort goes to phases 3, 3b and 3c; Z3 deprioritised.
- After Phase 3: if return-address tracking doesn't remove the idiom hacks,
  the main argument for the approach weakens a lot.
- Expected hard limits: runtime-built dispatch tables and self-modifying
  code. SuperSpider is still useful if it *says* "unresolved, bounded to N
  targets" instead of silently missing them.
