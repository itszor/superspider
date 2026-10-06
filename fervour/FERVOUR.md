Fervour: a sixth game
=====================

Fervour (A.E. Hersee / Clares, 1992): a desktop front end (icon bar, level
editor, options) and a game that takes over the screen in a 368x216
overscan mode. !Runimage is Acorn-squeezed and then self-decrypting; the
recompilation (~/games/fervour, README.md there) analyses the image as it
is once decrypted (unpacked/RunImage, entered at &8064) plus the modules
it brings: FervourMode, AEHModule, SoundMaster (a 4-channel tracker that
drives the sound DMA itself) and a dummy Joystick module.

                          code words  functions  unresolved  problems
    !Runimage, before           1577         26           1         2
    !Runimage, after           10101        155          25         0
    SoundMaster, before          448          7           0         0
    SoundMaster, after          9726          7           3         0

Play-testing (title, three level sets, steering) interprets three short
stretches (listed in the recompilation's game.c); the unresolved sites are
returns and pops whose targets the runtime dispatches.

What was new
------------

General, unless marked as an option:

1. XOS_Exit doesn't return either (only OS_Exit was listed).
2. Tables of cases. A computed jump with a wide range of targets (an index
   bounded only by its type, a byte) whose entries each end in an
   unconditional transfer before the next - a branch per word, or a few
   instructions and a branch per 16 bytes (SoundMaster's effect commands)
   - ends at the first entry that isn't one, instead of taking every
   plausible word in the range (which ran into the following functions).
3. A signed guard on the index of a computed jump made on that condition
   (cmp r0,#&19 ; addle pc,pc,r0,lsl #2 after Wimp_Poll) bounds it to
   0..n: a negative index would land in the code before the table.
4. Pointers walking records in the image: a register stepping by a
   constant through image addresses widens to a range with that step, to
   the end of the image, not to Top; and add pc,rN,#k with such a range is
   a computed jump into the records (Fervour's window list: name, handle
   and two branch instructions per window, executed in place).
5. Dispatches that are calls: a multi-way jump made with lr set just
   before by add/sub lr,pc,#k or mov lr,pc (a Wimp_Poll loop calling a
   handler per event) makes each target - or what its b goes to - a
   function, so that its return to lr comes back with the caller's state.
   A return into a function entry applies that function's summary; a
   cycle of those now stops where it started (it recursed for ever in
   Galactic Dan once more functions existed).
6. Saved stack pointers (setjmp/longjmp): str sp to a variable that some
   ldr sp,[pc,#k] restores - the saving function's frame may be popped at
   the restore sites, which are analysed from the save as that function
   (the game proper is left by restoring the stack saved on entry). Only
   when SP is the function's own (SoundMaster keeps SP as data in a
   variable).
7. ldm loading PC from a variable may go to its initial value, as ldr pc
   already could (the game's context block, reloaded with
   ldmia r0,{r0-r12,lr,pc}).
8. A self-modified word holding a transfer may be rewritten into one that
   falls through (FervourMode patches mov pc,lr into cmp r2,#mode): what
   follows it is code too.
9. Value domain: masks with few multiples of their lowest bit (and #&FF0000)
   give ranges; subs of a range reaching below the constant keeps the part
   that doesn't borrow (it is tested next); the flags of a result
   (ands r7,r0,#k) say on the EQ path that it is 0.
10. Option --global-r12: the program keeps a workspace pointer in r12 all
    through (Fervour's &51310, re-established by the routines the OS
    calls). r12 at a function's entry is then the constant all its call
    sites pass. Not the default: Twin World keeps return addresses in an
    r12 workspace too, and loads through a constant r12 read the image's
    initial words as if they were constant - 14 problems.

Diagnostics: SS_UNRESOLVED=1 prints each unresolved site with its function
and reason; the JSON summaries show r12 at exits that don't preserve it;
SS_DEBUG_DC=1 shows dispatches taken for calls.

Regression check
----------------

phase3/eval_s1b.py: galdan, lemprog, lemboot and musmod have the same code
and cover every executed word as before; Galactic Dan has 0 assumed
returns (was 1) and 14 stack-balance assumptions (was 31), its call tables
being functions now; a few more data words (tables) in galdan and
lemprog. Twin World, Gyrinus II's MCode and CoconizerSong, Pushy II: the
same code (Pushy II has 243 functions, its handlers).
