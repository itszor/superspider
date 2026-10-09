SuperSpider
===========

Code/data separation for raw ARM2/ARM3 (26-bit, RISC OS) binaries. See
NOTES.md for the idea and PLAN.md for the evaluation plan and status.
PORTING.md is the process for porting a new game, from disc image to
native binary, with the shared tools in tools/.

  dune build && dune test
  superspider analyse IMAGE BASE [entry points] [mechanisms] [-o ANALYSIS.json] [--c DIR [C options]]
  superspider gen IMAGE BASE ANALYSIS.json --c DIR [C options]
  superspider disasm IMAGE BASE [FROM [TO]]
  (superspider with no arguments lists every option; dune exec superspider -- ...
  or _build/default/bin/main.exe)

analyse finds the code and writes the analysis (-o, JSON) and/or its C
translation (--c, code*.c + gen.h + entries.c for libroger); gen translates
a saved analysis. Entry points: BASE (or --exec ADDR), the module header's
with --module, --entry ADDR, --roots FILE (one address per line, e.g. from
tools/gap_roots.py). The core analysis always runs and always finishes
quickly; everything else is turned on with --with (or all of it with
--full, which is what the games use):

  tables memory copies fields inline longjmp dispatch clib address-taken global-r12

clib is for C programs on the Shared C Library (AIF images linked with its
stubs): the library's entry vectors, filled at run time, are calls that
return; the start-up (_kernel_init, each language's Init, _main) and the
function pointers the library is given (main, atexit, signal, qsort) are
followed; and every APCS function entry in the image is an address-taken
candidate.

--budget N bounds the whole analysis (instruction steps, default 100M): when
it runs out the result is marked incomplete, and code it didn't reach runs
interpreted. Summaries that keep changing are widened, so a recursion that
pops ever more of its caller's frame (Stunt Racer 2000) can't grow forever.

  python3 tools/gap_roots.py IMAGE BASE ROOTS_FILE untranslated.log...
      merge the gap entries a recompiled program's --trace-gaps run logged
      (libroger) into a roots file, so the next analysis covers them:
      analyse -> recompile -> run --trace-gaps -> gap_roots.py -> analyse ...
  SS_DEBUG=<function hex> / SS_DEBUG_ADDR=<addr hex> / SS_DEBUG_VAR=<variable hex> /
  SS_EXITS=<function hex> (its summary each time it changes) / SS_TRACE=1
  (each function analysis: steps, time, why things are re-analysed) for tracing

The older stages (spider: S0; s1; s1b = analyse --full) still write their
JSON for the phase scripts.

src/      arm2.ml decoder, image.ml images + module headers, spider.ml (S0),
          s1.ml (S1: return-address / stack abstract interpretation; S1b:
          address-taken entry points), riscos.ml (SWI argument kinds),
          gen.ml (the C translation), json.ml (reading saved analyses)
bin/      command-line tool
tools/    the tools every game recompilation shares: disc/archive extraction,
          gap_roots.py, bas2c.py (see PORTING.md); gen_c.py and the modules it
          imports (spider.py, gen_asm.py, export_ghidra.py) only for the old
          Ghidra-based analyses (Lemmings' and Galactic Dan's regen-ghidra)
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
