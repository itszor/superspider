(* S0: plain recursive descent (PLAN.md phase 2).

   Follows b/bl and conditional fall-through from the given entry points.
   Knows only what the architecture and the OS define:
   - NV-conditioned words never execute, so tracing steps over them;
   - bl is a call that returns to the next instruction (the conventional
     assumption - phase 3 replaces it with return-address tracking);
   - OS_WriteS (SWI &01 / &20001) is followed by an inline string;
   - OS_Exit and OS_GenerateError (non-X) don't return.
   Any other write to the PC ends the path (no constant tracking, no
   tables yet). A path that reaches an undefined or implausible word, runs
   off the image or into data stops there; words already traced are kept. *)

type problem = { at : int; from_fn : int; msg : string }

type t = {
  img : Image.t;
  code : (int, int) Hashtbl.t;            (* addr -> entry of the function that reached it *)
  data : (int, string) Hashtbl.t;         (* word addr -> why it is data *)
  funcs : (int, unit) Hashtbl.t;
  callers : (int, int list) Hashtbl.t;    (* callee -> call sites *)
  mutable problems : problem list;
  work : (int * int) Stack.t;             (* (addr, function entry) *)
}

let create img = {
  img; code = Hashtbl.create 4096; data = Hashtbl.create 256; funcs = Hashtbl.create 256;
  callers = Hashtbl.create 256; problems = []; work = Stack.create ();
}

let problem t at from_fn msg = t.problems <- { at; from_fn; msg } :: t.problems

let add_func t ?src a =
  if not (Image.inside t.img a) || a land 3 <> 0 then
    problem t (Option.value src ~default:a) a (Printf.sprintf "entry &%x outside image" a)
  else begin
    Option.iter (fun s ->
        Hashtbl.replace t.callers a (s :: Option.value (Hashtbl.find_opt t.callers a) ~default:[]))
      src;
    if not (Hashtbl.mem t.funcs a) then begin
      Hashtbl.replace t.funcs a ();
      Stack.push (a, a) t.work
    end
  end

let add_data t a n why =
  let rec go x = if x < a + n then begin
      if Image.in_range t.img x && not (Hashtbl.mem t.data x) then Hashtbl.replace t.data x why;
      go (x + 4) end in
  go (a land lnot 3)

let os_writes n = n land lnot 0x20000 = 0x01
(* OS_Exit (either form: XOS_Exit never returns either) and OS_GenerateError
   (XOS_GenerateError returns with V set) *)
(* OS_Exit; OS_GenerateError and MessageTrans_ErrorLookup (without X: the
   error is raised) *)
let noreturn_swi n = n land lnot 0x20000 = 0x11 || n = 0x2B || n = 0x41506

(* Trace one path from a, owned by function fn. *)
let trace t a fn =
  let img = t.img in
  let rec step a =
    if not (Image.inside img a) then problem t a fn "flowed off the image"
    else if Hashtbl.mem t.code a then ()
    else if Hashtbl.mem t.data a then problem t a fn "flowed into data"
    else
      let i = Image.decode img a in
      if i.cond <> Arm2.NV && not (Arm2.plausible i) && not (Arm2.later_arm i)
         && not ((Arm2.sbz_only i || Arm2.undefined_trap i) && Hashtbl.mem t.code (a - 4)
               && Arm2.runs_on (Image.decode img (a - 4))) then
        problem t a fn ("invalid: " ^ Arm2.to_string i)
      else begin
        Hashtbl.replace t.code a fn;
        let next = a + 4 in
        if i.cond = Arm2.NV then step next
        else
          match i.kind with
          | Arm2.Branch { link = true; target } ->
            add_func t ~src:a target;
            step next
          | Arm2.Branch { link = false; target } ->
            Stack.push (target, fn) t.work;
            if not (Arm2.always i) then step next
          | Arm2.Swi n when os_writes n ->
            let rec strend s = if Image.in_range img s && Image.byte img s <> 0 then strend (s + 1) else s in
            let s = strend next in
            let after = (s + 4) land lnot 3 in
            add_data t next (after - next) "OS_WriteS string";
            step after
          | Arm2.Swi n when noreturn_swi n && Arm2.always i -> ()
          | _ when Arm2.writes_pc i -> if not (Arm2.always i) then step next
          | _ -> step next
      end
  in
  step a

let run t =
  while not (Stack.is_empty t.work) do
    let a, fn = Stack.pop t.work in
    trace t a fn
  done

let spider img entries =
  let t = create img in
  List.iter (fun a -> add_func t a) entries;
  run t;
  t

(* ------------------------------------------------------------------ output *)

let sorted_keys h = List.sort compare (Hashtbl.fold (fun k _ acc -> k :: acc) h [])

let json_ints l = "[" ^ String.concat "," (List.map string_of_int l) ^ "]"

let json_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter (fun c -> match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | c when Char.code c < 32 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c) s;
  Buffer.add_char b '"';
  Buffer.contents b

let to_json t ~entries oc =
  Printf.fprintf oc "{\"base\":%d,\"size\":%d,\n\"entries\":%s,\n\"funcs\":%s,\n\"code\":%s,\n\"data\":%s,\n"
    t.img.base t.img.size (json_ints entries) (json_ints (sorted_keys t.funcs))
    (json_ints (sorted_keys t.code)) (json_ints (sorted_keys t.data));
  Printf.fprintf oc "\"problems\":[%s]}\n"
    (String.concat ",\n" (List.rev_map (fun p ->
         Printf.sprintf "[%d,%d,%s]" p.at p.from_fn (json_string p.msg)) t.problems))
