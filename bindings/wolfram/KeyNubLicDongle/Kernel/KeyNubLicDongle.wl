(* ::Package:: *)

(* KeyNub License Dongle for the Wolfram Language.

   Calls the SDK's flat companion API (keynub_licdongle_flat) through
   ForeignFunctionLoad, which the Wolfram Language has had since 13.1. The flat
   API has no structures, no library-allocated memory and no callbacks: integer
   handles, caller-provided buffers and strings only, which is what a foreign
   function interface expresses without hand-written structure layouts. The
   cost is no progress reporting; records are read in one call.

   Failures come back as Failure objects with "Status", "Operation" and
   "Detail". LicDongleGenuineQ is the non-failing form for a gate and fails
   closed. *)

BeginPackage["KeyNubLicDongle`"];

LicDongleLibraryPath::usage = "LicDongleLibraryPath[] gives the native library in use, or the one the next call would load. LicDongleLibraryPath[path] names the library to load; call it before the first call.";
LicDongleLibraryVersion::usage = "LicDongleLibraryVersion[] gives {major, minor, patch} of the loaded native library.";
LicDongleDevices::usage = "LicDongleDevices[] lists the attached dongles as associations with \"Serial\" and \"Path\".";
LicDongleOpen::usage = "LicDongleOpen[] opens the first dongle; LicDongleOpen[serial] the one with that serial. Gives a handle, or a Failure.";
LicDongleOpenPath::usage = "LicDongleOpenPath[path] opens the dongle at a device path from LicDongleDevices.";
LicDongleClose::usage = "LicDongleClose[handle] releases a dongle.";
LicDongleInfo::usage = "LicDongleInfo[handle] gives the plaintext device information as an association.";
LicDongleSerial::usage = "LicDongleSerial[handle] gives the dongle's serial as hex.";
LicDongleVerifyGenuine::usage = "LicDongleVerifyGenuine[handle] proves authenticity; gives an association with \"Genuine\", \"Serial\" and \"ProvisionedDate\", or a Failure.";
LicDongleGenuineQ::usage = "LicDongleGenuineQ[handle] is True only when the dongle proves genuine; every failure gives False.";
LicDongleSetTrustRoot::usage = "LicDongleSetTrustRoot[handle, ByteArray] replaces the CA root that LicDongleVerifyGenuine checks against. Applications do not need this.";
LicDongleSessionOpen::usage = "LicDongleSessionOpen[handle] opens the encrypted session that records, counters and app-data encryption need.";
LicDongleSessionClose::usage = "LicDongleSessionClose[handle] ends the session.";
LicDongleAuthorizeWrite::usage = "LicDongleAuthorizeWrite[handle, ByteArray] elevates the session to the write role with the dongle's write key (P-256 private key, PKCS#8 DER).";
LicDongleRotateWriteKey::usage = "LicDongleRotateWriteKey[handle, ByteArray] replaces the dongle's write key with one you hold; needs the write role.";
LicDongleRecords::usage = "LicDongleRecords[handle] lists the records as associations with \"Name\" and \"Size\".";
LicDongleReadRecord::usage = "LicDongleReadRecord[handle, name] gives a record as a ByteArray.";
LicDongleWriteRecord::usage = "LicDongleWriteRecord[handle, name, data] replaces a record with a ByteArray or a String; needs the write role.";
LicDongleEraseRecord::usage = "LicDongleEraseRecord[handle, name] erases one record; needs the write role.";
LicDongleEraseAllRecords::usage = "LicDongleEraseAllRecords[handle] erases every record; needs the write role.";
LicDongleReadCounter::usage = "LicDongleReadCounter[handle, id] reads a hardware monotonic counter.";
LicDongleIncrementCounter::usage = "LicDongleIncrementCounter[handle, id] increments a counter, irreversibly; needs the write role.";
LicDongleAppEncrypt::usage = "LicDongleAppEncrypt[handle, data, scope] seals a ByteArray or String so that only a dongle can open it; scope is \"Device\" or \"Developer\".";
LicDongleAppDecrypt::usage = "LicDongleAppDecrypt[handle, ByteArray] opens data sealed with LicDongleAppEncrypt.";
LicDongleStatusText::usage = "LicDongleStatusText[status] gives the library's text for a status code.";
LicDongleLastErrorDetail::usage = "LicDongleLastErrorDetail[handle] gives the library's diagnostic detail for the most recent failure on that handle.";

Begin["`Private`"];

(* ---- the library -------------------------------------------------------- *)

