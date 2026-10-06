(* superspider: code discovery for raw ARM2/ARM3 RISC OS binaries.

   superspider decode IMAGE BASE
       one line per word: address, word, decoded fields (for cross-checking
       the decoder against capstone; see phase2/crosscheck_decoder.py)
   superspider disasm IMAGE BASE [FROM [TO]]
   superspider spider IMAGE BASE [--module] [--exec ADDR] [--entry ADDR]... [--roots FILE]...
                      [--global-r12] [-o OUT.json]
       S0 recursive descent.
       --roots FILE: more entry points, one address per line (blank lines and
       anything after '#' ignored) - e.g. the gap entries a run of the
       recompiled program found (tools/gap_roots.py), so each run's findings
       feed the next analysis.
   superspider s1 IMAGE BASE [same options]
       S1: return-address and stack abstract interpretation.
   superspider s1b IMAGE BASE [same options]
       S1 plus address-taken entry points (phase 3b) and, with --module,
       the module's *command table entries. Entry points: BASE for an absolute image (or
       its execution address, --exec, when that is not its load address), the module
       header's code entries with --module, plus any --entry. *)

open Superspider

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

let usage () =
  prerr_endline "usage: superspider (decode|disasm|spider) IMAGE BASE [options]";
  exit 2

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
  | ("spider" | "s1" | "s1b") as stage :: path :: base :: rest ->
    let img = Image.load path (int_of_hex base) in
    let exec = ref img.base in
    let rec opts entries out modl = function
      | "--module" :: r -> opts entries out true r
      | "--entry" :: a :: r -> opts (int_of_hex a :: entries) out modl r
      | "--roots" :: f :: r -> opts (List.rev_append (read_roots f) entries) out modl r
      | "--exec" :: a :: r -> exec := int_of_hex a; opts entries out modl r
      | "--global-r12" :: r -> S1.global_r12 := true; opts entries out modl r
      | "-o" :: f :: r -> opts entries (Some f) modl r
      | [] -> List.rev entries, out, modl
      | x :: _ -> prerr_endline ("unknown option " ^ x); usage () in
    let extra, out, modl = opts [] None false rest in
    let given =
      if modl then
        List.map snd (Image.module_header_entries img)
        @ (if stage = "s1b" then List.map snd (Image.module_command_entries img) else [])
      else [ !exec ] in
    let extra = List.sort_uniq compare (List.filter (fun e -> not (List.mem e given)) extra) in
    let entries = given @ extra in
    let oc = match out with Some f -> open_out f | None -> stdout in
    if stage = "spider" then begin
      let t = Spider.spider img entries in
      Spider.to_json t ~entries oc;
      Printf.eprintf "code %d words, %d functions, %d data words, %d problems\n"
        (Hashtbl.length t.code) (Hashtbl.length t.funcs) (Hashtbl.length t.data)
        (List.length t.problems)
    end else begin
      let t, decided =
        if stage = "s1b" then S1.spider_with_address_taken img entries
        else S1.spider img entries, Hashtbl.create 1 in
      S1.to_json t ~entries oc;
      if stage = "s1b" then begin
        (* verdicts as a trailing JSON document line, read by the scripts *)
        let l = List.sort compare (Hashtbl.fold (fun c v acc -> (c, v) :: acc) decided []) in
        Printf.fprintf oc "{\"address_taken\":[%s]}\n" (String.concat ",\n"
          (List.map (fun (c, v) -> Printf.sprintf "[%d,%s]" c
              (match v with S1.Accepted -> "\"accepted\""
                          | S1.Rejected why -> Printf.sprintf "\"rejected: %s\"" (String.escaped why))) l));
        Printf.eprintf "address-taken: %d accepted of %d candidates examined\n"
          (List.length (List.filter (fun (_, v) -> v = S1.Accepted) l)) (List.length l)
      end;
      Printf.eprintf "code %d words, %d functions, %d data words, %d unresolved, %d assumed returns, %d balance assumptions, %d problems\n"
        (Hashtbl.length t.code) (Hashtbl.length t.funcs) (Hashtbl.length t.data)
        (Hashtbl.length t.unresolved) (Hashtbl.length t.assumed) (Hashtbl.length t.balanced)
        (Hashtbl.length t.problems);
      (* SS_UNRESOLVED=1: each unresolved site, its function and why *)
      if Sys.getenv_opt "SS_UNRESOLVED" <> None then
        List.iter (fun (a, why) ->
            Printf.eprintf "unresolved &%x (in &%x): %s\n" a
              (Option.value (Hashtbl.find_opt t.owner a) ~default:0) why)
          (List.sort compare (Hashtbl.fold (fun a w acc -> (a, w) :: acc) t.unresolved []))
    end;
    if out <> None then close_out oc
  | _ -> usage ()
