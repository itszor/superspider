Phase 3b: address-taken entry points
====================================

Code: src/s1.ml (spider_with_address_taken), src/riscos.ml (SWI argument
table), src/image.ml (module_command_entries). Command:
`superspider s1b IMAGE BASE [--module]`. Evaluation: phase3/eval_s1b.py
(output phase3/eval_s1b.txt). Tests: "s1b address-taken entries",
"module command table".

Method
------
During S1, every constant that points inside the image (word-aligned) and is
either passed to a SWI or stored through a non-stack pointer is a candidate,
with its evidence:
- strong: a register a known SWI treats as a code pointer (OS_Claim/Release
  r1, OS_AddToVector, OS_CallAfter/CallEvery, OS_AddCallBack,
  OS_ChangeEnvironment, OS_ClaimDeviceVector, Sound_InstallVoice r0 ...);
- data: only ever a register a known SWI treats as a data pointer (OS_Word
  r1, OS_File, OS_SpriteOp, OS_ReadVduVariables, OS_Write0 ...) - rejected
  without analysis; registers that aren't inputs of a known SWI are ignored;
- weak: stored to memory, or an argument of a SWI nothing is known about
  (e.g. the game's own module's SWIs).
Each candidate not already code or data is analysed on its own with S1 and
accepted if: no problems, at least 3 instructions, no overlap with words the
main analysis classified as data. Weak candidates must also run at least 4
instructions, contain no zero word and no word code stores to as a variable,
and not start with two words of ASCII text. Accepted candidates become entry
points and everything is re-analysed until nothing new is accepted.

Module *command table entries are read from the module header (+&18) as
given entry points, like the other header entries.

Results
-------
Candidates accepted, against phase 0 ground truth:

  image     accepted  executed  not run (checked by hand)
  galdan        5         2     3: &1aac4 (vector handler, OS_Claim'd),
                                   &262b8/&2633c (voice generators, which
                                   the recompiled runtime emulates at high
                                   level instead of running)
  lemprog       2         2     -   (&8530 IRQ handler stored to &100,
                                     &2a70c Event_V handler via OS_Claim)
  lemboot       0         -     -   (needs phase 3c first)
  musmod        5         5     -   (voice generators &2444 &2608 &27cc
                                     &2990, fill code &2ed0; all "stored")

No executed candidate was rejected; no accepted candidate is data. Before
the OS table and the weak-evidence checks, 13 data blocks (OS_Word
parameter blocks, a variable, a string) had been accepted.

Code words found / executed words among them:

  image     exec   S1          S1b         B0 patched   B1 shipped   B2 shipped
  galdan    7867   7690/5601   7846/5684   14198/6997   18678/7867   18704/7864
  lemprog   5973   8553/4777   9325/5534    8577/4777    9900/5972    9887/5961
  lemboot    552      9/9         9/9        444/430      654/552      653/552
  musmod    1366    195/130    1903/1336    2375/1366    2533/1366    2532/1366

(B0 patched includes the hand seeds; B1/B2 add speculation, Ghidra and
gen_c extensions.)

Hand seeds now found without being given:
- lemprog: 1 of 1 (&19388).
- musmod: 14 of 15 (8 from the *command table, the voice generators and
  fill code as address-taken entries, &2f1c as a derived return). The one
  left, &2f60, never ran in our sessions.
- lemboot: 0 of 1 (&82c0: relocation, phase 3c).

What is still missed (executed words):
- lemprog, 439: the &9434 address table (438 words; phase 4) and one word.
- musmod, 30: behind the SWI dispatch branch table at &574 (phase 4).
- galdan, 2183: the bodies after its Duff's-device jumps and the object-
  handler/call tables (phase 4).
- lemboot, 543: everything after the jump into its relocated copy (phase 3c).

Precision: S1b has no code word that was read as data and never executed
on lemprog or musmod; on galdan the only two are the voice-generator blocks,
which the runtime reads to extract sample parameters (they are code).
