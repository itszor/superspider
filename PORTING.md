Porting a RISC OS game: from disc image to native binary
========================================================

How the recompilations so far were made: Galactic Dan, Lemmings, Twin
World, Gyrinus II, Pushy II and Fervour (~/games/<name>), then Elite,
Pac-Mania, Stunt Racer 2000, Chocks Away, Zool, Warlocks, Starch and Darkwood. Each is a static
recompilation of the game's ARM2 code to C, linked with libroger
(~/stuff/libroger), which emulates the Archimedes / Risc PC and the parts
of RISC OS the game uses. In this file $SS means ~/stuff/superspider (the
games' Makefiles use `SS ?= $(HOME)/stuff/superspider` and their scripts
use the `SUPERSPIDER` environment variable).

The shared tools ($SS/tools)
----------------------------

Every game uses these single copies. Fix bugs and add features here, then
run `make regen` in each game (see "Regression" below). Don't copy them
into a game.

    adf_extract.py IMAGE.adf [OUT]   ADFS D/E/F disc -> directory tree, names suffixed
                                     ',llllllll-eeeeeeee' (load/exec address)
    ADFSlib.py                       the ADFS reader it uses (David Boddie, GPL-3,
                                     github.com/dcf21/adfslib, vendored)
    hfe.py IMAGE.hfe OUT.img         an HxC floppy image (MFM) -> its sectors, as a flat
                                     .adf-style image; also each track's sectors with their
                                     IDs and CRCs (for protection tracks)
    arcfs.py ARCHIVE OUT             ArcFS archives (filetype &DDC): stored, packed, crunched
    detok.py FILE                    BBC BASIC V program -> text (inline assembler too)
    arm2.py                          a small ARM2 emulator in Python, for running a
                                     game's own unpacker (Lemmings' tools/unpack_lemboot.py)
    gap_roots.py                     run-time gaps -> roots for the next analysis
    bas2c.py PROGRAM OUT.c           BBC BASIC V program -> C, on a game's bas.c runtime
    spark.py ARCHIVE OUT             Spark archives (ARC with RISC OS headers, also &DDC):
                                     stored, packed, crunched, squashed, compressed
    weave.py identify|extract|build  recipes: recognise a user's discs (by content) and
                                     build the game from them (see Recipes, below)
    gen_c.py, spider.py, gen_asm.py, the old Python recompiler and the modules it
    export_ghidra.py                 imports: only for the Ghidra-based analyses
                                     (Lemmings' and Galactic Dan's regen-ghidra)

The pipeline for one image, as each game's `make regen` runs it
(superspider is $SS/_build/default/bin/main.exe):

    superspider analyse IMAGE BASE --full [--module] [--exec ADDR] [--global-r12] [--roots R] -o name.json
    superspider gen IMAGE BASE name.json --c gen [C options]

(or in one step: `superspider analyse ... -o name.json --c gen`). gen writes
gen/code*.c, gen/gen.h and gen/entries.c, which exports a `struct
roger_image` (named `<tabprefix>_image`, `recomp_image` by default). Use
`--prefix`/`--tabprefix` to give each image its own names when one binary
holds several, and `--covtag` for the phase 0 coverage builds. BASE is the
address the image is translated for: a module's is the RMA address game.c
loads it to. Run `superspider` with no arguments for the full option list.

1. Get the files off the disc
-----------------------------

- Dumps are usually ADFS .adf files (E format, 800K). Run
  `adf_extract.py game.adf extracted`. Flux-level dumps (HxC .hfe:
  Darkwood) go through `hfe.py` first; weave.py does that itself. Note
  that adf_extract.py's names carry the load address but not the
  execution address (it reads a field ADFSlib doesn't have, so it's
  always 0): take an absolute's entry from elsewhere (Gyrinus II's MCode,
  Darkwood's MCMain1). Keep the ',load-exec' suffixes:
  they are the only record of where an absolute file loads and starts. An
  `ff8` type, or a load address of &8000 with matching exec, is a plain
  absolute. `fffff8xx`-style values are filetype-stamped (no address).
- Old-map (D format) discs: ADFSlib reads them (Starch), and pads a dump
  cut short after its last used sector to the size its map gives.
  Galactic Dan's `extracted/tools/adfsd.py` is another reader.
