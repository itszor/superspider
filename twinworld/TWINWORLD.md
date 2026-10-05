Twin World: a third game, analysed cold
=======================================

Twin World (Ubi Soft 1990/91, by Cygnus Software Engineering, not Krisalis)
was the first binary SuperSpider met without a hand-made classification to
compare against. Its recompilation (~/games/twinworld, see README.md there)
is driven by `superspider s1b` alone through the phase 6 adapter:

    ~/games/twinworld/analysis/run.sh    s1b -> ss_to_spider.py -> twinworld.json
    ~/games/twinworld/recomp: make regen && make && ./twinworld --trace-gaps

Result: 5459 code words, 153 functions, 3 unresolved jumps, 2 problems
(two words of script data reached as resume offsets). In play-testing (title
menu, starting a game, moving, music and effects) the only interpreted code is
&9450-&945C (below).

What had to change
------------------

Everything below is general; none of it names a Twin World address.

1. Small dispatch stubs inlined. A callee of at most 16 instructions that
   met an unresolved jump in its own analysis (it dispatches through a table
   the caller passes in a register) is also followed inline at each call, so
   that the caller's values can resolve that jump. Its summary still
   applies, because inline, an unknown caller SP would lose the ordinary
   returns. The size limit is there because nested inlining blew up. Before
   this, the non-returning stub at &C64C lost everything after its calls.
2. Fields relative to any symbolic base. Stores through `Sym(b,k)` go into
   a field map keyed by (base, offset), and callers translate a callee's
   fields through substitution. Twin World's script coroutine (&D2A8) keeps
   resume pointers in the object it is passed.
3. Table returns. A summary return that substitutes to a Range or a Tab (a
   load through a caller's table) goes through `jump`. `subst` of `Load0`
   with a Range address loads through the table.
4. Range targets only at computed jumps. Only an `add pc, rN, rX…`
   enumerates a Range of targets, which must be inside the image, word
   aligned, plausible, not data, and not words below &10000. A pointer
   loaded into PC is a single value.
5. Tail exits keep their frame (new). `apply_exit` used to keep only the
   caller's stack. A callee that pushes LR and then leaves through a table
   jump (`stmdb sp!,{lr}; ldr pc,[r10,#&1c]` at &C658), into a routine that
   pops it (`ldmia sp!,{pc}` at &C7C0), needs its push to survive. The
   callee's net push (the slots between its exit SP and its entry SP) is
   now carried into the caller's frame, which works for descending and
   ascending stacks alike. A balanced exit carries nothing. Carrying all of
   the callee's stack writes, or everything at or above the exit SP,
   instead broke Galactic Dan (ascending stack, `stmia sp!`): 28 spurious
   promotions and 18 new unresolved jumps. Twin World gains &C624-&C648, and
   its decoder's leaf handlers (&9478, &948C, &94A0) resolve.
6. OS interface blocks (new). `Riscos.Entries n`: a register a SWI takes as
   a block of n entry points. Sound_InstallVoice r0 is the voice generator
   header (Fill, Update, GateOn, GateOff, Instantiate, Free, Install). Each
   entry is a strong address-taken candidate, exempt from the minimum
   length, because the entries are single branches or returns. Before
   this, only +0 was known, and the recompiled Twin World interpreted
   GateOn (&89B0) once the runtime started calling voices.

7. Jumps through a field of an unknown object (new). When a jump's value
   is Top, `field_jump` looks at the code. The jump can be `ldr pc,[rB,#k]`,
   or `add/mov pc, rN[,#c]` where the straight-line code before it set rN
   with `ldr rN,[rB,#k]` (rB not SP). If so, its targets are the image
   addresses ever stored at field offset k of any object, plus c, filtered
   for plausibility like Range targets. That's field-offset points-to,
   insensitive to the base. Stores record into `field_vals[k]` directly,
   and also when a callee's field writes substitute to constants at a call
   site. Functions that used offset k are re-queued when it grows. Twin
   World's animation scripts start with `bl &D2A8`/`bl &D2C4` followed by
   inline data. The callee stores LR+4 (the script base) in the object's
   field +&1C, and `addeq pc, r0, #8` at &D8B4 resumes at base+8: code 16
   bytes after the `bl`. &D2A8 reaches the jump itself, so its call sites
   resolve through its summary. &D2C4 returns to its caller's caller, so its
   one site (&D0E0 -> &D0F0) was found only by this fallback, and the
   recompiled game stopped there in play.

Regression check (phase3/eval_s1b.py, against the phase 0 ground truth)
-------------------------------------------------------------------------

lemprog, lemboot and musmod are unchanged (lemprog: 3 more data words
after point 7, same code). galdan keeps all 7867 executed
words and gains 165 code words: its 6 voice generator headers' entries (36
accepted candidates) and the voice code behind them. None of it ran in the
ground truth, because Galactic Dan's runtime implements voices natively. That
same native code reads the voices' GateOn instructions for sample start and
length, which is why read−exec rises from 6 to 66: host reads of real code,
not data. A runtime with a generic channel handler (as Twin World's now
has) executes this code.

Remaining gaps
--------------

- &9450-&945C: return sites of the self-recursive Huffman decoder &9434. A
  leaf does `moveq pc, r8` to a per-file-type output handler that pops the
  current invocation's LR. Through the outer call this resolves (point 5).
  Through the recursive call to itself, r8 stays symbolic and the exit
  becomes a tail exit of the summary, so the inner return sites are never
  continuations. Handling it needs recursion-aware frames. This code only
  runs while loading data files.
- &D8B4: resolved by point 7.
