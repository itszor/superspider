Phase 0: ground truth and baselines
===================================

See ../PLAN.md. This directory is the measuring stick for SuperSpider: what
code really runs in the two recompiled games, and what the existing ad-hoc
tooling classifies as code.

Pieces
------
cov/cov.c, cov/cov.h
    Coverage recorder linked into a recompiled game's runtime. Records per
    image tag: executed words (with hit counts), every non-sequential control
    edge src -> dst, image words read / written as data, and words executed
    after being written, plus entries from the runtime/OS (N lines:
    program start, interrupt/vector handlers, module calls). Writes
    $RECOMP_COV (default cov.out) at exit.

    Hooked into ~/games/lemmings/recomp and ~/games/galactic dan/recomp via
    COV_* macros in runtime.h (no-ops unless -DRECOMP_COV), brackets around
    the runtime's synthetic interrupt / vector / module calls in runtime.c,
    and a "make cov" target building lemmings-cov / galdan-cov from separate
    *.cov.o objects. The normal builds are unaffected.

    Tags: P LemProg, B LemBoot, M musmod2 (anything in &1800000-&18fffff),
    G Galactic Dan, T Galactic Dan's !TitlePic loader (ignored).

build_gd.sh
    Faithful Galactic Dan coverage build in build/gd: regenerates the C
    *without* gen_c.py --loops. The shipped build turns 8 Duff's-device
    plotters into loops over one block, so its PC stream (and the executed
    set inside the unrolled bodies) doesn't match the original program.
    Lemmings' build doesn't use --loops.

run_cov.py <session> [--grid]
    Runs one scripted session (SDL offscreen video, dummy audio) into
    runs/<session>/: cov.out, log.txt, screenshots, grid.png contact sheet.
    Sessions:
      lem-level00..25  LemProg, Fun level N (via poke), START, briefing,
                       then 100s of random clicks alternating between the
                       skill panel and the play area
      lem-boot         LemBoot: logos, unpack, chain-load, menu, level 1
      gd-headless      Galactic Dan's built-in deterministic scenario, 5e9 insns
      gd-play0..2      title, PLAY, briefing, then random steering / buttons /
                       keys for ~100s
    runs/extracted is a symlink to ~/games/lemmings/extracted: the Lemmings
    runtime loads musmod2 from ../extracted relative to its working directory.

baselines.py [--spec]
    Static baselines per image -> data/<image>.json:
      B0_generic  Galactic Dan's spider.py (no Lemmings idiom patches)
      B1_generic  B0_generic + speculation (--spec)
      B0_auto  project spider.py, recursive descent only, given entry points
               only (load address / module header)
      B0       B0_auto + the projects' hand-found seed entries
      B1_auto  B0_auto + spider's speculative gap pass (--spec; ~8 min)
      B1       shipped spider pickle (B0 + speculation)
      B2       shipped recompiler codemap (B1 + Ghidra-only + gen_c additions)

ground_truth.py
    Joins all runs with the baselines -> data/<image>.truth.json and a
    summary: recall of each baseline against executed words, baseline code
    that was read as data but never executed, indirect-jump sites with their
    observed target sets, return-edge shapes (bl+4, bl+8 literal thunks,
    push_pc+12, ...), and self-modified words.

census.py
    Phase 1: classifies every PC-writing instruction by where its target
    comes from (backward walk over static CFG + observed jumps), joins with
    observed targets and spider.py's handling, and attributes executed code
    a baseline misses to how it is reached -> data/<image>.census.json,
    summary in data/census.txt. Results: PHASE1.md.

show.py <image> <addr>[:before[:after]] ...
    Hand-review disassembly, marking B2 code (C), executed (x), B0_auto (0).

check_emu.py
    Cross-checks the recorder against Galactic Dan's emu.py trace.

facts.json
    Regression list of hand-found control-flow facts from the projects'
    READMEs / git history, each tagged with the kind of reasoning SuperSpider
    would need to find it unaided.

Caveats
-------
- Executed sets are lower bounds: they only cover what these sessions reach.
- LemBoot runs from a copy of itself at &40000; executed addresses are
  recorded unbiased, data accesses to the copy are mapped back by
  ground_truth.py. Its copy loop reads its whole image, so "read but not
  executed" is meaningless for LemBoot.
- Edges inside synthetic handler calls are recorded, but the call into the
  handler and the return to the interrupted code are not (by design).