- The files may themselves be archives (Fervour's disc holds an ArcFS
  archive: `arcfs.py`), BASIC programs (`detok.py`; Gyrinus II's loaders),
  or Obey files (!Run: plain text). Read every !Run, !Boot and BASIC
  loader first. They tell you the order things load in, the WimpSlot, the
  modules (RMLoad/RMEnsure), the system variables (`<Game$Dir>`), the
  screen mode and the real entry point.
- Compressed and protected programs: don't reimplement the codec, run
  the program's own unpacker and save the image it produces.
  - Lemmings: `tools/unpack_lemboot.py` runs LemBoot's LZ unpacker under
    `$SS/tools/arm2.py`.
  - Fervour: !RunImage is Acorn-squeezed, then self-decrypting (an XOR
    keyed by PC including its PSR bits). Its `tools/unpack` runs it under
    libroger's interpreter and saves the image when it reaches &8064.
  - Squeezed modules (Fervour's SoundMaster, AEHModule) are absolutes that
    insert the module they carry; unpack those the same way.
  - Code loaded as data: Warlocks unpacks its music player (WM, from its
    data disc, with its own LZW) into its own image and calls it. Its
    `tools/unpack` runs the game interpreted until the call and writes the
    image with those bytes in place; that image is translated and run, so
    when the game unpacks WM again it writes the same bytes (libroger
    compares a stored-to code word with what it held before, not with what
    was translated).

  - Programs on sectors no file owns: Starch's loader reads its program
    with ADFS_DiscOp from disc address &5000, decrypts it and checks for
    the original disc. Its `tools/unpack.py` does the same from the disc
    image (a recipe's `"raw": true` keeps it as extracted/<disc>.img) and
    the translation starts after the checks (`--exec`).

  - Protection that reads the disc itself: Darkwood calls FileCore's SWI
    handler directly to read a track of odd sector sizes and CRC errors.
    libroger reads it from the .hfe (roger_config.floppy; the recipe's
    `"raw": true` keeps it as extracted/<disc>.hfe), so the game's own
    check runs and passes.

  The image you translate is the one that actually runs, at the address it
  runs from.
- The game data stays as the original files. libroger maps the game's
  RISC OS paths onto the extracted tree (`appdir`, `dir_prefixes`,
  `variables` in roger_config), so nothing needs converting.

2. Decide what to translate
---------------------------

List every piece of ARM code that runs:

- The main program: its load address (BASE, normally &8000) and
  execution address (`--exec` when it isn't BASE: Gyrinus II's MCode loads
  at &7F800 and starts at &8BD08).
- Relocatable modules the game loads (`--module`, translated at a fixed
  RMA address: Gyrinus II's 16 voice modules, Fervour's four, Lemmings'
  music module at &1800000). Identical code in several files can share one
  translation (Gyrinus II's six Coconizer songs use one player).
- A program in several files that call each other at fixed addresses
  (Darkwood: a loader, a main file and overlays sharing addresses).
  Analyse each with the others' ranges as `--extern FROM-TO`: calls into
  them are assumed to return, and are listed (extern_calls) so that they
  become entry points of the image they land in. Darkwood's
  tools/images.py iterates that to a fixed point.
- Programs loaded later (`roger_config.programs`), programs that
  relocate themselves (LemBoot: `--pcbias`), and loader programs that are
  only worth interpreting (`loader_programs`, e.g. a title picture).
- BASIC: libroger has no BASIC interpreter. Translate the loader's logic
  into game.c by hand (Gyrinus II: Warnung, Loading, RunMe, EndGame).

With more than one or two images, write a `tools/images.py` that drives
analyse/gen/roots over a table of (name, path, base, exec, module). See
Gyrinus II's and Fervour's.

3. Analyse with SuperSpider
---------------------------

Run `superspider analyse --full` on each image and check the summary: code
words, functions, unresolved jumps, problems. Problems near zero and a
plausible code/data split are the aim. Without `--full` only the core
analysis runs; it's fast and always finishes, but finds much less (indirect
dispatch is what the other mechanisms are for). `--with`/`--without` turn
the mechanisms on and off one by one, to see which one finds (or costs)
what. Useful when the result isn't right:

- `SS_UNRESOLVED=1` lists each unresolved site with its reason.
- `SS_DEBUG=<fn>`, `SS_DEBUG_ADDR=<addr>`, `SS_DEBUG_VAR=<var>` and
  `SS_DEBUG_DC=1` trace a function, an address, a variable's values and
  dispatches taken as calls.
- `SS_TRACE=1` traces every function analysis (steps, time) and why
  functions are analysed again; `SS_EXITS=<fn>` prints a function's summary
  each time it changes. That is how to find an analysis that runs away.
  `--budget N` stops one that does (the result is marked incomplete).
- `superspider disasm IMAGE BASE FROM TO` disassembles a range.
- `--global-r12` is for programs that keep a workspace pointer in r12 all
  through (Fervour). It isn't the default because it broke Twin World.

When code is missed, fix it in SuperSpider as a general mechanism, never by
naming a game address. Each game's write-up (twinworld/, gyrinus/, pushy/,
fervour/) lists what it needed. The patterns so far:

- dispatch through tables passed in registers, objects or workspace
  fields
- setter-installed handlers
- coroutines that resume after inline data
- OS interface blocks (Sound_InstallVoice)
- jump tables of cases
- records executed in place
- setjmp/longjmp stacks
- self-modified transfers
- unrolled loops entered part way through with add pc,pc,rX,lsl #k
  (k >= 5: blocks of 2^k bytes; Darkwood's Gouraud routines)
- slots: a copy loop into the image from a source the analysis doesn't
  know (Starch copies the current level's header, branches and all, into
  one place). Calls into a slot are dispatched at run time and assumed to
  return; list the slot in `roger_config.interpreted` and the code it
  leads to in a roots file.

Then regression-check (below). As a last resort, a game can list entry
points in a roots file (`--roots`); `gap_roots.py` writes those for you
(step 6).

4. Write game.c
---------------

game.c holds everything specific to the game: a `struct roger_config`,
hooks, and `int main(int argc, char **argv) { roger_main(argc, argv,
&config); }`. Copy the closest existing game's game.c and Makefile and
adapt them:

- Twin World or Galactic Dan for a plain full-screen game.
- Lemmings for several images and a self-relocating loader.
- Gyrinus II for modules and BASIC loaders.
- Pushy II for a Wimp task, or a Risc PC mode (`vidc20`).
- Fervour for packed images, its own sound DMA, or a Wimp front end.

Fill in from what !Run did:

- `image_path` and `entry`
- `modules` (in !Run's order)
- `appdir`, `dir_prefixes` and `variables`
- `initial_mode`, `wimpslot` and `screen_size`
- `command_line`

Hooks handle game-specific behaviour:

- `swi`: a SWI handled specially
- `call_addr`: patching behaviour at a dispatch, e.g. Gyrinus II's music
  speed-up fix
- `wimp_idle`: stand in for the user at the desktop. libroger shows no
  desktop, so Pushy II and Fervour click their icon-bar icon and quit
  afterwards.
- `arg`/`usage`: game options such as `--levels=`
- `exited`: what !Run does after the program, e.g. Gyrinus II's EndGame
- `init`, `frame`: setup and per-frame work

Also add a headless scenario (`clicks`/`keys`) that plays a little of the
game.

Rule: if the behaviour belongs to RISC OS or the hardware, implement it in
libroger, generally (another game will need it). If it's a quirk of this
game, it goes in game.c as a config field or hook. libroger and SuperSpider
must stay free of game code, game data and ROM contents.

5. Fill in libroger
-------------------

The first runs stop at unimplemented SWIs, vectors, service calls or
hardware. Implement each from the documentation (the PRMs, RISC OS Open's
sources for exact behaviour), as the OS does it, not as this game happens
to use it. Things each game needed:

- Gyrinus II: voice generators and SoundChannels (Sound_SoundLog,
  *Tuning, SCCB durations)
- Pushy II: the Wimp, VIDC20 modes and OS_ScreenMode
- Fervour: Service_ModeExtension modes, MEMC sound DMA and IRQ device 9
- Lemmings: key transition events

6. Close the gaps
-----------------

Code the analysis missed (mostly addresses reached only at run time) shows
up as untranslated dispatches:

    ./game --trace-gaps            interpret and log them to untranslated.log
    make roots [LOG=...]           gap_roots.py merges them into the roots file
    make regen && make             re-analyse with them as entry points

Repeat while playing every part of the game: menus, each level type,
death, high scores, quitting. Prefer fixing SuperSpider (step 3) when a gap
shows a pattern. Roots are for leftovers. Code that genuinely can't be
translated (it's generated or modified at run time) goes in
`roger_config.interpreted` with a comment saying why.

7. Regression
-------------

Everything here is shared, so check the other games after any change:

- After changing SuperSpider: run `phase3/eval_s1b.py` (coverage of the
  phase 0 ground truth for galdan, lemprog, lemboot and musmod), and check
  that the other games' code word counts don't change unless you expect
  it.
- After changing libroger: do headless runs (`./game --limit=N`, or
  `--headless`) of every game before and after. Their .events, .vdu,
  .screen and .regs files (and `--wav` output) must be byte-identical.
- After changing the C generation (src/gen.ml) or the other tools: run
  `make regen` in every game and diff the generated `recomp/gen*`
  directories against the previous ones. Then do the headless runs.

Recipes
-------

A game repository is also a recipe: its committed files (game.c, the tools,
roots, Makefile) plus a recipe.json are everything needed to rebuild the
game from a user's own copy, and contain no game data, so the repository
can be shared. recipe.json lists the discs it needs, each recognised by
content - the sha256 of known images, and of the "key files" on the disc
that the build depends on - and the build steps. `weave.py build INPUT...`
finds the recipe the inputs match (any repository under ~/games, or
$WEAVE_RECIPES), extracts the discs into it and runs the steps; a game's
build.sh does the same for that recipe alone. A dump that matches only some
key files (another release, a modified copy) scores below 100% and isn't
built from. `weave.py index` writes recipes.json, every recipe's
fingerprints in one file. Chocks Away was the first (~/games/chocks-away);
every game has one now. Their inputs: TOSEC zips of disc images (Twin
World, Gyrinus II, Stunt Racer 2000, Fervour, Lemmings), disc images
(Warlocks, Galactic Dan; Darkwood's six HxC .hfe images), ArcFS archives (Zool, Pac-Mania), and zips of
plain files or directories (Pushy II, Elite: the filetypes from the zip's
RISC OS extra fields). A disc's "game_dirs" entry "$" copies the whole
disc into game/ (Warlocks' data disc, read from its root); directories of
the same name from several discs are merged (Stunt Racer's !SR2000). A
game that needs more than files from the disc (an unpacker run, a layout
of its own) does it in a build step, in tools/: Elite's images.py
assemble, Galactic Dan's game.py (the decrypted game, from an
unprotected or cracked disc).

Make the derived files (extracted/, game/, unpacked/, the generated C)
.gitignored, and keep the original discs out of the repository.

Layout of a game repository
---------------------------

    README.md          what the game is, how to build and run it, what's not supported
    <disc>.adf         the original (not distributable)
    extracted/         adf_extract.py's output
    tools/             only what is specific to this game (images.py, unpackers)
    analysis/          run.sh, or images.py's output; SuperSpider's results
    recomp/Makefile    make regen, make, make cov, make roots
    recomp/game.c      the roger_config and hooks
    recomp/gen*/       generated, not committed

Deferred: changes held back because they'd touch other games
-------------------------------------------------------------

Each of these is general and wanted, but changes what other games'
analyses or extracted trees look like, so it needs `make regen` (and the
headless regression runs) in every game, and fixes where a game depends on
the old behaviour. Left for a pass of its own (Darkwood, October 2026):

- Backward computed jumps into a run of instructions: `sub pc, rN, rM,
  <shift>` with rN a known constant (`add lr, pc, #k` before it) and rM
  unknown jumps back into the periodic run of words that ends at rN (a
  span fill: Darkwood's MCMain2 at &67384, into 16 stmias ending at
  &673C4). S1 only follows the forward form (`add pc, pc, rX`); Darkwood
  lists those entries by hand in analysis/mcmain2.roots. The encoding is
  in most other games' images (as code or as data that decodes to it), so
  their code word counts would change.
- adf_extract.py loses execution addresses: it reads `exec_address`, but
  ADFSlib's attribute is `execution_address`, so every name ends
  `-00000000`. The fix is one word, but it renames extracted files, and
  these recipes name them with the old suffix: fervour (tools/images.py),
  gyrinus-ii (tools/images.py, recomp/game.c, README.md), lemmings
  (recomp/Makefile, recomp/game.c, tools/unpack_lemboot.py),
  stunt-racer-2000 (tools/images.py, tools/cload.c, recomp/Makefile),
  twinworld (analysis/run.sh, recomp/Makefile, recomp/game.c). Fix them
  with it (or look files up ignoring the suffix); then Gyrinus II's and
  Darkwood's entry points could come from the names.
- Unrolled-loop blocks (`add pc, pc, rX, lsl #k`, all 2^k-byte blocks as
  entries) only for k >= 5. Galactic Dan has k = 3 jumps (two-instruction
  blocks), still handled the old way (fall into the next word); lowering
  the threshold would change its analysis.
- --extern ranges are consulted for b/bl targets and plain flow only; the
  other places S1 asks Image.inside (constant jumps, tables, address-taken
  code) still treat an extern range inside the image (an overlay over a
  stale part of it) as the image's own. Nothing needed it yet.
- libroger turns the OS pointer off on every mode change. RISC OS may well
  leave it as it was (games started from the desktop hide its pointer
  with OS_Byte 106,0 after their mode change; Darkwood relies on it
  staying on). Darkwood opts out (roger_config.desktop_pointer); making it
  the default would show a pointer in games that never asked for one, so
  check against RISC OS's sources and each game's headless runs first.
