(* superspider: code discovery and static recompilation for raw ARM2/ARM3
   RISC OS binaries.

   superspider analyse IMAGE BASE [options]
       Find the code (S1: return-address and stack abstract interpretation
       from the entry points), and write the analysis (-o) and/or the C
       translation (--c). See usage below.
   superspider gen IMAGE BASE ANALYSIS.json --c DIR [C options]
       The C translation of an analysis saved by analyse -o.

   Older stages, kept for the phase scripts (their JSON is what analyse -o
   writes, apart from the address-taken verdicts):
   superspider spider IMAGE BASE [entry options]   S0 recursive descent
   superspider s1 IMAGE BASE [entry options]       S1, analyse --full without address-taken
   superspider s1b IMAGE BASE [entry options]      analyse --full; the verdicts follow as a second JSON document
   superspider decode IMAGE BASE                   one line per word, for cross-checking the decoder
   superspider disasm IMAGE BASE [FROM [TO]] *)

open Superspider

let usage_text = {|usage:
  superspider analyse IMAGE BASE [options]
  superspider gen IMAGE BASE ANALYSIS.json --c DIR [C options]
  superspider (spider|s1|s1b) IMAGE BASE [entry options] [-o OUT.json]
  superspider disasm IMAGE BASE [FROM [TO]]
  superspider decode IMAGE BASE

entry points (BASE, or --exec, for an absolute; the header's for a module):
  --module          IMAGE is a relocatable module (its header entries, *commands)
  --exec ADDR       execution address, when it isn't BASE
  --entry ADDR      another entry point (repeatable)
  --roots FILE      more entry points, one address per line, '#' comments (repeatable);
                    e.g. tools/gap_roots.py's, from a recompiled program's --trace-gaps run
  --extern FROM-TO  code of another image there (repeatable): calls into it return, with
                    r0-r12 unknown; their targets are listed (extern_calls) as entry
                    points for that image's analysis

analysis (the core always runs: returns and stack through summaries, constant
jumps, OS_WriteS, hand-linked calls, stack balance):
  --full            all the mechanisms below except global-r12
  --with A,B..      turn mechanisms on:
                      tables         bounded computed jumps, jump tables, tables of cases
                      memory         values carried in variables (repeated rounds); setters
                      copies         code run from copies made by copy loops
                      fields         jumps through object fields (handler objects, menus)
                      inline         small dispatch stubs analysed inline at each call
                      longjmp        stack pointers saved and restored elsewhere
                      dispatch       multi-way dispatch with lr set: each target a function
                      address-taken  code addresses passed to SWIs or stored: analysed, accepted
                                     as entry points if they look like code
                      global-r12     r12 is a workspace pointer all through (not for every program)
  --without A,B..   turn mechanisms off (e.g. after --full)
  --global-r12      = --with global-r12
  --budget N        stop after N instruction steps in all (default 100000000); the
                    result is then incomplete (code not found runs interpreted)

output:
  -o FILE           the analysis as JSON (what gen reads)
  --c DIR           the C translation, into DIR (code*.c, HEADER.h, entries.c)

C options (gen, or analyse with --c):
  --prefix P        function names P_<addr> (default F)
  --tabprefix T     table names: T_entries, T_codemap, T_image (default recomp)
  --files N         number of code*.c files (default 16)
  --header NAME     the generated header, NAME.h (default gen)
  --covtag C        the coverage recorder's tag for this image
  --leaders all|dispatch
                    dispatch leaders: every code word (default), or only where control
                    is known to arrive indirectly (smaller, needs complete roots)
  --pcbias          PC-derived values relative to the runtime's pc_bias (an image
                    that runs from a copy of itself)
  --range FROM-TO   only the code in [FROM, TO), as an image of its own: an overlay
                    analysed as part of the program it is loaded beside (an image
                    of both), the program's code translated separately
  options may also be written --name=value
|}

let usage () = prerr_string usage_text; exit 2

let int_of_hex s =
  let s = if String.length s > 0 && s.[0] = '&' then "0x" ^ String.sub s 1 (String.length s - 1) else s in
  let s = if String.length s > 1 && (String.sub s 0 2 = "0x" || String.sub s 0 2 = "0X") then s else "0x" ^ s in
  int_of_string s

