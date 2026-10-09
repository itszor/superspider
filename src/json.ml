(* A small JSON reader, enough for SuperSpider's own analysis files (no
   dependencies, so the tool stays self-contained). *)

type t = Null | Bool of bool | Num of float | Int of int | Str of string | List of t list | Obj of (string * t) list

exception Error of string

let parse (s : string) =
  let n = String.length s and i = ref 0 in
  let err m = raise (Error (Printf.sprintf "%s at offset %d" m !i)) in
  let rec ws () = if !i < n && (s.[!i] = ' ' || s.[!i] = '\n' || s.[!i] = '\r' || s.[!i] = '\t') then (incr i; ws ()) in
  let expect ch = ws (); if !i < n && s.[!i] = ch then incr i else err (Printf.sprintf "expected '%c'" ch) in
  let str () =
    expect '"';
    let b = Buffer.create 16 in
    let rec go () =
      if !i >= n then err "unterminated string";
      match s.[!i] with
      | '"' -> incr i
      | '\\' ->
        if !i + 1 >= n then err "bad escape";
        let ch = s.[!i + 1] in
        i := !i + 2;
        (match ch with
         | 'n' -> Buffer.add_char b '\n' | 't' -> Buffer.add_char b '\t' | 'r' -> Buffer.add_char b '\r'
         | 'b' -> Buffer.add_char b '\b' | 'f' -> Buffer.add_char b '\012'
         | 'u' ->
           let code = int_of_string ("0x" ^ String.sub s !i 4) in
           i := !i + 4;
           if code < 0x80 then Buffer.add_char b (Char.chr code) else Buffer.add_utf_8_uchar b (Uchar.of_int code)
         | '0' .. '9' ->                    (* OCaml's String.escaped: \ddd *)
           let code = int_of_string (String.sub s (!i - 1) 3) in
           i := !i + 2;
           Buffer.add_char b (Char.chr (code land 255))
         | c -> Buffer.add_char b c);
        go ()
      | c -> Buffer.add_char b c; incr i; go () in
    go ();
    Buffer.contents b in
  let rec value () =
    ws ();
    if !i >= n then err "unexpected end";
    match s.[!i] with
    | '{' ->
      incr i; ws ();
      if !i < n && s.[!i] = '}' then (incr i; Obj [])
      else
        let rec fields acc =
          let k = str () in
          expect ':';
          let v = value () in
          ws ();
          if !i < n && s.[!i] = ',' then (incr i; fields ((k, v) :: acc))
          else (expect '}'; Obj (List.rev ((k, v) :: acc))) in
        fields []
    | '[' ->
      incr i; ws ();
      if !i < n && s.[!i] = ']' then (incr i; List [])
      else
        let rec items acc =
          let v = value () in
          ws ();
          if !i < n && s.[!i] = ',' then (incr i; items (v :: acc))
          else (expect ']'; List (List.rev (v :: acc))) in
        items []
    | '"' -> Str (str ())
    | 't' when !i + 4 <= n && String.sub s !i 4 = "true" -> i := !i + 4; Bool true
    | 'f' when !i + 5 <= n && String.sub s !i 5 = "false" -> i := !i + 5; Bool false
    | 'n' when !i + 4 <= n && String.sub s !i 4 = "null" -> i := !i + 4; Null
    | '-' | '0' .. '9' ->
      let st = !i in
      while !i < n && (match s.[!i] with '0' .. '9' | '-' | '+' | '.' | 'e' | 'E' -> true | _ -> false) do incr i done;
      let t = String.sub s st (!i - st) in
      (match int_of_string_opt t with Some k -> Int k | None -> Num (float_of_string t))
    | c -> err (Printf.sprintf "unexpected '%c'" c) in
  let v = value () in
  ws ();
  if !i < n then err "trailing data";
  v

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  parse s

let member k = function
  | Obj l -> (match List.assoc_opt k l with Some v -> v | None -> raise (Error ("no field " ^ k)))
  | _ -> raise (Error ("not an object, looking for " ^ k))

let member_opt k = function Obj l -> List.assoc_opt k l | _ -> None

let to_list = function List l -> l | _ -> raise (Error "not a list")
let to_int = function Int k -> k | Num f -> int_of_float f | _ -> raise (Error "not a number")
let to_string = function Str s -> s | _ -> raise (Error "not a string")
let to_bool = function Bool b -> b | _ -> raise (Error "not a boolean")

(* Writing: a string literal *)
let quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter (fun c -> match c with
      | '"' -> Buffer.add_string b "\\\"" | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n" | '\r' -> Buffer.add_string b "\\r" | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c) s;
  Buffer.add_char b '"';
  Buffer.contents b
