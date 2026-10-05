(* ARM2 / ARM3 instruction decoding (26-bit, pre-ARMv3 architecture).

   Differences from the ARMv7 decoder in ~/stuff/decompiler-git that matter
   here:
   - The NV condition (&F) means "never execute". Encodings in NV space are
     inert, so they are decoded like any other instruction and simply never
     run. RISC OS code uses them as fillers (Lemmings' push-pc idiom).
   - r15 holds both the PC (bits 2-25) and the PSR: N Z C V in bits 31-28,
     I F in 27-26, mode in 1-0. A data-processing instruction with S and
     rd = r15 (e.g. movs pc,lr) restores the PSR as it jumps; one of the
     test ops with rd = r15 (teqp etc.) writes the PSR without jumping;
     ldm with ^ and r15 in the list restores the PSR.
   - No halfword/signed transfers, no MRS/MSR, no BX: those encodings are
     undefined here. SWP exists from ARM3 on and is decoded.
   - Coprocessor instructions decode (FPA uses cp1/cp2); whether a given
     coprocessor is plausible is a separate question (Arm2.plausible). *)

type cond =
  | EQ | NE | CS | CC | MI | PL | VS | VC
  | HI | LS | GE | LT | GT | LE | AL | NV

type shift = LSL | LSR | ASR | ROR

(* Register shifted by an immediate, as encoded: an amount of 0 means
   "no shift" for LSL, #32 for LSR/ASR, and RRX for ROR. *)
type shifted =
  | Shift_imm of int * shift * int        (* rm, shift, amount 0-31 *)
  | Shift_reg of int * shift * int        (* rm, shift, rs *)

type operand2 =
  | Imm of int * int                      (* value (already rotated), rotate field *)
  | Reg of shifted

type dp_op =
  | AND | EOR | SUB | RSB | ADD | ADC | SBC | RSC
  | TST | TEQ | CMP | CMN | ORR | MOV | BIC | MVN

type offset =
  | Off_imm of int                        (* 12-bit unsigned *)
  | Off_reg of int * shift * int          (* rm, shift, amount (immediate only) *)

type cop_kind = Cdp | Mrc | Mcr | Ldc | Stc

type kind =
  | Dp of { op : dp_op; s : bool; rd : int; rn : int; op2 : operand2 }
  | Mul of { acc : bool; s : bool; rd : int; rn : int; rs : int; rm : int }
  | Swp of { byte : bool; rd : int; rm : int; rn : int }
  | Mem of { load : bool; byte : bool; pre : bool; up : bool; wb : bool;
             rd : int; rn : int; off : offset }
  | Block of { load : bool; pre : bool; up : bool; wb : bool; psr : bool;
               rn : int; regs : int }
  | Branch of { link : bool; target : int }
  | Swi of int
  | Cop of { ck : cop_kind; cp : int }
  | Undefined of string

type t = { addr : int; word : int; cond : cond; kind : kind }

let pc_mask = 0x3FFFFFC

let cond_of_int = function
  | 0 -> EQ | 1 -> NE | 2 -> CS | 3 -> CC | 4 -> MI | 5 -> PL | 6 -> VS
  | 7 -> VC | 8 -> HI | 9 -> LS | 10 -> GE | 11 -> LT | 12 -> GT | 13 -> LE
  | 14 -> AL | _ -> NV

let dp_op_of_int = function
  | 0 -> AND | 1 -> EOR | 2 -> SUB | 3 -> RSB | 4 -> ADD | 5 -> ADC
  | 6 -> SBC | 7 -> RSC | 8 -> TST | 9 -> TEQ | 10 -> CMP | 11 -> CMN
  | 12 -> ORR | 13 -> MOV | 14 -> BIC | _ -> MVN

let shift_of_int = function 0 -> LSL | 1 -> LSR | 2 -> ASR | _ -> ROR

let is_test = function TST | TEQ | CMP | CMN -> true | _ -> false

let ror32 v n =
  let n = n land 31 in
  if n = 0 then v
  else ((v lsr n) lor (v lsl (32 - n))) land 0xFFFFFFFF

let bit w n = (w lsr n) land 1 = 1
let field w lo len = (w lsr lo) land ((1 lsl len) - 1)

let decode_shifted w =
  let rm = field w 0 4 and sh = shift_of_int (field w 5 2) in
  if bit w 4 then Shift_reg (rm, sh, field w 8 4)
  else Shift_imm (rm, sh, field w 7 5)

let decode_kind addr w =
  match field w 25 3 with
  | 0 | 1 when field w 4 4 = 0b1001 && field w 22 6 = 0 ->
    Mul { acc = bit w 21; s = bit w 20; rd = field w 16 4; rn = field w 12 4;
          rs = field w 8 4; rm = field w 0 4 }
  | 0 when field w 4 4 = 0b1001 && field w 23 5 = 0b00010 && field w 20 2 = 0
           && field w 8 4 = 0 ->
    Swp { byte = bit w 22; rd = field w 12 4; rm = field w 0 4; rn = field w 16 4 }
  | 0 when bit w 7 && bit w 4 ->
    Undefined "halfword/long-multiply space (ARMv4+)"
  | (0 | 1) as t ->
    let op = dp_op_of_int (field w 21 4) and s = bit w 20 in
    if is_test op && not s then Undefined "MRS/MSR/BX space (test op without S)"
    else
      let op2 =
        if t = 1 then
          let rot = field w 8 4 in
          Imm (ror32 (field w 0 8) (rot * 2), rot)
        else Reg (decode_shifted w) in
      Dp { op; s; rd = field w 12 4; rn = field w 16 4; op2 }
  | 3 when bit w 4 -> Undefined "undefined instruction space"
  | (2 | 3) as t ->
    let off =
      if t = 2 then Off_imm (field w 0 12)
      else Off_reg (field w 0 4, shift_of_int (field w 5 2), field w 7 5) in
    Mem { load = bit w 20; byte = bit w 22; pre = bit w 24; up = bit w 23;
          wb = bit w 21; rd = field w 12 4; rn = field w 16 4; off }
  | 4 ->
    Block { load = bit w 20; pre = bit w 24; up = bit w 23; wb = bit w 21;
            psr = bit w 22; rn = field w 16 4; regs = field w 0 16 }
  | 5 ->
    let off = field w 0 24 in
    let off = if off land 0x800000 <> 0 then off - 0x1000000 else off in
    Branch { link = bit w 24; target = (addr + 8 + off * 4) land pc_mask }
  | 7 when bit w 24 -> Swi (field w 0 24)
  | 6 ->
    Cop { ck = (if bit w 20 then Ldc else Stc); cp = field w 8 4 }
  | _ ->
    let ck = if bit w 4 then (if bit w 20 then Mrc else Mcr) else Cdp in
    Cop { ck; cp = field w 8 4 }

let decode addr word =
  let word = word land 0xFFFFFFFF in
  { addr; word; cond = cond_of_int (word lsr 28); kind = decode_kind addr word }

(* ------------------------------------------------------------------ queries *)

let executes i = i.cond <> NV
let always i = i.cond = AL

let is_undefined i = match i.kind with Undefined _ -> true | _ -> false

(* Plausible as real ARM2/ARM3 code (independently of the condition):
   defined; coprocessor instructions only for the FPA (cp1, cp2); and no
   encodings an assembler never produces even though the CPU would execute
   them: should-be-zero fields that aren't (rn of mov/mvn, rd of the test
   ops other than the P forms), empty register lists, writeback to r15,
   mul with rd = rm or rd = r15 (unpredictable on ARM2). *)
let implausible_reason i =
  match i.kind with
  | Undefined why -> Some why
  | Cop { cp; _ } when cp <> 1 && cp <> 2 -> Some (Printf.sprintf "coprocessor %d" cp)
  | Dp { op = (MOV | MVN); rn; _ } when rn <> 0 -> Some "mov/mvn with rn <> 0"
  | Dp { op; rd; _ } when is_test op && rd <> 0 && rd <> 15 -> Some "test op with rd <> 0"
  | Block { regs = 0; _ } -> Some "empty register list"
  | Block { rn = 15; wb = true; _ } -> Some "writeback to r15"
  | Mem { rn = 15; wb; pre; _ } when wb || not pre -> Some "writeback to r15"
  | Mul { rd; rm; _ } when rd = rm || rd = 15 -> Some "mul rd = rm or r15"
  | _ -> None

let plausible i = implausible_reason i = None

let regs_of_mask m = List.filter (fun r -> m land (1 lsl r) <> 0) (List.init 16 Fun.id)

(* Registers written (r15 included when the instruction can write the PC).
   Test ops with rd = r15 (teqp etc.) write the PSR only. *)
let defs i =
  match i.kind with
  | Dp { op; rd; _ } -> if is_test op then [] else [ rd ]
  | Mul { rd; _ } -> [ rd ]
  | Swp { rd; _ } -> [ rd ]
  | Mem { load; pre; wb; rd; rn; _ } ->
    let base = if wb || not pre then [ rn ] else [] in
    if load then rd :: base else base
  | Block { load; wb; rn; regs; _ } ->
    (if load then regs_of_mask regs else []) @ (if wb then [ rn ] else [])
  | Branch { link; _ } -> if link then [ 14; 15 ] else [ 15 ]
  | Swi _ | Cop _ | Undefined _ -> []

let shifted_uses = function
  | Shift_imm (rm, _, _) -> [ rm ]
  | Shift_reg (rm, _, rs) -> [ rm; rs ]

let uses i =
  match i.kind with
  | Dp { op; rn; op2; _ } ->
    (if op = MOV || op = MVN then [] else [ rn ])
    @ (match op2 with Imm _ -> [] | Reg s -> shifted_uses s)
  | Mul { acc; rn; rs; rm; _ } -> (if acc then [ rn ] else []) @ [ rs; rm ]
  | Swp { rm; rn; _ } -> [ rm; rn ]
  | Mem { load; rd; rn; off; _ } ->
    (if load then [] else [ rd ]) @ [ rn ]
    @ (match off with Off_imm _ -> [] | Off_reg (rm, _, _) -> [ rm ])
  | Block { load; rn; regs; _ } -> rn :: (if load then [] else regs_of_mask regs)
  | Branch _ | Swi _ | Cop _ | Undefined _ -> []

let writes_pc i = List.mem 15 (defs i)

(* Data-processing writing r15 with S set also restores the PSR (movs pc,lr);
   ldm with ^ and r15 in the list does too. *)
let restores_psr i =
  match i.kind with
  | Dp { op; s; rd = 15; _ } -> s && not (is_test op)
  | Block { load = true; psr = true; regs; _ } -> regs land 0x8000 <> 0
  | _ -> false

(* ------------------------------------------------------------------ text *)

let string_of_cond = function
  | EQ -> "eq" | NE -> "ne" | CS -> "cs" | CC -> "cc" | MI -> "mi" | PL -> "pl"
  | VS -> "vs" | VC -> "vc" | HI -> "hi" | LS -> "ls" | GE -> "ge" | LT -> "lt"
  | GT -> "gt" | LE -> "le" | AL -> "" | NV -> "nv"

let string_of_dp_op = function
  | AND -> "and" | EOR -> "eor" | SUB -> "sub" | RSB -> "rsb" | ADD -> "add"
  | ADC -> "adc" | SBC -> "sbc" | RSC -> "rsc" | TST -> "tst" | TEQ -> "teq"
  | CMP -> "cmp" | CMN -> "cmn" | ORR -> "orr" | MOV -> "mov" | BIC -> "bic"
  | MVN -> "mvn"

let string_of_shift = function LSL -> "lsl" | LSR -> "lsr" | ASR -> "asr" | ROR -> "ror"

let reg r =
  match r with 13 -> "sp" | 14 -> "lr" | 15 -> "pc" | n -> "r" ^ string_of_int n

let string_of_shifted = function
  | Shift_imm (rm, LSL, 0) -> reg rm
  | Shift_imm (rm, ROR, 0) -> reg rm ^ ", rrx"
  | Shift_imm (rm, sh, n) ->
    Printf.sprintf "%s, %s #%d" (reg rm) (string_of_shift sh) (if n = 0 then 32 else n)
  | Shift_reg (rm, sh, rs) -> Printf.sprintf "%s, %s %s" (reg rm) (string_of_shift sh) (reg rs)

let string_of_regs m = "{" ^ String.concat ", " (List.map reg (regs_of_mask m)) ^ "}"

let to_string i =
  let c = string_of_cond i.cond in
  match i.kind with
  | Dp { op; s; rd; rn; op2 } ->
    let o2 = match op2 with Imm (v, _) -> Printf.sprintf "#&%x" v | Reg sh -> string_of_shifted sh in
    let name = string_of_dp_op op in
    if is_test op then
      Printf.sprintf "%s%s%s %s, %s" name c (if rd = 15 then "p" else "") (reg rn) o2
    else if op = MOV || op = MVN then
      Printf.sprintf "%s%s%s %s, %s" name c (if s then "s" else "") (reg rd) o2
    else Printf.sprintf "%s%s%s %s, %s, %s" name c (if s then "s" else "") (reg rd) (reg rn) o2
  | Mul { acc; s; rd; rn; rs; rm } ->
    if acc then Printf.sprintf "mla%s%s %s, %s, %s, %s" c (if s then "s" else "") (reg rd) (reg rm) (reg rs) (reg rn)
    else Printf.sprintf "mul%s%s %s, %s, %s" c (if s then "s" else "") (reg rd) (reg rm) (reg rs)
  | Swp { byte; rd; rm; rn } ->
    Printf.sprintf "swp%s%s %s, %s, [%s]" c (if byte then "b" else "") (reg rd) (reg rm) (reg rn)
  | Mem { load; byte; pre; up; wb; rd; rn; off } ->
    let sign = if up then "" else "-" in
    let o = match off with
      | Off_imm 0 -> ""
      | Off_imm n -> Printf.sprintf ", #%s&%x" sign n
      | Off_reg (rm, sh, n) -> ", " ^ sign ^ string_of_shifted (Shift_imm (rm, sh, n)) in
    let addr = if pre then Printf.sprintf "[%s%s]%s" (reg rn) o (if wb then "!" else "")
      else Printf.sprintf "[%s]%s" (reg rn) o in
    Printf.sprintf "%s%s%s%s %s, %s" (if load then "ldr" else "str") c
      (if byte then "b" else "") (if wb && not pre then "t" else "") (reg rd) addr
  | Block { load; pre; up; wb; psr; rn; regs } ->
    let mode = (if up then "i" else "d") ^ (if pre then "b" else "a") in
    Printf.sprintf "%s%s%s %s%s, %s%s" (if load then "ldm" else "stm") c mode (reg rn)
      (if wb then "!" else "") (string_of_regs regs) (if psr then "^" else "")
  | Branch { link; target } -> Printf.sprintf "b%s%s &%x" (if link then "l" else "") c target
  | Swi n -> Printf.sprintf "swi%s &%x" c n
  | Cop { ck; cp } ->
    Printf.sprintf "%s%s p%d (&%08x)"
      (match ck with Cdp -> "cdp" | Mrc -> "mrc" | Mcr -> "mcr" | Ldc -> "ldc" | Stc -> "stc") c cp i.word
  | Undefined why -> Printf.sprintf "undefined (%s)" why