(* A roots file: one address per line; '#' starts a comment. *)
let read_roots path =
  let ic = open_in path in
  let rec go acc =
    match input_line ic with
    | exception End_of_file -> close_in ic; List.rev acc
    | l ->
      let l = match String.index_opt l '#' with Some k -> String.sub l 0 k | None -> l in
      match String.split_on_char ' ' (String.trim l) |> List.filter (( <> ) "") with
      | [] -> go acc
      | a :: _ -> go (int_of_hex a :: acc) in
  go []

let ints l = String.concat "," (List.map string_of_int l)

let decode_line (i : Arm2.t) =
  let open Arm2 in
  let kind, extra = match i.kind with
    | Dp { op; s; rd; rn; op2 } ->
      "dp", Printf.sprintf "op=%s s=%b rd=%d rn=%d imm=%s" (string_of_dp_op op) s rd rn
        (match op2 with Imm (v, _) -> string_of_int v | Reg _ -> "-")
    | Mul { acc; _ } -> (if acc then "mla" else "mul"), ""
    | Swp _ -> "swp", ""
    | Mem { load; byte; pre; up; wb; rd; rn; off } ->
      (if load then "ldr" else "str"),
      Printf.sprintf "byte=%b pre=%b up=%b wb=%b rd=%d rn=%d imm=%s" byte pre up wb rd rn
        (match off with Off_imm n -> string_of_int n | Off_reg _ -> "-")
    | Block { load; psr; rn; regs; wb; _ } ->
      (if load then "ldm" else "stm"), Printf.sprintf "rn=%d regs=%d wb=%b psr=%b" rn regs wb psr
    | Branch { link; target } -> (if link then "bl" else "b"), Printf.sprintf "target=%d" target
    | Swi n -> "swi", Printf.sprintf "n=%d" n
    | Cop { cp; _ } -> "cop", Printf.sprintf "cp=%d" cp
    | Undefined _ -> "undef", "" in
  Printf.sprintf "%d %d %s cond=%s pc=%b plausible=%b defs=%s uses=%s %s"
    i.addr i.word kind (match i.cond with AL -> "al" | c -> string_of_cond c)
    (writes_pc i) (plausible i) (ints (defs i)) (ints (uses i)) extra

(* --name=value -> --name value *)
let split_eq args =
  List.concat_map (fun a ->
      if String.length a > 2 && String.sub a 0 2 = "--" then
        match String.index_opt a '=' with
        | Some k -> [ String.sub a 0 k; String.sub a (k + 1) (String.length a - k - 1) ]
        | None -> [ a ]
      else [ a ]) args

type opts = {
  mutable modl : bool;
  mutable exec : int option;
  mutable extra : int list;
  mutable out : string option;
  mutable cdir : string option;
  mutable address_taken : bool;
  mutable gen : Gen.options;
}

