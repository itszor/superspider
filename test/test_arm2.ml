open Superspider
open Arm2

let d ?(addr = 0x8000) w = decode addr w

let check_str name addr w expect =
  Alcotest.(check string) name expect (to_string (decode addr w))

let check_bool name b = Alcotest.(check bool) name true b

let ints = Alcotest.(list int)

let test_text () =
  (* words taken from the Lemmings and Galactic Dan images *)
  check_str "thunk bic" 0x8014 0xE3CEE3FF "bic lr, lr, #&fc000003";
  check_str "thunk ldr" 0x8018 0xE49E0004 "ldr r0, [lr], #&4";
  check_str "return" 0x801c 0xE1A0F00E "mov pc, lr";
  check_str "push pc" 0x27a60 0xE92D8000 "stmdb sp!, {pc}";
  check_str "NV filler" 0x27a64 0xF1A00000 "movnv r0, r0";
  check_str "pop pc" 0x8010 0xE8BD8000 "ldmia sp!, {pc}";
  check_str "teqp" 0x1802f1c 0xE33FF382 "teqp pc, #&8000002";
  check_str "orrs pc" 0x1802f18 0xE390F002 "orrs pc, r0, #&2";
  check_str "branch table" 0x1800574 0x308FF10B "addcc pc, pc, r11, lsl #2";
  check_str "address table" 0x9434 0xE79BF104 "ldr pc, [r11, r4, lsl #2]";
  check_str "bl" 0xe378 0xEBFFE73A "bl &8068";
  check_str "swi" 0x8000 0xEF000006 "swi &6";
  check_str "mul" 0x8a2c 0xE0030390 "mul r3, r0, r3";
  check_str "ldm decrement-before" 0x1a7f4 0xE93D0002 "ldmdb sp!, {r1}"

let test_semantics () =
  let i = d 0xE49E0004 in
  Alcotest.check ints "ldr post-index writes rd and base" [ 0; 14 ] (defs i);
  check_bool "mov pc,lr writes pc" (writes_pc (d 0xE1A0F00E));
  check_bool "mov pc,lr keeps psr" (not (restores_psr (d 0xE1A0F00E)));
  check_bool "movs pc,lr restores psr" (restores_psr (d 0xE1B0F00E));
  check_bool "ldm ^ with pc restores psr" (restores_psr (d 0xE8FD8000));
  check_bool "teqp writes no pc" (not (writes_pc (d 0xE33FF382)));
  check_bool "orrs pc writes pc" (writes_pc (d 0xE390F002));
  check_bool "stmdb {pc} writes no pc" (not (writes_pc (d 0xE92D8000)));
  check_bool "NV decodes but never executes" (not (executes (d 0xF1A00000)));
  check_bool "bl writes lr" (List.mem 14 (defs (d 0xEBFFE73A)));
  (match (d ~addr:0xe378 0xEBFFE73A).kind with
   | Branch { link = true; target } -> Alcotest.(check int) "bl target" 0x8068 target
   | _ -> Alcotest.fail "not a bl");
  (match (d 0xE3CEE3FF).kind with
   | Dp { op2 = Imm (v, _); _ } -> Alcotest.(check int) "rotated immediate" 0xFC000003 v
   | _ -> Alcotest.fail "not dp imm")

let test_undefined () =
  List.iter (fun (name, w) -> check_bool name (is_undefined (d w)))
    [ ("ldrh (ARMv4)", 0xE1D000B0); ("mrs (ARMv3)", 0xE10F0000);
      ("bx (ARMv4T)", 0xE12FFF1E); ("undefined space", 0xE6000010) ];
  check_bool "swp is ARM3" (match (d 0xE1000090).kind with Swp _ -> true | _ -> false);
  check_bool "FPA cp1 plausible" (plausible (d 0xEE000110));
  check_bool "cp15 implausible" (not (plausible (d 0xEE000F10)))

(* A tiny image at &8000:
     8000  bl   &8014          call
     8004  movnv r0, r0        NV filler: inert, traced over
     8008  swi  OS_WriteS      followed by "hi\0" padded to a word
     800c  .ascii "hi\0\0"
     8010  b    &8008          loop
     8014  movs pc, lr         callee: return
     8018  &e6000010           undefined - never reached
*)
let tiny_image () =
  let words = [ 0xEB000003; 0xF1A00000; 0xEF000001; 0x00006968; 0xEAFFFFFC;
                0xE1B0F00E; 0xE6000010 ] in
  let b = Bytes.create (4 * List.length words) in
  List.iteri (fun k w -> Bytes.set_int32_le b (4 * k) (Int32.of_int w)) words;
  { Image.data = Bytes.to_string b; base = 0x8000; size = Bytes.length b }

