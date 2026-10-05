Phase 5: memory-carried targets, self-modification and conflicts
================================================================

Code: src/s1.ml (note_store, next_var_known, variable-aware table scans,
smc/conflicts output). Evaluation: phase3/eval_s1b.py (phase3/eval_s1b.txt);
`superspider s1b` output now has "code_pointer_vars", "smc", "conflicts".
Test: "s1 jump through a variable".

Method
------
- Variables: every store to a constant address inside the image (and, as a
  weak update of each entry, through a small bounded range of addresses) is
  recorded. The analysis is repeated (with copy loops, phase 3c) until the
  recorded values stop changing; a load from a variable gives the constants
  stored to it in the previous round, Top if any store is unknown.
  A variable's initial image value is *not* one of its values (see
  "Unsoundness" below).
- Jump tables (phase 4) read entries that are variables through their stored
  values instead of their initial contents.
- Loads through a small set of constant addresses give any of their values.
- Self-modifying code: stores to a constant address that the analysis
  classifies as code (not mapped through copies: a store into a copy
  changes the copy).
- Conflicts: words classified as code that are read as data through a
  single constant address or a proven table (reads through a set of possible
  addresses, and reads made by a recognised copy loop, don't count).

Results
-------
Jumps through memory:
  galdan  &168c0 &16940 &16fb4 &16fd4 &16fe4 &17008 &1707c (through &1688c):
          all resolved to {&16690, &166e4}; observed {&16690}.
          &164f8 (object handler table): resolved, observed targets included.
  musmod  &1802f18 (voice dispatch through the run-time-filled table at
          &1802eb0): resolved to the four voice generators, all observed
          ones included. Before this phase the scan read the table's initial
          contents and missed &27cc.
  lemprog &85ac, lemboot &8868: correctly unresolved - they jump through the
          saved previous IRQ handler (read from the kernel slot &100, i.e.
          the OS), outside the program.
Every resolved non-return jump site in the four images includes all of its
observed targets.

Self-modifying code (static), against phase 0 (words executed after being
written) and Galactic Dan's recompiler:
  lemprog  14 flagged: all 12 observed, plus &24cdc and &24d24 in the same
           sprite plotter (not hit in our sessions).
  galdan   3 flagged (&19bd4, &19f94, &1b560), all among the 9 sites its
           recompiler handles; the other 6 are written through computed
           addresses, which constant-address detection doesn't see.
  lemboot, musmod: none.

Conflicts: galdan 1 (&1af74, read by &1aee0 with an index that comes from
flow-insensitive variable values - a false positive), others none.

Recall/precision (all phases; code words / executed among them):
  galdan  18376/7867 of 7867   lemprog 9763/5972 of 5973
  lemboot   566/552 of 552     musmod  2012/1366 of 1366
Galactic Dan gains 4 more Sound_InstallVoice voice-generator blocks
(&263c0..&26548: the install loop's arguments are now known constants);
like &262b8/&2633c they are code the recompiled runtime reads instead of
running. 0 problems; every observed return still lands in found code.

Fixed along the way
-------------------
- mla was evaluated without its accumulator, giving a plot routine a
  constant screen pointer inside the image and 8 false "self-modified"
  words in Galactic Dan.
- Including a data variable's initial image value in its values had the
  same effect (pointers made from initial contents) and let a data word
  (&25350, value 2) through as an address-taken entry in LemProg; weak
  address-taken candidates are now also rejected for any word below &10000
  (andeq r0,r0,<small>).

Unsoundness (documented assumptions)
------------------------------------
- Variable values are flow-insensitive and exclude the initial image value:
  a variable read before any store is mis-valued.
- Stores through non-constant pointers are not tracked (as before: no
  aliasing with the stack or with variables is assumed).
- Static SMC detection only sees stores to constant addresses.

Still unresolved (all code behind them is found by other routes):
  galdan 10, lemprog 7, lemboot 1, musmod 2 - returns where SP or the saved
  value is unknown (Galactic Dan's data-dependent pop loops, LemProg's
  self-modifying plotter) and the two OS-chain jumps above.
