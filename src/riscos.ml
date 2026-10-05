(* What RISC OS SWIs do with their input registers, as far as finding code
   is concerned: which registers carry a code pointer (a handler the OS will
   call) and which carry a pointer to data. From the RISC OS PRMs.

   Only SWIs listed here are "known"; for them, registers not listed carry no
   pointer worth considering. For any other SWI (e.g. a game's own module's
   SWIs) nothing is known and every register is weak evidence. The X bit
   (&20000) is ignored. *)

type arg = Code | Data | Entries of int   (* a block of n consecutive entry points (each
                                            word an instruction the OS calls) *)

let table : (int * (int * arg) list) list = [
  (* OS (kernel) *)
  0x00, [];                                   (* OS_WriteC *)
  0x02, [ (0, Data) ];                        (* OS_Write0 *)
  0x03, [];                                   (* OS_NewLine *)
  0x04, [];                                   (* OS_ReadC *)
  0x05, [ (0, Data) ];                        (* OS_CLI *)
  0x06, [];                                   (* OS_Byte *)
  0x07, [ (1, Data) ];                        (* OS_Word: parameter block *)
  0x08, [ (1, Data); (2, Data); (3, Data); (4, Data); (5, Data) ];   (* OS_File *)
  0x09, [ (2, Data) ];                        (* OS_Args *)
  0x0A, [ (2, Data) ];                        (* OS_BGet *)
  0x0B, [];                                   (* OS_BPut *)
  0x0C, [ (2, Data) ];                        (* OS_GBPB *)
  0x0D, [ (1, Data) ];                        (* OS_Find *)
  0x0E, [ (0, Data) ];                        (* OS_ReadLine *)
  0x10, [ (0, Data); (1, Data) ];             (* OS_GetEnv *)
  0x11, [ (0, Data) ];                        (* OS_Exit *)
  0x1C, [];                                   (* OS_Mouse *)
  0x1D, [];                                   (* OS_Heap *)
  0x1E, [ (1, Data); (2, Data) ];             (* OS_Module *)
  0x1F, [ (1, Code); (2, Data) ];             (* OS_Claim: vector handler *)
  0x20, [ (1, Code); (2, Data) ];             (* OS_Release *)
  0x23, [ (0, Data); (1, Data) ];             (* OS_ReadVarVal *)
  0x24, [ (0, Data); (1, Data) ];             (* OS_SetVarVal *)
  0x27, [ (0, Data); (1, Data) ];             (* OS_GSTrans *)
  0x2B, [ (0, Data) ];                        (* OS_GenerateError *)
  0x2E, [ (1, Data); (2, Data) ];             (* OS_SpriteOp *)
  0x31, [ (0, Data); (1, Data) ];             (* OS_ReadVduVariables *)
  0x35, [];                                   (* OS_ReadModeVariable *)
  0x36, [];                                   (* OS_RemoveCursors *)
  0x37, [];                                   (* OS_RestoreCursors *)
  0x3B, [ (1, Code); (2, Data) ];             (* OS_CallAfter *)
  0x3C, [ (1, Code); (2, Data) ];             (* OS_CallEvery *)
  0x3D, [ (0, Code); (1, Data) ];             (* OS_RemoveTickerEvent *)
  0x40, [ (1, Code); (2, Data); (3, Data) ];  (* OS_ChangeEnvironment *)
  0x42, [];                                   (* OS_ReadMonotonicTime *)
  0x46, [ (0, Data) ];                        (* OS_WriteN *)
  0x47, [ (1, Code); (2, Data) ];             (* OS_AddToVector *)
  0x4B, [ (1, Code); (2, Data) ];             (* OS_ClaimDeviceVector *)
  0x4C, [ (1, Code); (2, Data) ];             (* OS_ReleaseDeviceVector *)
  0x54, [ (0, Code); (1, Data) ];             (* OS_AddCallBack *)
  0x5F, [ (0, Code); (1, Data) ];             (* OS_RemoveCallBack *)
  (* Sound *)
  0x40140, [];                                (* Sound_Configure (handler blocks: unknown layout) *)
  0x40141, [];                                (* Sound_Enable *)
  0x40142, [];                                (* Sound_Stereo *)
  0x40143, [];                                (* Sound_Speaker *)
  0x40180, [];                                (* Sound_Volume *)
  0x40181, [];                                (* Sound_SoundLog *)
  0x40182, [];                                (* Sound_LogScale *)
  0x40183, [ (0, Entries 7) ];                (* Sound_InstallVoice: voice generator header -
                                                 Fill, Update, GateOn, GateOff, Instantiate,
                                                 Free, Install (then the name offset) *)
  0x40184, [];                                (* Sound_RemoveVoice *)
  0x40185, [];                                (* Sound_AttachVoice *)
  0x40186, [];                                (* Sound_ControlPacked *)
  0x40189, [];                                (* Sound_Control *)
  0x4018A, [];                                (* Sound_AttachNamedVoice *)
]

let lookup n = List.assoc_opt (n land lnot 0x20000) table

(* OS_WriteI: SWIs &100-&1FF write one character; no arguments. *)
let args n =
  let n' = n land lnot 0x20000 in
  if n' >= 0x100 && n' < 0x200 then Some [] else lookup n
