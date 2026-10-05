Phase 0 results (2026-10-04)
============================

11 scripted sessions: 6 LemProg levels (Fun 1, 6, 11, 16, 21, 26), one LemBoot
boot-to-level run, Galactic Dan's deterministic headless scenario (5e9
instructions) and 3 random-play Galactic Dan sessions. Regenerate with
run_cov.py / baselines.py / ground_truth.py (see README.md).

Recorder validation
-------------------
asm/executed.json (5063 addresses run by Galactic Dan's independent Python
emulator on the original binary) is a strict subset of gd-headless's
executed set (5152 words; that run is longer). check_emu.py: 0 missing.

Recall: executed words that each baseline classifies as code
-------------------------------------------------------------
"missed" = executed but not in the baseline.

                 executed   B0_auto missed   B0 missed   B1_auto missed   B1 missed
  galdan            7867        870 (11%)     870            0              0
  lemprog           5973       1196 (20%)    1196            1              1
  lemboot            552        543 (98%)     122          141              0
  musmod            1362        630 (46%)       0           67              0

  B0_auto = recursive descent from given entries only; B0 adds hand seeds;
  B1_auto = B0_auto + speculation; B1 = what shipped (B0 + speculation).
  LemProg's 1 word missed by B1 (and 12 by B2) are self-modified words,
  which run through the interpreter by design.

- Plain recursive descent misses 11-20% of the code that actually runs in
  the two games, and almost all of LemBoot (it relocates itself to &40000
  and jumps into the copy).
- Speculation recovers everything in galdan/lemprog, but not LemBoot or the
  module: there the hand-found seeds are what close the gap (LemBoot
  &82c0; musmod's 15 seeds).

Return shapes (distinct return edges observed)
----------------------------------------------
                 bl+4   bl+8 (literal thunk)   push_pc+12   after-jump   other
  galdan          166          0                    0            13         2
  lemprog          41        206                  298             0         0
  lemboot           9          5                   38             0         0
  musmod           80          0                   25             4         0

In LemProg only 41 of 545 return edges follow the "bl returns to +4"
convention the spider assumes. This is the strongest evidence so far for
PLAN.md phase 3 (return-address tracking) on Lemmings. Galactic Dan is
conventional, so expect little gain there from phase 3.

Indirect control flow (input to phase 1)
----------------------------------------
                 indirect sites   with >1 observed target
  galdan              124                 44
  lemprog             200                 64
  lemboot              29                 10
  musmod               64                 30
(Includes returns; phase 1 separates returns, tables, memory-carried targets.)

Precision proxy: baseline code that was read as data and never executed
-------------------------------------------------------------------------
  B1: galdan 141, lemprog 40, musmod 53 words (lemboot not meaningful: its
  copy loop reads the whole image). These are candidates for speculative
  misclassification; inspect in phase 1.

Self-modifying code
-------------------
  lemprog: 12 words executed after being written, all at known sites
  (&9338, &93fc, &24478.., &2b3cc, &2b414). galdan: 0 in these sessions; its
  9 SMC sites' writer (&23f90) is never reached. lemboot's 441 are an
  artifact (it runs from the &40000 copy; the low copy has been overwritten).

Limits
------
- Executed sets are lower bounds: 9.3% of Galactic Dan's image and 16.2% of
  LemProg's ran. B1 claims 18678 / 9900 code words respectively, so most
  speculative code is still unconfirmed either way.
- Random input doesn't reach everything (e.g. Galactic Dan's later sectors,
  Lemmings' later difficulty ratings, menus like passwords/options).
