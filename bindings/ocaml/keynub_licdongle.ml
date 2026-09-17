(* KeyNub License Dongle for OCaml: the flat companion API through
   ctypes-foreign. See keynub_licdongle.mli for the interface. *)

open Ctypes
open Foreign

(* ---- failures ------------------------------------------------------------ *)

type status =
  | Invalid_arg | No_device | Access_denied | Io | Timeout | Protocol
  | Not_genuine | Cert_invalid | Session_expired | Tag_mismatch | Range
  | Storage_full | Busy | Not_found | Auth_required | Firmware_incompatible
  | Sdk_too_old | Cancelled | Not_implemented | Internal
  | Unknown of int

let status_of_code = function
  | -1 -> Invalid_arg | -2 -> No_device | -3 -> Access_denied | -4 -> Io
  | -5 -> Timeout | -6 -> Protocol | -7 -> Not_genuine | -8 -> Cert_invalid
  | -9 -> Session_expired | -10 -> Tag_mismatch | -11 -> Range | -12 -> Storage_full
  | -13 -> Busy | -14 -> Not_found | -15 -> Auth_required | -16 -> Firmware_incompatible
  | -17 -> Sdk_too_old | -18 -> Cancelled | -19 -> Not_implemented | -20 -> Internal
  | c -> Unknown c

let status_to_string = function
  | Invalid_arg -> "Invalid_arg" | No_device -> "No_device" | Access_denied -> "Access_denied"
  | Io -> "Io" | Timeout -> "Timeout" | Protocol -> "Protocol" | Not_genuine -> "Not_genuine"
  | Cert_invalid -> "Cert_invalid" | Session_expired -> "Session_expired"
  | Tag_mismatch -> "Tag_mismatch" | Range -> "Range" | Storage_full -> "Storage_full"
  | Busy -> "Busy" | Not_found -> "Not_found" | Auth_required -> "Auth_required"
  | Firmware_incompatible -> "Firmware_incompatible" | Sdk_too_old -> "Sdk_too_old"
  | Cancelled -> "Cancelled" | Not_implemented -> "Not_implemented" | Internal -> "Internal"
  | Unknown c -> Printf.sprintf "Unknown %d" c

exception Error of { status : status; code : int; operation : string; detail : string }
exception Library_error of string

let () =
  Printexc.register_printer (function
    | Error e ->
      Some (Printf.sprintf "%s: %s (%d)%s" e.operation (status_to_string e.status) e.code
              (if e.detail = "" then "" else ": " ^ e.detail))
    | Library_error m -> Some ("KeyNub library: " ^ m)
    | _ -> None)

(* ---- the library --------------------------------------------------------- *)

