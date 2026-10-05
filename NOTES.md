SuperSpider
===========

This will be SuperSpider, a tool to discover executable instructions in
a raw binary file based on a list of header instructions/entry points
and abstract interpretation.

The project will be implemented in OCaml, based on parts of the decompiler at ~/stuff/decompiler-git. Two other projects can be used to learn successful and less-successful techniques from: "~/games/galactic dan" and "~/games/lemmings". Both are static recompilations of RISC OS games.

We will statically spider branch (b) and call (bl) instructions to discover branch targets and subroutines. We will trace through stack saves of the link register to corresponding stack loads of the PC by tracing stack-pointer adjustments (when necessary).

We will handle indirect jumps by tracing back over abstract call traces gathering facts about the indirect jump's controlling variables: for instance if we have 'and r4, r4, #7' followed by 'add pc, pc, r4, lsl #2' we know that there must be a jump table with at most 8 entries.  When tracing back, many such facts will be obtained: some of these will be redundant and can be elided. During the abstract backtrace, we will stop when we hit a loop.

Some given indirect jump may be reachable via many different routes. In this case the rules we gather will be treated as a disjunction: the hope is that we can discover the whole set of reachable targets by evaluating call traces. We will probably need to use a solver like Z3 to evaluate the rules we gather.

The primary use of this tool will initially be analyzing RISC OS game binaries to separate code from embedded data. This code is often ARM2 or ARM3-era, so uses 26-bit addressing and sometimes encodings like the "never" condition code (NV).