let test_spider () =
  let t = Spider.spider (tiny_image ()) [ 0x8000 ] in
  Alcotest.check ints "code" [ 0x8000; 0x8004; 0x8008; 0x8010; 0x8014 ] (Spider.sorted_keys t.code);
  Alcotest.check ints "data" [ 0x800c ] (Spider.sorted_keys t.data);
  Alcotest.check ints "functions" [ 0x8000; 0x8014 ] (Spider.sorted_keys t.funcs);
  Alcotest.(check int) "no problems" 0 (List.length t.problems)

(* Literal thunk and push-pc call at &8000:
     8000  bl &8020               call a literal thunk ...
     8004  &00001234              ... which consumes this literal (decodes as
                                  a plausible andeq: S0 takes it for code)
     8008  stmdb sp!, {pc}        push &8014 (ARM2 stores PC + 12)
     800c  movnv r0, r0           inert filler
     8010  b &802c                "call" by branching
     8014  swi OS_Exit            return site: reached only via the pop
     8018  &deadbeef, &deadbeef   data
     8020  bic lr, lr, #&fc000003 thunk
     8024  ldr r0, [lr], #4
     8028  mov pc, lr
     802c  ldmia sp!, {pc}        routine: returns to the pushed address
     8030  &deadbeef              data *)
let idiom_image () =
  let words = [ 0xEB000006; 0x00001234; 0xE92D8000; 0xF1A00000; 0xEA000005; 0xEF000011;
                0xDEADBEEF; 0xDEADBEEF; 0xE3CEE3FF; 0xE49E0004; 0xE1A0F00E; 0xE8BD8000;
                0xDEADBEEF ] in
  let b = Bytes.create (4 * List.length words) in
  List.iteri (fun k w -> Bytes.set_int32_le b (4 * k) (Int32.of_int w)) words;
  { Image.data = Bytes.to_string b; base = 0x8000; size = Bytes.length b }

let test_s1_idioms () =
  let t = S1.spider (idiom_image ()) [ 0x8000 ] in
  Alcotest.check ints "code"
    [ 0x8000; 0x8008; 0x800c; 0x8010; 0x8014; 0x8020; 0x8024; 0x8028; 0x802c ]
    (S1.keys t.code);
  check_bool "literal is data" (Hashtbl.mem t.data 0x8004);
  Alcotest.check ints "thunk call returns to +8" [ 0x8008 ]
    (S1.IS.elements (Hashtbl.find t.ret_sites 0x8000));
  Alcotest.(check int) "no assumptions" 0 (Hashtbl.length t.assumed + Hashtbl.length t.balanced);
  (* S0, assuming bl returns to +4, takes the literal for code and never
     finds the return site of the push-pc call *)
  let s0 = Spider.spider (idiom_image ()) [ 0x8000 ] in
  check_bool "S0 takes the literal for code" (Hashtbl.mem s0.code 0x8004);
  check_bool "S0 misses the push-pc return site" (not (Hashtbl.mem s0.code 0x8014))

(* Address-taken entry points at &8000:
     8000  mov r0, #&10
     8004  add r1, pc, #&c        &8018: a handler ...
     8008  swi OS_Claim           ... passed where the OS expects code
     800c  add r1, pc, #&10       &8024: a block that decodes as code ...
     8010  swi OS_Word            ... but is passed as a data pointer
     8014  swi OS_Exit
     8018  mov r0, #1             handler
     801c  mov r1, #2
     8020  mov pc, lr
     8024  mov r0, #2             parameter block (looks like code)
     8028  mov r1, #3
     802c  mov pc, lr *)
let address_taken_image () =
  let words = [ 0xE3A00010; 0xE28F100C; 0xEF00001F; 0xE28F1010; 0xEF000007; 0xEF000011;
                0xE3A00001; 0xE3A01002; 0xE1A0F00E; 0xE3A00002; 0xE3A01003; 0xE1A0F00E ] in
  let b = Bytes.create (4 * List.length words) in
  List.iteri (fun k w -> Bytes.set_int32_le b (4 * k) (Int32.of_int w)) words;
  { Image.data = Bytes.to_string b; base = 0x8000; size = Bytes.length b }

let test_s1b () =
  let t, decided = S1.spider_with_address_taken (address_taken_image ()) [ 0x8000 ] in
  check_bool "OS_Claim handler accepted" (Hashtbl.find_opt decided 0x8018 = Some S1.Accepted);
  check_bool "handler is code" (Hashtbl.mem t.code 0x8018);
  check_bool "OS_Word block rejected"
    (match Hashtbl.find_opt decided 0x8024 with Some (S1.Rejected _) -> true | _ -> false);
  check_bool "block is not code" (not (Hashtbl.mem t.code 0x8024))