let parse_opts ~what rest =
  let o = { modl = false; exec = None; extra = []; out = None; cdir = None; address_taken = false;
            gen = Gen.default_options } in
  let mechanisms on l =
    List.iter (fun n ->
        if n = "address-taken" then o.address_taken <- on
        else if List.mem n S1.feature_names then S1.set_feature n on
        else (prerr_endline ("unknown mechanism " ^ n); usage ()))
      (String.split_on_char ',' l |> List.filter (( <> ) "")) in
  let gen_only () = if what = `Legacy then usage () in
  let rec go = function
    | "--module" :: r -> o.modl <- true; go r
    | "--entry" :: a :: r -> o.extra <- int_of_hex a :: o.extra; go r
    | "--roots" :: f :: r -> o.extra <- List.rev_append (read_roots f) o.extra; go r
    | "--extern" :: x :: r ->
      (match String.split_on_char '-' x with
       | [ lo; hi ] -> S1.externs := (int_of_hex lo, int_of_hex hi) :: !S1.externs
       | _ -> usage ());
      go r
    | "--exec" :: a :: r -> o.exec <- Some (int_of_hex a); go r
    | "--global-r12" :: r -> S1.set_feature "global-r12" true; go r
    | "-o" :: f :: r -> o.out <- Some f; go r
    | "--full" :: r when what = `Analyse -> S1.set_full (); o.address_taken <- true; go r
    | "--with" :: l :: r when what = `Analyse -> mechanisms true l; go r
    | "--without" :: l :: r when what = `Analyse -> mechanisms false l; go r
    | "--budget" :: n :: r when what = `Analyse -> S1.budget := int_of_string n; go r
    | "--c" :: d :: r -> gen_only (); o.cdir <- Some d; go r
    | "--prefix" :: p :: r -> gen_only (); o.gen <- { o.gen with prefix = p }; go r
    | "--tabprefix" :: p :: r -> gen_only (); o.gen <- { o.gen with tabprefix = p }; go r
    | "--files" :: n :: r -> gen_only (); o.gen <- { o.gen with files = max 1 (int_of_string n) }; go r
    | "--header" :: n :: r -> gen_only (); o.gen <- { o.gen with header = n }; go r
    | "--covtag" :: c :: r -> gen_only (); o.gen <- { o.gen with covtag = c }; go r
    | "--pcbias" :: r -> gen_only (); o.gen <- { o.gen with pcbias = true }; go r
    | "--banner" :: b :: r -> gen_only (); o.gen <- { o.gen with banner = b }; go r
    | "--range" :: x :: r ->
      gen_only ();
      (match String.split_on_char '-' x with
       | [ lo; hi ] -> o.gen <- { o.gen with range = Some (int_of_hex lo, int_of_hex hi) }
       | _ -> usage ());
      go r
    | "--leaders" :: l :: r ->
      gen_only ();
      let l = match l with
        | "all" -> Gen.All | "dispatch" | "ss" -> Gen.Dispatch
        | _ -> prerr_endline ("unknown --leaders " ^ l); usage () in
      o.gen <- { o.gen with leaders = l }; go r
    | [] -> ()
    | x :: _ -> prerr_endline ("unknown option " ^ x); usage () in
  go (split_eq rest);
  o

(* The entry points: the module header's (and *commands', with
   address-taken), or the execution address; then the extra ones. *)
let entry_points img o ~commands =
  let given =
    if o.modl then
      List.map snd (Image.module_header_entries img)
      @ (if commands then List.map snd (Image.module_command_entries img) else [])
    else [ Option.value o.exec ~default:img.Image.base ] in
  let extra = List.sort_uniq compare (List.filter (fun e -> not (List.mem e given)) o.extra) in
  given @ extra

let verdicts_json decided =
  let l = List.sort compare (Hashtbl.fold (fun c v acc -> (c, v) :: acc) decided []) in
  "[" ^ String.concat ",\n" (List.map (fun (c, v) -> Printf.sprintf "[%d,%s]" c
      (match v with S1.Accepted -> "\"accepted\"" | S1.Rejected why -> Json.quote ("rejected: " ^ why))) l) ^ "]"

let summary_line (t : S1.t) =
  Printf.sprintf "code %d words, %d functions, %d data words, %d unresolved, %d assumed returns, %d balance assumptions, %d problems"
    (Hashtbl.length t.code) (Hashtbl.length t.funcs) (Hashtbl.length t.data)
    (Hashtbl.length t.unresolved) (Hashtbl.length t.assumed) (Hashtbl.length t.balanced)
    (Hashtbl.length t.problems)

(* SS_UNRESOLVED=1: each unresolved site, its function and why *)
let list_unresolved (t : S1.t) =
  if Sys.getenv_opt "SS_UNRESOLVED" <> None then
    List.iter (fun (a, why) ->
        Printf.eprintf "unresolved &%x (in &%x): %s\n" a (Option.value (Hashtbl.find_opt t.owner a) ~default:0) why)
      (List.sort compare (Hashtbl.fold (fun a w acc -> (a, w) :: acc) t.unresolved []))

let gen_c img dir o inp =
  let c = Gen.create o.gen inp ~data:img.Image.data ~base:img.Image.base in
  prerr_endline (Gen.write c dir)

let analyse path base rest =
  S1.budget := 100_000_000;
  let o = parse_opts ~what:`Analyse rest in
  if o.out = None && o.cdir = None then (prerr_endline "analyse: nothing to write (-o and/or --c)"; usage ());
  let img = Image.load path base in
  let entries = entry_points img o ~commands:o.address_taken in
  let t, decided =
    if o.address_taken then S1.spider_with_address_taken img entries else S1.spider img entries, Hashtbl.create 1 in
  let complete = not (S1.exhausted ()) in
  Option.iter (fun p ->
      let oc = open_out p in
      S1.to_json t ~entries oc ~extra:[
        ("mechanisms", "[" ^ String.concat "," (List.map Json.quote
                                                  (S1.enabled_features () @ if o.address_taken then [ "address-taken" ] else [])) ^ "]");
        ("address_taken", verdicts_json decided);
        ("steps", string_of_int !S1.steps_taken);
        ("complete", string_of_bool complete) ];
      close_out oc) o.out;
  if o.address_taken then
    Printf.eprintf "address-taken: %d accepted of %d candidates examined\n"
      (Hashtbl.fold (fun _ v n -> if v = S1.Accepted then n + 1 else n) decided 0) (Hashtbl.length decided);
  prerr_endline (summary_line t);
  if Hashtbl.length t.widened > 0 then
    Printf.eprintf "%d summaries widened (they kept changing: see \"widened\" in the analysis)\n"
      (Hashtbl.length t.widened);
  Printf.eprintf "%d steps%s\n" !S1.steps_taken
    (if complete then "" else Printf.sprintf " - INCOMPLETE: the budget of %d steps ran out" !S1.budget);
  list_unresolved t;
  Option.iter (fun d -> gen_c img d o (Gen.of_s1 t ~entries)) o.cdir

