Phase 3c: relocation
====================

Code: src/s1.ml (detect_copy_loop, unreloc; `spider` re-runs when new
copies are found). Test: "s1 relocation". Evaluation: phase3/eval_s1b.py
(phase3/eval_s1b.txt).

Method
------
At a short backward conditional branch (a loop of at most 64 bytes), S1
checks whether the loop body copies memory: exactly one post-incremented
load through one register and one post-incremented store through another,
with the same step (ldr/ldrb/str/strb with an immediate, or ldmia/stmia with
writeback). The trip count comes from a register counted down to zero
(subs rc,rc,#n ; bne) or from comparing the source pointer with a constant
end. Source, destination and count are taken from the state on first
arrival at the loop head; if all are constants and the source is in the
image, the copy is recorded.

An address outside the image that falls in a copy's destination maps back to
the image word it was copied from. This applies to constant jump targets,
literal loads and address-taken candidates. Code reached that way is
analysed at its original address: relative branches are the same, and
addresses the relocated code computes from its own PC come out unbiased,
consistently within the analysis. If new copies are found during a run,
S1 runs again with them known (jumps met before the copy was recognised are
resolved then).

Results
-------
LemBoot: the copy &8000 -> &40000 (&2000 bytes, loop at &801c-&8028) is
recognised; `ldr pc,[pc,#-4]` at &802c (to &402c0) resolves to &82c0 - the
project's one hand seed - and the IRQ handler &880c, stored to &100 from the
relocated code, is accepted as an address-taken entry.

  LemBoot   executed   found by S1b   missed   S1b code words   of them not in shipped codemap
  before        552           9         543            9                     0
  after         552         552           0          566                     0

The other images are unchanged. LemProg has three small in-image copy loops
(string copies); mapping only applies to addresses outside the image, so
they have no effect.

Caveat: LemBoot's jump to &8000 at &8400 is the chain-load into LemProg,
which it has just loaded over itself at &8000. Statically that maps onto
LemBoot's own entry point (already code), which is harmless for finding
code but not what happens at run time. Modelling loads that replace the
program would need knowledge of OS_File and the file system.

Hand seeds after phases 3b and 3c: LemProg 1/1, LemBoot 1/1, musmod 14/15
(the last never ran in our sessions) found without being given.