let test_command_table () =
  (* module header with a *command table at &30: "Foo" -> code at &50 *)
  let b = Bytes.make 0x60 '\000' in
  Bytes.set_int32_le b 0x18 0x30l;
  Bytes.blit_string "Foo" 0 b 0x30 3;
  Bytes.set_int32_le b 0x34 0x50l;
  let img = { Image.data = Bytes.to_string b; base = 0x1800000; size = 0x60 } in
  Alcotest.(check (list (pair string int))) "command entries" [ ("Foo", 0x1800050) ]
    (Image.module_command_entries img)

(* Relocation at &8000 (as LemBoot does it):
     8000  mov r1, #&40000        destination
     8004  mov r0, #&8000         source
     8008  ldr r2, [pc, #&14]     length (&40, at &8024)
     800c  ldrb r3, [r0], #1      copy loop
     8010  strb r3, [r1], #1
     8014  subs r2, r2, #1
     8018  bne &800c
     801c  ldr pc, [pc, #-4]      jump to &40028: &8028 in the copy
     8020  &00040028
     8024  &00000040
     8028  swi OS_Exit            reached only through the copy
     802c  zero words *)
let relocation_image () =
  let words = [ 0xE3A01701; 0xE3A00902; 0xE59F2014; 0xE4D03001; 0xE4C13001; 0xE2522001;
                0x1AFFFFFB; 0xE51FF004; 0x00040028; 0x00000040; 0xEF000011;
                0; 0; 0; 0; 0 ] in
  let b = Bytes.create (4 * List.length words) in
  List.iteri (fun k w -> Bytes.set_int32_le b (4 * k) (Int32.of_int w)) words;
  { Image.data = Bytes.to_string b; base = 0x8000; size = Bytes.length b }

let test_relocation () =
  let t = S1.spider (relocation_image ()) [ 0x8000 ] in
  check_bool "copy loop recognised"
    (List.exists (fun (c : S1.copy) -> c.src = 0x8000 && c.dst = 0x40000 && c.len = 0x40) t.copies);
  check_bool "jump into the copy maps back" (Hashtbl.mem t.code 0x8028);
  Alcotest.(check int) "no problems" 0 (Hashtbl.length t.problems)

(* Bounded indirect jumps at &8000:
     8000  and r0, r0, #3         index 0..3
     8004  add r1, pc, #4         table at &8010
     8008  ldr pc, [r1, r0, lsl #2]
     800c  swi OS_Exit            (not reached)
     8010  &8020 &8024 &8028 &802c  address table
     8020  swi OS_Exit (x3)
     802c  cmp r11, #2
     8030  addcc pc, pc, r11, lsl #2   branch table: &8038 or &803c
     8034  swi OS_Exit            r11 >= 2
     8038  swi OS_Exit
     803c  swi OS_Exit *)
let tables_image () =
  let words = [ 0xE2000003; 0xE28F1004; 0xE791F100; 0xEF000011;
                0x8020; 0x8024; 0x8028; 0x802c;
                0xEF000011; 0xEF000011; 0xEF000011;
                0xE35B0002; 0x308FF10B; 0xEF000011; 0xEF000011; 0xEF000011 ] in
  let b = Bytes.create (4 * List.length words) in
  List.iteri (fun k w -> Bytes.set_int32_le b (4 * k) (Int32.of_int w)) words;
  { Image.data = Bytes.to_string b; base = 0x8000; size = Bytes.length b }

let test_tables () =
  let t = S1.spider (tables_image ()) [ 0x8000 ] in
  Alcotest.check ints "address table targets" [ 0x8020; 0x8024; 0x8028; 0x802c ]
    (S1.IS.elements (Hashtbl.find t.const_jumps 0x8008));
  Alcotest.check ints "branch table targets" [ 0x8038; 0x803c ]
    (S1.IS.elements (Hashtbl.find t.const_jumps 0x8030));
  List.iter (fun a -> check_bool (Printf.sprintf "&%x is data" a) (Hashtbl.mem t.data a && not (Hashtbl.mem t.code a)))
    [ 0x8010; 0x8014; 0x8018; 0x801c ];
  check_bool "&800c not code" (not (Hashtbl.mem t.code 0x800c));
  Alcotest.(check int) "no problems" 0 (Hashtbl.length t.problems)

(* A jump through a variable set at run time, at &8000:
     8000  add r0, pc, #&8        handler &8010
     8004  str r0, [pc, #&10]     variable at &801c (initially 0)
     8008  ldr pc, [pc, #&c]      jump through it
     800c  swi OS_Exit            (not reached)
     8010  mov r0, #1             handler
     8014  mov r1, #2
     8018  swi OS_Exit
     801c  &00000000              variable *)
let variable_image () =
  let words = [ 0xE28F0008; 0xE58F0010; 0xE59FF00C; 0xEF000011;
                0xE3A00001; 0xE3A01002; 0xEF000011; 0x00000000 ] in
  let b = Bytes.create (4 * List.length words) in
  List.iteri (fun k w -> Bytes.set_int32_le b (4 * k) (Int32.of_int w)) words;
  { Image.data = Bytes.to_string b; base = 0x8000; size = Bytes.length b }

let test_variable_jump () =
  let t = S1.spider (variable_image ()) [ 0x8000 ] in
  Alcotest.check ints "jump through the variable" [ 0x8010 ]
    (S1.IS.elements (Hashtbl.find t.const_jumps 0x8008));
  check_bool "handler is code" (Hashtbl.mem t.code 0x8010);
  check_bool "variable is not code" (not (Hashtbl.mem t.code 0x801c));
  check_bool "&800c not code" (not (Hashtbl.mem t.code 0x800c))

let image_of words =
  let b = Bytes.create (4 * List.length words) in
  List.iteri (fun k w -> Bytes.set_int32_le b (4 * k) (Int32.of_int w)) words;
  { Image.data = Bytes.to_string b; base = 0x8000; size = Bytes.length b }

(* A variable set through a setter routine (its argument, substituted at
   the call site), then jumped through:
     8000  add r0, pc, #&14       handler &801c
     8004  bl &8014
     8008  ldr pc, [pc, #&18]     jump through the variable at &8028
     800c  swi OS_Exit            (not reached)
     8010  swi OS_Exit            (not reached)
     8014  str r0, [pc, #&c]      setter: variable := r0
     8018  mov pc, lr
     801c  mov r0, #1             handler
     8020  mov r1, #2
     8024  swi OS_Exit
     8028  &00000000              variable *)
let test_setter_jump () =
  let img = image_of [ 0xE28F0014; 0xEB000002; 0xE59FF018; 0xEF000011; 0xEF000011;
                       0xE58F000C; 0xE1A0F00E; 0xE3A00001; 0xE3A01002; 0xEF000011; 0 ] in
  let t = S1.spider img [ 0x8000 ] in
  Alcotest.check ints "jump through the variable" [ 0x801c ]
    (S1.IS.elements (Hashtbl.find t.const_jumps 0x8008));
  check_bool "handler is code" (Hashtbl.mem t.code 0x801c)

(* A jump through a table inside an object stored at a field:
     8000  add r0, pc, #&14       the object at &801c
     8004  str r0, [r12, #&58]    stored at field &58
     8008  ldr r1, [r12, #&58]
     800c  ldr r2, [r12, #&5c]    an unknown index
     8010  ldr pc, [r1, r2, lsl #2]
     8014  mov r0, #1             handler
     8018  swi OS_Exit
     801c  &00000005, &00008014   the object: a count, then the handler *)
let test_object_jump () =
  let img = image_of [ 0xE28F0014; 0xE58C0058; 0xE59C1058; 0xE59C205C; 0xE791F102;
                       0xE3A00001; 0xEF000011; 0x5; 0x8014 ] in
  let t = S1.spider img [ 0x8000 ] in
  Alcotest.check ints "jump into the object's table" [ 0x8014 ]
    (S1.IS.elements (Hashtbl.find t.const_jumps 0x8010));
  check_bool "object is not code" (not (Hashtbl.mem t.code 0x801c))

let () =
  Alcotest.run "superspider"
    [ ("decode", [ Alcotest.test_case "text" `Quick test_text;
                   Alcotest.test_case "semantics" `Quick test_semantics;
                   Alcotest.test_case "undefined" `Quick test_undefined ]);
      ("spider", [ Alcotest.test_case "s0 tiny image" `Quick test_spider;
                   Alcotest.test_case "s1 derives thunk and push-pc returns" `Quick test_s1_idioms;
                   Alcotest.test_case "s1b address-taken entries" `Quick test_s1b;
                   Alcotest.test_case "module command table" `Quick test_command_table;
                   Alcotest.test_case "s1 relocation" `Quick test_relocation;
                   Alcotest.test_case "s1 bounded tables" `Quick test_tables;
                   Alcotest.test_case "s1 jump through a variable" `Quick test_variable_jump;
                   Alcotest.test_case "s1 variable set by a setter" `Quick test_setter_jump;
                   Alcotest.test_case "s1 table in an object" `Quick test_object_jump ]) ]
