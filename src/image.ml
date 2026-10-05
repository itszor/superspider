(* A raw binary loaded at a base address. *)

type t = { data : string; base : int; size : int }

let load path base =
  let ic = open_in_bin path in
  let data = really_input_string ic (in_channel_length ic) in
  close_in ic;
  { data; base; size = String.length data }

let inside img a = a >= img.base && a + 4 <= img.base + img.size
let in_range img a = a >= img.base && a < img.base + img.size

let word img a =
  let o = a - img.base in
  Char.code img.data.[o]
  lor (Char.code img.data.[o + 1] lsl 8)
  lor (Char.code img.data.[o + 2] lsl 16)
  lor (Char.code img.data.[o + 3] lsl 24)

let byte img a = Char.code img.data.[a - img.base]

let decode img a = Arm2.decode a (word img a)

(* RISC OS relocatable module header: word offsets from the module base.
   Entry points that are code: start (+0), init (+4), final (+8),
   service call handler (+&c), SWI handler (+&20), SWI decoding code (+&28).
   An offset of 0 means "none". The *command table (+&18) is handled
   separately: its entries are code too, but finding them means walking
   the table. *)
let module_header_entries img =
  let off o = if inside img (img.base + o) then word img (img.base + o) else 0 in
  let entries = [ ("start", 0x0); ("init", 0x4); ("final", 0x8); ("service", 0xc);
                  ("swi_handler", 0x20); ("swi_decode", 0x28) ] in
  List.filter_map (fun (name, o) ->
      let v = off o in
      (* start is a branch instruction in some modules, an offset in others;
         RISC OS treats it as an offset, and 0 means none. Offsets with high
         bits set are not code offsets (e.g. flags). *)
      if v = 0 || v land 3 <> 0 || v >= img.size then None
      else Some (name, img.base + v))
    entries

(* The module's *command table (header +&18): entries of a NUL-terminated
   name, padded to a word, then the code offset, an information word and
   the syntax/help message offsets. An empty name ends the table; a code
   offset of 0 means help-only. *)
let module_command_entries img =
  let off o = if inside img (img.base + o) then word img (img.base + o) else 0 in
  let table = off 0x18 in
  if table = 0 || table >= img.size then []
  else
    let rec walk p acc =
      if not (in_range img (img.base + p)) || byte img (img.base + p) = 0 then List.rev acc
      else
        let rec name_end q = if in_range img (img.base + q) && byte img (img.base + q) <> 0 then name_end (q + 1) else q in
        let q = (name_end p + 4) land lnot 3 in
        if not (inside img (img.base + q + 12)) then List.rev acc
        else
          let name = String.sub img.data p (name_end p - p) in
          let code = word img (img.base + q) in
          let acc = if code <> 0 && code land 3 = 0 && code < img.size then (name, img.base + code) :: acc else acc in
          walk (q + 16) acc
    in
    walk table []
