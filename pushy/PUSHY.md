Pushy II: a fifth game, analysed cold
=====================================

Pushy II (R-Fred-W / FishNet Software, 1996, freeware): a desktop
application whose !RunImage is a 30K AIF image written in assembler. The
recompilation is ~/games/pushy2 (README.md there); its analysis/run.sh
runs `superspider s1b` and phase6/ss_to_spider.py:

                         code words  functions  data  unresolved  problems
    before (914337c)           1684         91   103           5         0
    after                      5524        165   183           0         0

Before, the recompiled game interpreted a quarter to a half of its
instructions (the sprite plotters, every screen of the front end, the
game itself); now play-testing (both level sets, the menus, quitting)
reaches no untranslated code. What was missing is how the program is organised: a main loop that
calls whatever the current screen installed, screens described by objects
in the image holding their handlers, per-mode routines in tables indexed
by workspace fields.

What was new
------------

Everything below is general; none of it names a Pushy II address.

1. Shifted symbolic values are unknown multiples. `ldr pc,[r1,r0,lsl #2]`
   with r1 a constant table and r0 a field of the workspace (`ldr r0,
   [r12,#&d4]`: a symbolic value) gave Top, so the table was never
   scanned. A symbolic value shifted left is now treated like Top: some
   multiple of 2^n, which makes the load a table (`Tab`) and the existing
   scan applies. (The mode-setting routines, the per-mode plotters.)
2. Setter routines. A store to a variable of a value relative to the
   function's entry (a setter: `str r0,[pc,#k]` storing its argument) is
   kept with the function (`sym_stores`) instead of joined into the
   variable's values (where a symbolic value made it Top). Each call
   site substitutes its own state and stores the result, which may be
   constant, or relative to the caller and so kept with it in turn.
   Callers are re-analysed when a callee gains such stores. A symbolic
   store in a function nobody calls makes the variable Top. And 0 among
   other values of a variable is dropped: a setter called with 0 for
   "the default" (`teq r0,#0 ; addeq r0,pc,#k ; str r0,...`) stores 0 only
   on the path the test rules out. (The main loop's current-screen
   handlers, &E3B4 and &E3B8, set by &E38C and &E3A0.)
3. Summary exits are kept apart by flag knowledge, as states inside a
   function already were. The setter above returns r0 = the default on
   one path and the argument on the other; joined, r0 was Top, and a
   caller passing the result on (`bl &e38c ; bl &e3a0`) stored Top.
4. A jump through a variable may go to its initial value. Variables'
   known values exclude their initial image contents (Galactic Dan's
   data pointers, PHASE5.md); a jump table that start-up code may
   overwrite (Pushy II swaps in StrongARM-safe plotters when
   OS_PlatformFeatures reports separate caches) still dispatches to its
   initial entries otherwise. Only where the variable is jumped through
   (`ldr pc` from it, or a scanned table entry), and only if the initial
   word is a plausible code address.
5. Objects holding handlers. Field-offset points-to (TWINWORLD.md point
   7) extended to objects: `ldr pc,[rO,rI,lsl #2]` or `ldr pc,[rO,#j]`
   where rO was loaded from field k (`ldr rO,[rB,#k]` in the straight-
   line code before) goes to the code addresses stored in the objects
   that are stored at field k - all of their words up to 64 (stopping at
   code) for a register index, word j for an offset (falling back to
   the plain field rule when that finds nothing). Pushy II's menu
   screens are descriptors in the image (&AD24, &AE30, &B354: positions,
   item count, the current item at +&1C, a handler per item from +&28,
   the Escape handler at +&24) passed to &C774, which stores the current
   one at [r12,#&58].
6. `movs`/`mvns` of an immediate sets Z from a known constant, so the
   path through `moveqs r3,#0` still knows EQ (one conditional return
   after it was joined with the fall-through path, losing the return).
   Only an immediate: tried for any constant result, it lost 274
   executed words of Lemmings - `ldr r0,[pc,#k] ; movs r0,r0 ; bne`
   reads a variable the analysis takes for its literal value, and
   pruning a path on that is wrong.

And a bug: a function analysed depth-first from a call while still on the
stack of fresh functions stayed marked as queued, so requests to
re-analyse it when a callee's summary changed were dropped. It surfaced
here (a malloc whose failure path reaches the main loop recursively, so
its callers were first analysed against an empty summary) as about 540
lost words.

Regression check
----------------

phase3/eval_s1b.py: galdan, lemprog, lemboot and musmod cover every
executed word as before; galdan has 15 more data words, lemprog one fewer
function (code unchanged). Twin World, Gyrinus II's MCode and the
CoconizerSong player: identical code. Twin World's stack-balance
assumptions go from 17 to 36 (point 3 keeps more exits apart; same code).
test/: two new cases, a setter-installed variable and a table in an
object. SS_DEBUG_VAR=<hex> prints what each round stored to a variable.
