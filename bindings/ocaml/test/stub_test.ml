(* Every call of the binding against a stand-in for the flat C API: the SDK's
   flat layer compiled together with the C ABI stand-in
   (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
   into one shared library, with a C compiler from the path (cc, gcc, clang or
   zig cc). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled stand-in
   skips the build; KEYNUB_SDK_ROOT names the SDK sources when the test does
   not run inside a clone. Exit code 0 when every check passed. *)

open Keynub_licdongle

let failures = ref 0

let check cond what =
  if not cond then begin
    incr failures;
    print_endline ("  FAIL  " ^ what)
  end

let fails status what f =
  match f () with
  | _ -> check false (what ^ ": no failure")
  | exception Error e -> check (e.status = status) (what ^ ": " ^ status_to_string e.status)

(* ---- the stand-in -------------------------------------------------------- *)

let file_exists_in dir rel = Sys.file_exists (Filename.concat dir rel)

let sdk_root () =
  match Sys.getenv_opt "KEYNUB_SDK_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec up dir =
      if file_exists_in dir "bindings/flat/licd_flat.c" then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then begin
          print_endline "the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT";
          exit 1
        end
        else up parent
    in
    up (Sys.getcwd ())

let stand_in () =
  match Sys.getenv_opt "KEYNUB_LICDONGLE_FLAT_LIBRARY" with
  | Some p when p <> "" -> p
  | _ ->
    let root = sdk_root () in
    let windows = Sys.os_type = "Win32" in
    let include_dir =
      if file_exists_in root "core/include/licdongle.h" then Filename.concat root "core/include"
      else Filename.concat root "include"
    in
    (* Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by
       leaf name even for an absolute-path dlopen, and a build tree on that
       path holds the real library under that name. Written straight into the
       temporary directory: the standard library before 4.12 has no mkdir. *)
    let out =
      Filename.concat (Filename.get_temp_dir_name ())
        (if windows then "keynub_flat_standin.dll" else "libkeynub_flat_standin.so")
    in
    let args =
      [ "-shared"; "-O1"; "-DLICD_BUILD_SHARED"; "-DLICDF_BUILD_SHARED";
        "-I" ^ include_dir; "-I" ^ Filename.concat root "bindings/flat";
        "-o"; out;
        Filename.concat root "bindings/flat/licd_flat.c";
        Filename.concat root "bindings/julia/test/stub/licd_stub.c" ]
      @ (if windows then [] else [ "-fPIC" ])
    in
    let compilers = [ "cc"; "gcc"; "clang"; "zig cc" ] in
    let rec try_compilers = function
      | [] ->
        print_endline "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc) on the path";
        exit 1
      | c :: rest ->
        let cmd = String.concat " " (c :: List.map Filename.quote args) ^ " 2>/dev/null" in
        if Sys.command cmd = 0 then out else try_compilers rest
    in
    try_compilers compilers

(* ---- the checks ---------------------------------------------------------- *)

let () =
  set_library_path (stand_in ());
  let serial_value = "04A1B2C3D4E5F6" in
  let bytes l = String.init (List.length l) (fun i -> Char.chr (List.nth l i)) in
  let factory_key = bytes [ 0x30; 0x10; 0x01; 0x02; 0x03 ] in
  let replacement_key = bytes [ 0x30; 0x11; 0x09; 0x08; 0x07; 0x06 ] in

  check (library_version () = (9, 8, 7)) "the stand-in reports 9.8.7";
  check (status_text (-2) = "no device") "strerror text";

  check (devices () = [ { serial = serial_value; path = "stub:0" } ]) "enumeration";
  fails No_device "open with a wrong serial" (fun () -> open_serial "nope");
  fails No_device "open at a wrong path" (fun () -> open_path "stub:9");

  let d = open_first () in
  check (serial d = serial_value) "serial";
  let i = info d in
  check (i.protocol_version = (1, 0) && i.firmware_version = (2, 3, 4)) "versions";
  check (i.secure_element_ready && i.provisioned && i.isolated) "flags set";
  check ((not i.watchdog_reboot) && not i.write_auth_rotated) "flags clear";
  check (i.data_capacity = 1024 * 1024 && i.data_free = 1000000) "storage";
  let g = verify_genuine d in
  check (g.genuine_serial = serial_value && g.provisioned_date = "2026-08-15") "genuine";
  check (is_genuine d) "is_genuine";

  fails Cert_invalid "a non-DER root is refused" (fun () -> set_trust_root d (bytes [ 0x02; 0x01; 0x00 ]));
  set_trust_root d (bytes [ 0x30; 0x82; 0x01; 0x00 ] ^ String.make 128 '\xAB');
  fails Cert_invalid "verification under a foreign root" (fun () -> verify_genuine d);
  check (not (is_genuine d)) "is_genuine fails closed";
  set_trust_root d (bytes [ 0x30; 0x82; 0x01; 0x00 ] ^ String.make 128 '\x01');
  check (is_genuine d) "genuine again under the issuing root";

  fails Session_expired "records need a session" (fun () -> records d);
  session_open d;
  let payload = "license-blob-0123456789" in
  fails Auth_required "writing needs the write role" (fun () -> write_record d "lic" payload);
  fails Not_genuine "a wrong key does not elevate" (fun () -> authorize_write d (bytes [ 0x30; 0x00 ]));
  authorize_write d factory_key;
  write_record d "lic" payload;
  check (read_record d "lic" = payload) "read back what was written";
  write_record d "cfg" "cfgdata";
  let recs = records d in
  check (List.sort compare (List.map (fun r -> r.name) recs) = [ "cfg"; "lic" ]) "record names";
  check (List.exists (fun r -> r.name = "lic" && r.size = String.length payload) recs) "record size";
  check (read_record d "cfg" = "cfgdata") "a string is stored as its bytes";
  fails Not_found "reading a missing record" (fun () -> read_record d "nope");
  fails Invalid_arg "an empty name never erases" (fun () -> erase_record d "");
  check (List.length (records d) = 2) "nothing erased by mistake";
  erase_record d "cfg";
  check (List.map (fun r -> r.name) (records d) = [ "lic" ]) "one record after the erase";
  write_record d "empty" "";
  check (read_record d "empty" = "") "an empty record reads back empty";

  let before = read_counter d 0 in
  check (increment_counter d 0 = before + 1) "increment returns the new value";
  check (read_counter d 0 = before + 1 && read_counter d 1 = 0) "counters";
  fails Range "a counter the dongle lacks" (fun () -> read_counter d 7);

  let secret = String.init 100 (fun k -> Char.chr ((3 * k + 7) mod 256)) in
  List.iter
    (fun (scope, byte, label) ->
      let blob = app_encrypt d scope secret in
      check (String.length blob > String.length secret) ("sealed data is longer, " ^ label);
      check (Char.code blob.[0] = byte) ("scope byte " ^ label);
      check (app_decrypt d blob = secret) ("round trip " ^ label);
      let last = String.length blob - 1 in
      let tampered =
        String.mapi (fun k c -> if k = last then Char.chr (Char.code c lxor 1) else c) blob
      in
      fails Tag_mismatch ("tampered data " ^ label) (fun () -> app_decrypt d tampered))
    [ (Device_scope, 0, "Device"); (Developer_scope, 1, "Developer") ];
  erase_all_records d;
  check (records d = []) "erase all leaves nothing";

  rotate_write_key d replacement_key;
  write_record d "lic" "still-writable";
  session_close d;
  check (info d).write_auth_rotated "the rotation flag is set";
  session_open d;
  fails Not_genuine "the factory key no longer elevates" (fun () -> authorize_write d factory_key);
  authorize_write d replacement_key;
  write_record d "lic" "new-key-writes";
  check (read_record d "lic" = "new-key-writes") "the new key writes";
  session_close d;
  close d;
  check (match serial d with _ -> false | exception Error _ -> true) "a closed handle refuses calls";

  if !failures = 0 then print_endline "keynub-licdongle: every call passed against the ABI stand-in"
  else begin
    Printf.printf "%d check(s) failed\n" !failures;
    exit 1
  end
