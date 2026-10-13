(* S1: return-address and stack abstract interpretation (PLAN.md phase 3).

   Functions are the given entry points and every bl target. Each function
   is analysed on its own, from a symbolic entry state: every register holds
   "its value at entry" (r14 = LR0, r13 = SP0), the stack is empty, and a
   word of the caller's frame at SP0+n reads as "caller slot n".

   Within a function, b and constant-target PC writes are followed inline
   (code reached from several functions is analysed once per function).
   A PC write whose value is symbolic - LR0+k, caller slot n (+k), or some
   other entry register - is an exit. The function's summary is the list of
   its exits: the PC value and the register/SP state there, all relative to
   entry.

   At a bl, the caller substitutes its own state (lr = call site + 4) into
   the callee's summary: an exit "LR0+4" becomes a return to call site + 8,
   an exit through "caller slot 0" becomes whatever the caller pushed. No
   calling convention or idiom is assumed. Summaries start empty (no exits:
   the call does not return) and grow to a fixpoint; callers are re-analysed
   when a callee's summary changes.

   Two explicit assumptions, each counted in the output:
   - hand-linked calls: an unresolved indirect jump made with lr = this
     instruction + 4 (add lr,pc,#0 ; mov pc,r2) calls something that returns
     to lr, clobbering r0-r3, r12 and r14; likewise one made with a code
     address pushed on top of the stack (add r0,pc,#k ; push ; jump) returns
     there, popping it and clobbering every register but SP;
   - stack balance: where SP has become unknown (e.g. a loop popping a
     data-dependent number of words), a PC popped off the stack is the one
     saved return value in the function's frame, if there is exactly one;
     and a callee whose exit SP is unknown restores the caller's SP. *)

module IS = Set.Make (Int)
module IM = Map.Make (Int)

(* Symbolic bases, relative to the function's entry:
   Reg0 r       the value register r had at entry
   Slot0 n      the caller's stack word at SP0 + n
   Load0 (r, k) the word at address (entry value of r) + k, e.g. the literal
                after a call site, read through LR0 by a literal thunk *)
type base = Reg0 of int | Slot0 of int | Load0 of int * int

(* Values (phase 4 adds the last two):
   Range (lo, hi, step)  lo, lo+step, ..., hi (unsigned); an index that is
                         only known to be a multiple of step has hi = the
                         largest such 32-bit value ("unbounded")
   Tab t                 a word loaded from a table at t.tbase + i*t.stride
                         (or at each of t.more's bases) for an unknown (or
                         loosely bounded) i, plus t.tadd
   Idx (t, lo, hi, step) an address: a word from the small table t (at most
                         max_consts entries, each the base of another
                         table) plus lo, lo+step, ..., hi - a table of
                         tables (ldr rT,[rT,rI,lsl #2] ; ldr rT,[rT,rJ,lsl #2])
   Obj (t, k)            the word at offset t.tadd of each object a table of
                         object pointers points to (t's entries), plus k:
                         ldr r3,[r5,r7,lsl #2] ; ldr r4,[r3,#&14] ; mov pc,r4.
                         Only jumps make use of it. *)
type v = Top | Consts of IS.t | Sym of base * int | Range of int * int * int | Tab of tab
       | Idx of tab * int * int * int | Obj of tab * int
and tab = { tbase : int; more : int list; stride : int; tadd : int; limit : int option; tfield : int option }
(* limit: at most this many entries; tfield: plus the word at field offset k
   of some object (record_field's values) - a table of offsets from an
   address the program keeps in its workspace, e.g. where it was loaded *)

(* The mechanisms beyond the core analysis (summaries of returns and stack,
   constant jumps, OS_WriteS, the hand-linked call and stack balance
   assumptions). Each can be turned on separately; the core alone always
   finishes quickly. --full turns on all but global_r12 (what s1b did). *)
type features = {
  mutable tables : bool;          (* phase 4: bounded computed jumps, jump tables, tables of cases *)
  mutable memory : bool;          (* phase 5: values carried in variables, over repeated rounds *)
  mutable copies : bool;          (* phase 3c: code run from a copy made by a copy loop *)
  mutable fields : bool;          (* jumps through fields of objects (handler objects, menus) *)
  mutable inline : bool;          (* small dispatch stubs re-analysed inline at each call *)
  mutable longjmp : bool;         (* saved stack pointers restored elsewhere (setjmp/longjmp) *)
  mutable dispatch : bool;        (* multi-way dispatch with lr set: each target a function *)
  mutable global_r12 : bool;      (* r12 is a workspace pointer all through (see note_entry_consts) *)
  mutable clib : bool;            (* calls into the Shared C Library's entry vectors (see lib_call) *)
}

(* Code in other images (--extern FROM-TO): a program split over several
   files loaded side by side, calling each other at fixed addresses (an
   overlay, a main file and its loader). A call into one is assumed to
   return, with r0-r12 and lr unknown; a branch into one is a tail call.
   A range inside the image counts as another's too (an overlay loaded
   over part of it).
   Their targets are listed in the output (extern_calls), to be entry
   points of the image that holds them. *)
let externs : (int * int) list ref = ref []
let extern_targets : (int, unit) Hashtbl.t = Hashtbl.create 64
let in_extern a = List.exists (fun (lo, hi) -> a >= lo && a < hi) !externs

let features = { tables = false; memory = false; copies = false; fields = false; inline = false;
                 longjmp = false; dispatch = false; global_r12 = false; clib = false }

let feature_names = [ "tables"; "memory"; "copies"; "fields"; "inline"; "longjmp"; "dispatch"; "clib"; "global-r12" ]

let set_feature name on =
  match name with
  | "tables" -> features.tables <- on | "memory" -> features.memory <- on
  | "copies" -> features.copies <- on | "fields" -> features.fields <- on
  | "inline" -> features.inline <- on | "longjmp" -> features.longjmp <- on
  | "dispatch" -> features.dispatch <- on | "global-r12" -> features.global_r12 <- on
  | "clib" -> features.clib <- on
  | _ -> invalid_arg name

let set_full () = List.iter (fun n -> if n <> "global-r12" then set_feature n true) feature_names

let enabled_features () =
  List.filter (fun n -> match n with
      | "tables" -> features.tables | "memory" -> features.memory | "copies" -> features.copies
      | "fields" -> features.fields | "inline" -> features.inline | "longjmp" -> features.longjmp
      | "dispatch" -> features.dispatch | "clib" -> features.clib | _ -> features.global_r12) feature_names

(* A hard bound on the whole analysis: instructions stepped, over every
   function analysis, round and address-taken candidate. When it runs out
   the analysis stops where it is and the result is incomplete (code it
   didn't reach is interpreted at run time). *)
let budget = ref max_int
let steps_taken = ref 0
let exhausted () = !steps_taken >= !budget

let max_consts = 32
let max_enum = 1024                 (* largest range / table enumerated *)
let m32 = 0xFFFFFFFF
let addr_mask = 0x3FFFFFC

let const c = Consts (IS.singleton (c land m32))

let rec gcd a b = if b = 0 then abs a else gcd b (a mod b)

let mk_range lo hi step =
  let step = max 1 step in
  if lo < 0 || hi > m32 || lo > hi then Top
  else
    let hi = lo + (hi - lo) / step * step in
    if lo = hi then const lo else Range (lo, hi, step)

let range_count lo hi step = (hi - lo) / step + 1

let unbounded = function Range (lo, hi, step) -> range_count lo hi step > max_enum | _ -> false

(* All values of v, if there are at most limit of them. *)
let elements v limit =
  match v with
  | Consts s when IS.cardinal s <= limit -> Some (IS.elements s)
  | Range (lo, hi, step) when range_count lo hi step <= limit ->
    Some (List.init (range_count lo hi step) (fun k -> lo + k * step))
  | _ -> None

let to_range = function
  | Consts s when not (IS.is_empty s) ->
    let lo = IS.min_elt s and hi = IS.max_elt s in
    Some (lo, hi, IS.fold (fun c g -> gcd g (c - lo)) s 0)
  | Range (lo, hi, step) -> Some (lo, hi, step)
  | _ -> None

let join_v a b =
  match a, b with
  | Top, _ | _, Top -> Top
  | Consts x, Consts y ->
    let u = IS.union x y in
    if IS.cardinal u > max_consts then Top else Consts u
  | Sym (b1, k1), Sym (b2, k2) when b1 = b2 && k1 = k2 -> a
  | (Range _, (Range _ | Consts _)) | (Consts _, Range _) ->
    (match to_range a, to_range b with
     | Some (l1, h1, s1), Some (l2, h2, s2) ->
       mk_range (min l1 l2) (max h1 h2) (gcd (gcd s1 s2) (abs (l1 - l2)))
     | _ -> Top)
  | Tab x, Tab y when x = y -> a
  | _ -> Top

let add_k v k =
  match v with
  | Top -> Top
  | Consts s -> Consts (IS.map (fun c -> (c + k) land m32) s)
  | Sym (b, j) -> Sym (b, j + k)
  | Range (lo, hi, step) ->
    if lo + k < 0 then Top
    else if hi + k > m32 then mk_range (lo + k) m32 step       (* stays unbounded *)
    else mk_range (lo + k) (hi + k) step
  | Tab t -> Tab { t with tadd = t.tadd + k }
  | Idx (t, lo, hi, step) -> if lo + k < 0 then Top else Idx (t, lo + k, hi + k, step)
  | Obj (t, j) -> Obj (t, j + k)

(* Number of trailing zero bits of m (m > 0). *)
let trailing_zeros m = let rec go k = if m land (1 lsl k) <> 0 || k >= 32 then k else go (k + 1) in go 0

(* Largest value with the same number of bits as h: 2^k - 1 >= h. *)
let pow2mask h = let rec go m = if m >= h then m else go ((m lsl 1) lor 1) in go 0

let map_consts f = function
  | Consts s ->
    let s' = IS.map (fun c -> f c land m32) s in
    Consts s'
  | _ -> Top

let map2_consts f a b =
  match a, b with
  | Consts x, Consts y ->
    let r = IS.fold (fun c acc -> IS.fold (fun d acc -> IS.add (f c d land m32) acc) y acc) x IS.empty in
    (* a constant applied to a set (e.g. pc + each entry of a table) may
       stay as large as the set *)
    let cap = if IS.cardinal x = 1 || IS.cardinal y = 1 then max_enum else max_consts in
    if IS.cardinal r > cap then Top else Consts r
  | _ -> Top

let string_of_v = function
  | Top -> "T"
  | Consts s -> "{" ^ String.concat "," (List.map (Printf.sprintf "&%x") (IS.elements s)) ^ "}"
  | Sym (Reg0 14, k) -> Printf.sprintf "LR0%+d" k
  | Sym (Reg0 13, k) -> Printf.sprintf "SP0%+d" k
  | Sym (Reg0 r, k) -> Printf.sprintf "r%d_0%+d" r k
  | Sym (Slot0 n, k) -> Printf.sprintf "[SP0%+d]%+d" n k
  | Sym (Load0 (r, n), k) -> Printf.sprintf "[r%d_0%+d]%+d" r n k
  | Range (lo, hi, step) -> Printf.sprintf "[&%x..&%x/%d]" lo hi step
  | Tab t -> Printf.sprintf "tab(&%x%s+i*%d)%+d%s" t.tbase
               (String.concat "" (List.map (Printf.sprintf ",&%x") t.more)) t.stride t.tadd
               (match t.tfield with Some k -> Printf.sprintf "+field(&%x)" k | None -> "")
  | Idx (t, lo, hi, step) -> Printf.sprintf "[tab(&%x+i*%d)%+d]+[&%x..&%x/%d]" t.tbase t.stride t.tadd lo hi step
  | Obj (t, k) -> Printf.sprintf "[tab(&%x+i*%d)%+d]%+d" t.tbase t.stride t.tadd k

(* ------------------------------------------------------------------ state *)

(* stack: SP0-relative word offset -> value (the function's own frame and,
   for offsets >= 0, the caller's); amem: stores to absolute constant
   addresses (e.g. a stack whose pointer was set to a constant). Stores
   through unknown pointers are assumed not to alias either. *)
(* fk: what is known about the flags - -1 nothing, else 2*cond + 1 if that
   condition is known to hold, 2*cond if known not to. States at the same
   address with different flag knowledge are kept apart, so a conditional
   instruction followed by another on the same condition (stmnedb sp!,{pc} ;
   bne) doesn't mix its two paths. *)
(* cmp: the last comparison of a register with a constant (cmp rN,#imm)
   whose flags are still current, so that a condition known to hold on a
   path bounds rN there (cmp r11,#17 ; addlo pc,pc,r11,lsl #2). *)
(* fields: memory relative to a symbolic pointer other than SP - (b, k) is
   the word at b + k, where b is an entry register (e.g. the object r11
   points to) or a pointer loaded from entry-relative memory. Different
   bases are assumed not to alias (as for the stack). *)
module PM = Map.Make (struct type t = base * int let compare = compare end)

type state = { regs : v array; stack : v IM.t; amem : v IM.t; fields : v PM.t; fk : int; cmp : (int * int) option }

let field_default b k = match b with Reg0 r -> Sym (Load0 (r, k), 0) | _ -> Top

let entry_state ?consts () =
  let reg r = match consts with
    | Some (c : v array) when r < 13 && (match c.(r) with Consts _ -> true | _ -> false) -> c.(r)
    | _ -> Sym (Reg0 r, 0) in
  { regs = Array.init 16 reg; stack = IM.empty; amem = IM.empty; fields = PM.empty;
    fk = -1; cmp = None }

let read_field st b k =
  match PM.find_opt (b, k) st.fields with Some v -> v | None -> field_default b k

let cond_index (c : Arm2.cond) =
  match c with
  | EQ -> 0 | NE -> 1 | CS -> 2 | CC -> 3 | MI -> 4 | PL -> 5 | VS -> 6 | VC -> 7
  | HI -> 8 | LS -> 9 | GE -> 10 | LT -> 11 | GT -> 12 | LE -> 13 | AL -> 14 | NV -> 15

let fk_of c holds = 2 * cond_index c + if holds then 1 else 0

(* Is condition c known to hold / not hold under flag knowledge fk?
   Conditions come in complementary pairs (EQ/NE, CS/CC, ... GT/LE). *)
let known fk c =
  if fk < 0 then None
  else
    let kc = fk / 2 and holds = fk land 1 = 1 and q = cond_index c in
    if q = kc then Some holds else if q = kc lxor 1 then Some (not holds) else None

let read_slot st off =
  match IM.find_opt off st.stack with
  | Some v -> v
  | None -> if off >= 0 then Sym (Slot0 off, 0) else Top

let join_state a b =
  let regs = Array.init 16 (fun r -> join_v a.regs.(r) b.regs.(r)) in
  let stack = IM.merge (fun off x y ->
      let x = match x with Some v -> v | None -> if off >= 0 then Sym (Slot0 off, 0) else Top in
      let y = match y with Some v -> v | None -> if off >= 0 then Sym (Slot0 off, 0) else Top in
      match join_v x y with Top -> None | v -> if v = Sym (Slot0 off, 0) then None else Some v)
      a.stack b.stack in
  let amem = IM.merge (fun _ x y ->
      match x, y with
      | Some x, Some y -> Some (join_v x y)
      | _ -> Some Top) a.amem b.amem in
  let fields = PM.merge (fun (b, k) x y ->
      let get = function Some v -> v | None -> field_default b k in
      match join_v (get x) (get y) with
      | v when v = field_default b k -> None
      | v -> Some v) a.fields b.fields in
  { regs; stack; amem; fields; fk = (if a.fk = b.fk then a.fk else -1); cmp = (if a.cmp = b.cmp then a.cmp else None) }

(* Widening: any value that changed goes to Top. *)
(* A register that keeps changing goes to Top, except a pointer stepping
   through the image (a loop walking records: ldr r8,[r7,#16]!): constants
   or ranges in the image in arithmetic progression widen to a range with
   that step, extended to the image's end in the direction it grows. *)
let widen_v (img : Image.t) old j =
  if old = j then old
  else match to_range old, to_range j with
    | Some (l1, h1, s1), Some (l2, h2, s2) ->
      let step = gcd (gcd s1 s2) (abs (l1 - l2)) in
      if step = 0 || not (Image.in_range img l1 && Image.in_range img h1) then Top
      else
        (* anchored on the old values; one more step may already have
           gone past the image's end, which the widened range stops at *)
        let first = img.base and last = img.base + img.size - 1 in
        let lo = if l2 < l1 then l1 - (l1 - first) / step * step else l1 in
        let hi = if h2 > h1 then h1 + (last - h1) / step * step else h1 in
        mk_range lo hi step
    | _ -> Top

let widen_state img old j =
  let w a b = if a = b then a else widen_v img a b in
  { regs = Array.init 16 (fun r -> w old.regs.(r) j.regs.(r));
    stack = IM.filter_map (fun off v ->
        match IM.find_opt off old.stack with
        | Some o when o = v -> Some v
        | _ -> None) j.stack;
    amem = IM.mapi (fun a v -> match IM.find_opt a old.amem with Some o when o = v -> v | _ -> Top) j.amem;
    (* a field the old state didn't have is dropped, not made Top: the keys
       stay bounded by the old ones (a cycle of functions storing a block
       through r8 that steps 32 bytes on each pass: Zool's &26148) *)
    fields = PM.filter_map (fun key v -> match PM.find_opt key old.fields with
        | Some o when o = v -> Some v | Some _ -> Some Top | None -> None) j.fields;
    fk = j.fk; cmp = j.cmp }

let widen_after = 4

let equal_state a b =
  a.fk = b.fk && a.cmp = b.cmp && a.regs = b.regs && IM.equal ( = ) a.stack b.stack && IM.equal ( = ) a.amem b.amem
  && PM.equal ( = ) a.fields b.fields

(* ------------------------------------------------------------------ summaries *)

type exit_ = { pc : v; st : state; at : int }        (* at: address of the exiting instruction *)

type summary = exit_ list                           (* joined per pc value and flag knowledge *)

(* Exits are joined per target and flag knowledge: the paths of a
   conditional default (teq r0,#0 ; addeq r0,pc,#k ; mov pc,lr) return
   different values, which a join would lose. *)
let add_exit (s : summary) e =
  match List.partition (fun x -> x.pc = e.pc && x.st.fk = e.st.fk) s with
  | [ x ], rest -> { x with st = join_state x.st e.st } :: rest
  | _, rest -> e :: rest

let equal_summary (a : summary) (b : summary) =
  List.length a = List.length b
  && List.for_all (fun x -> List.exists (fun y -> y.pc = x.pc && equal_state x.st y.st) b) a

let shape_of_exit e =
  match e.pc with
  | Sym (Reg0 14, k) -> if k = 0 then "LR" else Printf.sprintf "LR%+d" k
  | Sym (Slot0 n, k) -> Printf.sprintf "caller-slot%+d%s" n (if k = 0 then "" else Printf.sprintf "%+d" k)
  | Sym (Reg0 r, k) -> Printf.sprintf "r%d%+d" r k
  | v -> string_of_v v

(* Widening a summary that keeps changing: an exit whose target the old
   summary didn't have becomes an exit to an unknown target (callers count
   it unresolved), and exit states are widened against the old ones. The
   set of targets is then bounded by the old one, and states can only climb
   a finite way. *)
let summary_widen_after = ref 8

let widen_summary img (old : summary) (s : summary) =
  let s = List.fold_left (fun acc e ->
      if List.exists (fun x -> x.pc = e.pc && x.st.fk = e.st.fk) old then add_exit acc e
      else add_exit acc { e with pc = Top; st = { e.st with fk = -1 } }) [] s in
  List.map (fun e ->
      match List.find_opt (fun x -> x.pc = e.pc && x.st.fk = e.st.fk) old with
      | Some o -> { e with st = widen_state img o.st (join_state o.st e.st) }
      | None -> e) s

(* ------------------------------------------------------------------ analysis *)

type t = {
  img : Image.t;
  vars : (int, unit) Hashtbl.t;                     (* words written by pc-relative stores *)
  summaries : (int, summary) Hashtbl.t;
  callers : (int, (int, unit) Hashtbl.t) Hashtbl.t; (* callee -> caller functions *)
  code : (int, unit) Hashtbl.t;
  data : (int, string) Hashtbl.t;
  ret_sites : (int, IS.t) Hashtbl.t;                (* call site -> resolved return targets *)
  assumed : (int, unit) Hashtbl.t;                  (* unresolved jumps assumed to return to lr *)
  balanced : (int, unit) Hashtbl.t;                 (* stack-balance assumptions *)
  promoted : (int, unit) Hashtbl.t;                 (* jump targets made functions *)
  cands : (int, (int * string) list) Hashtbl.t;     (* address-taken code candidates -> evidence *)
  unresolved : (int, string) Hashtbl.t;
  const_jumps : (int, IS.t) Hashtbl.t;              (* non-bl PC writes with constant targets *)
  problems : (int, string) Hashtbl.t;
  funcs : (int, unit) Hashtbl.t;
  fresh : int Stack.t;                              (* newly found functions: analysed first *)
  analysed : (int, unit) Hashtbl.t;
  in_progress : (int, unit) Hashtbl.t;
  work : int Queue.t;                               (* callers whose callees' summaries changed *)
  queued : (int, unit) Hashtbl.t;
  mutable copies : copy list;                       (* recognised copy loops (phase 3c) *)
  tables : (int, string * int) Hashtbl.t;           (* jump site -> how bounded, number of targets *)
  var_known : (int, v) Hashtbl.t;                   (* variable -> values from the previous round (phase 5) *)
  var_stores : (int, v) Hashtbl.t;                  (* variable -> join of values stored this round *)
  var_loads : (int, int) Hashtbl.t;                 (* load site -> variable it read *)
  code_writes : (int, int list) Hashtbl.t;          (* image word stored to -> store sites *)
  data_reads : (int, int list) Hashtbl.t;           (* words read as data through constant addresses -> sites *)
  mutable cur_site : int;                           (* instruction being analysed *)
  follow : (int, unit) Hashtbl.t;                   (* computed jumps assumed into following code *)
  owner : (int, int) Hashtbl.t;                     (* code word -> first function analysis reaching it *)
  linked : (int, unit) Hashtbl.t;                   (* indirect PC writes made with lr = site + 4 (calls) *)
  fn_unresolved : (int, unit) Hashtbl.t;            (* functions with an unresolved jump of their own *)
  fn_size : (int, int) Hashtbl.t;                   (* instructions a function's own analysis visits *)
  inlined : (int, unit) Hashtbl.t;                  (* call sites analysed by inlining the callee *)
  field_vals : (int, IS.t) Hashtbl.t;               (* field offset -> image addresses stored there *)
  field_users : (int, (int, unit) Hashtbl.t) Hashtbl.t;   (* field offset -> functions jumping through it *)
  sym_stores : (int, (int * v) list) Hashtbl.t;    (* function -> (variable, value relative to its entry) *)
  pc_slots : (int, unit) Hashtbl.t;                 (* words tracked in amem because stored PC-relative *)
  entry_consts : (int, v array) Hashtbl.t;          (* function -> r0-r12 at every call site: a constant, or Top *)
  roots : (int, unit) Hashtbl.t;                    (* entry points: called from outside the image *)
  sp_restores : (int, int list) Hashtbl.t;          (* saved-SP variable -> ldr sp,[pc,#k] sites reading it *)
  changes : (int, int) Hashtbl.t;                   (* function -> times its summary changed *)
  previous : (int, summary) Hashtbl.t;              (* function -> its summary before the current one *)
  widened : (int, unit) Hashtbl.t;                  (* functions whose summary was widened *)
  libvec : (int, int * int) Hashtbl.t;              (* C library vector word -> (chunk, entry) *)
  lang_inits : (int, unit) Hashtbl.t;               (* C library language Init routines *)
}

(* A copy loop: len bytes from src (inside the image) to dst, found at the
   loop's closing branch. Code that jumps into the destination runs the
   copy of the image there. src < 0: a slot - a copy into the image from a
   source the analysis doesn't know (Starch copies the current level's
   header, branches included, from one of five blocks into one place): what
   the slot holds is only known at run time. *)
and copy = { src : int; dst : int; len : int; loop_at : int }

(* Saved stack pointers (setjmp/longjmp): str sp,[pc,#k] saves SP in a
   variable; ldr sp,[pc,#k'] elsewhere, from the same variable, goes back
   to that frame (and pops a return off it). Variable -> restore sites, for
   variables some code saves SP in. *)
let scan_sp_restores img =
  let pcrel a (i : Arm2.t) ~load =
    match i.kind with
    | Arm2.Mem { load = l; byte = false; rd = 13; rn = 15; pre = true; up; off = Arm2.Off_imm n; _ }
      when l = load && Arm2.plausible i && i.cond <> Arm2.NV ->
      Some ((a + 8 + if up then n else -n) land lnot 3)
    | _ -> None in
  let saved = Hashtbl.create 8 and restores = Hashtbl.create 8 in
  let each f = let a = ref img.Image.base in
    while Image.inside img !a do f !a (Image.decode img !a); a := !a + 4 done in
  each (fun a i -> match pcrel a i ~load:false with Some w -> Hashtbl.replace saved w () | None -> ());
  each (fun a i -> match pcrel a i ~load:true with
      | Some w when Hashtbl.mem saved w ->
        Hashtbl.replace restores w (a :: Option.value (Hashtbl.find_opt restores w) ~default:[])
      | _ -> ());
  restores

let scan_vars img =
  let vars = Hashtbl.create 64 in
  let a = ref img.Image.base in
  while Image.inside img !a do
    let i = Image.decode img !a in
    (match i.kind with
     | Arm2.Mem { load = false; rn = 15; pre = true; up; off = Arm2.Off_imm n; _ }
       when Arm2.plausible i && i.cond <> Arm2.NV ->
       let x = (!a + 8 + if up then n else -n) land lnot 3 in
       if Image.inside img x then Hashtbl.replace vars x ()
     | _ -> ());
    a := !a + 4
  done;
  vars

(* The C library vector, once found: kept for the analyses that follow
   (repeated rounds, address-taken candidates analysed on their own) *)
let known_libvec : (int, int * int) Hashtbl.t = Hashtbl.create 256

let create ?(copies = []) ?(var_known = Hashtbl.create 1) img = {
  copies; var_known; var_stores = Hashtbl.create 64; var_loads = Hashtbl.create 64;
  code_writes = Hashtbl.create 64; pc_slots = Hashtbl.create 64; data_reads = Hashtbl.create 1024; cur_site = 0; tables = Hashtbl.create 64; follow = Hashtbl.create 64;
  owner = Hashtbl.create 8192; linked = Hashtbl.create 64;
  entry_consts = Hashtbl.create 256; roots = Hashtbl.create 16; sp_restores = scan_sp_restores img;
  fn_unresolved = Hashtbl.create 16; inlined = Hashtbl.create 16; fn_size = Hashtbl.create 256;
  img; vars = scan_vars img; summaries = Hashtbl.create 256; callers = Hashtbl.create 256;
  code = Hashtbl.create 8192; data = Hashtbl.create 1024; ret_sites = Hashtbl.create 1024;
  assumed = Hashtbl.create 64; balanced = Hashtbl.create 64; promoted = Hashtbl.create 64; cands = Hashtbl.create 64; unresolved = Hashtbl.create 64; const_jumps = Hashtbl.create 64;
  problems = Hashtbl.create 64; funcs = Hashtbl.create 256; fresh = Stack.create (); work = Queue.create ();
  analysed = Hashtbl.create 256; in_progress = Hashtbl.create 64;
  queued = Hashtbl.create 256; field_vals = Hashtbl.create 16; field_users = Hashtbl.create 16;
  sym_stores = Hashtbl.create 16; changes = Hashtbl.create 256; previous = Hashtbl.create 256; widened = Hashtbl.create 16;
  libvec = Hashtbl.copy known_libvec; lang_inits = Hashtbl.create 4;
}

(* An address in the destination of a copy loop (and not in the image)
   maps back to the image word it was copied from. *)
let unreloc t a =
  if Image.inside t.img a then None
  else
    List.find_map (fun c ->
        if c.src >= 0 && a >= c.dst && a < c.dst + c.len && Image.inside t.img (a - c.dst + c.src)
        then Some (a - c.dst + c.src) else None) t.copies

let map_addr t a = Option.value (unreloc t a) ~default:a

(* An address in a slot (a copy loop's in-image destination, filled from
   somewhere unknown): its words are whatever was copied there last. *)
let in_slot t a = List.exists (fun c -> c.src < 0 && a >= c.dst && a < c.dst + c.len) t.copies

(* A constant that may be a code address, used as evidence (site, how). *)
let note_candidates t v site how =
  match v with
  | Consts s ->
    IS.iter (fun c ->
        let c = map_addr t c in
        if c land 3 = 0 && Image.inside t.img c then begin
          let l = Option.value (Hashtbl.find_opt t.cands c) ~default:[] in
          if not (List.mem (site, how) l) then Hashtbl.replace t.cands c ((site, how) :: l)
        end) s
  | _ -> ()

let enqueue t f =
  if not (Hashtbl.mem t.queued f) then begin
    Hashtbl.replace t.queued f ();
    Queue.push f t.work
  end

(* Field-offset points-to (base-insensitive): image addresses stored to a
   field at offset k of any object (str rX,[rB,#k], rB not SP, or a callee's
   field write substituted at a call site). A jump whose target is loaded
   from offset k of an unknown object (see field_jump) may go to any of
   them; functions that used field k are re-analysed when it grows. *)
let record_field t k v =
  if features.fields then
  match v with
  | Consts s when k >= 0 && k < 0x1000 ->
    let s = IS.filter (fun c -> c land 3 = 0 && Image.inside t.img c) s in
    let old = Option.value (Hashtbl.find_opt t.field_vals k) ~default:IS.empty in
    let nw = IS.union old s in
    if not (IS.equal nw old) then begin
      if Sys.getenv_opt "SS_TRACE" <> None then
        Printf.eprintf "field +&%x grows to %d values (%s)\n%!" k (IS.cardinal nw)
          (String.concat " " (List.map (Printf.sprintf "&%x") (IS.elements (IS.diff nw old))));
      Hashtbl.replace t.field_vals k nw;
      match Hashtbl.find_opt t.field_users k with
      | Some us -> Hashtbl.iter (fun f () -> enqueue t f) us
      | None -> ()
    end
  | _ -> ()

let add_func t f =
  if not (Hashtbl.mem t.funcs f) then begin
    Hashtbl.replace t.funcs f ();
    Hashtbl.replace t.summaries f [];
    Hashtbl.replace t.callers f (Hashtbl.create 4);
    Hashtbl.replace t.queued f ();
    Stack.push f t.fresh
  end

let add_set tbl k s =
  Hashtbl.replace tbl k (IS.union s (Option.value (Hashtbl.find_opt tbl k) ~default:IS.empty))

(* The Shared C Library (features.clib). A program linked with its stubs
   calls SharedCLibrary_LibInitAPCS_A/R (SWI &80680/&80681) with r0
   pointing to a list of chunk descriptors {id, vector start, vector end,
   static data start, static data end}, ending with -1; the library fills
   each vector - a word per library function, in the library's order - with
   branches into itself. Those words are recorded here: a bl to one calls
   the library (APCS: it returns, r0-r3, ip, lr and the flags changed), and
   a b to the kernel's first entry, _kernel_init, with r0 a kernel init
   block {image base, language descriptions, their end}, starts the
   program: each language description's Init routine (at +16) is called,
   and the code address it returns (the main program) run. Arguments that
   are code addresses by the library's interface - the C library's _main's
   main (entry 18, r1), atexit's (71, r0), qsort's comparison (76, r3),
   signal's handler (128, r1) - are functions too. *)
let note_libinit t st =
  match st.regs.(0) with
  | Consts s when IS.cardinal s = 1 ->
    let rec chunk d =
      if Image.inside t.img (d + 16) && Image.word t.img d <> 0xFFFFFFFF then begin
        let id = Image.word t.img d and vs = Image.word t.img (d + 4) and ve = Image.word t.img (d + 8) in
        if id >= 1 && id <= 2 && vs < ve && ve - vs < 0x1000 && Image.inside t.img vs then begin
          let rec mark w k = if w < ve then begin
              Hashtbl.replace t.libvec w (id, k);
              Hashtbl.replace known_libvec w (id, k);
              if not (Hashtbl.mem t.code w) then Hashtbl.replace t.data w "C library vector";
              mark (w + 4) (k + 1) end in
          mark vs 0
        end;
        for k = 0 to 4 do Hashtbl.replace t.data (d + 4 * k) "C library chunk list" done;
        chunk (d + 20)
      end in
    chunk (IS.choose s)
  | _ -> ()

let lib_callbacks = [ (2, 18), 1; (2, 71), 0; (2, 76), 3; (2, 128), 1 ]

(* Barrel shifter on known values (immediate amounts; rrx needs the carry). *)
let shift_const sh n c =
  let open Arm2 in
  match sh, n with
  | LSL, 0 -> Some c
  | LSL, n -> Some ((c lsl n) land m32)
  | LSR, 0 -> Some 0
  | LSR, n -> Some (c lsr n)
  | ASR, n ->
    let n = if n = 0 then 32 else n in
    let s = if c land 0x80000000 <> 0 then c - 0x100000000 else c in
    Some ((s asr (min n 31)) land m32)
  | ROR, 0 -> None
  | ROR, n -> Some (Arm2.ror32 c n)

(* Value of a register as an operand of the instruction at a. *)
let reg_val st a r = if r = 15 then const (a + 8) else st.regs.(r)

let shift_v sh n v =
  match v, sh with
  | Consts s, _ ->
    let r = IS.fold (fun c acc -> match acc, shift_const sh n c with
        | Some acc, Some x -> Some (IS.add x acc) | _ -> None) s (Some IS.empty) in
    (match r with Some s -> Consts s | None -> Top)
  | Range (lo, hi, step), Arm2.LSL when n > 0 ->
    if hi lsl n > m32 then mk_range (lo lsl n) (m32 land lnot ((step lsl n) - 1)) (step lsl n)
    else mk_range (lo lsl n) (hi lsl n) (step lsl n)
  | Range (lo, hi, step), Arm2.LSR when n > 0 ->
    mk_range (lo lsr n) (hi lsr n) (if step land ((1 lsl n) - 1) = 0 then step lsr n else 1)
  | (Top | Sym _), Arm2.LSL when n > 0 ->
    (* an unknown value shifted left (a symbolic one, e.g. an index read
       from a field of the workspace, is just as unknown): some multiple
       of 2^n *)
    mk_range 0 (m32 land lnot ((1 lsl n) - 1)) (1 lsl n)
  | _ -> Top

let op2_val st (i : Arm2.t) = function
  | Arm2.Imm (v, _) -> const v
  | Arm2.Reg (Arm2.Shift_imm (rm, Arm2.LSL, 0)) -> reg_val st i.addr rm
  | Arm2.Reg (Arm2.Shift_imm (rm, sh, n)) -> shift_v sh n (reg_val st i.addr rm)
  | Arm2.Reg (Arm2.Shift_reg _) -> Top

let single = function Consts s when IS.cardinal s = 1 -> Some (IS.choose s) | _ -> None

let add_v a b =
  match a, b, single a, single b with
  | Sym (x, k), _, _, Some c | _, Sym (x, k), Some c, _ -> Sym (x, k + c)
  | (Range _ | Tab _ | Idx _ | Obj _), _, _, Some c -> add_k a c
  | Tab tb, Sym (Load0 (r, k), c), _, _ | Sym (Load0 (r, k), c), Tab tb, _, _
    when features.fields && tb.tfield = None && r < 13 ->
    (* a table entry plus a field: ldr r0,[r5,r0] ; ldr r1,[r11,#k] ; add r0,r0,r1 *)
    Tab { tb with tfield = Some k; tadd = tb.tadd + c }
  | _, (Range _ | Tab _ | Idx _ | Obj _), Some c, _ -> add_k b c
  | Range (l1, h1, s1), Range (l2, h2, s2), _, _ ->
    if h1 + h2 > m32 then Top else mk_range (l1 + l2) (h1 + h2) (gcd s1 s2)
  | Tab tb, Range (lo, hi, step), _, _ | Range (lo, hi, step), Tab tb, _, _
    when features.tables && tb.more = [] && tb.tfield = None && (match tb.limit with Some n -> n <= max_consts | None -> false) ->
    Idx (tb, lo, hi, step)
  | va, vb, _, _ -> map2_consts ( + ) va vb

let sub_v a b =
  match a, b with
  | Sym (x, k), c when single c <> None -> Sym (x, k - Option.get (single c))
  | (Range (lo, _, _) as r), c when single c <> None && lo >= Option.get (single c) ->
    add_k r (- Option.get (single c))
  | va, vb -> map2_consts ( - ) va vb

(* Masks that only touch the 26-bit PSR bits leave a code address intact. *)
let psr_only m = m land addr_mask = 0

let eval_dp st (i : Arm2.t) op rn op2 =
  let open Arm2 in
  let b = op2_val st i op2 in
  let a () = reg_val st i.addr rn in
  match op with
  | MOV -> b
  | MVN -> map_consts (fun c -> lnot c) b
  | ADD -> add_v (a ()) b
  | SUB -> (match a (), single b, i.kind with
      | Range (lo, hi, step), Some c, Dp { s = true; _ } when lo < c && c <= hi ->
        (* subs of a range reaching below the constant: the part that
           doesn't borrow (the code tests the flags next: subs r7,r7,#n ;
           addge pc,pc,r7,lsr #k) *)
        let l = lo + (c - lo + step - 1) / step * step in
        if l > hi then Top else mk_range (l - c) (hi - c) step
      | va, _, _ -> sub_v va b)
  | RSB -> (match a (), single b with
      | Range (lo, hi, step), Some c when c >= hi -> mk_range (c - hi) (c - lo) step
      | va, _ -> map2_consts (fun x y -> y - x) va b)
  | AND -> (match a (), b with
      | (Sym _ as v), Consts s when IS.cardinal s = 1 && IS.choose s land addr_mask = addr_mask -> v
      | (Consts _ as va), vb -> map2_consts ( land ) va vb
      | va, Consts s when IS.cardinal s = 1
                          && (IS.choose s < 0x100000
                              || IS.choose s lsr trailing_zeros (IS.choose s) < max_enum) ->
        (* masking bounds the result (a field higher up, and #&FF0000, too:
           few multiples of its lowest bit) *)
        let m = IS.choose s in
        let hi = match va with Range (_, h, _) -> min m (pow2mask h) | _ -> m in
        (* low bits the mask clears are zero: the result steps by 2^tz *)
        mk_range 0 hi (if m = 0 then 1 else 1 lsl trailing_zeros m)
      | va, vb -> map2_consts ( land ) va vb)
  | ORR -> (match a (), b with
      | ((Sym _ | Tab _) as v), Consts s when IS.cardinal s = 1 && psr_only (IS.choose s) -> v
      | va, vb -> map2_consts ( lor ) va vb)
  | EOR -> map2_consts ( lxor ) (a ()) b
  | BIC -> (match a (), b with
      | ((Sym _ | Tab _) as v), Consts s when IS.cardinal s = 1 && psr_only (IS.choose s) -> v
      | Range (_, h, _), Consts s when IS.cardinal s = 1 ->
        let m = IS.choose s in
        mk_range 0 (pow2mask h land lnot m) (1 lsl trailing_zeros (lnot m land m32))
      | va, vb -> map2_consts (fun x y -> x land lnot y) va vb)
  | ADC | SBC | RSC | TST | TEQ | CMP | CMN -> Top

(* A word of the image at address a. A run-time variable (some store writes
   it) reads as the values stored to it in the previous round (phase 5),
   or Top if none are known yet. *)
let image_word ?(record = true) t a ~byte =
  let a = map_addr t a in
  let w = a land lnot 3 in
  if not (Image.inside t.img w) then Top
  else begin
    if record then begin
      let l = Option.value (Hashtbl.find_opt t.data_reads w) ~default:[] in
      if not (List.mem t.cur_site l) then Hashtbl.replace t.data_reads w (t.cur_site :: l)
    end;
    match Hashtbl.find_opt t.var_known w with
    | Some v -> if byte then Top else v
    | None ->
      if Hashtbl.mem t.vars w then Top
      else begin
        if record && not (Hashtbl.mem t.code w) then Hashtbl.replace t.data w "literal";
        if byte then const (Image.byte t.img a) else const (Image.word t.img w)
      end
  end

(* The initial image value of variable w, if it was written at run time
   (only stored values are its known values, see next_var_known) and looks
   like a code address: used only where the variable is a jump target, e.g.
   a dispatch table that start-up code may overwrite with other routines. *)
let initial_target t w =
  let w = w land lnot 3 in
  if not (Image.inside t.img w) || not (Hashtbl.mem t.var_known w) then []
  else
    let c = Image.word t.img w land addr_mask in
    if c land 3 = 0 && Image.inside t.img c && Image.word t.img c >= 0x10000
       && (let i = Image.decode t.img c in Arm2.plausible i && i.cond <> Arm2.NV)
    then [ c ] else []

(* A store of v to address value av (not through SP), in function f: a
   constant address in the image is a variable (and, if it holds code,
   self-modification). A value relative to f's entry (a setter storing its
   argument: str r0,[pc,#k]) is kept with f, and each call site stores
   that value substituted with its own state (see apply_summary). *)
let max_sym_values = 8

let note_store t ~f site av v ~byte =
  match av with
  | Consts s when IS.cardinal s = 1 && not byte && features.memory
                  && (match v with Sym (b, _) -> b <> Reg0 13 | _ -> false)
                  && Image.inside t.img (IS.choose s land lnot 3) ->
    let w = IS.choose s land lnot 3 in
    Hashtbl.replace t.code_writes w (site :: Option.value (Hashtbl.find_opt t.code_writes w) ~default:[]);
    let l = Option.value (Hashtbl.find_opt t.sym_stores f) ~default:[] in
    (* at most max_sym_values per variable, then it stores something
       unknown (Top): values substituted from a recursion through the
       caller's frame ([SP0+n] for ever larger n) would grow without end *)
    let mine = List.filter (fun (w', _) -> w' = w) l in
    if List.mem (w, Top) l || List.mem (w, v) l then ()
    else if List.length mine >= max_sym_values then
      Hashtbl.replace t.sym_stores f ((w, Top) :: List.filter (fun (w', _) -> w' <> w) l)
    else Hashtbl.replace t.sym_stores f ((w, v) :: l)
  | Consts s when IS.cardinal s = 1 ->
    (* not mapped back through copies: a store into a copy changes the
       copy, not the image (the copy loop itself writes all of it) *)
    let w = IS.choose s land lnot 3 in
    if Image.inside t.img w then begin
      Hashtbl.replace t.code_writes w (site :: Option.value (Hashtbl.find_opt t.code_writes w) ~default:[]);
      let v = if byte then Top else v in
      Hashtbl.replace t.var_stores w
        (match Hashtbl.find_opt t.var_stores w with Some old -> join_v old v | None -> v)
    end
  | Range (lo, hi, step) when range_count lo hi step <= max_consts ->
    (* a small table written with a bounded index: a weak update of each
       entry (it may receive v) *)
    List.iter (fun k ->
        let w = (lo + k * step) land lnot 3 in
        if Image.inside t.img w then
          Hashtbl.replace t.var_stores w
            (match Hashtbl.find_opt t.var_stores w with
             | Some old -> join_v old (if byte then Top else v)
             | None -> if byte then Top else join_v v (const (Image.word t.img w))))
      (List.init (range_count lo hi step) Fun.id)
  | _ -> ()

(* A word loaded from address value av. A range of addresses inside the
   image (a table with a bounded index) reads every entry, which become
   data; an unbounded one gives a symbolic table value. *)
let load_word t st av ~byte =
  match av with
  | Sym (Reg0 13, k) when not byte -> read_slot st k
  | Sym (b, k) when not byte && b <> Reg0 13 -> read_field st b k
  | Consts s when IS.cardinal s = 1 ->
    let a = IS.choose s in
    (match IM.find_opt (a land lnot 3) st.amem with
     | Some v -> if byte then Top else v
     | None -> image_word t a ~byte)
  | Consts s when IS.cardinal s <= max_consts ->
    (* a few possible addresses: any of their values (an approximation, so
       not taken as evidence that these words are data) *)
    IS.fold (fun a acc ->
        let v = match IM.find_opt (a land lnot 3) st.amem with
          | Some v -> if byte then Top else v
          | None -> image_word ~record:false t a ~byte in
        match acc with None -> Some v | Some x -> Some (join_v x v)) s None
    |> Option.value ~default:Top
  | Range _ when not features.tables -> if byte then Range (0, 255, 1) else Top
  | Range (lo, hi, step) when byte && range_count lo hi step <= max_consts ->
    let addrs = List.init (range_count lo hi step) (fun k -> map_addr t (lo + k * step)) in
    if List.for_all (fun a -> Image.inside t.img (a land lnot 3) && not (Hashtbl.mem t.vars (a land lnot 3))) addrs
    then begin
      let vals = List.map (fun a ->
          let w = a land lnot 3 in
          if not (Hashtbl.mem t.code w) then Hashtbl.replace t.data w "table";
          if byte then Image.byte t.img a else Image.word t.img w) addrs in
      Consts (IS.of_list vals)
    end else if byte then Range (0, 255, 1) else Top
  | Range (lo, hi, step) when not byte && Image.inside t.img lo ->
    (* a loose bound (e.g. a byte index): only a limit for the content scan *)
    Tab { tbase = lo; more = []; stride = step; tadd = 0; tfield = None;
          limit = if unbounded av then None else Some (range_count lo hi step) }
  | Idx (tb, lo, hi, step) when not byte && features.tables ->
    (* the entries of the first table are the bases of the second *)
    let n = Option.value tb.limit ~default:0 in
    let bases = List.filter_map (fun k ->
        let e = map_addr t (tb.tbase + k * tb.stride) in
        if not (Image.inside t.img e) || Hashtbl.mem t.vars e then None
        else begin
          if not (Hashtbl.mem t.code e) then Hashtbl.replace t.data e "table";
          let b = (Image.word t.img e + tb.tadd + lo) land m32 in
          if Image.inside t.img b then Some b else None
        end) (List.init n Fun.id) in
    (match List.sort_uniq compare bases with
     | [] -> Top
     | b :: more ->
       let cnt = range_count 0 (hi - lo) step in
       Tab { tbase = b; more; stride = step; tadd = 0; tfield = None; limit = if cnt > max_enum then None else Some cnt })
  | Tab tb when not byte && features.tables && tb.tfield = None -> Obj (tb, 0)
  | _ -> if byte then Range (0, 255, 1) else Top

(* Absolute-address memory is tracked for stack traffic (base register
   SP), i.e. a stack whose pointer is a known constant, and (with the
   memory mechanism) for words addressed PC-relative: a routine that keeps
   its return address in a word of its own (str lr,[pc,#k] ... ldr lr,
   [pc,#j] ; mov pc,lr: Chocks Away) returns through it. Not for the
   program's other global variables; but a tracked word stored to again
   through another register is updated (one constant address) or forgotten
   (several). *)
let store t st ~base_reg av v =
  match av with
  | Sym (Reg0 13, k) -> { st with stack = IM.add k v st.stack }
  | Sym (b, k) -> { st with fields = PM.add (b, k) v st.fields }
  | Consts s when IS.cardinal s = 1
                  && (base_reg = 13 || (base_reg = 15 && features.memory)
                      || IM.mem (IS.choose s land lnot 3) st.amem) ->
    if base_reg = 15 then Hashtbl.replace t.pc_slots (IS.choose s land lnot 3) ();
    { st with amem = IM.add (IS.choose s land lnot 3) v st.amem }
  | Consts s when not (IM.is_empty st.amem) ->
    { st with amem = IS.fold (fun a m -> if IM.mem (a land lnot 3) m then IM.add (a land lnot 3) Top m else m) s st.amem }
  | Range (lo, hi, _) when not (IM.is_empty st.amem) ->
    { st with amem = IM.mapi (fun a x -> if a >= (lo land lnot 3) && a <= hi then Top else x) st.amem }
  | _ -> st

let clobber st regs = let r = Array.copy st.regs in List.iter (fun k -> r.(k) <- Top) regs; { st with regs = r }

let set_reg st r v = let regs = Array.copy st.regs in regs.(r) <- v; { st with regs }

(* Substitute the caller's state cs into a value relative to the callee's entry. *)
let subst t cs = function
  | Top -> Top
  | (Consts _ | Range _ | Tab _ | Idx _ | Obj _) as c -> c
  | Sym (Reg0 r, k) -> add_k cs.regs.(r) k
  | Sym (Slot0 n, k) ->
    (match cs.regs.(13) with
     | Sym (Reg0 13, sp) -> add_k (read_slot cs (sp + n)) k
     | Consts s when IS.cardinal s = 1 ->
       add_k (load_word t cs (const (IS.choose s + n)) ~byte:false) k
     | _ -> Top)
  | Sym (Load0 (r, n), k) ->
    (match add_k cs.regs.(r) n with
     | Consts s when IS.cardinal s = 1 -> add_k (image_word t (IS.choose s) ~byte:false) k
     | Sym (Reg0 13, n') -> add_k (read_slot cs n') k
     | Sym (b', n') -> add_k (read_field cs b' n') k
     | Range _ as av -> add_k (load_word t cs av ~byte:false) k     (* a table load in the caller *)
     | _ -> Top)

let top_of_stack st =
  match st.regs.(13) with
  | Sym (Reg0 13, k) -> read_slot st k
  | Consts s when IS.cardinal s = 1 ->
    Option.value (IM.find_opt (IS.choose s land lnot 3) st.amem) ~default:Top
  | _ -> Top

let apply_exit t cs (e : exit_) =
  let regs = Array.init 16 (fun r -> subst t cs e.st.regs.(r)) in
  if regs.(13) = Top then regs.(13) <- cs.regs.(13);    (* stack balance (counted by caller) *)
  (* Caller's stack and absolute memory survive; the callee's absolute
     stores are carried over, and so are its stack writes (relative to its
     SP0), at the caller's SP plus the same offset: after a balanced return
     they are dead (dropped), but at a tail exit (push lr, then jump
     through a table to a routine that pops it) the callee's net push - the
     slots between its exit SP and its entry SP, for a descending or an
     ascending stack - is the frame the continuation pops. *)
  (* (a word the callee keeps PC-relative, e.g. its own return address, is
     carried over only if the caller tracks it too: otherwise every
     caller's summary would gather all its callees' words) *)
  let amem = IM.fold (fun a v m ->
      if Hashtbl.mem t.pc_slots a && not (IM.mem a cs.amem) then m else IM.add a (subst t cs v) m)
      e.st.amem cs.amem in
  let lo, hi = match e.st.regs.(13) with Sym (Reg0 13, k) -> (min k 0, max k 0) | _ -> (0, 0) in
  let stack, amem = IM.fold (fun off v (stk, am) ->
      if off < lo || off >= hi then (stk, am) else
      match cs.regs.(13) with
      | Sym (Reg0 13, sp) -> (IM.add (sp + off) (subst t cs v) stk, am)
      | Consts s when IS.cardinal s = 1 ->
        (stk, IM.add ((IS.choose s + off) land lnot 3) (subst t cs v) am)
      | _ -> (stk, am)) e.st.stack (cs.stack, amem) in
  (* fields the callee wrote, relative to its entry registers, become the
     caller's fields at the corresponding addresses *)
  PM.iter (fun (b, k) v -> if b <> Reg0 13 then record_field t k (subst t cs v)) e.st.fields;
  let fields = PM.fold (fun (b, k) v m ->
      match subst t cs (Sym (b, k)) with
      | Sym (b', k') when b' <> Reg0 13 -> PM.add (b', k') (subst t cs v) m
      | _ -> m) e.st.fields cs.fields in
  { regs; stack; amem; fields; fk = -1; cmp = None }    (* callee may change the flags *)

(* Does instruction i (when executed) change the flags? *)
let sets_flags (i : Arm2.t) =
  match i.kind with
  | Arm2.Dp { s; _ } | Arm2.Mul { s; _ } -> s
  | Arm2.Swi _ -> true
  | Arm2.Cop { ck = Arm2.Mrc; _ } -> true
  | Arm2.Block { load = true; psr = true; _ } -> true
  | _ -> false

let cond_of_index = function
  | 0 -> Arm2.EQ | 1 -> Arm2.NE | 2 -> Arm2.CS | 3 -> Arm2.CC | 4 -> Arm2.MI | 5 -> Arm2.PL
  | 6 -> Arm2.VS | 7 -> Arm2.VC | 8 -> Arm2.HI | 9 -> Arm2.LS | 10 -> Arm2.GE | 11 -> Arm2.LT
  | 12 -> Arm2.GT | 13 -> Arm2.LE | 14 -> Arm2.AL | _ -> Arm2.NV

(* On a path where condition c is known to hold (or not), narrow the
   register of the comparison that set the flags (imm -1: the flags of a
   result, ands r7,r0,#k - only EQ says something, that it is 0). Unsigned lower / lower-or-
   same and equality bound it; the signed ones only when it is already known
   to be a non-negative range, or for the index of a computed jump made on
   that condition (cmp r0,#n ; addle pc,pc,r0,lsl #2 - a negative index
   would land in the code before the table, so the program means 0..n). *)
let refine ?(index = false) st c holds =
  match st.cmp with
  | None -> st
  | Some (r, imm) ->
    let c = if holds then c else cond_of_index (cond_index c lxor 1) in
    let cur = st.regs.(r) in
    let nonneg = index || match cur with Range (_, h, _) -> h < 0x80000000 | _ -> false in
    let bound = if imm < 0 then (if c = Arm2.EQ then Some (0, 0) else None) else match c with
      | Arm2.CC when imm > 0 -> Some (0, imm - 1)
      | Arm2.LS -> Some (0, imm)
      | Arm2.EQ -> Some (imm, imm)
      | Arm2.LT when nonneg && imm > 0 -> Some (0, imm - 1)
      | Arm2.LE when nonneg -> Some (0, imm)
      | _ -> None in
    match bound with
    | None -> st
    | Some (lo, hi) ->
      let nv = match cur with
        | Consts _ when index && hi - lo < max_enum ->
          (* the index of a guarded computed jump: every case up to the
             guard is in the table, whatever values the analysis saw
             stored (a variable's are an under-approximation: a zero-
             initialised one's initial 0, stores in code not yet found) *)
          mk_range lo hi 1
        | Consts s ->
          let s' = IS.filter (fun x -> x >= lo && x <= hi) s in
          if IS.is_empty s' then cur else Consts s'
        | Range (l, h, step) ->
          let l' = if l >= lo then l else l + ((lo - l + step - 1) / step) * step in
          (match mk_range l' (min h hi) step with Top -> cur | v -> v)
        | Top -> mk_range lo hi 1
        | Sym (Reg0 r', _) when r' <> 13 && r' <> 14 -> mk_range lo hi 1
        | _ -> cur in
      let regs = Array.copy st.regs in
      regs.(r) <- nv;
      { st with regs }

(* Recognise a copy loop closed by the branch at tail back to head: the body
   loads through one register and stores through another, both
   post-incremented by the same step (ldr/ldrb/str/strb with an immediate,
   or ldmia/stmia with writeback), and ends either by counting a register
   down to zero (subs rc,rc,#n ; bne) or by comparing the source pointer
   with a constant end (cmp ra,#end or cmp ra,rk with rk constant). The
   source, destination and count come from the state on first arrival at
   the loop head. *)
let detect_copy_loop t head tail (entry : state) =
  let img = t.img in
  let insns = List.init ((tail - head) / 4 + 1) (fun k -> Image.decode img (head + 4 * k)) in
  let single v = match v with Consts s when IS.cardinal s = 1 -> Some (IS.choose s) | _ -> None in
  let step_of (i : Arm2.t) ~load =
    match i.kind with
    | Arm2.Mem { load = l; pre = false; up = true; rn; off = Arm2.Off_imm n; byte; _ }
      when l = load && rn <> 15 && n = (if byte then 1 else 4) -> Some (rn, n)
    | Arm2.Block { load = l; pre = false; up = true; wb = true; rn; regs; _ }
      when l = load && rn <> 15 && regs land 0x8000 = 0 ->
      Some (rn, 4 * List.length (Arm2.regs_of_mask regs))
    | _ -> None in
  let loads = List.filter_map (step_of ~load:true) insns in
  let stores = List.filter_map (step_of ~load:false) insns in
  match loads, stores with
  | [ (ra, k) ], [ (rb, k') ] when k = k' && ra <> rb ->
    let iterations =
      List.find_map (fun (i : Arm2.t) ->
          match i.kind with
          | Arm2.Dp { op = Arm2.SUB; s = true; rd; rn; op2 = Arm2.Imm (n, _); _ } when rd = rn && n > 0 ->
            Option.map (fun c -> c / n) (single entry.regs.(rd))
          | Arm2.Dp { op = Arm2.CMP; rn; op2; _ } when rn = ra ->
            let lim = match op2 with
              | Arm2.Imm (n, _) -> Some n
              | Arm2.Reg (Arm2.Shift_imm (rm, Arm2.LSL, 0)) -> single entry.regs.(rm)
              | _ -> None in
            (match lim, single entry.regs.(ra) with
             | Some e, Some a0 when e > a0 -> Some ((e - a0) / k)
             | _ -> None)
          | _ -> None) insns in
    (match single entry.regs.(ra), single entry.regs.(rb), iterations with
     | Some src, Some dst, Some n when n > 0 && Image.inside img src ->
       let c = { src; dst; len = n * k; loop_at = tail } in
       if not (List.mem c t.copies) then t.copies <- c :: t.copies
     | None, Some dst, Some n when n > 0 && k land 3 = 0 && dst land 3 = 0
                                   && Image.inside img dst && Image.inside img (dst + n * k - 1) ->
       (* words to a word: what could be code *)
       let c = { src = -1; dst; len = n * k; loop_at = tail } in
       if not (List.mem c t.copies) then t.copies <- c :: t.copies
     | _ -> ())
  | _ -> ()

let max_inline = 16

(* --global-r12: the program keeps a workspace pointer in r12, the same
   all through (Fervour's &51310, set at start and re-established by the
   routines the OS calls). Then r12 is, at a function's entry, the
   constant every call site passes, rather than symbolic: a path that
   reloads it (add r12,pc,#k) joins the others instead of losing it, and
   pointers into the workspace (records holding instructions) are known.
   The join over all call sites found so far; a function is re-analysed
   when it changes. Entry points (roots) are called from outside and stay
   symbolic. Not the default: a program that uses r12 for
   other things too, or keeps return addresses in its workspace (Twin
   World), is misread - loads through it see the image's initial
   contents. *)

let note_entry_consts t g (st : state) =
  if features.global_r12 && not (Hashtbl.mem t.roots g) then begin
    let cur = Array.init 13 (fun r -> match st.regs.(r) with
        | Consts s as v when IS.cardinal s = 1 && r = 12 -> v
        | _ -> Top) in
    let nw = match Hashtbl.find_opt t.entry_consts g with
      | None -> cur
      | Some old -> Array.init 13 (fun r -> if old.(r) = cur.(r) then old.(r) else Top) in
    match Hashtbl.find_opt t.entry_consts g with
    | Some old when old = nw -> ()
    | prev ->
      Hashtbl.replace t.entry_consts g nw;
      if prev <> None && Hashtbl.mem t.analysed g then enqueue t g
  end

(* Analyse g now if it never has been (depth-first, so that a caller sees
   its callees' summaries in the same pass); re-analyse on demand otherwise. *)
let rec ensure_analysed t g =
  if not (Hashtbl.mem t.analysed g) && not (Hashtbl.mem t.in_progress g) then update t g

and update t g =
  if Sys.getenv_opt "SS_TRACE" <> None then Printf.eprintf "start &%x\n%!" g;
  Hashtbl.replace t.analysed g ();
  Hashtbl.replace t.in_progress g ();
  (* any analysis answers a pending request: a function first analysed
     depth-first from a call, while still waiting on the fresh stack, must
     not stay marked queued, or later requests to re-analyse it are lost *)
  Hashtbl.remove t.queued g;
  let nsym () = List.length (Option.value (Hashtbl.find_opt t.sym_stores g) ~default:[]) in
  let sym_before = nsym () in
  let s = analyse_function t g in
  Hashtbl.remove t.in_progress g;
  if nsym () <> sym_before && Sys.getenv_opt "SS_TRACE" <> None then
    Printf.eprintf "&%x symbolic stores %d -> %d: %s\n%!" g sym_before (nsym ())
      (String.concat " " (List.map (fun (w, v) -> Printf.sprintf "&%x=%s" w (string_of_v v))
                            (Option.value (Hashtbl.find_opt t.sym_stores g) ~default:[])));
  if nsym () <> sym_before then          (* new symbolic stores: the call sites substitute them *)
    Hashtbl.iter (fun c () -> if not (Hashtbl.mem t.in_progress c) then enqueue t c) (Hashtbl.find t.callers g);
  let old = Hashtbl.find t.summaries g in
  (* A summary that keeps changing is widened (see widen_summary): a cycle
     of functions whose paths pop ever more of the caller's frame (a
     recursion through tail transfers) would otherwise grow without end.
     One that changes back to what it was before the last change is
     oscillating (functions whose summaries depend on each other's, one
     path's state appearing and disappearing in turn: Zool's main loop,
     whose analysis takes seconds): it is widened at once. *)
  let s =
    if equal_summary s old then s
    else begin
      let n = 1 + Option.value (Hashtbl.find_opt t.changes g) ~default:0 in
      Hashtbl.replace t.changes g n;
      let flips = match Hashtbl.find_opt t.previous g with Some p -> equal_summary s p | None -> false in
      Hashtbl.replace t.previous g old;
      if n > !summary_widen_after || flips then (Hashtbl.replace t.widened g (); widen_summary t.img old s) else s
    end in
  if Sys.getenv_opt "SS_TRACE" <> None then
    Printf.eprintf "&%x exits %d -> %d%s\n%!" g (List.length old) (List.length s)
      (if equal_summary s old then "" else " CHANGED");
  if not (equal_summary s old) then begin
    if Sys.getenv_opt "SS_EXITS" = Some (Printf.sprintf "%x" g) then
      List.iter (fun e -> Printf.eprintf "  exit at &%x pc=%s fk=%d sp=%s\n" e.at (string_of_v e.pc) e.st.fk
                    (string_of_v e.st.regs.(13))) s;
    flush stderr;
    Hashtbl.replace t.summaries g s;
    Hashtbl.iter (fun c () -> if not (Hashtbl.mem t.in_progress c) then enqueue t c)
      (Hashtbl.find t.callers g)
  end

and analyse_function t f =
  let img = t.img in
  let t0 = Sys.time () in

  let states : (int * int, state) Hashtbl.t = Hashtbl.create 256 in
  let visits : (int * int, int) Hashtbl.t = Hashtbl.create 256 in
  let first : (int, state) Hashtbl.t = Hashtbl.create 256 in     (* first state seen at an address *)
  let wl = Queue.create () in
  let summary = ref [] in
  let propagate a st =
    if a land 3 = 0 && in_extern a then
      Hashtbl.replace extern_targets a ()             (* a tail call into another image *)
    else if not (Image.inside img a) || a land 3 <> 0 then
      Hashtbl.replace t.problems a (Printf.sprintf "flow to &%x outside image (function &%x)" a f)
    else begin
      if not (Hashtbl.mem first a) then Hashtbl.replace first a st;
      let key = (a, st.fk) in
      match Hashtbl.find_opt states key with
      | None -> Hashtbl.replace states key st; Queue.push key wl
      | Some old ->
        let j = join_state old st in
        if not (equal_state j old) then begin
          let n = 1 + Option.value (Hashtbl.find_opt visits key) ~default:0 in
          Hashtbl.replace visits key n;
          let j = if n > widen_after then widen_state img old j else j in
          Hashtbl.replace states key j; Queue.push key wl
        end
    end
  in
  (* Apply the summary of function target at site a (a bl, or a jump to a
     function entry: a tail transfer). *)
  let applying = Hashtbl.create 16 in
  let rec apply_summary a st target =
    (* a return into a function entry applies that function's summary in
       turn; a cycle of such returns ends where it started *)
    if Hashtbl.mem applying (a, target) then () else begin
    Hashtbl.replace applying (a, target) ();
    Fun.protect ~finally:(fun () -> Hashtbl.remove applying (a, target)) (fun () ->
    add_func t target;
    Hashtbl.replace (Hashtbl.find t.callers target) f ();
    note_entry_consts t target st;
    ensure_analysed t target;
    List.iter (fun (w, v) -> note_store t ~f a (const w) (subst t st v) ~byte:false)
      (Option.value (Hashtbl.find_opt t.sym_stores target) ~default:[]);
    List.iter (fun (e : exit_) ->
        if e.st.regs.(13) = Top then Hashtbl.replace t.balanced a ();
        let ret = subst t st e.pc in
        if Sys.getenv_opt "SS_DEBUG_ADDR" = Some (Printf.sprintf "%x" a) then
          Printf.eprintf "summary return at &%x from &%x: exit %s -> %s (r10=%s)\n" a target
            (string_of_v e.pc) (string_of_v ret) (string_of_v st.regs.(10));
        let st' = apply_exit t st e in
        match ret with
        | Consts s ->
          let s = IS.map (fun c -> c land addr_mask) s in
          add_set t.ret_sites a s;
          IS.iter (fun r -> goto a r st') s
        | Sym _ -> summary := add_exit !summary { pc = ret; st = st'; at = a }   (* tail exit *)
        | Range _ | Tab _ | Idx _ | Obj _ -> jump a st' ret        (* e.g. through a caller's table *)
        | Top -> Hashtbl.replace t.unresolved a "return target unknown")
      (Hashtbl.find t.summaries target))
    end
  (* Transfer control from a to target (not a call). A known function entry
     is entered through its summary. A target reached again with a different
     stack pointer, or different return addresses pushed in the frame, while
     return addresses are waiting in the frame, is a routine shared by
     several contexts that each pushed their own return before branching to
     it: it becomes a function, so that each context gets its own return.
     (Loop heads popping data with a moving stack pointer are not promoted.) *)
  (* Code addresses pushed in the current frame (at or above SP, within a
     window): return addresses waiting to be popped. *)
  and frame_returns st =
    let code_consts v acc = match v with
      | Consts s when IS.for_all (fun c -> Image.inside img (c land addr_mask) && c land 3 = 0) s ->
        IS.union s acc
      | _ -> acc in
    match st.regs.(13) with
    | Sym (Reg0 13, k) ->
      IM.fold (fun off v acc -> if off >= k && off < k + 256 then code_consts v acc else acc) st.stack IS.empty
    | Consts sp when IS.cardinal sp = 1 ->
      let sp = IS.choose sp in
      IM.fold (fun a v acc -> if a >= sp && a < sp + 256 then code_consts v acc else acc) st.amem IS.empty
    | _ -> IS.empty
  and pushed_return st =
    match top_of_stack st with
    | Consts s -> IS.for_all (fun c -> Image.inside img (c land addr_mask)) s
    | _ -> false
  and goto a target st =
    if in_slot t target then unknown_jump a st
    else if target <> f && Hashtbl.mem t.funcs target then apply_summary a st target
    else
      match Hashtbl.find_opt first target with
      | Some old when target <> f
                      && not (IS.is_empty (frame_returns st)) && not (IS.is_empty (frame_returns old))
                      && (old.regs.(13) <> st.regs.(13) || frame_returns old <> frame_returns st) ->
        Hashtbl.replace t.promoted target ();
        apply_summary a st target
      | _ -> propagate target st
  and jump a st v =
    (* a PC write at a with value v *)
    (match st.regs.(14), v with
     | _, Sym _ -> ()
     | Consts s, _ when IS.equal s (IS.singleton (a + 4)) -> Hashtbl.replace t.linked a ()
     | _ -> ());
    match v with
     | Consts s when IS.for_all (fun c -> c land addr_mask = 0) s ->
       (* only 0: a pointer not set yet (a variable's initial value), not
          a target *)
       unknown_jump a st
     | Consts s ->
       let s = IS.filter (fun c -> c land addr_mask <> 0) s in
       let s = IS.map (fun c -> map_addr t (c land addr_mask)) s in
       add_set t.const_jumps a s;
       if IS.cardinal s > 1 then Hashtbl.replace t.tables a ("bounded", IS.cardinal s);
       dispatched_calls a st s;
       IS.iter (fun c -> goto a c st) s
     | Sym (Load0 _, _) when (match st.regs.(14) with
                               | Consts s -> IS.equal s (IS.singleton (a + 4)) | _ -> false) ->
       (* a hand-linked call through a pointer loaded from memory (ldr r1,
          [r11,#k] ; add lr,pc,#0 ; mov pc,r1): a call, not a return, even
          though the pointer is relative to the function's entry *)
       unknown_jump a st
     | Sym _ ->
       if Hashtbl.mem t.lang_inits f then          (* the main program, which Init returns *)
         (match st.regs.(0) with
          | Consts s -> IS.iter (fun c -> if Image.inside img c && c land 3 = 0 then add_func t c) s
          | _ -> ());
       summary := add_exit !summary { pc = v; st; at = a }
     | (Range _ | Tab _) when not features.tables -> unknown_jump a st
     | Range (lo, _, step) when not (unbounded v)
                                && Image.inside img lo && step land 3 = 0
                                && (match (Image.decode img a).kind with
                                    | Arm2.Dp { op = Arm2.ADD; rd = 15; op2 = Arm2.Reg _; _ } -> true
                                    | Arm2.Dp { op = Arm2.ADD; rd = 15; rn; op2 = Arm2.Imm _; _ } -> rn <> 15
                                    | _ -> false) ->
       (* only a computed jump (add pc, rN, rX... or add pc, rN, #k with rN
          stepping through records holding instructions) can have a range
          of targets: returns and pointers loaded into PC are single values *)
       (* a range of code addresses (e.g. add pc,pc,rX,lsl #2); a range of
          small values (a byte loaded into PC) is not one. Targets must look
          like code: plausible, not data, not a word below &10000 (andeq
          r0,r0,<small> - table entries, zeros) *)
       (match elements v max_enum with
        | Some l ->
          (* (a range widened to the image's end may reach just past it) *)
          let l = List.filter (Image.inside img) l in
          let ok x =
            let i = Image.decode img x in
            Arm2.plausible i && i.cond <> Arm2.NV && Image.word img x >= 0x10000
            && not (Hashtbl.mem t.data x) in
          (* a wide range (bounded by the index's type, e.g. a byte, not
             by a guard) of entries that each end with an unconditional
             transfer before the next one - a branch per word, or a few
             instructions and a branch per 16 bytes (SoundMaster's effect
             commands) - is a table of cases: it ends at the first entry
             that isn't one (what follows is other code, entered with
             other states) *)
          let transfer x =
            let i = Image.decode img x in
            Arm2.always i && Arm2.writes_pc i
            && (match i.kind with Arm2.Branch { link = true; _ } -> false | _ -> true) in
          let case_block x =
            let rec go a = a < x + step && Image.inside img a
                           && Arm2.plausible (Image.decode img a)
                           && (transfer a || go (a + 4)) in
            go x in
          let l = match List.sort compare l with
            | x :: _ as l when List.length l > 64 && case_block x ->
              let rec upto = function x :: r when case_block x -> x :: upto r | _ -> [] in
              upto l
            | l -> l in
          (match List.filter ok l with
           | [] -> unknown_jump a st
           | l' -> jump a st (Consts (IS.of_list l')))
        | None -> unknown_jump a st)
     | Tab tb ->
       (* entries that give a plausible code target; with a tight bound
          (at most max_consts entries) invalid entries (null slots) are
          skipped; otherwise the table ends at its first invalid entry *)
       let limit = Option.value tb.limit ~default:512 in
       let adds = match tb.tfield with
         | None -> [ tb.tadd ]
         | Some k -> use_field k; List.map (fun v -> v + tb.tadd) (IS.elements (field_values k)) in
       let rec scan base k acc =
         let e = map_addr t (base + k * tb.stride) in
         if k >= limit || not (Image.inside img e) || Hashtbl.mem t.code e then acc
         else
           (* an entry written at run time holds the values stored to it *)
           let entry_vals = match Hashtbl.find_opt t.var_known e with
             | Some (Consts s) -> initial_target t e @ IS.elements s
             | Some _ -> initial_target t e       (* stored values unknown: still the one it starts with *)
             | None -> if Hashtbl.mem t.vars e then [] else [ Image.word img e ] in
           let valid = List.concat_map (fun add -> List.filter_map (fun w ->
               let target = map_addr t ((w + add) land addr_mask) in
               if Image.inside img target && Arm2.plausible (Image.decode img target)
                  && (Image.decode img target).cond <> Arm2.NV && not (Hashtbl.mem t.data target)
               then Some target else None) entry_vals) adds in
           if valid <> [] then begin
             Hashtbl.replace t.data e "jump table";
             scan base (k + 1) (List.fold_left (fun acc x -> IS.add x acc) acc valid)
           end else if limit <= max_consts || Hashtbl.mem t.var_known e then scan base (k + 1) acc
           else acc in
       let targets = List.fold_left (fun acc b -> scan b 0 acc) IS.empty (tb.tbase :: tb.more) in
       if Sys.getenv_opt "SS_DEBUG_ADDR" = Some (Printf.sprintf "%x" a) then
         Printf.eprintf "table jump at &%x: %s -> %d targets (%s)\n%!" a (string_of_v v) (IS.cardinal targets)
           (String.concat " " (List.map (fun b -> Printf.sprintf "&%x:%d" b (IS.cardinal (scan b 0 IS.empty)))
                                 (tb.tbase :: tb.more)));
       if Sys.getenv_opt "SS_DEBUG_ADDR" = Some (Printf.sprintf "%x" a) then
         List.iter (fun b ->
             let rec stop k =
               let e = b + k * tb.stride in
               if k >= limit then Printf.sprintf "limit %d" k
               else if Hashtbl.mem t.code e then Printf.sprintf "entry &%x is code (k=%d)" e k
               else
                 let w = Image.word img e land addr_mask in
                 if not (Image.inside img w) then Printf.sprintf "k=%d &%x outside" k w
                 else if Hashtbl.mem t.data w then Printf.sprintf "k=%d target &%x is data (%s)" k w (Hashtbl.find t.data w)
                 else if not (Arm2.plausible (Image.decode img w)) then Printf.sprintf "k=%d &%x implausible" k w
                 else stop (k + 1) in
             Printf.eprintf "  base &%x stops: %s\n%!" b (stop 0)) (tb.tbase :: tb.more);
       if IS.is_empty targets then unknown_jump a st
       else begin
         Hashtbl.replace t.tables a
           ((match tb.limit with None -> "data-bounded (scanned)" | Some n -> Printf.sprintf "scanned, at most %d" n),
            IS.cardinal targets);
         add_set t.const_jumps a targets;
         dispatched_calls a st targets;
         IS.iter (fun c -> goto a c st) targets
       end
     | Obj (tb, k) ->
       (* the table's entries point to objects (in the image); the word at
          offset tadd of each is a target. Unbounded, the table ends at its
          first entry that isn't such a pointer *)
       let limit = Option.value tb.limit ~default:512 in
       let rec scan base i acc =
         let e = map_addr t (base + i * tb.stride) in
         if i >= limit || not (Image.inside img e) || Hashtbl.mem t.code e then acc
         else
           let ptr = if Hashtbl.mem t.vars e then None else Some (Image.word img e) in
           match ptr with
           | Some p when p land 3 = 0 && Image.inside img (p + tb.tadd) && not (Hashtbl.mem t.code p) ->
             let f = p + tb.tadd in
             let w = if Hashtbl.mem t.vars f then initial_target t f else [ Image.word img f ] in
             let ts = List.filter code_target (List.map (fun w -> map_addr t ((w + k) land addr_mask)) w) in
             if ts <> [] then Hashtbl.replace t.data e "object table";
             scan base (i + 1) (List.fold_left (fun acc x -> IS.add x acc) acc ts)
           | _ -> if limit <= max_consts then scan base (i + 1) acc else acc in
       let targets = List.fold_left (fun acc b -> scan b 0 acc) IS.empty (tb.tbase :: tb.more) in
       if IS.is_empty targets then unknown_jump a st
       else begin
         Hashtbl.replace t.tables a (Printf.sprintf "objects' field +&%x" tb.tadd, IS.cardinal targets);
         add_set t.const_jumps a targets;
         dispatched_calls a st targets;
         IS.iter (fun c -> goto a c st) targets
       end
     | Range _ | Idx _ | Top -> unknown_jump a st
  (* A multi-way dispatch made with lr set to a return address: the last
     instruction before it to write lr is add/sub lr,pc,#k or mov lr,pc
     (sub lr,pc,#k ; cmp r0,#n ; addle pc,pc,r0,lsl #2 - a Wimp_Poll loop
     calling a handler per event; lr holding data, or what a bl left there,
     doesn't count). Each target, or the destination of the unconditional b
     it holds, is a function, so that its return to lr comes back there
     with the caller's state. *)
  and dispatched_calls a st targets =
    if features.dispatch then
    let sets_return =
      let rec back k x =
        k < 64 && Image.inside img x &&
        (let i = Image.decode img x in
         if List.mem 14 (Arm2.defs i) then
           (match i.kind with
            | Arm2.Dp { op = (Arm2.ADD | Arm2.SUB); rd = 14; rn = 15; op2 = Arm2.Imm _; _ } -> true
            | Arm2.Dp { op = Arm2.MOV; rd = 14; op2 = Arm2.Reg (Arm2.Shift_imm (15, Arm2.LSL, 0)); _ } -> true
            | _ -> false)
         else back (k + 1) (x - 4)) in
      back 0 (a - 4) in
    match st.regs.(14) with
    | Consts l when IS.cardinal l = 1 && IS.cardinal targets > 1 && sets_return ->
      let r = IS.choose l land addr_mask in
      if Image.inside img r && not (IS.mem r targets) then begin
        if Sys.getenv_opt "SS_DEBUG_DC" <> None then
          Printf.eprintf "dispatch in &%x, lr &%x: %s\n%!" f r
            (String.concat " " (List.map (Printf.sprintf "&%x") (IS.elements targets)));
        IS.iter (fun c ->
            let i = Image.decode img c in
            let c' = match i.kind with
              | Arm2.Branch { link = false; target } when Arm2.always i -> map_addr t target
              | _ -> c in
            (* (not code just before the return point: what the
               dispatch falls back into, not a handler) *)
            if c' <> f && Image.inside img c' && not (c' >= r - 8 && c' <= r) then add_func t c') targets
      end
    | _ -> ()
  (* functions that jumped through field k are re-analysed when the values
     stored there grow *)
  and use_field k =
    let us = match Hashtbl.find_opt t.field_users k with
      | Some us -> us
      | None -> let us = Hashtbl.create 4 in Hashtbl.replace t.field_users k us; us in
    Hashtbl.replace us f ()
  and field_values k = Option.value (Hashtbl.find_opt t.field_vals k) ~default:IS.empty
  and unknown_jump a st =
       (match st.regs.(14), top_of_stack st with
        | Consts s, _ when IS.equal s (IS.singleton (a + 4)) ->
          Hashtbl.replace t.assumed a ();
          propagate (a + 4) (clobber st [ 0; 1; 2; 3; 12; 14 ])
        | _, (Consts rs as r) when pushed_return st ->
          (* return address pushed on the stack before the jump *)
          Hashtbl.replace t.assumed a ();
          let st' = clobber st [ 0; 1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11; 12; 14 ] in
          let st' = set_reg st' 13 (add_k st.regs.(13) 4) in
          ignore r;
          IS.iter (fun c -> add_set t.ret_sites a (IS.singleton (c land addr_mask));
                    goto a (c land addr_mask) st') rs
        | _ ->
          let use = use_field and vals = field_values in
          let field_targets k c =
            use k;
            IS.filter code_target (IS.map (fun v -> map_addr t ((v + c) land addr_mask)) (vals k)) in
          let how, targets = match (if features.fields then field_jump a else None) with
            | Some (`Object (k, None)) ->
              (* a table inside the objects stored at field k *)
              use k;
              (Printf.sprintf "object at field +&%x" k,
               IS.fold (fun o acc -> IS.union (object_code_words o) acc) (vals k) IS.empty)
            | Some (`Object (k, Some j)) ->
              (* word j of the objects stored at field k; failing that, any
                 value stored at field offset j *)
              use k;
              let objs = IS.filter (fun o -> Image.inside img (o + j)) (vals k) in
              let ts = IS.filter code_target (IS.map (fun o -> Image.word img (o + j)) objs) in
              if IS.is_empty ts then (Printf.sprintf "field +&%x" j, field_targets j 0)
              else (Printf.sprintf "object at field +&%x, +&%x" k j, ts)
            | Some (`Field (k, c)) -> (Printf.sprintf "field +&%x" k, field_targets k c)
            | None -> ("", IS.empty) in
          if IS.is_empty targets then begin
            Hashtbl.replace t.unresolved a "unknown target"; Hashtbl.replace t.fn_unresolved f ()
          end else begin
            Hashtbl.remove t.unresolved a;
            Hashtbl.replace t.tables a (how, IS.cardinal targets);
            jump a st (Consts targets)
          end)
  (* The code addresses among an object's words: up to max_object words
     from its start, stopping at a word the analysis found to be code. A
     word that holds a code address must be inside the image, aligned, at
     plausible code that isn't data and isn't a word below &10000. *)
  and code_target x =
    x land 3 = 0 && Image.inside img x && not (Hashtbl.mem t.data x) && Image.word img x >= 0x10000
    && (let i = Image.decode img x in Arm2.plausible i && i.cond <> Arm2.NV)
  and object_code_words o =
    let max_object = 64 in
    let rec go k acc =
      let w = o + 4 * k in
      if k >= max_object || not (Image.inside img w) || Hashtbl.mem t.code w then acc
      else
        let x = Image.word img w in
        go (k + 1) (if code_target x then IS.add x acc else acc) in
    go 0 IS.empty
  (* The jump at a, with an unknown target: is it through a value loaded
     from a field (ldr pc,[rB,#k]; or add/mov pc,rN[,#c] where the
     straight-line code before it set rN with ldr rN,[rB,#k])? Then
     (k, c): its targets are the addresses stored at offset k, plus c.
     Or through an object loaded from a field (rO set with ldr rO,[rB,#k]
     in the straight-line code before): ldr pc,[rO,rI,lsl #2], a table in
     the object, gives `Object (k, None) - its targets are the code
     addresses stored in the objects that are stored at offset k
     (object_code_words), e.g. a menu screen's handler list indexed by the
     item chosen; ldr pc,[rO,#j] gives `Object (k, Some j), the word at
     offset j of each such object. *)
  and field_jump a =
    let fld (i : Arm2.t) = match i.kind with
      | Arm2.Mem { load = true; byte = false; pre = true; up = true; rn; off = Arm2.Off_imm k; _ }
        when rn <> 13 && rn <> 15 -> Some k
      | _ -> None in
    let rec back r c x n =
      if n = 0 || not (Image.inside img x) then None
      else
        let i = Image.decode img x in
        match i.kind with
        | Arm2.Branch _ | Arm2.Swi _ -> None
        | _ when List.mem 15 (Arm2.defs i) -> None
        | _ when List.mem r (Arm2.defs i) ->
          if i.cond <> Arm2.AL then None
          else Option.map (fun k -> (k, c)) (fld i)
        | _ -> back r c (x - 4) (n - 1) in
    let field kc = Option.map (fun (k, c) -> `Field (k, c)) kc in
    let i = Image.decode img a in
    match i.kind with
    | Arm2.Mem { load = true; byte = false; pre = true; up = true; rn;
                 off = Arm2.Off_reg (rm, Arm2.LSL, 2); _ } when rn <> 13 && rn <> 15 && rm <> rn ->
      Option.map (fun (k, _) -> `Object (k, None)) (back rn 0 (a - 4) 16)
    | Arm2.Mem { rn; off = Arm2.Off_imm j; _ } when fld i <> None ->
      (* a field of an object itself loaded from a field, or any field *)
      (match back rn 0 (a - 4) 16 with
       | Some (k, _) when Hashtbl.mem t.field_vals k -> Some (`Object (k, Some j))
       | _ -> field (Option.map (fun k -> (k, 0)) (fld i)))
    | Arm2.Dp { op = Arm2.ADD; rd = 15; rn; op2 = Arm2.Imm (c, _); _ } when rn <> 15 -> field (back rn c (a - 4) 16)
    | Arm2.Dp { op = Arm2.MOV; rd = 15; op2 = Arm2.Reg (Arm2.Shift_imm (rm, Arm2.LSL, 0)); _ } when rm <> 15 ->
      field (back rm 0 (a - 4) 16)
    | _ -> None
  in
  (* With SP unknown: the single saved return value in the frame, if any. *)
  let saved_return st =
    let cands = IM.fold (fun _ v acc -> match v with
        | Sym ((Reg0 14 | Slot0 _), _) when not (List.mem v acc) -> v :: acc
        | _ -> acc) st.stack [] in
    match cands with [ v ] -> Some v | _ -> None in
  let pop_pc a st v =
    match v, st.regs.(13) with
    | Top, Top ->
      (match saved_return st with
       | Some r -> Hashtbl.replace t.balanced a (); jump a st r
       | None -> jump a st Top)
    | _ -> jump a st v in
  (* A small callee (a dispatch stub of at most max_inline instructions)
     that met an unresolved jump in its own analysis - e.g. it dispatches
     through a table the caller passes in a register - is also followed
     inline here, where the caller's values may resolve that jump. Its
     summary still gives the call's ordinary returns (inline, an unknown
     caller SP would lose them). Larger callees are not inlined: nested
     inlining multiplies analysis cost. *)
  let call a st target =
    let st = set_reg st 14 (const (a + 4)) in
    if in_slot t target then unknown_jump a st       (* a call into a slot: whatever it holds then *)
    else begin
    add_func t target;
    ensure_analysed t target;
    if features.inline && Hashtbl.mem t.fn_unresolved target && target <> f && not (Hashtbl.mem t.in_progress target)
       && Option.value (Hashtbl.find_opt t.fn_size target) ~default:max_int <= max_inline
    then begin
      Hashtbl.replace t.inlined a ();
      propagate target st
    end;
    apply_summary a st target
    end in
  let debug = match Sys.getenv_opt "SS_DEBUG" with
    | Some x -> int_of_string ("0x" ^ x) = f | None -> false in
  let debug_addr = Option.map (fun x -> int_of_string ("0x" ^ x)) (Sys.getenv_opt "SS_DEBUG_ADDR") in
  let step a st =
    t.cur_site <- a;
    let i = Image.decode img a in
    if debug_addr = Some a then Printf.eprintf "function &%x reaches &%x\n" f a;
    if debug then
      Printf.eprintf "%08x %-32s regs=%s lr=%s sp=%s stack=%s amem=%s\n" a (Arm2.to_string i)
        (String.concat "," (List.init 13 (fun r -> string_of_v st.regs.(r))))
        (string_of_v st.regs.(14)) (string_of_v st.regs.(13))
        (String.concat " " (List.map (fun (k, v) -> Printf.sprintf "%d:%s" k (string_of_v v))
                              (IM.bindings st.stack)))
        (String.concat " " (List.map (fun (k, v) -> Printf.sprintf "%x:%s" k (string_of_v v))
                              (List.filter (fun (k, _) -> match st.regs.(13) with
                                   | Consts s -> IS.exists (fun c -> abs (k - c) < 64) s | _ -> false)
                                  (IM.bindings st.amem))));
    if i.cond <> Arm2.NV && not (Arm2.plausible i) then
      Hashtbl.replace t.problems a ("invalid: " ^ Arm2.to_string i)
    else begin
      Hashtbl.replace t.code a ();
      if not (Hashtbl.mem t.owner a) then Hashtbl.replace t.owner a f;
      Hashtbl.remove t.data a;
      let next = a + 4 in
      (* a self-modified word (stored to by pc-relative stores) holding a
         transfer may be rewritten into an instruction that falls through
         (FervourMode patches mov pc,lr into cmp r2,#mode): what follows
         is code too *)
      if Hashtbl.mem t.vars a && Arm2.always i && Arm2.writes_pc i then
        goto a next { st with fk = -1; cmp = None };
      if i.cond = Arm2.NV then goto a next st
      else
        let run =
          if Arm2.always i then true
          else match known st.fk i.cond with
            | Some h -> if not h then goto a next st; h
            | None -> goto a next (refine { st with fk = fk_of i.cond false } i.cond false); true in
        if run then begin
        let st =
          if Arm2.always i then st
          else
            let index = match i.kind with
              | Arm2.Dp { op = Arm2.ADD; rd = 15; rn = 15; op2 = Arm2.Reg (Arm2.Shift_imm (rm, _, _)); _ } ->
                (match st.cmp with Some (r, _) -> r = rm | None -> false)
              | _ -> false in
            refine ~index { st with fk = fk_of i.cond true } i.cond true in
        let st = if sets_flags i then { st with fk = -1 } else st in
        (* comparison tracking: cmp rN,#imm (or a constant register) starts
           it; anything else that sets the flags or redefines rN ends it *)
        let st = match i.kind with
          | Arm2.Dp { op = Arm2.CMP; rn; op2; _ } when rn <> 15 ->
            (match op2_val st i op2 with
             | Consts c when IS.cardinal c = 1 -> { st with cmp = Some (rn, IS.choose c) }
             | _ -> { st with cmp = None })
          | Arm2.Dp { op; s = true; rd; _ }
            when rd <> 15 && not (List.mem op Arm2.[ TST; TEQ; CMP; CMN ]) ->
            { st with cmp = Some (rd, -1) }          (* Z: rd = 0 (see refine) *)
          | _ when sets_flags i -> { st with cmp = None }
          | _ -> (match st.cmp with
              | Some (r, _) when List.mem r (Arm2.defs i) -> { st with cmp = None }
              | _ -> st) in
        match i.kind with
        | Arm2.Branch { link; target } when Hashtbl.mem t.libvec target ->
          let id, k = Hashtbl.find t.libvec target in
          List.iter (fun ((c, e), r) -> if (c, e) = (id, k) then
                        match st.regs.(r) with
                        | Consts s -> IS.iter (fun x -> if Image.inside img x && x land 3 = 0 then add_func t x) s
                        | _ -> ()) lib_callbacks;
          let st' = { (clobber st [ 0; 1; 2; 3; 12; 14 ]) with fk = -1; cmp = None } in
          if link then goto a next st'
          else if (id, k) = (1, 0) then begin           (* _kernel_init: the program starts *)
            match st.regs.(0) with
            | Consts s when IS.cardinal s = 1 && Image.inside img (IS.choose s + 8) ->
              let blk = IS.choose s in
              let le = Image.word img (blk + 8) in
              let rec langs d =
                if d < le && Image.inside img (d + 20) then begin
                  let size = Image.word img d in
                  let init = Image.word img (d + 16) in
                  for w = 0 to (max size 20) / 4 - 1 do Hashtbl.replace t.data (d + 4 * w) "language description" done;
                  if size > 16 && init <> 0 && Image.inside img init then begin
                    Hashtbl.replace t.lang_inits init ();
                    Hashtbl.replace t.roots init ();
                    add_func t init
                  end;
                  if size >= 4 then langs (d + size)
                end in
              langs (Image.word img (blk + 4))
            | _ -> Hashtbl.replace t.unresolved a "_kernel_init: init block unknown"
          end else jump a st' st.regs.(14)              (* a tail call: the library returns to lr *)
        | Arm2.Branch { link = false; target } ->
          if features.copies && target <= a && a - target <= 64 && not (Arm2.always i) then
            (match Hashtbl.find_opt first target with
             | Some entry -> detect_copy_loop t target a entry
             | None -> ());
          goto a target st
        | Arm2.Branch { link = true; target } ->
          if Image.inside img target && not (in_extern target) then call a st target
          else if in_extern target then begin
            Hashtbl.replace extern_targets target ();
            Hashtbl.replace t.assumed a ();
            goto a next { (clobber st [ 0; 1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11; 12; 14 ]) with fk = -1; cmp = None }
          end
          else Hashtbl.replace t.problems a (Printf.sprintf "call to &%x outside image" target)
        | Arm2.Swi n when n land lnot 0x20000 = 0x01 ->
          let rec strend s = if Image.in_range img s && Image.byte img s <> 0 then strend (s + 1) else s in
          let after = (strend next + 4) land lnot 3 in
          let rec mark x = if x < after then begin
              if not (Hashtbl.mem t.code x) then Hashtbl.replace t.data x "OS_WriteS string";
              mark (x + 4) end in
          mark next;
          goto a after st
        | Arm2.Swi n when features.clib && (n land lnot 0x20000 = 0x80680 || n land lnot 0x20000 = 0x80681) ->
          note_libinit t st;
          goto a next (clobber st [ 0; 1; 2; 3; 4; 5; 6 ])
        | Arm2.Swi n when Spider.noreturn_swi n -> ()
        | Arm2.Swi n ->
          (match Riscos.args n with
           | Some regs ->
             List.iter (fun (r, kind) ->
                 match kind with
                 | Riscos.Entries k ->
                   for e = 0 to k - 1 do
                     note_candidates t (add_k st.regs.(r) (4 * e)) a
                       (Printf.sprintf "swi &%x r%d+%d entry" n r (4 * e))
                   done
                 | _ ->
                   note_candidates t st.regs.(r) a
                     (Printf.sprintf "swi &%x r%d %s" n r (match kind with Riscos.Code -> "code" | _ -> "data")))
               regs
           | None ->
             for r = 0 to 7 do
               note_candidates t st.regs.(r) a (Printf.sprintf "swi &%x r%d" n r)
             done);
          goto a next (clobber st [ 0; 1; 2; 3 ])
        | Arm2.Dp { op; rd; rn; op2; s = setf; _ } ->
          if Arm2.is_test op then goto a next st
          else
            let v = eval_dp st i op rn op2 in
            (* movs/mvns of an immediate sets Z from a constant: after
               moveqs r3,#0 the path that ran it still knows EQ. (Not any
               constant result: a value loaded from the image may be a
               variable written in ways the analysis doesn't see, and
               pruning a path on it loses code.) *)
            let st = match op, op2 with
              | (Arm2.MOV | Arm2.MVN), Arm2.Imm _ when setf && rd <> 15 ->
                (match single v with Some c -> { st with fk = fk_of Arm2.EQ (c = 0) } | None -> st)
              | _ -> st in
            if rd = 15 then begin
              match op, rn, op2 with
              | Arm2.ADD, 15, Arm2.Reg (Arm2.Shift_imm (_, Arm2.LSL, k))
                when k >= 5 && (v = Top || unbounded v) ->
                (* into one of a run of blocks of 2^k bytes that follows
                   (add pc,pc,rX,lsl #k: an unrolled loop entered part way
                   through, each block padded to the same size): every
                   block start up to the first that doesn't hold code (to its
                   end, or to a transfer it always takes: the loop's last
                   block may end in its exit) *)
                let size = 1 lsl k in
                let block_ok b =
                  let rec ok x = x >= b + size ||
                                 (Image.inside img x &&
                                  (let i = Image.decode img x in
                                   Arm2.plausible i && ((Arm2.always i && Arm2.writes_pc i) || ok (x + 4)))) in
                  ok b in
                let rec starts b n acc = if n < 256 && block_ok b then starts (b + size) (n + 1) (b :: acc) else acc in
                (match starts (a + 8) 0 [] with
                 | [] -> Hashtbl.replace t.follow a (); goto a (a + 8) st
                 | bs -> jump a st (Consts (IS.of_list bs)))
              | Arm2.ADD, 15, Arm2.Reg _ when v = Top || unbounded v ->
                (* computed jump into the code that follows (add pc,pc,rX
                   with rX unknown, e.g. a Duff's device): assume rX >= 0 *)
                Hashtbl.replace t.follow a ();
                goto a (a + 8) st
              | _ -> jump a st v
            end
            else goto a next (set_reg st rd v)
        | Arm2.Mul { acc; rd; rn; rm; rs; _ } ->
          let scale r k = match r with
            | Range (lo, hi, step) when k > 0 && hi * k <= m32 -> mk_range (lo * k) (hi * k) (step * k)
            | _ -> Top in
          let v = match st.regs.(rm), st.regs.(rs) with
            | (Range _ as r), c when single c <> None -> scale r (Option.get (single c))
            | c, (Range _ as r) when single c <> None -> scale r (Option.get (single c))
            | x, y -> map2_consts ( * ) x y in
          let v = if acc then add_v v st.regs.(rn) else v in       (* mla: + rn *)
          goto a next (set_reg st rd v)
        | Arm2.Swp { rd; _ } -> goto a next (set_reg st rd Top)
        | Arm2.Mem { load; byte; pre; up; wb; rd; rn; off } ->
          let base = reg_val st a rn in
          let offv = match off with
            | Arm2.Off_imm n -> const n
            | Arm2.Off_reg (rm, sh, n) -> op2_val st i (Arm2.Reg (Arm2.Shift_imm (rm, sh, n))) in
          let moved = if up then add_v base offv else sub_v base offv in
          let av = if pre then moved else base in
          let st1 = if wb || not pre then set_reg st rn moved else st in
          if load then begin
            let v = load_word t st av ~byte in
            (* a jump through a variable may also go to its initial value *)
            let v = match v, av with
              | Consts s, Consts w when rd = 15 && IS.cardinal w = 1 && not byte ->
                (match initial_target t (IS.choose w) with
                 | [ c ] -> Consts (IS.add c s)
                 | _ -> v)
              | _ -> v in
            if rd = 15 then (if rn = 13 then pop_pc a st1 v else jump a st1 v)
            else goto a next (set_reg st1 rd v)
          end else begin
            (* a saved stack pointer (this function's own: SP may also be
               used as a data register and kept in a variable), to a
               variable some ldr sp,[pc,#k] restores: this frame may later
               be returned to from any of those restore sites, which go on
               (pop a return...) as this function with its stack. (The
               restore sites are also analysed where they are, with SP
               unknown there.) *)
            (match av, st.regs.(13) with
             | Consts w, Sym (Reg0 13, _) when features.longjmp && rd = 13 && not byte && IS.cardinal w = 1
                                             && Hashtbl.mem t.sp_restores (IS.choose w) ->
               let st' = { st with regs = Array.mapi (fun r v -> if r = 13 then v else Top) st.regs;
                                   fk = -1; cmp = None } in
               List.iter (fun r ->
                   Hashtbl.replace t.code r ();
                   propagate (r + 4) st') (Hashtbl.find t.sp_restores (IS.choose w))
             | _ -> ());
            let v = if rd = 15 then const (a + 12) else st.regs.(rd) in
            if rn <> 13 && rd <> 15 && not byte then note_candidates t v a "stored";
            if rn <> 13 then note_store t ~f a av v ~byte;
            (match off with
             | Arm2.Off_imm n when rn <> 13 && rn <> 15 && pre && up && not byte -> record_field t n v
             | _ -> ());
            goto a next (store t st1 ~base_reg:rn av (if byte then Top else v))
          end
        | Arm2.Block { load; pre; up; wb; rn; regs; _ } ->
          let rl = Arm2.regs_of_mask regs in
          let n = List.length rl in
          let base = reg_val st a rn in
          let first = match up, pre with
            | true, false -> 0 | true, true -> 4 | false, false -> -4 * (n - 1) | false, true -> -4 * n in
          let addr_of k = add_k base (first + 4 * k) in
          let final = add_k base (if up then 4 * n else -4 * n) in
          if load then begin
            let st1 = ref st and pcv = ref None in
            List.iteri (fun k r ->
                let v = load_word t st (addr_of k) ~byte:false in
                (* a PC loaded from a variable may also be its initial
                   value (as for ldr pc): a context block reloaded with
                   ldmia r0,{r0-r12,lr,pc} starts at the code it holds *)
                let v = match v, addr_of k with
                  | (Consts _ | Top), Consts w when r = 15 && IS.cardinal w = 1 ->
                    (match initial_target t (IS.choose w), v with
                     | [ c ], Consts s -> Consts (IS.add c s)
                     | [ c ], _ ->
                       Hashtbl.replace t.unresolved a "PC loaded from a variable: only its initial value known";
                       const c
                     | _ -> v)
                  | _ -> v in
                if r = 15 then pcv := Some v else st1 := set_reg !st1 r v) rl;
            let st1 = if wb then set_reg !st1 rn final else !st1 in
            match !pcv with
            | Some v -> if rn = 13 then pop_pc a st1 v else jump a st1 v
            | None -> goto a next st1
          end else begin
            let st1 = ref st in
            List.iteri (fun k r ->
                let v = if r = 15 then const (a + 12) else st.regs.(r) in
                if rn <> 13 && r <> 15 then note_candidates t v a "stored";
                if rn <> 13 then note_store t ~f a (addr_of k) v ~byte:false;
                st1 := store t !st1 ~base_reg:rn (addr_of k) v) rl;
            goto a next (if wb then set_reg !st1 rn final else !st1)
          end
        | Arm2.Cop _ -> goto a next st
        | Arm2.Undefined _ -> ()
        end
    end
  in
  propagate f (entry_state ?consts:(if Hashtbl.mem t.roots f then None else Hashtbl.find_opt t.entry_consts f) ());
  let steps = ref 0 in
  while not (Queue.is_empty wl) && !steps < 2_000_000 && not (exhausted ()) do
    incr steps;
    incr steps_taken;
    let key = Queue.pop wl in
    step (fst key) (Hashtbl.find states key)
  done;
  if !steps >= 2_000_000 then Hashtbl.replace t.problems f "analysis step limit";
  if Sys.getenv_opt "SS_TRACE" <> None then
    Printf.eprintf "&%x: %d steps, %d addresses, %d states, %.2fs\n%!" f !steps (Hashtbl.length first)
      (Hashtbl.length states) (Sys.time () -. t0);
  Hashtbl.replace t.fn_size f (Hashtbl.length first);
  !summary

let run t entries =
  List.iter (fun e -> Hashtbl.replace t.roots e ()) entries;
  List.iter (add_func t) entries;
  let rounds = ref 0 in
  (* New functions first (most recent first), then callers whose callees'
     summaries changed. *)
  while (not (Stack.is_empty t.fresh) || not (Queue.is_empty t.work)) && !rounds < 100_000
        && not (exhausted ()) do
    incr rounds;
    if not (Stack.is_empty t.fresh) then begin
      let f = Stack.pop t.fresh in
      Hashtbl.remove t.queued f;
      ensure_analysed t f
    end else begin
      let f = Queue.pop t.work in
      Hashtbl.remove t.queued f;
      update t f
    end
  done

(* Copy loops are found during the analysis; jumps into a copy that were
   met before the copy was recognised are only resolved by running again
   with the copies known. *)
(* Variable values for the next round: the constants stored to each
   variable; any unknown store makes it Top. The variable's initial image
   value is not included: it is often 0 ("not set yet"), and treating a data
   variable's initial contents as one of its values makes pointers out of
   them (seen in Galactic Dan: plot-routine screen pointers turned into
   addresses inside the image). Unsound for a variable read before any
   store; recorded as such in PHASE5.md. *)
(* A symbolic store in a function nobody calls (an entry point, or code
   reached some other way) stores something unknown. Zero among other
   values is dropped: a setter called with 0 for "none" or "the default"
   (teq r0,#0 ; addeq r0,pc,#k ; str r0,[pc,#v]) stores 0 only on the path
   the test rules out, and a pointer variable's 0 means "not set". *)
let next_var_known t =
  let h = Hashtbl.create 64 in
  Hashtbl.iter (fun f l ->
      match Hashtbl.find_opt t.callers f with
      | Some cs when Hashtbl.length cs > 0 -> ()
      | _ -> List.iter (fun (w, _) -> Hashtbl.replace t.var_stores w Top) l) t.sym_stores;
  (match Sys.getenv_opt "SS_DEBUG_VAR" with
   | Some x -> let w = int_of_string ("0x" ^ x) in
     Printf.eprintf "var &%x: stored %s; symbolic in %s\n%!" w
       (match Hashtbl.find_opt t.var_stores w with Some v -> string_of_v v | None -> "-")
       (String.concat " " (Hashtbl.fold (fun f l acc ->
            List.fold_left (fun acc (w', v) -> if w' = w then Printf.sprintf "&%x:%s(%d callers)" f (string_of_v v)
                (match Hashtbl.find_opt t.callers f with Some c -> Hashtbl.length c | None -> 0) :: acc else acc) acc l)
            t.sym_stores []))
   | None -> ());
  Hashtbl.iter (fun w v -> Hashtbl.replace h w (match v with
      | Consts s when IS.cardinal s > 1 && IS.mem 0 s -> Consts (IS.remove 0 s)
      | Consts _ -> v
      | _ -> Top)) t.var_stores;
  h

let same_vars a b =
  Hashtbl.length a = Hashtbl.length b
  && Hashtbl.fold (fun k v acc -> acc && Hashtbl.find_opt b k = Some v) a true

(* Variables whose values keep changing from round to round are widened to
   Top for good, or the rounds go on to their limit (Zool, every round):
   - one that goes back to the values it had two rounds before: its stores
     depend on what the round knows of it (Zool's &25410: a constant one
     round, Top the next);
   - one that changes a second time with no value inside the image: a
     counter, gaining a value every round (Zool's &b0fc: sub r0,r0,#1).
   A variable holding addresses in the image is left to grow: code
   pointers found round by round (Pushy II's dispatch variables). *)
let widen_vars img changes before vars vars' =
  let outside = function
    | Some (Consts s) -> IS.for_all (fun a -> not (Image.inside img (a land lnot 3))) s
    | _ -> true in
  Hashtbl.iter (fun w v ->
      if v = -1 then Hashtbl.replace vars' w Top
      else if Hashtbl.find_opt vars w <> Hashtbl.find_opt vars' w then begin
        let flips = Hashtbl.mem before w && Hashtbl.find_opt before w = Hashtbl.find_opt vars' w in
        let counter = v >= 1 && outside (Hashtbl.find_opt vars w) && outside (Hashtbl.find_opt vars' w) in
        if flips || counter then (Hashtbl.replace changes w (-1); Hashtbl.replace vars' w Top)
        else Hashtbl.replace changes w (v + 1)
      end) (Hashtbl.copy changes);
  Hashtbl.iter (fun w _ ->
      if not (Hashtbl.mem changes w) && Hashtbl.find_opt vars w <> Hashtbl.find_opt vars' w then
        Hashtbl.replace changes w 1) (Hashtbl.copy vars')

(* Copy loops and variable values are found during the analysis; the
   analysis is repeated with what the previous round found until neither
   changes. *)
let spider img entries =
  let changes = Hashtbl.create 16 in
  let rec go before copies vars n =
    let t = create ~copies ~var_known:vars img in
    run t entries;
    let vars' = next_var_known t in
    widen_vars img changes before vars vars';
    if n < 8 && not (exhausted ())
       && (List.length t.copies > List.length copies || (features.memory && not (same_vars vars vars')))
    then go vars t.copies (if features.memory then vars' else Hashtbl.create 1) (n + 1) else t
  in
  go (Hashtbl.create 1) [] (Hashtbl.create 1) 0

(* Phase 3b: address-taken entry points. Code addresses passed to SWIs or
   stored to memory by code already found are candidates, with evidence:
   - strong: passed in a register a known SWI treats as a code pointer
     (OS_Claim r1, ... - see Riscos), or an entry of a block of entry
     points a known SWI is given (Sound_InstallVoice r0: the voice
     generator header), which may be a single instruction;
   - data: only ever passed where a known SWI expects a data pointer
     (OS_Word r1, ...) - rejected without analysis;
   - weak: stored to memory, or passed to a SWI nothing is known about.
   Each candidate not already code or data is analysed on its own. It is
   accepted if that analysis meets no problem, doesn't run into words the
   main analysis classified as data and runs at least min_insns
   instructions; a weak candidate must also run min_insns_weak, contain no
   word below &10000 (andeq r0,r0,... - zeros and small integers, in
   practice data) and no word that code
   stores to as a variable, and must not start with two words of ASCII
   text. Accepted candidates become entry points and the
   whole analysis is redone, until nothing new is accepted. *)
type verdict = Accepted | Rejected of string

let min_insns = 3
let min_insns_weak = 4

(* A word that looks like ASCII text: every byte printable or NUL, at least
   three printable. *)
let texty w =
  let bytes = List.init 4 (fun k -> (w lsr (8 * k)) land 0xFF) in
  List.for_all (fun b -> b = 0 || (b >= 0x20 && b < 0x7F) || b = 10 || b = 13) bytes
  && List.length (List.filter (fun b -> b >= 0x20 && b < 0x7F) bytes) >= 3

let ends_with s suf =
  let n = String.length s and k = String.length suf in
  n >= k && String.sub s (n - k) k = suf

let spider_with_address_taken img entries =
  let decided : (int, verdict) Hashtbl.t = Hashtbl.create 64 in
  let rec loop entries =
    let t = spider img entries in
    (* a program linked with the C library: every Norcroft APCS function
       entry (mov ip,sp ; stmdb sp!,{...fp,ip,lr,pc} ; sub fp,ip,#4) is a
       candidate - C reaches functions through pointers passed as
       arguments, stored in structures, ... *)
    if features.clib && Hashtbl.length t.libvec > 0 then begin
      let rec scan a =
        if Image.inside img (a + 8) then begin
          if Image.word img a = 0xE1A0C00D && Image.word img (a + 4) land 0xFFFFD800 = 0xE92DD800
             && Image.word img (a + 8) = 0xE24CB004 && not (Hashtbl.mem t.code a) then
            Hashtbl.replace t.cands a ((a, "APCS function entry code") ::
                                       Option.value (Hashtbl.find_opt t.cands a) ~default:[]);
          scan (a + 4)
        end in
      scan img.Image.base
    end;
    let fresh = Hashtbl.fold (fun c _ acc ->
        if Hashtbl.mem decided c || Hashtbl.mem t.code c || Hashtbl.mem t.data c then acc else c :: acc)
        t.cands [] in
    let accepted = List.filter (fun c -> not (exhausted ()) &&
        let ev = List.map snd (Hashtbl.find t.cands c) in
        (* an entry of an OS interface block (voice generator header...):
           certain, and often a single instruction (a branch, a return) *)
        let entry = List.exists (fun h -> ends_with h " entry") ev in
        let strong = entry || List.exists (fun h -> ends_with h " code") ev in
        let data_only = List.for_all (fun h -> ends_with h " data") ev in
        let tc = spider img [ c ] in
        (* a word whose top 16 bits are zero is andeq r0, r0, <small>: data
           in practice (zero, small integers) *)
        let zero_or_var () =
          Hashtbl.fold (fun a () acc -> acc || Image.word img a < 0x10000 || Hashtbl.mem t.vars a) tc.code false in
        let verdict =
          if data_only then Rejected "only passed as an OS data pointer"
          else if Hashtbl.length tc.problems > 0 then
            Rejected (snd (List.hd (List.sort compare (Hashtbl.fold (fun a m acc -> (a, m) :: acc) tc.problems []))))
          else if Hashtbl.length tc.code < min_insns && not entry then Rejected "too short"
          else if Hashtbl.fold (fun a () acc -> acc || Hashtbl.mem t.data a) tc.code false then
            Rejected "runs into data"
          else if not strong && Hashtbl.length tc.code < min_insns_weak then Rejected "too short (weak evidence)"
          else if not strong && zero_or_var () then Rejected "zero word or variable (weak evidence)"
          else if not strong && Image.inside img (c + 4) && texty (Image.word img c) && texty (Image.word img (c + 4))
          then Rejected "looks like text (weak evidence)"
          else Accepted in
        Hashtbl.replace decided c verdict;
        verdict = Accepted) (List.sort compare fresh) in
    if accepted = [] || exhausted () then t else loop (entries @ accepted)
  in
  let t = loop entries in
  (t, decided)

(* ------------------------------------------------------------------ output *)

let keys h = List.sort compare (Hashtbl.fold (fun k _ acc -> k :: acc) h [])

let json_ints l = "[" ^ String.concat "," (List.map string_of_int l) ^ "]"

let to_json ?(extra = []) t ~entries oc =
  let p fmt = Printf.fprintf oc fmt in
  p "{\"base\":%d,\"size\":%d,\n\"entries\":%s,\n\"funcs\":%s,\n\"code\":%s,\n\"data\":%s,\n"
    t.img.Image.base t.img.size (json_ints entries) (json_ints (keys t.funcs))
    (json_ints (keys t.code)) (json_ints (keys t.data));
  p "\"returns\":[%s],\n" (String.concat ","
    (List.map (fun a -> Printf.sprintf "[%d,%s]" a (json_ints (IS.elements (Hashtbl.find t.ret_sites a))))
       (keys t.ret_sites)));
  p "\"assumed_returns\":%s,\n" (json_ints (keys t.assumed));
  p "\"extern_calls\":%s,\n" (json_ints (keys extern_targets));
  p "\"assumed_balanced\":%s,\n" (json_ints (keys t.balanced));
  p "\"promoted\":%s,\n" (json_ints (keys t.promoted));
  p "\"unresolved\":%s,\n" (json_ints (keys t.unresolved));
  p "\"const_jumps\":[%s],\n" (String.concat ","
    (List.map (fun a -> Printf.sprintf "[%d,%s]" a (json_ints (IS.elements (Hashtbl.find t.const_jumps a))))
       (keys t.const_jumps)));
  p "\"summaries\":[%s],\n" (String.concat ",\n"
    (List.map (fun f ->
         let s = Hashtbl.find t.summaries f in
         Printf.sprintf "[%d,[%s]]" f
           (String.concat "," (List.map (fun e ->
                (* r12 too when not preserved: a program's workspace
                   pointer is usually kept there *)
                let r12 = match e.st.regs.(12) with
                  | Sym (Reg0 12, 0) -> "" | v -> " r12=" ^ string_of_v v in
                Printf.sprintf "\"%s\"" (shape_of_exit e ^ " sp=" ^ string_of_v e.st.regs.(13) ^ r12)) s)))
       (keys t.summaries)));
  p "\"tables\":[%s],\n" (String.concat ","
    (List.map (fun a -> let how, n = Hashtbl.find t.tables a in Printf.sprintf "[%d,\"%s\",%d]" a how n)
       (keys t.tables)));
  p "\"follow\":%s,\n" (json_ints (keys t.follow));
  p "\"code_pointer_vars\":[%s],\n" (String.concat ","
    (List.filter_map (fun w -> match Hashtbl.find t.var_known w with
         | Consts s -> Some (Printf.sprintf "[%d,%s]" w (json_ints (IS.elements s)))
         | _ -> None) (keys t.var_known)));
  p "\"smc\":[%s],\n" (String.concat ","
    (List.filter_map (fun w -> if Hashtbl.mem t.code w then
                         Some (Printf.sprintf "[%d,%s]" w (json_ints (List.sort_uniq compare (Hashtbl.find t.code_writes w))))
                       else None) (keys t.code_writes)));
  p "\"conflicts\":[%s],\n" (String.concat ","
    (List.filter_map (fun w ->
         (* reads made by a recognised copy loop are expected *)
         let in_copy_loop site = List.exists (fun c -> site <= c.loop_at && site >= c.loop_at - 64) t.copies in
         let readers = List.filter (fun x -> not (in_copy_loop x)) (Hashtbl.find t.data_reads w) in
         if Hashtbl.mem t.code w && readers <> [] then
           Some (Printf.sprintf "[%d,%s]" w (json_ints (List.sort_uniq compare readers)))
         else None) (keys t.data_reads)));
  p "\"copies\":[%s],\n" (String.concat ","
    (List.map (fun c -> Printf.sprintf "{\"src\":%d,\"dst\":%d,\"len\":%d,\"loop\":%d}" c.src c.dst c.len c.loop_at)
       t.copies));
  p "\"candidates\":[%s],\n" (String.concat ",\n"
    (List.map (fun c ->
         Printf.sprintf "[%d,[%s]]" c (String.concat "," (List.map (fun (a, how) ->
             Printf.sprintf "[%d,\"%s\"]" a how) (Hashtbl.find t.cands c))))
       (keys t.cands)));
  p "\"owner\":[%s],\n" (String.concat ","
    (List.map (fun a -> Printf.sprintf "[%d,%d]" a (Hashtbl.find t.owner a)) (keys t.owner)));
  p "\"linked\":%s,\n" (json_ints (keys t.linked));
  p "\"widened\":%s,\n" (json_ints (keys t.widened));
  p "\"inlined_calls\":%s,\n" (json_ints (keys t.inlined));
  p "\"smc_values\":[%s],\n" (String.concat ","
    (List.filter_map (fun w -> match Hashtbl.find_opt t.var_stores w with
         | Some (Consts s) when Hashtbl.mem t.code w -> Some (Printf.sprintf "[%d,%s]" w (json_ints (IS.elements s)))
         | _ -> None) (keys t.var_stores)));
  List.iter (fun (k, v) -> p "%s:%s,\n" (Json.quote k) v) extra;
  p "\"problems\":[%s]}\n" (String.concat ",\n"
    (List.map (fun a -> Printf.sprintf "[%d,%s]" a (Json.quote (Hashtbl.find t.problems a)))
       (keys t.problems)))
