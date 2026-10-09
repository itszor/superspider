Phase 6: end-to-end swap
========================

Both recompilations rebuilt from SuperSpider's analysis alone, then run on
the same 11 scripted sessions as phase 0.

  phase6/build.sh         mirror builds in phase6/build/{gd,lem}: copies of
                          each project's recomp/ sources (the game
                          repositories are only read)
  phase6/ss_to_spider.py  SuperSpider s1b output -> a spider.Spider pickle
                          + the project's own export_ghidra.py JSON + a
                          functions.tsv; adds "ss_dispatch" (leaders)
  tools/gen_c.py --leaders=ss   dispatch leaders from ss_dispatch instead
                          of every code word (Lemmings) / direct references
                          only (Galactic Dan); Galactic Dan's dynamic facts
                          not used (this was phase6/patch_gen_c.py, patching
                          a copy of each project's gen_c.py)
  phase6/gaps.py, compare.py   results (gaps.txt, compare.txt)
  phase0/run_cov.py <session> --build=phase6   runs into phase0/runs6/

What is not used any more: Ghidra (functions, Ghidra-only code), the hand
seeds (&19388, &82c0, musmod's 15), the spider's speculative gap filling,
Galactic Dan's asm/dyn_*.json (facts recorded by running the original), and
Lemmings' "every classified address is dispatchable" fallback.

What gen_c.py still does on its own (unchanged): its translation rules,
including Lemmings' call_return_site / natural_next for the literal-thunk and
push-pc idioms (they only set the expected return of a CALL and skip the NV
filler; with SuperSpider's leaders a wrong expectation would cost a trip
through the dispatcher, not correctness).

Leaders: ss_dispatch = function entries, resolved return sites (incl. thunk
+8 and push-pc returns), resolved jump/table/variable targets, Duff's-device
continuations, address-taken entries, plus words where control falls into
another function's code (gen_c leaves a C function through the dispatcher
there). Without that last group the first trial run hit 24 gap entries,
all of them such fall-throughs.

Entry points generated: LemProg 1673 (shipped: every code word, 9887),
LemBoot 129, musmod 450, Galactic Dan 3292 (shipped 3300).

Results
-------
- Untranslated jumps: 0 in all 11 sessions (Lemmings run with --trace-gaps,
  Galactic Dan with RECOMP_ISTAT).
- gd-headless (deterministic): event log, VDU output, screen and registers
  byte-identical to the shipped-analysis build.
- Interpreted instructions: Galactic Dan 9 per interactive session (its
  !TitlePic loader, interpreted by design - same as shipped); Lemmings
  0-9,220 per session vs 20,920-94,858 shipped: the self-modification
  values SuperSpider records give gen_c's SMC switches the instruction forms
  the shipped analysis didn't know.
- Executed words per session: identical for Galactic Dan; Lemmings 3 fewer
  per session, all explained:
    &195a8, &1800b04  NV fillers after stmdb sp!,{pc}, which the translated
                      code steps over (inert either way);
    &2a5e0            a literal (&00019d18) after `bl &8038`, a literal
                      thunk. The shipped codemap (B2; not the spider's B1)
                      classifies it as code, so the shipped translation
                      runs it after the call returns as
                      `andeq r9, r1, r8, lsl sp` - harmless only while Z is
                      clear (the thunk preserves the caller's flags); with
                      Z set it overwrites r9. SuperSpider classifies it as
                      data. This was also the one "executed word SuperSpider
                      misses" in phases 4-5: it isn't code.

So with SuperSpider's classification the recompiled games run the same
sessions with no translation gaps, and recall is 100% of the code that
really executes in them.
