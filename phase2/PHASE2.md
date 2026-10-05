Phase 2: ARM2 front end and plain spider (S0)
=============================================

Code: src/arm2.ml (decoder), src/image.ml (images, module headers),
src/spider.ml (S0), bin/main.ml (superspider decode|disasm|spider),
test/test_arm2.ml (alcotest: `dune test`).

Why a new decoder rather than an ARM2 mode in ~/stuff/decompiler-git
--------------------------------------------------------------------
The decompiler's decode_arm.ml targets ARMv7 and its Insn type has no SWI,
coprocessor or 26-bit PSR concepts (ldm ^, teqp, movs pc / orrs pc
restoring the PSR). Its later stages (insn_to_ir, sptracking) are tied to
ELF and its IR. An "ARM2 mode" would have been a parallel decoder anyway.
arm2.ml keeps the decompiler's naming (conditions, dp ops, shifts) so its
stages can be adapted later if useful.

Decoder
-------
- NV decodes normally and never executes (cond = NV).
- Undefined on ARM2: halfword/long-multiply space, MRS/MSR/BX space,
  undefined space. SWP (ARM3) decodes. Coprocessor instructions decode;
  only cp1/cp2 (FPA) count as plausible.
- `plausible` also rejects encodings no assembler produces: should-be-zero
  fields that aren't (rn of mov/mvn, rd of test ops other than the P forms),
  empty register lists, writeback to r15, mul with rd = rm or rd = r15.

Cross-check (phase2/crosscheck_decoder.py, all 125,346 words of the four
images; phase2/crosscheck.txt):
- Branch targets and data-processing immediates agree with capstone
  everywhere (non-canonical "#imm, #rot" immediates compared rotated).
- Registers: capstone never lists a register we don't. Every disagreement
  is capstone omitting something: writeback bases (post-indexed ldr/str,
  stmdb rN!), the shift register of register-shifted operands, the stored
  registers of stm, and lr for svc (that is lr_svc, not the user's r14).
- 4,935 words capstone decodes as ARMv4+/v3+ (mrs, ldrh, ldrd, umull,
  movw, ...) are undefined here, as expected. All 1,491 non-coprocessor
  words capstone can't decode are implausible here (mostly mov/mvn with
  rn <> 0 and empty register lists).
- Plausibility vs spider.py's valid_arm2 (non-NV words): strictly tighter -
  1,802 words valid_arm2 accepts are implausible here, never the reverse.
  No executed word is implausible.

S0 spider
---------
b/bl and conditional fall-through from the given entries (load address, or
the module header's code entries); steps over NV words; bl returns to +4;
OS_WriteS inline strings; OS_Exit / OS_GenerateError don't return; any
other PC write ends the path. No constant tracking, no tables.

Results (phase2/score.py, phase2/score_s0.txt):

  image    executed   S0 code   exec found   exec missed   B0_generic
  galdan      7867      7530        5597         2270          14198
  lemprog     5973        29          27         5946             29
  lemboot      552         9           9          543              9
  musmod      1366       195         130         1236            756

S0 is a subset of B0_generic on every image (no false code; no decoding
problems). It equals B0_generic on LemProg and LemBoot. The differences are
fully explained by three features B0_generic has and S0 deliberately leaves
to later phases:
- galdan, 6,624 words: B0_generic keeps decoding linearly after Duff's-device
  jumps (add pc,pc,rX) into the unrolled bodies (phase 4: computed jumps).
- galdan, 37+ words: indirect calls with a hand-built link
  (add lr,pc,#0 ; mov pc,r2): the next instruction is a return site (phase 3).
- musmod, 561 words: the SWI dispatch branch table at &1800574
  (addlo pc,pc,r11,lsl #2), which B0_generic walks (phase 4).

Why LemProg stops at 29 words: at &192d4, `bl &8074` calls a literal thunk.
Assuming bl returns to +4, S0 decodes the literal at &192d8 (&00008008) as
`andeq r8, r0, r8` - plausible, so silently accepted as code - and stops at
the next thunk's literal (&192e4), which decodes as an ARMv4 halfword
instruction. Both kinds of error (a literal silently taken as code, and a
trace cut short) are what phase 3's return-address tracking has to remove.
The "read but never executed" column of score.py (2 words for LemProg)
catches the silent case.