let legacy stage path base rest =
  let o = parse_opts ~what:`Legacy rest in
  let img = Image.load path base in
  let oc = match o.out with Some f -> open_out f | None -> stdout in
  let entries = entry_points img o ~commands:(stage = "s1b") in
  if stage = "spider" then begin
    let t = Spider.spider img entries in
    Spider.to_json t ~entries oc;
    Printf.eprintf "code %d words, %d functions, %d data words, %d problems\n"
      (Hashtbl.length t.code) (Hashtbl.length t.funcs) (Hashtbl.length t.data) (List.length t.problems)
  end else begin
    S1.set_full ();
    let t, decided =
      if stage = "s1b" then S1.spider_with_address_taken img entries
      else S1.spider img entries, Hashtbl.create 1 in
    S1.to_json t ~entries oc;
    if stage = "s1b" then begin
      (* verdicts as a trailing JSON document line, read by the scripts *)
      Printf.fprintf oc "{\"address_taken\":%s}\n" (verdicts_json decided);
      Printf.eprintf "address-taken: %d accepted of %d candidates examined\n"
        (Hashtbl.fold (fun _ v n -> if v = S1.Accepted then n + 1 else n) decided 0) (Hashtbl.length decided)
    end;
    prerr_endline (summary_line t);
    list_unresolved t
  end;
  if o.out <> None then close_out oc

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  match args with
  | "decode" :: path :: base :: _ ->
    let img = Image.load path (int_of_hex base) in
    let a = ref img.base in
    while Image.inside img !a do
      print_endline (decode_line (Image.decode img !a));
      a := !a + 4
    done
  | "disasm" :: path :: base :: rest ->
    let img = Image.load path (int_of_hex base) in
    let lo, hi = match rest with
      | [ f ] -> int_of_hex f, int_of_hex f + 64
      | f :: t :: _ -> int_of_hex f, int_of_hex t
      | [] -> img.base, img.base + img.size in
    let a = ref (lo land lnot 3) in
    while !a < hi && Image.inside img !a do
      let i = Image.decode img !a in
      Printf.printf "%08x  %08x  %s\n" !a i.word (Arm2.to_string i);
      a := !a + 4
    done
  | ("analyse" | "analyze") :: path :: base :: rest -> analyse path (int_of_hex base) rest
  | "gen" :: path :: base :: json :: rest ->
    let o = parse_opts ~what:`Gen rest in
    (match o.cdir with
     | None -> prerr_endline "gen: --c DIR is required"; usage ()
     | Some d ->
       let img = Image.load path (int_of_hex base) in
       gen_c img d o (Gen.of_json (Json.read_file json)))
  | ("spider" | "s1" | "s1b") as stage :: path :: base :: rest -> legacy stage path (int_of_hex base) rest
  | _ -> usage ()
