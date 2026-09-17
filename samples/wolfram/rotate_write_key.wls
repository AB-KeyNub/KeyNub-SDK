#!/usr/bin/env wolframscript
(* KeyNub SDK - Wolfram Language sample: take ownership of a new dongle.

   A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
   so that from the next session onward only your key can write records, erase
   them or increment counters. Run it once per dongle, when it arrives.

   Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:

     openssl ecparam -name prime256v1 -genkey -noout |
       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der

     wolframscript -f rotate_write_key.wls ../../keys/keynub-shipping-writeauth.key.der my-key.der

   Targets real hardware: with no dongle attached it prints guidance and exits 0.

   The replacement key is worth what your licence-signing key is worth. It
   cannot be recovered from the dongle, and a unit rotated to a key you have
   lost has to come back to be re-provisioned. *)

PacletDirectoryLoad[FileNameJoin[{DirectoryName[$InputFileName, 3], "bindings", "wolfram", "KeyNubLicDongle"}]];
Needs["KeyNub`KeyNubLicDongle`"];

bail[f_Failure] := (Print["KeyNub error: ", f["Message"]]; Exit[1]);
readKey[path_] := If[FileExistsQ[path], ReadByteArray[path], Print["cannot open ", path]; Exit[2]];

If[Length[$ScriptCommandLine] != 3,
  Print["usage: wolframscript -f rotate_write_key.wls <current-key.der> <new-key.der>"]; Exit[2]];
current = readKey[$ScriptCommandLine[[2]]];
replacement = readKey[$ScriptCommandLine[[3]]];

If[LicDongleDevices[] === {}, Print["Connect a KeyNub dongle and re-run."]; Exit[0]];
h = LicDongleOpen[];
If[FailureQ[h], bail[h]];
Print["Dongle ", LicDongleSerial[h]];
If[LicDongleInfo[h]["WriteAuthRotated"],
  Print["This dongle's write key has already been rotated away from the factory one."]];

LicDongleSessionOpen[h];
r = LicDongleAuthorizeWrite[h, current];          (* the key the dongle accepts today *)
If[FailureQ[r], bail[r]];
r = LicDongleRotateWriteKey[h, replacement];      (* from the next session: only the new one *)
If[FailureQ[r], bail[r]];
LicDongleSessionClose[h];

Print["Write key rotated: ", If[LicDongleInfo[h]["WriteAuthRotated"], "yes", "no"]];
LicDongleClose[h];
