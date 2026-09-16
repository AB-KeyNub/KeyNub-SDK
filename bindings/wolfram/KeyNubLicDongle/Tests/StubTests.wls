#!/usr/bin/env wolframscript
(* Tests against a stand-in for the flat C API: KEYNUB_LICDONGLE_FLAT_LIBRARY
   must name a compiled keynub_licdongle_flat whose core is the SDK's C ABI
   stand-in (bindings/julia/test/stub/licd_stub.c). Every call of the paclet
   runs end to end without hardware.

     wolframscript -f Tests/StubTests.wls        (from the paclet folder)

   Exit code 0 when every check passed. *)

PacletDirectoryLoad[DirectoryName[$InputFileName, 2]];
Needs["KeyNubLicDongle`"];

failures = 0;
check[cond_, what_] := If[TrueQ[cond], Null, failures++; Print["  FAIL  ", what]];
failureWith[status_] := _Failure?(#["Status"] === status &);

lib = Environment["KEYNUB_LICDONGLE_FLAT_LIBRARY"];
If[!StringQ[lib] || lib === "",
  Print["KEYNUB_LICDONGLE_FLAT_LIBRARY must name the compiled stand-in"]; Exit[2]];
LicDongleLibraryPath[lib];

factoryKey = ByteArray[{16^^30, 16^^10, 16^^01, 16^^02, 16^^03}];
replacementKey = ByteArray[{16^^30, 16^^11, 16^^09, 16^^08, 16^^07, 16^^06}];
serial = "04A1B2C3D4E5F6";

check[LicDongleLibraryVersion[] === {9, 8, 7}, "the stand-in reports 9.8.7"];
check[LicDongleStatusText[-2] === "no device", "strerror text"];

devices = LicDongleDevices[];
check[Length[devices] == 1 && devices[[1, "Serial"]] === serial && devices[[1, "Path"]] === "stub:0", "enumeration"];
check[MatchQ[LicDongleOpen["nope"], failureWith[-2]], "open with a wrong serial"];
check[MatchQ[LicDongleOpenPath["stub:9"], failureWith[-2]], "open at a wrong path"];

h = LicDongleOpen[];
check[IntegerQ[h] && h > 0, "open the first dongle"];
check[LicDongleSerial[h] === serial, "serial"];
info = LicDongleInfo[h];
check[info["ProtocolVersion"] === {1, 0} && info["FirmwareVersion"] === {2, 3, 4}, "versions"];
check[info["SecureElementReady"] && info["Provisioned"] && info["Isolated"], "flags set"];
check[!info["WatchdogReboot"] && !info["WriteAuthRotated"], "flags clear"];
check[info["DataCapacity"] == 1024*1024 && info["DataFree"] == 1000000, "storage"];
g = LicDongleVerifyGenuine[h];
check[g["Genuine"] && g["Serial"] === serial && g["ProvisionedDate"] === "2026-08-15", "genuine"];
check[LicDongleGenuineQ[h], "GenuineQ"];

check[MatchQ[LicDongleSetTrustRoot[h, ByteArray[{16^^02, 16^^01, 16^^00}]], failureWith[-8]], "a non-DER root is refused"];
LicDongleSetTrustRoot[h, ByteArray[Join[{16^^30, 16^^82, 16^^01, 16^^00}, ConstantArray[16^^AB, 128]]]];
check[MatchQ[LicDongleVerifyGenuine[h], failureWith[-8]], "verification under a foreign root"];
check[!LicDongleGenuineQ[h], "GenuineQ fails closed"];
LicDongleSetTrustRoot[h, ByteArray[Join[{16^^30, 16^^82, 16^^01, 16^^00}, ConstantArray[16^^01, 128]]]];
check[LicDongleGenuineQ[h], "genuine again under the issuing root"];

check[MatchQ[LicDongleRecords[h], failureWith[-9]], "records need a session"];
LicDongleSessionOpen[h];
payload = StringToByteArray["license-blob-0123456789"];
check[MatchQ[LicDongleWriteRecord[h, "lic", payload], failureWith[-15]], "writing needs the write role"];
check[MatchQ[LicDongleAuthorizeWrite[h, ByteArray[{16^^30, 16^^00}]], failureWith[-7]], "a wrong key does not elevate"];
LicDongleAuthorizeWrite[h, factoryKey];
LicDongleWriteRecord[h, "lic", payload];
check[LicDongleReadRecord[h, "lic"] === payload, "read back what was written"];
LicDongleWriteRecord[h, "cfg", "cfgdata"];
recs = LicDongleRecords[h];
check[Sort[recs[[All, "Name"]]] === {"cfg", "lic"}, "record names"];
check[SelectFirst[recs, #Name === "lic" &]["Size"] == Length[payload], "record size"];
check[ByteArrayToString[LicDongleReadRecord[h, "cfg"]] === "cfgdata", "a string is stored as its bytes"];
check[MatchQ[LicDongleReadRecord[h, "nope"], failureWith[-14]], "reading a missing record"];
check[MatchQ[LicDongleEraseRecord[h, ""], failureWith[-1]], "an empty name never erases"];
check[Length[LicDongleRecords[h]] == 2, "nothing erased by mistake"];
LicDongleEraseRecord[h, "cfg"];
check[LicDongleRecords[h][[All, "Name"]] === {"lic"}, "one record after the erase"];
LicDongleWriteRecord[h, "empty", ByteArray[{}]];
check[LicDongleReadRecord[h, "empty"] === ByteArray[{}], "an empty record reads back empty"];

before = LicDongleReadCounter[h, 0];
check[LicDongleIncrementCounter[h, 0] == before + 1, "increment returns the new value"];
check[LicDongleReadCounter[h, 0] == before + 1 && LicDongleReadCounter[h, 1] == 0, "counters"];
check[MatchQ[LicDongleReadCounter[h, 7], failureWith[-11]], "a counter the dongle lacks"];

secret = ByteArray[Table[Mod[3 i + 7, 256], {i, 0, 99}]];
Do[
  blob = LicDongleAppEncrypt[h, secret, scope];
  check[Length[blob] > Length[secret], "sealed data is longer, " <> scope];
  check[Normal[blob][[1]] == If[scope === "Device", 0, 1], "scope byte " <> scope];
  check[LicDongleAppDecrypt[h, blob] === secret, "round trip " <> scope];
  tampered = ByteArray[MapAt[BitXor[#, 1] &, Normal[blob], -1]];
  check[MatchQ[LicDongleAppDecrypt[h, tampered], failureWith[-10]], "tampered data " <> scope],
  {scope, {"Device", "Developer"}}];
check[ByteArrayToString[LicDongleAppDecrypt[h, LicDongleAppEncrypt[h, "text"]]] === "text", "a string round-trips"];
LicDongleEraseAllRecords[h];
check[LicDongleRecords[h] === {}, "erase all leaves nothing"];

check[MatchQ[LicDongleRotateWriteKey[h, replacementKey], Null], "rotation with the write role"];
LicDongleWriteRecord[h, "lic", "still-writable"];
LicDongleSessionClose[h];
check[LicDongleInfo[h]["WriteAuthRotated"], "the rotation flag is set"];
LicDongleSessionOpen[h];
check[MatchQ[LicDongleAuthorizeWrite[h, factoryKey], failureWith[-7]], "the factory key no longer elevates"];
LicDongleAuthorizeWrite[h, replacementKey];
LicDongleWriteRecord[h, "lic", "new-key-writes"];
check[ByteArrayToString[LicDongleReadRecord[h, "lic"]] === "new-key-writes", "the new key writes"];
LicDongleSessionClose[h];
LicDongleClose[h];
check[MatchQ[LicDongleSerial[h], _Failure], "a closed handle refuses calls"];

If[failures == 0,
  Print["KeyNubLicDongle: every call passed against the ABI stand-in"]; Exit[0],
  Print[failures, " check(s) failed"]; Exit[1]];