(* Every function of the flat API, resolved from the loaded library. int32_t
   is a C int on every platform the library ships for, so ctypes' [int] does. *)
type api = {
  version : int ptr -> int ptr -> int ptr -> int;
  device_count : int ptr -> int;
  device_serial : int -> char ptr -> int -> int;
  device_path : int -> char ptr -> int -> int;
  open_ : string -> int;
  open_path : string -> int;
  close : int -> int;
  set_trust_root : int -> char ptr -> int -> int;
  get_serial : int -> char ptr -> int -> int;
  get_info : int -> int ptr -> int ptr -> int ptr -> int ptr -> int ptr -> int ptr -> int ptr
             -> int ptr -> int;
  verify_genuine : int -> int ptr -> char ptr -> int -> char ptr -> int -> int;
  session_open : int -> int;
  session_close : int -> int;
  write_auth : int -> char ptr -> int -> int;
  write_auth_rotate : int -> char ptr -> int -> int;
  record_count : int -> int ptr -> int;
  record_name : int -> int -> char ptr -> int -> int ptr -> int;
  record_read : int -> string -> char ptr -> int -> int ptr -> int;
  record_write : int -> string -> char ptr -> int -> int;
  record_erase : int -> string -> int;
  record_erase_all : int -> int;
  counter_read : int -> int -> int ptr -> int;
  counter_increment : int -> int -> int ptr -> int;
  app_encrypt : int -> int -> char ptr -> int -> char ptr -> int -> int ptr -> int;
  app_decrypt : int -> char ptr -> int -> char ptr -> int -> int ptr -> int;
  strerror : int -> char ptr -> int -> int;
  last_error : int -> char ptr -> int -> int;
}

let bind path lib =
  let f name typ =
    try foreign ~from:lib name typ
    with Dl.DL_error _ -> raise (Library_error (path ^ " does not export " ^ name))
  in
  let i = int and p = ptr int and b = ptr char in
  {
    version = f "licdf_version" (p @-> p @-> p @-> returning i);
    device_count = f "licdf_device_count" (p @-> returning i);
    device_serial = f "licdf_device_serial" (i @-> b @-> i @-> returning i);
    device_path = f "licdf_device_path" (i @-> b @-> i @-> returning i);
    open_ = f "licdf_open" (string @-> returning i);
    open_path = f "licdf_open_path" (string @-> returning i);
    close = f "licdf_close" (i @-> returning i);
    set_trust_root = f "licdf_set_trust_root" (i @-> b @-> i @-> returning i);
    get_serial = f "licdf_get_serial" (i @-> b @-> i @-> returning i);
    get_info = f "licdf_get_info"
        (i @-> p @-> p @-> p @-> p @-> p @-> p @-> p @-> p @-> returning i);
    verify_genuine = f "licdf_verify_genuine" (i @-> p @-> b @-> i @-> b @-> i @-> returning i);
    session_open = f "licdf_session_open" (i @-> returning i);
    session_close = f "licdf_session_close" (i @-> returning i);
    write_auth = f "licdf_write_auth" (i @-> b @-> i @-> returning i);
    write_auth_rotate = f "licdf_write_auth_rotate" (i @-> b @-> i @-> returning i);
    record_count = f "licdf_record_count" (i @-> p @-> returning i);
    record_name = f "licdf_record_name" (i @-> i @-> b @-> i @-> p @-> returning i);
    record_read = f "licdf_record_read" (i @-> string @-> b @-> i @-> p @-> returning i);
    record_write = f "licdf_record_write" (i @-> string @-> b @-> i @-> returning i);
    record_erase = f "licdf_record_erase" (i @-> string @-> returning i);
    record_erase_all = f "licdf_record_erase_all" (i @-> returning i);
    counter_read = f "licdf_counter_read" (i @-> i @-> p @-> returning i);
    counter_increment = f "licdf_counter_increment" (i @-> i @-> p @-> returning i);
    app_encrypt = f "licdf_app_encrypt" (i @-> i @-> b @-> i @-> b @-> i @-> p @-> returning i);
    app_decrypt = f "licdf_app_decrypt" (i @-> b @-> i @-> b @-> i @-> p @-> returning i);
    strerror = f "licdf_strerror" (i @-> b @-> i @-> returning i);
    last_error = f "licdf_last_error" (i @-> b @-> i @-> returning i);
  }

let chosen : string option ref = ref None
let loaded : (string * api) option ref = ref None

let set_library_path path =
  match !loaded with
  | Some (lp, _) when lp <> path ->
    raise (Library_error (Printf.sprintf "the KeyNub library is already loaded from %s; a process loads it once" lp))
  | _ -> chosen := Some path

let basenames =
  match Sys.os_type with
  | "Win32" | "Cygwin" -> [ "keynub_licdongle_flat.dll" ]
  | _ -> [ "libkeynub_licdongle_flat.so"; "libkeynub_licdongle_flat.dylib" ]

let platform_folders =
  [ "win-x64"; "win-x86"; "win-arm64"; "linux-x64"; "linux-arm64"; "osx-x64"; "osx-arm64" ]

(* natives/<platform>/ of a clone of the SDK repository, from the working
   directory upwards; every existing candidate, the loader tells which fits. *)
let natives_candidates () =
  let rec up dir acc =
    let here =
      List.concat
        (List.map
           (fun folder ->
             List.map
               (fun base -> Filename.concat (Filename.concat (Filename.concat dir "natives") folder) base)
               basenames)
           platform_folders)
    in
    let acc = acc @ List.filter Sys.file_exists here in
    let parent = Filename.dirname dir in
    if parent = dir then acc else up parent acc
  in
  up (Sys.getcwd ()) []

(* The path given to set_library_path, then KEYNUB_LICDONGLE_FLAT_LIBRARY,
   then the natives folders, then the bare name for the system loader. *)
let candidates () =
  match !chosen with
  | Some p -> [ p ]
  | None -> (
    match Sys.getenv_opt "KEYNUB_LICDONGLE_FLAT_LIBRARY" with
    | Some p when p <> "" -> [ p ]
    | _ -> natives_candidates () @ basenames)

let api () =
  match !loaded with
  | Some (_, a) -> a
  | None ->
    let cands = candidates () in
    let rec go = function
      | [] ->
        raise (Library_error (Printf.sprintf "cannot load the KeyNub library (tried %s)" (String.concat ", " cands)))
      | path :: rest -> (
        match Dl.dlopen ~filename:path ~flags:[ Dl.RTLD_NOW ] with
        | lib ->
          let a = bind path lib in
          loaded := Some (path, a);
          a
        | exception Dl.DL_error _ -> go rest)
    in
    go cands

let library_path () =
  match !loaded with
  | Some (p, _) -> p
  | None -> ( match candidates () with p :: _ -> p | [] -> List.hd basenames)

let loaded_library_path () = match !loaded with Some (p, _) -> Some p | None -> None

(* ---- helpers ------------------------------------------------------------- *)

let serial_size = 15
let date_size = 11
let path_size = 512
let error_size = 256
let range_code = -11

type dongle = int

let buffer n =
  let b = allocate_n char ~count:(max n 1) in
  b <-@ '\000';
  b

let cstring p = coerce (ptr char) string p

(* An OCaml string as a C pointer and length; a copy the C side may read. *)
let bytes_arg s =
  let n = String.length s in
  let arr = CArray.make char (max n 1) in
  String.iteri (fun i c -> CArray.set arr i c) s;
  (CArray.start arr, n)

let last_error_raw h =
  let a = api () in
  let buf = buffer error_size in
  if a.last_error h buf error_size = 0 then cstring buf else ""

let check ?h op rc =
  if rc <> 0 then begin
    let detail = match h with Some d -> last_error_raw d | None -> "" in
    raise (Error { status = status_of_code rc; code = rc; operation = op; detail })
  end

let read_string ?h op n f =
  let buf = buffer n in
  check ?h op (f buf n);
  cstring buf

(* Bytes of unknown length: ask with a capacity of 0, the library answers
   Range and the size needed, then read into a buffer of that size. *)
let read_bytes ?h op f =
  let len = allocate int 0 in
  let rc0 = f (from_voidp char null) 0 len in
  if rc0 = 0 then ""
  else if rc0 <> range_code then (check ?h op rc0; "")
  else begin
    let need = !@len in
    let buf = buffer need in
    len <-@ 0;
    check ?h op (f buf need len);
    string_from_ptr buf ~length:!@len
  end

(* ---- the library, records, counters ------------------------------------- *)

let library_version () =
  let a = api () in
  let x = allocate int 0 and y = allocate int 0 and z = allocate int 0 in
  check "licdf_version" (a.version x y z);
  (!@x, !@y, !@z)

let status_text code =
  let a = api () in
  let buf = buffer error_size in
  ignore (a.strerror code buf error_size);
  cstring buf

let last_error_detail = last_error_raw

type device = { serial : string; path : string }

let devices () =
  let a = api () in
  let n = allocate int 0 in
  check "licdf_device_count" (a.device_count n);
  List.init !@n (fun i ->
      let serial = read_string "licdf_device_serial" path_size (a.device_serial i) in
      let path = read_string "licdf_device_path" path_size (a.device_path i) in
      { serial; path })

let handle_of op h =
  if h > 0 then h else raise (Error { status = status_of_code h; code = h; operation = op; detail = "" })

let open_serial s = handle_of "licdf_open" ((api ()).open_ s)
let open_first () = open_serial ""
let open_path p = handle_of "licdf_open_path" ((api ()).open_path p)
let close h = check "licdf_close" ((api ()).close h)

let with_dongle ?serial f =
  let d = match serial with Some s -> open_serial s | None -> open_first () in
  match f d with
  | v -> close d; v
  | exception e -> (try close d with _ -> ()); raise e

let serial h = read_string ~h "licdf_get_serial" serial_size ((api ()).get_serial h)

type info = {
  protocol_version : int * int;
  firmware_version : int * int * int;
  secure_element_ready : bool;
  provisioned : bool;
  watchdog_reboot : bool;
  isolated : bool;
  write_auth_rotated : bool;
  data_capacity : int;
  data_free : int;
}

let info h =
  let a = api () in
  let v = Array.init 8 (fun _ -> allocate int 0) in
  check ~h "licdf_get_info" (a.get_info h v.(0) v.(1) v.(2) v.(3) v.(4) v.(5) v.(6) v.(7));
  let g i = !@(v.(i)) in
  let flags = g 5 in
  let flag bit = flags land bit <> 0 in
  {
    protocol_version = (g 0, g 1);
    firmware_version = (g 2, g 3, g 4);
    secure_element_ready = flag 0x01;
    provisioned = flag 0x02;
    watchdog_reboot = flag 0x04;
    isolated = flag 0x08;
    write_auth_rotated = flag 0x10;
    data_capacity = g 6;
    data_free = g 7;
  }

type genuine = { genuine_serial : string; provisioned_date : string }

let verify_genuine h =
  let a = api () in
  let g = allocate int 0 in
  let s = buffer serial_size and d = buffer date_size in
  check ~h "licdf_verify_genuine" (a.verify_genuine h g s serial_size d date_size);
  if !@g = 0 then
    raise (Error { status = Not_genuine; code = -7; operation = "licdf_verify_genuine"; detail = "" });
  { genuine_serial = cstring s; provisioned_date = cstring d }

let is_genuine h = try ignore (verify_genuine h); true with _ -> false

let set_trust_root h der =
  let p, n = bytes_arg der in
  check ~h "licdf_set_trust_root" ((api ()).set_trust_root h p n)

let session_open h = check ~h "licdf_session_open" ((api ()).session_open h)
let session_close h = check ~h "licdf_session_close" ((api ()).session_close h)

let with_session h f =
  session_open h;
  match f () with
  | v -> session_close h; v
  | exception e -> (try session_close h with _ -> ()); raise e

let authorize_write h key =
  let p, n = bytes_arg key in
  check ~h "licdf_write_auth" ((api ()).write_auth h p n)

let rotate_write_key h key =
  let p, n = bytes_arg key in
  check ~h "licdf_write_auth_rotate" ((api ()).write_auth_rotate h p n)

type record_info = { name : string; size : int }

let records h =
  let a = api () in
  let n = allocate int 0 in
  check ~h "licdf_record_count" (a.record_count h n);
  List.init !@n (fun i ->
      let buf = buffer path_size and size = allocate int 0 in
      check ~h "licdf_record_name" (a.record_name h i buf path_size size);
      { name = cstring buf; size = !@size })

let read_record h name =
  let a = api () in
  read_bytes ~h "licdf_record_read" (fun buf cap len -> a.record_read h name buf cap len)

let write_record h name data =
  let p, n = bytes_arg data in
  check ~h "licdf_record_write" ((api ()).record_write h name p n)

let erase_record h name = check ~h "licdf_record_erase" ((api ()).record_erase h name)
let erase_all_records h = check ~h "licdf_record_erase_all" ((api ()).record_erase_all h)

let read_counter h id =
  let v = allocate int 0 in
  check ~h "licdf_counter_read" ((api ()).counter_read h id v);
  !@v

let increment_counter h id =
  let v = allocate int 0 in
  check ~h "licdf_counter_increment" ((api ()).counter_increment h id v);
  !@v

type scope = Device_scope | Developer_scope

let app_encrypt h scope plain =
  let a = api () in
  let code = match scope with Device_scope -> 0 | Developer_scope -> 1 in
  let p, n = bytes_arg plain in
  read_bytes ~h "licdf_app_encrypt" (fun buf cap len -> a.app_encrypt h code p n buf cap len)

let app_decrypt h packed =
  let a = api () in
  let p, n = bytes_arg packed in
  read_bytes ~h "licdf_app_decrypt" (fun buf cap len -> a.app_decrypt h p n buf cap len)
