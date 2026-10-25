(* Static recompilation to C: an ARM2 image and its analysis -> C, one
   instruction at a time, using the macros in libroger's roger_cpu.h.
   (Formerly tools/gen_c.py, which read the analysis through Ghidra-shaped
   intermediates; this reads it directly.)

   Each code word belongs to one C function, its owner in the analysis.
   Dispatch leaders - addresses a CALL or JUMP may land on, which get a
   label and an entry in the entry table - are chosen by [leaders]:
     All       every code word (and the analysis' dispatch targets): any
               address can be jumped to, as on the real machine
     Dispatch  only where the analysis knows control arrives indirectly,
               plus direct branch targets and the like (smaller output,
               but needs complete roots: Lemmings, Galactic Dan)
   The output: <out>/code00.c.. (the functions), <out>/<header>.h, and
   <out>/entries.c, which exports a struct roger_image named
   <tabprefix>_image. *)

module IS = Set.Make (Int)

let m32 = 0xFFFFFFFF

(* What the generator needs from the analysis. *)
type input = {
  code : (int, unit) Hashtbl.t;       (* code words *)
  owner : (int, int) Hashtbl.t;       (* code word -> owning function (missing: itself) *)
  funcs : int list;                   (* function entries *)
  entries : int list;                 (* entry points (roots) *)
  linked : int list;                  (* indirect transfers made with lr = site + 4: calls *)
  follow : int list;                  (* computed jumps into the following code (Duff's devices) *)
  smc : (int * int list) list;        (* self-modified code word -> the words stored there *)
  returns : (int * int list) list;    (* call site -> return targets *)
  const_jumps : (int * int list) list;(* jump site -> targets *)
}

type leaders = All | Dispatch

type options = {
  prefix : string;          (* function symbols: <prefix>_<addr> *)
  tabprefix : string;       (* tables: <tabprefix>_entries, _codemap, _image *)
  pcbias : bool;            (* PC-derived values relative to the runtime's pc_bias *)
  files : int;              (* number of code*.c files *)
  header : string;          (* header name, without .h *)
  covtag : string;          (* the coverage recorder's tag for this image ("" none) *)
  leaders : leaders;
  banner : string;          (* what the generated files say generated them *)
  range : (int * int) list;
                            (* emit only the code in these [from, to) ranges (none: all
                               of it): an overlay analysed together with the program it
                               is loaded beside (the program's code is translated
                               separately; calls into it are dispatched), or the parts
                               of a program that are translated while the rest is not
                               (native code in their place). The image spans them all *)
  no_smc : bool;            (* no check before each instruction that the program hasn't
                               stored over it since (I_() rather than I()): for an image
                               known not to modify its code, about a fifth faster. Words
                               the analysis found stored to keep it *)
}

let default_options = { prefix = "F"; tabprefix = "recomp"; pcbias = false; files = 16; header = "gen";
                        covtag = ""; leaders = All; banner = "superspider"; range = [];
                        no_smc = false }

let of_s1 (t : S1.t) ~entries =
  let keys h = List.sort compare (Hashtbl.fold (fun k _ acc -> k :: acc) h []) in
  let sets h = List.map (fun k -> (k, S1.IS.elements (Hashtbl.find h k))) (keys h) in
  { code = t.code; owner = t.owner; funcs = keys t.funcs; entries; linked = keys t.linked;
    follow = keys t.follow;
    smc = List.filter_map (fun w ->
        if not (Hashtbl.mem t.code w) then None
        else Some (w, match Hashtbl.find_opt t.var_stores w with
          | Some (S1.Consts s) -> S1.IS.elements s
          | _ -> [])) (keys t.code_writes);
    returns = sets t.ret_sites; const_jumps = sets t.const_jumps }

(* ------------------------------------------------------------------ the image *)

type ctx = {
  o : options;
  inp : input;
  data : string;
  base : int;
  iend : int;
  ebase : int;                               (* the image emitted: [ebase, eend) (--range) *)
  eend : int;
  owner_of : (int, int) Hashtbl.t;           (* every code word -> its C function *)
  funcs : (int, int list) Hashtbl.t;         (* C function -> its words, ascending *)
  calls : (int, unit) Hashtbl.t;             (* CALL overrides *)
  fallthrough : (int, int) Hashtbl.t;        (* OS_WriteS -> where execution resumes *)
  duff : (int, int list) Hashtbl.t;          (* computed jump -> the entries of its unrolled body *)
  smc : (int, int list) Hashtbl.t;
  smc_words : (int, unit) Hashtbl.t;         (* stored-to code words: not in the code map *)
  mutable leaders : (int, unit) Hashtbl.t;
  mutable insns : int;
  mutable nsmc : int;
  mutable nduff : int;
}

let byte c a = if a >= c.base && a < c.base + String.length c.data then Char.code c.data.[a - c.base] else 0
let word c a = byte c a lor (byte c (a + 1) lsl 8) lor (byte c (a + 2) lsl 16) lor (byte c (a + 3) lsl 24)
let inside c a = a >= c.base && a < c.iend
let is_code c a = Hashtbl.mem c.inp.code a

let ror v s = let s = s land 31 in if s = 0 then v else ((v lsr s) lor (v lsl (32 - s))) land m32

let h v = Printf.sprintf "0x%xu" (v land m32)

let conds = [| "EQ"; "NE"; "CS"; "CC"; "MI"; "PL"; "VS"; "VC"; "HI"; "LS"; "GE"; "LT"; "GT"; "LE"; "AL"; "NV" |]
let dpops = [| "AND"; "EOR"; "SUB"; "RSB"; "ADD"; "ADC"; "SBC"; "RSC";
               "TST"; "TEQ"; "CMP"; "CMN"; "ORR"; "MOV"; "BIC"; "MVN" |]
let logical op = List.mem op [ 0; 1; 8; 9; 12; 13; 14; 15 ]

(* ------------------------------------------------------------------ labels *)

(* Printable text in the data: OS_WriteS strings, and runs of text in the
   gaps between code (as export_ghidra.py found them). Only used to keep
   the offset-table scan below out of strings. *)
let textlike (txt : string) =
  let n = String.length txt in
  let alpha ch = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') in
  let upper ch = ch >= 'A' && ch <= 'Z' and lower ch = ch >= 'a' && ch <= 'z' in
  let words = ref [] and i = ref 0 in
  while !i < n do
    if alpha txt.[!i] then begin
      let j = ref !i in
      while !j < n && alpha txt.[!j] do incr j done;
      words := String.sub txt !i (!j - !i) :: !words; i := !j
    end else incr i
  done;
  let words = List.rev !words in
  let letters = String.concat "" words in
  let nl = String.length letters in
  let word_ok w =
    (* [A-Z]?[a-z]+ | [A-Z]+ *)
    let k = String.length w in
    String.for_all upper w
    || (k >= 1 && (let s = if upper w.[0] then 1 else 0 in
                   k - s >= 1 && String.for_all lower (String.sub w s (k - s)))) in
  let repeat4 =
    let r = ref false in
    for k = 0 to n - 4 do
      let ch = txt.[k] in
      if ch <> '\n' && txt.[k + 1] = ch && txt.[k + 2] = ch && txt.[k + 3] = ch then r := true
    done; !r in
  let rule4 =
    let r = ref false and run = ref 0 in
    String.iter (fun ch -> if String.contains " =*-" ch then (incr run; if !run >= 4 then r := true) else run := 0) txt;
    !r in
  let distinct = List.length (List.sort_uniq compare (List.init nl (String.get letters))) in
  if nl < 4 then false
  else if not (List.for_all word_ok words) then false
  else if (repeat4 && not rule4) || distinct < 3 then false
  else
    let v = String.fold_left (fun acc ch -> if String.contains "aeiouAEIOU" ch then acc + 1 else acc) 0 letters in
    let r = float_of_int v /. float_of_int nl in
    r >= 0.2 && r <= 0.65

let strings_in c lo hi =
  let out = ref [] and a = ref lo in
  let printable b = (b >= 32 && b < 127) || b = 10 || b = 13 in
  while !a < hi do
    let b = ref !a in
    while !b < hi && printable (byte c !b) do incr b done;
    let txt = String.init (!b - !a) (fun k -> Char.chr (byte c (!a + k))) in
    let letters = String.fold_left (fun acc ch ->
        if (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch = ' ' || ch = '\n' || ch = '\r'
        then acc + 1 else acc) 0 txt in
    if !b - !a >= 6 && float_of_int letters >= 0.8 *. float_of_int (String.length txt) && textlike txt then begin
      let term = !b < hi && byte c !b = 0 in
      out := (!a, !b - !a + (if term then 1 else 0)) :: !out;
      a := !b + 1
    end else a := if !b = !a then !b + 1 else !b
  done;
  List.rev !out

let os_writes w = (w lsr 24) land 15 = 0xF && (w land lnot 0x20000) land 0xFFFFFF = 1

let strings c codes =
  let ws = List.filter_map (fun a ->
      if os_writes (word c a) then begin
        let s = a + 4 in
        let e = ref s in
        while byte c !e <> 0 do incr e done;
        Some (s, !e - s + 1)
      end else None) codes in
  let covered = Hashtbl.create 64 in
  List.iter (fun (s, l) -> for x = s to s + l - 1 do Hashtbl.replace covered x () done) ws;
  let gaps = ref [] and lo = ref (-1) in
  for a = c.base to c.iend - 1 do
    let inc = is_code c (a land lnot 3) in
    if not inc && !lo < 0 then lo := a;
    if (inc || a = c.iend - 1) && !lo >= 0 then begin
      List.iter (fun (s, l) -> if not (Hashtbl.mem covered s) then gaps := (s, l) :: !gaps)
        (strings_in c !lo (if inc then a else c.iend));
      lo := -1
    end
  done;
  ws @ List.rev !gaps

(* Labels the old assembler-oriented analysis gave (gen_asm.py): they are
   dispatch leaders when they are code. Function entries, OS_WriteS
   strings, the image base, and both ends of PC-relative offsets: a
   literal holding (target - (use + 8)) used by add rY,pc,rX or
   ldr/str rY,[pc,rX], and tables of such offsets indexed by a masked
   register (static_tables). *)
let ws_top = 0xA8000            (* top of a 640K wimpslot: workspace above the image *)

let labels c codes =
  let labels = Hashtbl.create 1024 in
  let label a = Hashtbl.replace labels a () in
  List.iter (fun f -> if f < 0x10000000 then label f) c.inp.funcs;
  let strs = strings c codes in
  List.iter (fun (s, _) -> label s) strs;
  label c.base;
  let offset_words : (int, int * int * int option) Hashtbl.t = Hashtbl.create 64 in
  (* ldr rX,[pc,#lit] ... add rY,pc,rX | ldr/str rY,[pc,rX] *)
  List.iter (fun a ->
      let w = word c a in
      if w land 0x0F7F0000 = 0x051F0000 && w lsr 28 = 14 then begin
        let rx = (w lsr 12) land 15 and off = w land 0xFFF in
        let lit = a + 8 + (if w land (1 lsl 23) <> 0 then off else - off) in
        if inside c lit && not (is_code c lit) && lit land 3 = 0 then begin
          let v = word c lit in
          let rec scan u =
            if u < a + 28 && is_code c u then begin
              let x = word c u in
              let use = (x land 0x0FEF0FF0 = 0x008F0000 && x land 15 = rx)
                        || (x land 0x0FAF0FF0 = 0x078F0000 && x land 15 = rx) in
              if use then begin
                let t = (u + 8 + v) land m32 in
                if (inside c t || (c.iend <= t && t < ws_top)) && not (Hashtbl.mem offset_words lit) then
                  Hashtbl.replace offset_words lit (t, u + 8, Some u)
              end else begin
                let t3 = (x lsr 25) land 7 in
                let stop = t3 = 5 || (x lsr 24) land 15 = 0xF
                           || (t3 <= 3 && (x lsr 12) land 15 = rx)
                           || (t3 = 4 && (x lsr 20) land 1 = 1 && x land (1 lsl rx) <> 0) in
                if not stop then scan (u + 4)
              end
            end in
          scan (a + 4)
        end
      end) codes;
  (* tables of offsets *)
  let target_kind t =
    if is_code c t && t land 3 = 0 then Some 'C'
    else if inside c t then (if not (is_code c t) then Some 'i' else None)
    else if c.iend <= t && t < ws_top then Some 'w' else None in
  let add_table_word x b =
    if x land 3 <> 0 || not (inside c x) || Hashtbl.mem offset_words x then false
    else if List.exists (fun (s, l) -> s <= x && x < s + l) strs then false
    else
      let t = (b + word c x) land m32 in
      if target_kind t = None || is_code c x then false
      else begin
        Hashtbl.replace offset_words x (t, b, if is_code c (b - 8) then Some (b - 8) else None);
        true
      end in
  let const_before at r =
    let rec go a =
      if a <= at - 32 then None
      else if not (is_code c a) then None
      else
        let y = word c a in
        if (y lsr 12) land 15 <> r then (if (y lsr 25) land 7 = 5 then None else go (a - 4))
        else if y land 0x0FEF0000 = 0x028F0000 || y land 0x0FEF0000 = 0x024F0000 then
          let v = ror (y land 0xFF) (((y lsr 8) land 15) * 2) in
          Some ((if (y lsr 21) land 15 = 4 then a + 8 + v else a + 8 - v) land m32)
        else if y land 0x0FEF0FF0 = 0x008F0000 && y land 15 = r then
          let rec lit b =
            if b <= a - 16 then None
            else
              let z = word c b in
              if z land 0x0F7F0000 = 0x051F0000 && (z lsr 12) land 15 = r then
                let off = z land 0xFFF in
                let l = b + 8 + (if z land (1 lsl 23) <> 0 then off else - off) in
                Some ((a + 8 + word c l) land m32)
              else lit (b - 4) in
          lit (a - 4)
        else None in
    go (at - 4) in
  let index_bound at r =
    let rec go a =
      if a <= at - 32 || not (is_code c a) then None
      else
        let y = word c a in
        if (y lsr 12) land 15 = r && y land 0x0FE00000 = 0x02000000 then
          (if (y lsr 8) land 15 = 0 then Some ((y land 0xFF) + 1) else None)
        else if (y lsr 12) land 15 = r && y land 0x0FE00000 = 0x03C00000 then
          (if (y lsr 8) land 15 = 0 then Some ((lnot (y land 0xFF) land 0xFF) + 1) else None)
        else if y land 0x0FF00000 = 0x03500000 && (y lsr 16) land 15 = r then None
        else if (y lsr 12) land 15 = r then None
        else go (a - 4) in
    go (at - 4) in
  List.iter (fun u ->
      let w = word c u in
      let rx = if w land 0x0FEF0FF0 = 0x008F0000 || w land 0x0FAF0FF0 = 0x078F0000 then Some (w land 15) else None in
      match rx with
      | None -> ()
      | Some rx ->
        let rec find_ld a =
          if a <= u - 24 || not (is_code c a) then None
          else
            let y = word c a in
            if y land 0x0E100000 = 0x06100000 && (y lsr 12) land 15 = rx && (y lsr 22) land 1 = 0
               && (y lsr 24) land 1 = 1 && (y lsr 5) land 3 = 0 && y land 0x10 = 0 then Some a
            else if (y lsr 12) land 15 = rx || (y lsr 25) land 7 = 5 then None
            else find_ld (a - 4) in
        match find_ld (u - 4) with
        | None -> ()
        | Some ld ->
          let y = word c ld in
          let rt = (y lsr 16) land 15 and ri = y land 15 and sh = (y lsr 7) land 31 in
          if rt <> 15 && ri <> 15 then
            match const_before ld rt with
            | None -> ()
            | Some tbase ->
              let count = index_bound ld ri in
              let stride, count = if sh = 0 then 4, Option.map (fun n -> (n + 3) / 4) count
                else 1 lsl sh, count in
              let rec go k =
                if (match count with None -> true | Some n -> k < n) then
                  if add_table_word (tbase + k * stride) (u + 8) && k + 1 <= 256 then go (k + 1) in
              go 0) codes;
  Hashtbl.iter (fun _ (t, b, u) ->
      if not (t land 3 <> 0 && is_code c (t land lnot 3)) then label t;
      match u with
      | Some u when b = u + 8 -> label u
      | _ -> label b) offset_words;
  labels

(* ------------------------------------------------------------------ set-up *)

let branch_target a w =
  let off = w land 0xFFFFFF in
  let off = if off land 0x800000 <> 0 then off - 0x1000000 else off in
  (a + 8 + off * 4) land 0x3FFFFFC

(* bic lr,lr,#&FC000003 ; ldr rX,[lr],#4 ; mov pc,lr: a bl to one of these
   consumes the literal word after the call site and returns to site + 8. *)
let is_literal_thunk c t =
  c.base <= t && t < c.iend - 8 && word c t = 0xE3CEE3FF && word c (t + 8) = 0xE1A0F00E

let call_return_site c a w t = if w land (1 lsl 24) <> 0 && is_literal_thunk c t then a + 8 else a + 4

(* Where control continues after a: a literal-thunk call skips its literal;
   stmdb sp!,{pc} (push a return address) skips the NV filler after it when
   that is what follows (stmdb sp!,{pc}; movnv; b X). Otherwise the next
   instruction is the call itself and runs (Chuck Rock: stmdb sp!,{pc};
   ldr pc,[r6,#&2C]; movnv). *)
let natural_next c a w =
  if (w lsr 25) land 7 = 5 && w land (1 lsl 24) <> 0 then call_return_site c a w (branch_target a w)
  else if w land 0x0FFFFFFF = 0x092D8000 && inside c (a + 4) && word c (a + 4) lsr 28 = 0xF then a + 8
  else a + 4

(* The stride of a computed add pc,pc,X whose X is a multiple of a
   constant just made: mov rK,#k ; mul X,rK,rY (or rY,rK) ; add pc,pc,X. *)
let mul_stride c a =
  if not (inside c (a - 8)) then None
  else
    let at x = Arm2.decode x (word c x) in
    let add = at a and mul = at (a - 4) and mov = at (a - 8) in
    match add.kind, mul.kind, mov.kind with
    | Arm2.Dp { op = Arm2.ADD; rd = 15; rn = 15; op2 = Arm2.Reg (Arm2.Shift_imm (x, Arm2.LSL, 0)); _ },
      Arm2.Mul { acc = false; rd; rs; rm; _ },
      Arm2.Dp { op = Arm2.MOV; rd = r; op2 = Arm2.Imm (k, _); _ }
      when Arm2.always mul && Arm2.always mov && rd = x && r <> x && (rs = r || rm = r)
           && k > 0 && k land 3 = 0 -> Some k
    | _ -> None

(* The unrolled body after a computed add pc,pc,X: its repetition period,
   and the block starts aligned to the end of the repeated run - or, when X
   is a multiple of a constant (mul_stride), a + 8 and every multiple of it
   after. They differ when the run doesn't end on a block boundary: Gods'
   &57760 enters blocks of 25 words at a + 8 + 100k (mov r7,#100 ; mul
   r6,r7,r6), and the repetition goes on 18 words into the code after the
   last block. *)
let duff_entries c a =
  let s = a + 8 in
  let best = ref None in
  for p = 1 to 32 do
    let n = ref 0 in
    while inside c (s + 4 * (!n + p)) && word c (s + 4 * !n) = word c (s + 4 * (!n + p)) do incr n done;
    if !n >= 2 * p && (match !best with None -> true | Some (_, bn) -> !n > bn + p) then best := Some (p, !n)
  done;
  match !best with
  | None -> []
  | Some (p, n) ->
    let fin = s + 4 * (n + p) in
    let ents = ref (IS.of_list [ a + 4; fin ]) and e = ref fin in
    while !e >= s do ents := IS.add !e !ents; e := !e - 4 * p done;
    (match mul_stride c a with
     | Some k -> e := s; while !e <= fin do ents := IS.add !e !ents; e := !e + k done
     | None -> ());
    IS.elements !ents

let create o inp ~data ~base =
  let codes = List.sort compare (Hashtbl.fold (fun a () acc -> a :: acc) inp.code []) in
  let iend = base + String.length data in
  let ebase, eend = match o.range with
    | [] -> base, iend
    | rs -> List.fold_left (fun (lo, hi) (f, t) -> min lo f, max hi t) (max_int, min_int) rs in
  let c = { o; inp; data; base; iend; ebase; eend; owner_of = Hashtbl.create 8192;
            funcs = Hashtbl.create 1024; calls = Hashtbl.create 64; fallthrough = Hashtbl.create 64;
            duff = Hashtbl.create 16; smc = Hashtbl.create 16; smc_words = Hashtbl.create 16;
            leaders = Hashtbl.create 8192; insns = 0; nsmc = 0; nduff = 0 } in
  let own a = Option.value (Hashtbl.find_opt inp.owner a) ~default:a in
  List.iter (fun a ->
      let o = own a in
      Hashtbl.replace c.owner_of a o;
      Hashtbl.replace c.funcs o (a :: Option.value (Hashtbl.find_opt c.funcs o) ~default:[])) codes;
  Hashtbl.filter_map_inplace (fun _ l -> Some (List.rev l)) c.funcs;
  List.iter (fun a -> if is_code c a then Hashtbl.replace c.calls a ()) inp.linked;
  List.iter (fun a ->
      let w = word c a in
      if (w lsr 24) land 15 = 0xF && (w land 0xFFFFFF) land lnot 0x20000 = 1 then begin
        let e = ref (a + 4) in
        while byte c !e <> 0 do incr e done;
        Hashtbl.replace c.fallthrough a ((!e + 4) land lnot 3)
      end) codes;
  List.iter (fun a -> match duff_entries c a with
      | [] -> ()
      | ents -> if is_code c a then Hashtbl.replace c.duff a ents) inp.follow;
  List.iter (fun (w, vs) ->
      Hashtbl.replace c.smc_words w ();
      if is_code c w then Hashtbl.replace c.smc w vs) inp.smc;
  (* dispatch leaders *)
  let dispatch () =
    (* every address the analysis knows control arrives at indirectly, and
       the words where one C function's code continues into another's *)
    let d = Hashtbl.create 4096 in
    let add a = Hashtbl.replace d a () in
    List.iter add inp.funcs; List.iter add inp.entries;
    List.iter (fun (_, ts) -> List.iter add ts) inp.returns;
    List.iter (fun (_, ts) -> List.iter add ts) inp.const_jumps;
    List.iter (fun a -> add (a + 8)) inp.follow;
    List.iter (fun a -> List.iter (fun n -> if is_code c n && own n <> own a then add n) [ a + 4; a + 8 ]) codes;
    Hashtbl.filter_map_inplace (fun a () -> if is_code c a then Some () else None) d;
    d in
  let l = dispatch () in
  if o.leaders = All then List.iter (fun a -> Hashtbl.replace l a ()) codes;
  let add a = Hashtbl.replace l a () in
  let labels = labels c codes in
  List.iter (fun a ->
      let w = word c a in
      if Hashtbl.mem labels a then add a;
      let t = (w lsr 25) land 7 in
      if t = 5 then begin
        let tgt = branch_target a w in
        add tgt;
        if w land (1 lsl 24) <> 0 || Hashtbl.mem c.calls a then add (call_return_site c a w tgt)
      end;
      if Hashtbl.mem c.calls a then add (a + 4);
      (* a coprocessor or undefined instruction leaves for the dispatcher
         (undefined_insn: the FPEmulator carries out the FPA's), which goes
         on at the next word *)
      if w lsr 28 <> 15 && (t = 6 || (t = 7 && w land (1 lsl 24) = 0) || (t = 3 && w land 0x10 <> 0)) then add (a + 4);
      if t = 1 && (w lsr 16) land 15 = 15 && ((w lsr 21) land 15 = 2 || (w lsr 21) land 15 = 4) then begin
        let v = ror (w land 0xFF) (((w lsr 8) land 15) * 2) in          (* ADR: a code address taken *)
        add ((if (w lsr 21) land 15 = 4 then a + 8 + v else a + 8 - v) land m32)
      end) codes;
  Hashtbl.iter (fun _ b -> add b) c.fallthrough;
  Hashtbl.iter (fun _ ents -> List.iter add ents) c.duff;
  List.iter add inp.funcs;
  Hashtbl.iter (fun o _ -> add o) c.funcs;
  Hashtbl.filter_map_inplace (fun a () -> if is_code c a then Some () else None) l;
  c.leaders <- l;
  if o.range <> [] then begin
    (* only the ranges' words: functions trimmed to them (each entered at its
       first), and their leaders; a call or jump out of them is dispatched *)
    let inr a = List.exists (fun (f, t) -> a >= f && a < t) o.range in
    Hashtbl.filter_map_inplace (fun _ ws ->
        match List.filter inr ws with
        | [] -> None
        | first :: _ as ws -> add first; Some ws) c.funcs;
    Hashtbl.filter_map_inplace (fun a () -> if inr a then Some () else None) l;
    Hashtbl.filter_map_inplace (fun a v -> if inr a then Some v else None) c.smc
  end;
  c

(* ------------------------------------------------------------------ translation *)

let is_leader c a = Hashtbl.mem c.leaders a

(* A PC-derived value. With pcbias the image may be running from a copy of
   itself (LemBoot), so everything the program observes of its PC is offset
   by the runtime's pc_bias; dispatch still uses unbiased addresses. *)
let pc c v = if c.o.pcbias then Printf.sprintf "(%s + pc_bias)" (h v) else h v

let regv c n a pcoff full =
  if n = 15 then
    let p = (a + pcoff) land 0x3FFFFFC in
    if full then Printf.sprintf "(%s | PSR())" (pc c p) else pc c p
  else Printf.sprintf "R[%d]" n

let imm_shift v typ amt =
  match typ with
  | 0 -> if amt = 0 then v, "CF" else Printf.sprintf "SH_LSL(%s, %d)" v amt, Printf.sprintf "CY_LSL(%s, %d)" v amt
  | 1 | 2 ->
    let n = if amt = 0 then 32 else amt and k = if typ = 1 then "LSR" else "ASR" in
    Printf.sprintf "SH_%s(%s, %d)" k v n, Printf.sprintf "CY_%s(%s, %d)" k v n
  | _ ->
    if amt = 0 then Printf.sprintf "SH_RRX(%s)" v, Printf.sprintf "CY_RRX(%s)" v
    else Printf.sprintf "SH_ROR(%s, %d)" v amt, Printf.sprintf "CY_ROR(%s, %d)" v amt

(* (value, carry out, register-specified shift) for operand 2 *)
let op2 c a w =
  if w land (1 lsl 25) <> 0 then
    let rot = ((w lsr 8) land 15) * 2 in
    let v = ror (w land 0xFF) rot in
    h v, (if rot <> 0 then string_of_int (v lsr 31) else "CF"), false
  else
    let rm = w land 15 and typ = (w lsr 5) land 3 in
    if w land 0x10 <> 0 then
      let rs = (w lsr 8) land 15 in
      let rmv = regv c rm a 12 true in
      let amt = Printf.sprintf "(%s & 0xFF)" (regv c rs a 8 true) in
      Printf.sprintf "SHR(%s, %d, %s)" rmv typ amt, Printf.sprintf "SHRC(%s, %d, %s)" rmv typ amt, true
    else
      let v, cy = imm_shift (regv c rm a 8 true) typ ((w lsr 7) land 31) in
      v, cy, false

let call_code c t ret =
  if is_code c t && is_leader c t then
    Printf.sprintf "CALL(%s_%x, %s, %s);" c.o.prefix (Hashtbl.find c.owner_of t) (h t) (pc c ret)
  else Printf.sprintf "npc = %s; CALLI(%s);" (pc c t) (pc c ret)

let jump_code c fn t =
  if is_code c t && Hashtbl.find_opt c.owner_of t = Some fn && is_leader c t then Printf.sprintf "goto L_%x;" t
  else Printf.sprintf "JUMP(%s);" (pc c t)

let duff_dispatch c fn a =
  let ents = List.filter (fun e -> Hashtbl.find_opt c.owner_of e = Some fn && is_leader c e) (Hashtbl.find c.duff a) in
  c.nduff <- c.nduff + 1;
  Printf.sprintf "switch (npc%s) { %s default: LEAVE(); }" (if c.o.pcbias then " - pc_bias" else "")
    (String.concat " " (List.map (fun e -> Printf.sprintf "case %s: goto L_%x;" (h e) e) ents))

(* npc has been set by the instruction at a (not a branch) *)
let after_pc_write c fn a =
  if Hashtbl.mem c.calls a then Printf.sprintf "CALLI(%s);" (pc c (a + 4))
  else if Hashtbl.mem c.duff a then duff_dispatch c fn a
  else "LEAVE();"

let mul _c _a w =
  let rd = (w lsr 16) land 15 and rn = (w lsr 12) land 15 and rs = (w lsr 8) land 15 and rm = w land 15 in
  let s = if w land (1 lsl 20) <> 0 then "S" else "" in
  if w land (1 lsl 21) <> 0 then [ Printf.sprintf "MLA%s(%d, %d, %d, %d);" s rd rm rs rn ]
  else [ Printf.sprintf "MUL%s(%d, %d, %d);" s rd rm rs ]

(* the long multiplies (ARMv3M: the StrongARM's) *)
let mull _c _a w =
  let hi = (w lsr 16) land 15 and lo = (w lsr 12) land 15 and rs = (w lsr 8) land 15 and rm = w land 15 in
  let name = [| "UMULL"; "UMLAL"; "SMULL"; "SMLAL" |].((w lsr 21) land 3) in
  [ Printf.sprintf "%s%s(%d, %d, %d, %d);" name (if w land (1 lsl 20) <> 0 then "S" else "") lo hi rm rs ]

let dataproc c fn a w =
  let op = (w lsr 21) land 15 and s = (w lsr 20) land 1 in
  let rn = (w lsr 16) land 15 and rd = (w lsr 12) land 15 in
  let b, cy, regshift = op2 c a w in
  let av = regv c rn a (if regshift then 12 else 8) false in
  let name = dpops.(op) in
  if op >= 8 && op <= 11 && s = 0 then
    (* MRS/MSR (ARMv3): on an ARM2 or ARM3 a test op without S, which writes
       nothing - see Arm2 *)
    [ Printf.sprintf "/* %s: nothing on an ARM2 */" (Arm2.to_string (Arm2.decode a w)) ]
  else if op >= 8 && op <= 11 then begin
    if rd = 15 then
      (* TEQP & co: the PSR from the result. R15 as Rn reads as the bare
         address, so TEQP PC,#0 means "USR mode, flags clear". *)
      let e = match op with
        | 8 -> Printf.sprintf "%s & %s" av b | 9 -> Printf.sprintf "%s ^ %s" av b
        | 10 -> Printf.sprintf "%s - %s" av b | _ -> Printf.sprintf "%s + %s" av b in
      [ Printf.sprintf "SETPSR(%s);" e ]
    else if op = 8 || op = 9 then [ Printf.sprintf "DP_%s(%s, %s, %s);" name av b cy ]
    else [ Printf.sprintf "DP_%s(%s, %s);" name av b ]
  end
  else if rd = 15 then
    let e = match op with
      | 0 -> Printf.sprintf "%s & %s" av b | 1 -> Printf.sprintf "%s ^ %s" av b
      | 2 -> Printf.sprintf "%s - %s" av b | 3 -> Printf.sprintf "%s - %s" b av
      | 4 -> Printf.sprintf "%s + %s" av b | 5 -> Printf.sprintf "%s + %s + CF" av b
      | 6 -> Printf.sprintf "%s + ~%s + CF" av b | 7 -> Printf.sprintf "%s + ~%s + CF" b av
      | 12 -> Printf.sprintf "%s | %s" av b | 13 -> b
      | 14 -> Printf.sprintf "%s & ~%s" av b | _ -> Printf.sprintf "~%s" b in
    [ Printf.sprintf "SETPC(%s, %d);" e s; after_pc_write c fn a ]
  else
    let args =
      if op = 13 || op = 15 then [ string_of_int rd; b ] @ (if s = 1 then [ cy ] else [])
      else if logical op then [ string_of_int rd; av; b ] @ (if s = 1 then [ cy ] else [])
      else [ string_of_int rd; av; b ] in
    [ Printf.sprintf "DP_%s%s(%s);" name (if s = 1 then "S" else "") (String.concat ", " args) ]

let ldrstr c fn a w =
  let bit k = (w lsr k) land 1 in
  let p = bit 24 and u = bit 23 and bb = bit 22 and wbit = bit 21 and l = bit 20 in
  let rn = (w lsr 16) land 15 and rd = (w lsr 12) land 15 in
  let off = if w land (1 lsl 25) <> 0 then fst (imm_shift (regv c (w land 15) a 8 true) ((w lsr 5) land 3) ((w lsr 7) land 31))
    else h (w land 0xFFF) in
  let base = regv c rn a 8 false in
  let wb = if (p = 0 || wbit = 1) && rn <> 15 then rn else -1 in
  if l = 1 then
    if rd = 15 then [ Printf.sprintf "LDRPC_(%s, %s, %d, %d, %d);" base off p u wb; after_pc_write c fn a ]
    else [ Printf.sprintf "LDR_(%d, %s, %s, %d, %d, %d, %d);" rd base off p u bb wb ]
  else
    let v = if rd = 15 then Printf.sprintf "(%s | PSR())" (pc c (a + 12)) else Printf.sprintf "R[%d]" rd in
    [ Printf.sprintf "STR_(%s, %s, %s, %d, %d, %d, %d);" v base off p u bb wb ]

let ldmstm c fn a w =
  let bit k = (w lsr k) land 1 in
  let p = bit 24 and u = bit 23 and s = bit 22 and wbit = bit 21 and l = bit 20 in
  let rn = (w lsr 16) land 15 in
  let regs = List.filter (fun k -> w land (1 lsl k) <> 0) (List.init 16 Fun.id) in
  let n = List.length regs in
  let base = if rn <> 15 then Printf.sprintf "R[%d]" rn else pc c (a + 8) in
  let start, wbv =
    if u = 1 then Printf.sprintf "%s + %d" base (if p = 1 then 4 else 0), Printf.sprintf "%s + %d" base (4 * n)
    else Printf.sprintf "%s - %d" base (4 * n - (if p = 1 then 0 else 4)), Printf.sprintf "%s - %d" base (4 * n) in
  let wbs = if wbit = 1 && rn <> 15 then Printf.sprintf "R[%d] = %s; " rn wbv else "" in
  (* ^ without a PC load transfers the user bank (in a privileged mode) *)
  let user = s = 1 && not (l = 1 && List.mem 15 regs) in
  if l = 1 then
    let parts = Printf.sprintf "LDM_BEGIN(%s) %s" start wbs
                :: List.map (fun k -> if k = 15 then Printf.sprintf "LDM_PC(%d)" s
                              else Printf.sprintf (if user then "LDM_RU(%d)" else "LDM_R(%d)") k) regs in
    [ String.concat " " parts ^ " XFER_END;" ] @ (if List.mem 15 regs then [ after_pc_write c fn a ] else [])
  else
    let parts = Printf.sprintf "STM_BEGIN(%s)" start
                :: List.map (fun k -> Printf.sprintf "STM_V(%s)"
                                (if k = 15 then Printf.sprintf "(%s | PSR())" (pc c (a + 12))
                                 else if user then Printf.sprintf "user_reg(%d)" k else Printf.sprintf "R[%d]" k)) regs in
    [ String.concat " " parts ^ Printf.sprintf " %sXFER_END;" wbs ]

let body c fn a w =
  let t = (w lsr 25) land 7 in
  if t <= 1 && w land 0x0FC00090 = 0x90 then mul c a w            (* bits 6-5 any: Arm2.decode_kind *)
  else if t <= 1 && w land 0x0F8000F0 = 0x00800090 then mull c a w
  else if t <= 1 && w land 0x0FB00FF0 = 0x01000090 then [ Printf.sprintf "interp_exec(%s, %s);" (pc c a) (h w) ]  (* SWP *)
  else if t <= 1 then dataproc c fn a w
  else if t = 2 || t = 3 then
    if t = 3 && w land 0x10 <> 0 then [ Printf.sprintf "undefined_insn(%s, %s); LEAVE();" (h a) (h w) ]
    else ldrstr c fn a w
  else if t = 4 then ldmstm c fn a w
  else if t = 5 then begin
    let tgt = branch_target a w in
    if w land (1 lsl 24) <> 0 then
      (* r14 is always site + 4; only the expected return site differs *)
      [ Printf.sprintf "R[14] = %s | PSR();" (pc c (a + 4)); call_code c tgt (call_return_site c a w tgt) ]
    else if Hashtbl.mem c.calls a then [ call_code c tgt (a + 4) ]
    else [ jump_code c fn tgt ]
  end
  else if t = 7 && (w lsr 24) land 1 = 1 then begin
    let n = w land 0xFFFFFF in
    Printf.sprintf "SWI(%s, %s);" (h n) (pc c (a + 4))
    :: (match Hashtbl.find_opt c.fallthrough a with
        | Some b when n land lnot 0x20000 = 1 -> [ jump_code c fn b ]
        | _ -> [])
  end
  else [ Printf.sprintf "undefined_insn(%s, %s); LEAVE();" (h a) (h w) ]

let translate c fn a w =
  let cond = w lsr 28 in
  if cond = 15 then []                                  (* NV: never executes *)
  else
    let b = body c fn a w in
    if cond = 14 || b = [] then b
    else (Printf.sprintf "if (C_%s) {" conds.(cond) :: List.map (fun l -> "    " ^ l) b) @ [ "}" ]

let smc_switch c fn a w =
  c.nsmc <- c.nsmc + 1;
  let forms = w :: List.filter (( <> ) w) (Hashtbl.find c.smc a) in
  [ Printf.sprintf "switch (*(uint32_t *)(MEM + %s)) {" (pc c a) ]
  @ List.concat_map (fun v ->
      (Printf.sprintf "case %s:" (h v) :: List.map (fun l -> "    " ^ l) (translate c fn a v)) @ [ "    break;" ]) forms
  @ [ "default:   /* instruction form not seen during analysis */";
      Printf.sprintf "    if (interp_exec(%s, *(uint32_t *)(MEM + %s))) LEAVE();" (pc c a) (pc c a);
      "}" ]

let emit_function c buf fn =
  let addrs = Hashtbl.find c.funcs fn in
  let line s = Buffer.add_string buf s; Buffer.add_char buf '\n' in
  line (Printf.sprintf "void %s_%x(uint32_t e)" c.o.prefix fn);
  line "{";
  line "    switch (e) {";
  List.iter (fun x -> if is_leader c x then line (Printf.sprintf "    case %s: goto L_%x;" (h x) x)) addrs;
  line (Printf.sprintf "    default: bad_entry(%s, e); return;" (h fn));
  line "    }";
  let own = IS.of_list addrs in
  List.iter (fun x ->
      if is_leader c x then line (Printf.sprintf "L_%x:" x);
      let w = word c x in
      line (Printf.sprintf "    %s(%s);" (if c.o.no_smc && not (Hashtbl.mem c.smc_words x) then "I_" else "I") (h x));
      c.insns <- c.insns + 1;
      List.iter (fun l -> line ("    " ^ l))
        (if Hashtbl.mem c.smc x then smc_switch c fn x w else translate c fn x w);
      let nxt = natural_next c x w in
      if not (IS.mem nxt own) then line (Printf.sprintf "    JUMP(%s);" (pc c nxt))) addrs;
  line "}"

let write_file path s = let oc = open_out_bin path in output_string oc s; close_out oc

let rec mkdir_p d =
  if d <> "" && d <> "." && d <> "/" && not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    Sys.mkdir d 0o755
  end

(* Write the C for the image into outdir; returns a one-line summary. *)
let write c outdir =
  mkdir_p outdir;
  let o = c.o in
  let header = o.header ^ ".h" in
  let fns = List.sort compare (Hashtbl.fold (fun f _ acc -> f :: acc) c.funcs []) in
  let hdr = Buffer.create 65536 in
  Buffer.add_string hdr (Printf.sprintf "/* generated by %s */\n#include \"roger_cpu.h\"\n\n" o.banner);
  List.iter (fun f -> Buffer.add_string hdr (Printf.sprintf "void %s_%x(uint32_t);\n" o.prefix f)) fns;
  write_file (Filename.concat outdir header) (Buffer.contents hdr);
  let fa = Array.of_list fns in
  for i = 0 to o.files - 1 do
    let buf = Buffer.create (1 lsl 20) in
    Buffer.add_string buf (Printf.sprintf "/* generated by %s - do not edit */\n#include \"%s\"\n\n" o.banner header);
    let k = ref i in
    while !k < Array.length fa do
      emit_function c buf fa.(!k);
      Buffer.add_char buf '\n';
      k := !k + o.files
    done;
    write_file (Filename.concat outdir (Printf.sprintf "code%02d.c" i)) (Buffer.contents buf)
  done;
  (* entry table and code map *)
  let buf = Buffer.create (1 lsl 20) in
  let line s = Buffer.add_string buf s; Buffer.add_char buf '\n' in
  line (Printf.sprintf "/* generated by %s */" o.banner);
  line (Printf.sprintf "#include \"%s\"" header);
  line (Printf.sprintf "const struct roger_entry %s_entries[] = {" o.tabprefix);
  let ents = List.sort compare (Hashtbl.fold (fun a () acc -> a :: acc) c.leaders []) in
  List.iter (fun a -> line (Printf.sprintf "    {%s, %s_%x}," (h a) o.prefix (Hashtbl.find c.owner_of a))) ents;
  line "};";
  line (Printf.sprintf "const unsigned %s_nentries = %d;" o.tabprefix (List.length ents));
  let nwords = (c.eend - c.ebase) / 4 in
  let bits = Bytes.make ((nwords + 7) / 8) '\000' in
  Hashtbl.iter (fun a () ->
      if not (Hashtbl.mem c.smc a || Hashtbl.mem c.smc_words a) then begin
        let k = (a - c.ebase) / 4 in
        if k >= 0 && a < c.eend && k / 8 < Bytes.length bits then
          Bytes.set bits (k / 8) (Char.chr (Char.code (Bytes.get bits (k / 8)) lor (1 lsl (k mod 8))))
      end) c.inp.code;
  line (Printf.sprintf "const uint8_t %s_codemap[] = {" o.tabprefix);
  let n = Bytes.length bits in
  let i = ref 0 in
  while !i < n do
    let row = List.init (min 16 (n - !i)) (fun k -> string_of_int (Char.code (Bytes.get bits (!i + k)))) in
    line ("    " ^ String.concat ", " row ^ ",");
    i := !i + 16
  done;
  line "};";
  line (Printf.sprintf "const uint32_t %s_img_base = %s;" o.tabprefix (h c.ebase));
  line (Printf.sprintf "const uint32_t %s_img_end = %s;" o.tabprefix (h c.eend));
  line (Printf.sprintf "const struct roger_image %s_image = {%s, %s, %s_entries, %d, %s_codemap, %s};"
          o.tabprefix (h c.ebase) (h c.eend) o.tabprefix (List.length ents) o.tabprefix
          (if o.covtag = "" then "0" else Printf.sprintf "'%s'" o.covtag));
  write_file (Filename.concat outdir "entries.c") (Buffer.contents buf);
  Printf.sprintf "functions %d, instructions %d, entry points %d, SMC sites %d, Duff jumps %d, files %d"
    (List.length fns) c.insns (List.length ents) c.nsmc c.nduff o.files

(* ------------------------------------------------------------------ reading a saved analysis *)

let of_json (j : Json.t) =
  let ints k = List.map Json.to_int (Json.to_list (Json.member k j)) in
  let pairs k = List.map (fun p -> match Json.to_list p with
      | [ a; l ] -> (Json.to_int a, List.map Json.to_int (Json.to_list l))
      | _ -> failwith ("bad " ^ k)) (Json.to_list (Json.member k j)) in
  let code = Hashtbl.create 8192 in
  List.iter (fun a -> Hashtbl.replace code a ()) (ints "code");
  let owner = Hashtbl.create 8192 in
  List.iter (fun p -> match Json.to_list p with
      | [ a; f ] -> Hashtbl.replace owner (Json.to_int a) (Json.to_int f)
      | _ -> failwith "bad owner") (Json.to_list (Json.member "owner" j));
  let smc_values = pairs "smc_values" in
  { code; owner; funcs = ints "funcs"; entries = ints "entries"; linked = ints "linked"; follow = ints "follow";
    smc = List.map (fun (w, _) -> (w, Option.value (List.assoc_opt w smc_values) ~default:[])) (pairs "smc");
    returns = pairs "returns"; const_jumps = pairs "const_jumps" }
