(* KeyNub SDK - OCaml sample: verify a dongle and read what it holds.

     dune exec samples/ocaml/verify_and_read.exe      (from the repository root)

   Targets real hardware: with no dongle attached it prints guidance and exits 0. *)

open Keynub_licdongle

let report d =
  let i = info d in
  let pa, pb = i.protocol_version and fa, fb, fc = i.firmware_version in
  Printf.printf "Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free.\n" pa pb fa fb fc i.data_free
    i.data_capacity;
  (* The only trace a firmware hang leaves behind. Worth reporting to support. *)
  if i.watchdog_reboot then print_endline "WARNING: this dongle's previous boot ended in a watchdog reset.";
  let g = verify_genuine d in
  Printf.printf "Genuine: yes (serial %s, provisioned %s)\n" g.genuine_serial g.provisioned_date

let read_records d =
  let recs = records d in
  Printf.printf "%d record(s) on the dongle:\n" (List.length recs);
  List.iter (fun r -> Printf.printf "  %-16s %d bytes\n" r.name r.size) recs;
  (* A missing record is a normal state, not an error. *)
  if List.exists (fun r -> r.name = "license") recs then
    Printf.printf "Read %d bytes from the license record.\n" (String.length (read_record d "license"))

(* The part that actually protects something. At licence-issue time you would
   call app_encrypt once, with a developer dongle, and ship only the sealed
   data; the program then cannot proceed without a dongle, because it holds no
   other copy. Developer_scope lets any dongle you have issued decrypt it, so
   one file serves every customer; Device_scope locks it to one dongle. *)
let protect_something d =
  let needed = "the data this program cannot run without" in
  let sealed = app_encrypt d Developer_scope needed in
  let recovered = app_decrypt d sealed in
  Printf.printf "App-crypto round trip: %d bytes -> %d sealed -> %s\n" (String.length needed)
    (String.length sealed)
    (if recovered = needed then "recovered intact" else "MISMATCH")

let () =
  try
    let a, b, c = library_version () in
    Printf.printf "KeyNub library v%d.%d.%d\n" a b c;
    if devices () = [] then print_endline "Connect a KeyNub dongle and re-run."
    else
      with_dongle (fun d ->
          report d;
          with_session d (fun () ->
              read_records d;
              protect_something d))
  with e ->
    print_endline ("KeyNub error: " ^ Printexc.to_string e);
    exit 1
