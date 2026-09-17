(* KeyNub SDK - OCaml sample: take ownership of a new dongle.

   A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
   so that from the next session onward only your key can write records, erase
   them or increment counters. Run it once per dongle, when it arrives.

   Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:

     openssl ecparam -name prime256v1 -genkey -noout |
       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der

     dune exec samples/ocaml/rotate_write_key.exe -- keys/keynub-shipping-writeauth.key.der my-key.der

   Targets real hardware: with no dongle attached it prints guidance and exits 0.

   The replacement key is worth what your licence-signing key is worth. It
   cannot be recovered from the dongle, and a unit rotated to a key you have
   lost has to come back to be re-provisioned. *)

open Keynub_licdongle

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let run current replacement =
  if devices () = [] then print_endline "Connect a KeyNub dongle and re-run."
  else
    with_dongle (fun d ->
        Printf.printf "Dongle %s\n" (serial d);
        if (info d).write_auth_rotated then
          print_endline "This dongle's write key has already been rotated away from the factory one.";
        with_session d (fun () ->
            authorize_write d current;          (* the key the dongle accepts today *)
            rotate_write_key d replacement);    (* from the next session: only the new one *)
        Printf.printf "Write key rotated: %s\n" (if (info d).write_auth_rotated then "yes" else "no"))

let () =
  match Sys.argv with
  | [| _; current; replacement |] -> (
    try run (read_file current) (read_file replacement)
    with e ->
      print_endline ("KeyNub error: " ^ Printexc.to_string e);
      exit 1)
  | _ ->
    print_endline "usage: rotate_write_key <current-key.der> <new-key.der>";
    exit 2
