SuperSpider
===========

Code/data separation for raw ARM2/ARM3 (26-bit, RISC OS) binaries. See
NOTES.md for the idea and PLAN.md for the evaluation plan and status.

  dune build && dune test
  dune exec superspider -- disasm IMAGE BASE [FROM [TO]]
  dune exec superspider -- spider IMAGE BASE [--module] [--exec ADDR] [--entry ADDR]... [--global-r12] [-o OUT.json]   (S0)
  dune exec superspider -- s1 IMAGE BASE [same options]       (S1)
  dune exec superspider -- s1b IMAGE BASE [same options]      (S1 + address-taken + relocation + tables: the full pipeline)
      --exec: an absolute file's execution address, when it isn't BASE (its load address)
      --global-r12: the program keeps a workspace pointer in r12 throughout (S1)
      SS_DEBUG=<function hex> / SS_DEBUG_ADDR=<addr hex> / SS_DEBUG_VAR=<variable hex> /
      SS_TRACE=1 for tracing

src/      arm2.ml decoder, image.ml images + module headers, spider.ml (S0),
          s1.ml (S1: return-address / stack abstract interpretation; S1b:
          address-taken entry points), riscos.ml (SWI argument kinds)
bin/      command-line tool
test/     alcotest unit tests
phase0/   ground truth (coverage of the recompiled games) and baselines;
          phase 1 census (PHASE1.md)
phase2/   decoder cross-check against capstone, scoring scripts (PHASE2.md)
phase3/   S1, S1b and relocation results (PHASE3.md, PHASE3B.md, PHASE3C.md)
phase4/   bounded indirect jumps (PHASE4.md)
phase5/   memory-carried targets, SMC, conflicts (PHASE5.md)
phase6/   end-to-end: recompilations rebuilt from SuperSpider (PHASE6.md, build.sh)
twinworld/ a third game analysed cold, and the generalisations it needed (TWINWORLD.md)
gyrinus/   a fourth: Gyrinus II, program and 17 module images (GYRINUS.md)
pushy/     a fifth: Pushy II, a desktop game run through setters and handler objects (PUSHY.md)
fervour/   a sixth: Fervour, packed and encrypted, a Wimp front end, record tables, its own sound DMA (FERVOUR.md)
