#!/usr/bin/env wolframscript
(* KeyNub dongle check from the Wolfram Language: enumerate -> open -> verify ->
   session -> read a record -> app-crypto round trip.

     wolframscript -f verify_and_read.wls         (from samples/wolfram)

   Run from this checkout the paclet finds the native library in
   natives/<platform> on its own; elsewhere set KEYNUB_LICDONGLE_FLAT_LIBRARY or
   call LicDongleLibraryPath[path] first. Note the library: the paclet goes
   through the flat companion API, so it wants keynub_licdongle_flat.

   Targets real hardware: with no dongle attached it prints guidance and exits 0.

   READ FIRST: docs/integration-security.md. This sample prints whether the
   dongle is genuine, which is the one thing a real licence check must not do: a
   printed boolean is a deleted line away from nothing. protectSomething shows
   the shape that actually protects something. For a Wolfram package that is
   usually easy, because the valuable part is normally data: fitted parameters, a
   correlation set, a proprietary model's coefficients. *)

PacletDirectoryLoad[FileNameJoin[{DirectoryName[$InputFileName, 3], "bindings", "wolfram", "KeyNubLicDongle"}]];
Needs["KeyNubLicDongle`"];

bail[f_Failure] := (Print["KeyNub error: ", f["Message"]]; Exit[1]);

report[h_] := Module[{info = LicDongleInfo[h], g},
  If[FailureQ[info], bail[info]];
  Print[StringTemplate["Protocol v`1`.`2`, firmware v`3`.`4`.`5`, `6` of `7` bytes free."][
    Sequence @@ info["ProtocolVersion"], Sequence @@ info["FirmwareVersion"], info["DataFree"], info["DataCapacity"]]];
  If[info["WatchdogReboot"],
    (* The only trace a firmware hang leaves behind. Worth reporting to support. *)
    Print["WARNING: this dongle's previous boot ended in a watchdog reset."]];
  g = LicDongleVerifyGenuine[h];
  If[FailureQ[g], bail[g]];
  Print["Genuine: ", g["Genuine"], " (serial ", g["Serial"], ", provisioned ", g["ProvisionedDate"], ")"]];

readRecords[h_] := Module[{recs = LicDongleRecords[h], data},
  If[FailureQ[recs], bail[recs]];
  Print[Length[recs], " record(s) on the dongle:"];
  Scan[Print["  ", StringPadRight[#Name, 16], " ", #Size, " bytes"] &, recs];
  (* A missing record is a normal state, not an error. *)
  If[MemberQ[recs[[All, "Name"]], "license"],
    data = LicDongleReadRecord[h, "license"];
    If[FailureQ[data], bail[data]];
    Print["Read ", Length[data], " bytes from the license record."]]];

(* The part that actually protects something. At licence-issue time you would
   call LicDongleAppEncrypt once, with a developer dongle, and ship only the
   sealed data; the program then cannot proceed without a dongle, because it
   holds no other copy. "Developer" lets any dongle you have issued decrypt it,
   so one file serves every customer; "Device" locks it to one dongle. *)
protectSomething[h_] := Module[{needed = "the data this program cannot run without", sealed, recovered},
  sealed = LicDongleAppEncrypt[h, needed, "Developer"];
  If[FailureQ[sealed], bail[sealed]];
  recovered = LicDongleAppDecrypt[h, sealed];
  If[FailureQ[recovered], bail[recovered]];
  Print["App-crypto round trip: ", StringLength[needed], " bytes -> ", Length[sealed], " sealed -> ",
    If[ByteArrayToString[recovered] === needed, "recovered intact", "MISMATCH"]]];

version = LicDongleLibraryVersion[];
Print["KeyNub SDK ", StringRiffle[ToString /@ version, "."], " (", LicDongleLibraryPath[], ")"];
devices = LicDongleDevices[];
If[FailureQ[devices], bail[devices]];
Print["Found ", Length[devices], " KeyNub dongle(s)."];
MapIndexed[Print["  [", First[#2] - 1, "] serial ", #1["Serial"]] &, devices];
If[devices === {}, Print["No dongle attached; nothing to do."]; Exit[0]];

h = LicDongleOpen[];                         (* first dongle, or LicDongleOpen[serial] *)
If[FailureQ[h], bail[h]];
report[h];
If[FailureQ[LicDongleSessionOpen[h]], bail[LicDongleSessionOpen[h]]];
readRecords[h];
protectSomething[h];
LicDongleSessionClose[h];
LicDongleClose[h];