$chosenPath = None;
$loadedPath = None;
$api = None;

defaultBasename[] := Switch[$OperatingSystem,
  "Windows", "keynub_licdongle_flat.dll",
  "MacOSX", "libkeynub_licdongle_flat.dylib",
  _, "libkeynub_licdongle_flat.so"];

(* The natives/<platform> folder name of the SDK repository for this kernel. *)
platformFolder[] := Switch[$SystemID,
  "Windows-x86-64", "win-x64",
  "Windows-ARM64", "win-arm64",
  "Windows", "win-x86",
  "Linux-x86-64", "linux-x64",
  "Linux-ARM64", "linux-arm64",
  "MacOSX-x86-64", "osx-x64",
  "MacOSX-ARM64", "osx-arm64",
  _, "unknown"];

(* KEYNUB_LICDONGLE_FLAT_LIBRARY, then natives/<platform> of a clone found from
   the working directory upwards, then the bare name along the loader's path. *)
resolvePath[] := Module[{env, dir, candidate, parent},
  env = Environment["KEYNUB_LICDONGLE_FLAT_LIBRARY"];
  If[StringQ[env] && env =!= "", Return[env]];
  dir = Directory[];
  Do[
    candidate = FileNameJoin[{dir, "natives", platformFolder[], defaultBasename[]}];
    If[FileExistsQ[candidate], Return[candidate, Module]];
    parent = ParentDirectory[dir];
    If[parent === dir, Break[]];
    dir = parent,
    {8}];
  defaultBasename[]];

LicDongleLibraryPath[] := Which[$loadedPath =!= None, $loadedPath, $chosenPath =!= None, $chosenPath, True, resolvePath[]];
LicDongleLibraryPath[path_String] := (
  If[$loadedPath =!= None && path =!= $loadedPath,
    Return[Failure["LicDongleLibrary", <|"MessageTemplate" -> "the KeyNub library is already loaded from `Path`; a kernel loads it once", "MessageParameters" -> <|"Path" -> $loadedPath|>|>]]];
  $chosenPath = path);

(* One ForeignFunction per flat-API entry, bound by name. *)
api[] := Module[{path, lib, ff},
  If[$api =!= None, Return[$api]];
  path = If[$chosenPath =!= None, $chosenPath, resolvePath[]];
  ff[name_, sig_] := ForeignFunctionLoad[path, name, sig];
  $api = <|
    "version" -> ff["licdf_version", {"RawPointer"::["Integer32"], "RawPointer"::["Integer32"], "RawPointer"::["Integer32"]} -> "Integer32"],
    "device_count" -> ff["licdf_device_count", {"RawPointer"::["Integer32"]} -> "Integer32"],
    "device_serial" -> ff["licdf_device_serial", {"Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32"} -> "Integer32"],
    "device_path" -> ff["licdf_device_path", {"Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32"} -> "Integer32"],
    "open" -> ff["licdf_open", {"RawPointer"::["UnsignedInteger8"]} -> "Integer32"],
    "open_path" -> ff["licdf_open_path", {"RawPointer"::["UnsignedInteger8"]} -> "Integer32"],
    "close" -> ff["licdf_close", {"Integer32"} -> "Integer32"],
    "set_trust_root" -> ff["licdf_set_trust_root", {"Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32"} -> "Integer32"],
    "get_serial" -> ff["licdf_get_serial", {"Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32"} -> "Integer32"],
    "get_info" -> ff["licdf_get_info", {"Integer32", "RawPointer"::["Integer32"], "RawPointer"::["Integer32"], "RawPointer"::["Integer32"], "RawPointer"::["Integer32"], "RawPointer"::["Integer32"], "RawPointer"::["Integer32"], "RawPointer"::["Integer32"], "RawPointer"::["Integer32"]} -> "Integer32"],
    "verify_genuine" -> ff["licdf_verify_genuine", {"Integer32", "RawPointer"::["Integer32"], "RawPointer"::["UnsignedInteger8"], "Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32"} -> "Integer32"],
    "session_open" -> ff["licdf_session_open", {"Integer32"} -> "Integer32"],
    "session_close" -> ff["licdf_session_close", {"Integer32"} -> "Integer32"],
    "write_auth" -> ff["licdf_write_auth", {"Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32"} -> "Integer32"],
    "write_auth_rotate" -> ff["licdf_write_auth_rotate", {"Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32"} -> "Integer32"],
    "record_count" -> ff["licdf_record_count", {"Integer32", "RawPointer"::["Integer32"]} -> "Integer32"],
    "record_name" -> ff["licdf_record_name", {"Integer32", "Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32", "RawPointer"::["Integer32"]} -> "Integer32"],
    "record_read" -> ff["licdf_record_read", {"Integer32", "RawPointer"::["UnsignedInteger8"], "RawPointer"::["UnsignedInteger8"], "Integer32", "RawPointer"::["Integer32"]} -> "Integer32"],
    "record_write" -> ff["licdf_record_write", {"Integer32", "RawPointer"::["UnsignedInteger8"], "RawPointer"::["UnsignedInteger8"], "Integer32"} -> "Integer32"],
    "record_erase" -> ff["licdf_record_erase", {"Integer32", "RawPointer"::["UnsignedInteger8"]} -> "Integer32"],
    "record_erase_all" -> ff["licdf_record_erase_all", {"Integer32"} -> "Integer32"],
    "counter_read" -> ff["licdf_counter_read", {"Integer32", "Integer32", "RawPointer"::["Integer32"]} -> "Integer32"],
    "counter_increment" -> ff["licdf_counter_increment", {"Integer32", "Integer32", "RawPointer"::["Integer32"]} -> "Integer32"],
    "app_encrypt" -> ff["licdf_app_encrypt", {"Integer32", "Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32", "RawPointer"::["Integer32"]} -> "Integer32"],
    "app_decrypt" -> ff["licdf_app_decrypt", {"Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32", "RawPointer"::["Integer32"]} -> "Integer32"],
    "strerror" -> ff["licdf_strerror", {"Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32"} -> "Integer32"],
    "last_error" -> ff["licdf_last_error", {"Integer32", "RawPointer"::["UnsignedInteger8"], "Integer32"} -> "Integer32"]
  |>;
  $loadedPath = path;
  $api];

(* ---- memory helpers ----------------------------------------------------- *)

(* RawMemoryAllocate gives a managed pointer in current versions, freed with the
   object; an older kernel gives an unmanaged RawPointer, which is freed here. *)
release[p_RawPointer] := RawMemoryFree[p];
release[_] := Null;

(* A zero-filled byte buffer for a string the library may or may not fill: an
   unwritten buffer then reads back as "" rather than as leftover memory. *)
zeroed[n_Integer] := RawMemoryExport[ByteArray[ConstantArray[0, n]]];

$statusRange = -11;   (* LICD_E_RANGE: the buffer was too small; *out_len is the size *)

(* Calls f with a fresh Integer32 cell and gives {result, value}. *)
withInt[f_] := Module[{p = RawMemoryAllocate["Integer32", 1], r},
  RawMemoryWrite[p, 0];
  r = f[p];
  {r, RawMemoryRead[p]} // (release[p]; #) &];

(* A NUL-terminated string in a buffer the library filled. *)
readCString[p_, n_] := RawMemoryImport[p, "String", CharacterEncoding -> "UTF-8"];

toBytes[data_ByteArray] := data;
toBytes[data_String] := StringToByteArray[data, "UTF-8"];

(* A string for a const char* argument: its UTF-8 bytes with the terminating
   NUL, exported to managed memory. *)
cstr[s_String] := RawMemoryExport[Join[StringToByteArray[s, "UTF-8"], ByteArray[{0}]]];

(* Exports a ByteArray to raw memory; gives {pointer, length}. RawMemoryExport
   gives a managed pointer, freed with the object; an empty array gets a
   one-byte buffer with length 0 so that the C side never sees a null pointer
   with a non-zero length. *)
exportBytes[data_ByteArray] := Module[{n = Length[data]},
  {If[n > 0, RawMemoryExport[data], RawMemoryExport[ByteArray[{0}]]], n}];

(* ---- failures ----------------------------------------------------------- *)

LicDongleStatusText[status_Integer] := Module[{r, p},
  p = zeroed[256];
  r = api[]["strerror"][status, p, 256];
  With[{text = If[r == 0, readCString[p, 256], "status " <> ToString[status]]}, release[p]; text]];

LicDongleLastErrorDetail[handle_Integer] := Module[{r, p},
  p = zeroed[256];
  r = api[]["last_error"][handle, p, 256];
  With[{text = If[r == 0, readCString[p, 256], ""]}, release[p]; text]];

fail[status_Integer, operation_String, detail_String] := Failure["LicDongleError", <|
  "MessageTemplate" -> If[detail === "", "`Operation`: `Message`", "`Operation`: `Message` (`Detail`)"],
  "MessageParameters" -> <|"Operation" -> operation, "Message" -> LicDongleStatusText[status], "Detail" -> detail|>,
  "Status" -> status, "Operation" -> operation, "Detail" -> detail|>];

failOn[handle_Integer, status_Integer, operation_String] :=
  fail[status, operation, If[handle > 0, LicDongleLastErrorDetail[handle], ""]];

(* Runs body; a non-zero status becomes a Failure carrying the handle's detail. *)
SetAttributes[check, HoldRest];
check[handle_, operation_, status_, value_] := If[status == 0, value, failOn[handle, status, operation]];

(* ---- module level ------------------------------------------------------- *)

LicDongleLibraryVersion[] := Module[{a, b, c, r},
  {a, b, c} = RawMemoryAllocate["Integer32", 1] & /@ Range[3];
  r = api[]["version"][a, b, c];
  With[{v = RawMemoryRead /@ {a, b, c}}, release /@ {a, b, c}; v]];

LicDongleDevices[] := Module[{r, count, serial, path, devices},
  {r, count} = withInt[api[]["device_count"][#] &];
  If[r != 0, Return[fail[r, "licdf_device_count", ""]]];
  devices = Table[
    Module[{sp = zeroed[15], pp = zeroed[512]},
      api[]["device_serial"][i, sp, 15];
      api[]["device_path"][i, pp, 512];
      With[{s = readCString[sp, 15], p = readCString[pp, 512]}, release /@ {sp, pp};
        <|"Serial" -> s, "Path" -> p|>]],
    {i, 0, count - 1}];
  devices];

LicDongleOpen[] := LicDongleOpen[""];
LicDongleOpen[serial_String] := Module[{h = api[]["open"][cstr[serial]]},
  If[h > 0, h, fail[h, "licdf_open", ""]]];
LicDongleOpenPath[path_String] := Module[{h = api[]["open_path"][cstr[path]]},
  If[h > 0, h, fail[h, "licdf_open_path", ""]]];
LicDongleClose[handle_Integer] := check[handle, "licdf_close", api[]["close"][handle], Null];

LicDongleSetTrustRoot[handle_Integer, der_ByteArray] := Module[{p, n, r},
  {p, n} = exportBytes[der];
  r = api[]["set_trust_root"][handle, p, n];
  check[handle, "licdf_set_trust_root", r, Null]];

LicDongleSerial[handle_Integer] := Module[{p = zeroed[15], r},
  r = api[]["get_serial"][handle, p, 15];
  With[{s = readCString[p, 15]}, release[p]; check[handle, "licdf_get_serial", r, s]]];

LicDongleInfo[handle_Integer] := Module[{cells, r, v},
  cells = RawMemoryAllocate["Integer32", 1] & /@ Range[8];
  r = api[]["get_info"] @@ Prepend[cells, handle];
  v = RawMemoryRead /@ cells;
  release /@ cells;
  check[handle, "licdf_get_info", r, <|
    "ProtocolVersion" -> v[[1 ;; 2]],
    "FirmwareVersion" -> v[[3 ;; 5]],
    "SecureElementReady" -> BitAnd[v[[6]], 1] != 0,
    "Provisioned" -> BitAnd[v[[6]], 2] != 0,
    "WatchdogReboot" -> BitAnd[v[[6]], 4] != 0,
    "Isolated" -> BitAnd[v[[6]], 8] != 0,
    "WriteAuthRotated" -> BitAnd[v[[6]], 16] != 0,
    "DataCapacity" -> v[[7]],
    "DataFree" -> v[[8]]|>]];

LicDongleVerifyGenuine[handle_Integer] := Module[{g = RawMemoryAllocate["Integer32", 1], sp, dp, r, genuine, serial, date},
  sp = zeroed[15];
  dp = zeroed[11];
  RawMemoryWrite[g, 0];
  r = api[]["verify_genuine"][handle, g, sp, 15, dp, 11];
  genuine = RawMemoryRead[g]; serial = readCString[sp, 15]; date = readCString[dp, 11];
  release /@ {g, sp, dp};
  Which[
    r != 0, failOn[handle, r, "licdf_verify_genuine"],
    genuine == 0, fail[-7, "licdf_verify_genuine", ""],
    True, <|"Genuine" -> True, "Serial" -> serial, "ProvisionedDate" -> date|>]];

LicDongleGenuineQ[handle_Integer] := AssociationQ[Quiet[LicDongleVerifyGenuine[handle]]];
LicDongleGenuineQ[_] := False;

LicDongleSessionOpen[handle_Integer] := check[handle, "licdf_session_open", api[]["session_open"][handle], Null];
LicDongleSessionClose[handle_Integer] := check[handle, "licdf_session_close", api[]["session_close"][handle], Null];

bytesCall[handle_Integer, operation_String, fn_String, data_ByteArray] := Module[{p, n, r},
  {p, n} = exportBytes[data];
  r = api[][fn][handle, p, n];
  check[handle, operation, r, Null]];

LicDongleAuthorizeWrite[handle_Integer, key_ByteArray] := bytesCall[handle, "licdf_write_auth", "write_auth", key];
LicDongleRotateWriteKey[handle_Integer, key_ByteArray] := bytesCall[handle, "licdf_write_auth_rotate", "write_auth_rotate", key];

LicDongleRecords[handle_Integer] := Module[{r, count},
  {r, count} = withInt[api[]["record_count"][handle, #] &];
  If[r != 0, Return[failOn[handle, r, "licdf_record_count"]]];
  Table[
    Module[{np = zeroed[64], sz = RawMemoryAllocate["Integer32", 1], rc},
      rc = api[]["record_name"][handle, i, np, 64, sz];
      With[{name = readCString[np, 64], size = RawMemoryRead[sz]}, release /@ {np, sz};
        If[rc != 0, failOn[handle, rc, "licdf_record_name"], <|"Name" -> name, "Size" -> size|>]]],
    {i, 0, count - 1}]];

(* The flat API's two-call size protocol: a zero-capacity call answers RANGE
   with the size needed, so nothing guesses a buffer size. *)
twoCall[handle_Integer, operation_String, call_] := Module[{r, needed, p, got, out},
  {r, needed} = withInt[call[RawMemoryExport[ByteArray[{0}]], 0, #] &];
  If[r != 0 && r != $statusRange, Return[failOn[handle, r, operation]]];
  If[needed == 0, Return[ByteArray[{}]]];
  p = zeroed[needed];
  {r, got} = withInt[call[p, needed, #] &];
  out = If[r == 0, RawMemoryImport[p, {"ByteArray", got}], failOn[handle, r, operation]];
  release[p];
  out];

LicDongleReadRecord[handle_Integer, name_String] := (
  If[name === "", Return[fail[-1, "licdf_record_read", "the record name must not be empty"]]];
  twoCall[handle, "licdf_record_read", api[]["record_read"][handle, cstr[name], #1, #2, #3] &]);

LicDongleWriteRecord[handle_Integer, name_String, data_] := Module[{p, n, r},
  If[name === "", Return[fail[-1, "licdf_record_write", "the record name must not be empty"]]];
  {p, n} = exportBytes[toBytes[data]];
  r = api[]["record_write"][handle, cstr[name], p, n];
  check[handle, "licdf_record_write", r, Null]];

LicDongleEraseRecord[handle_Integer, name_String] := (
  (* To the C library an empty name would mean nothing here; the flat API keeps
     "erase everything" as its own function, and so does this paclet. *)
  If[name === "", Return[fail[-1, "licdf_record_erase", "the record name must not be empty; use LicDongleEraseAllRecords"]]];
  check[handle, "licdf_record_erase", api[]["record_erase"][handle, cstr[name]], Null]);
LicDongleEraseAllRecords[handle_Integer] := check[handle, "licdf_record_erase_all", api[]["record_erase_all"][handle], Null];

LicDongleReadCounter[handle_Integer, id_Integer] := Module[{r, v},
  {r, v} = withInt[api[]["counter_read"][handle, id, #] &];
  check[handle, "licdf_counter_read", r, v]];
LicDongleIncrementCounter[handle_Integer, id_Integer] := Module[{r, v},
  {r, v} = withInt[api[]["counter_increment"][handle, id, #] &];
  check[handle, "licdf_counter_increment", r, v]];

scopeCode["Device"] = 0;
scopeCode["Developer"] = 1;

LicDongleAppEncrypt[handle_Integer, data_, scope : ("Device" | "Developer") : "Device"] := Module[{p, n, out},
  {p, n} = exportBytes[toBytes[data]];
  twoCall[handle, "licdf_app_encrypt", api[]["app_encrypt"][handle, scopeCode[scope], p, n, #1, #2, #3] &]];

LicDongleAppDecrypt[handle_Integer, packed_ByteArray] := Module[{p, n, out},
  {p, n} = exportBytes[packed];
  twoCall[handle, "licdf_app_decrypt", api[]["app_decrypt"][handle, p, n, #1, #2, #3] &]];

End[];
EndPackage[];
