// Every call of the binding against a stand-in for the flat C API: the SDK's
// flat layer compiled together with the C ABI stand-in
// (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
// into one shared library, with a C compiler from the path (cc, gcc, clang,
// zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
// stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the
// test does not run inside a clone. Exit code 0 when every check passed.
//
//     deno run -A bindings/deno/test/standin_test.ts      (from the repository root)
import {
  devices,
  Dongle,
  LIBRARY_ENVIRONMENT_VARIABLE,
  libraryPath,
  libraryVersion,
  LicDongleError,
  loadedLibraryPath,
  Scope,
  setLibraryPath,
  Status,
  statusName,
  statusText,
  withDongle,
} from "../mod.ts";

const SERIAL = "04A1B2C3D4E5F6";
const FACTORY_KEY = new Uint8Array([0x30, 0x10, 0x01, 0x02, 0x03]);
const REPLACEMENT_KEY = new Uint8Array([0x30, 0x11, 0x09, 0x08, 0x07, 0x06]);

let failures = 0;

function check(condition: boolean, what: string): void {
  if (condition) return;
  failures++;
  console.log(`  FAIL  ${what}`);
}

function fails(status: Status, what: string, body: () => unknown): void {
  try {
    body();
    check(false, `${what}: no failure`);
  } catch (e) {
    if (e instanceof LicDongleError) check(e.status === status, `${what}: ${statusName(e.code)}`);
    else check(false, `${what}: ${e}`);
  }
}

function bytes(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

function equal(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((v, k) => v === b[k]);
}

// ---- the stand-in ----------------------------------------------------------

const windows = Deno.build.os === "windows";
const sep = windows ? "\\" : "/";

function isFile(path: string): boolean {
  try {
    return Deno.statSync(path).isFile;
  } catch {
    return false;
  }
}

function sdkRoot(): string {
  const given = Deno.env.get("KEYNUB_SDK_ROOT");
  if (given) return given;
  let dir = Deno.cwd();
  for (;;) {
    if (isFile([dir, "bindings", "flat", "licd_flat.c"].join(sep))) return dir;
    const at = Math.max(dir.lastIndexOf("/"), dir.lastIndexOf("\\"));
    const parent = at > 0 ? dir.slice(0, at) : dir;
    if (parent === dir || /^[A-Za-z]:$/.test(parent)) break;
    dir = parent;
  }
  console.log("the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT");
  Deno.exit(1);
}

function buildStandIn(): string {
  const root = sdkRoot();
  const tmp = Deno.makeTempDirSync();
  // Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf
  // name even for an absolute-path dlopen, and a build tree on that path holds
  // the real library under that name.
  const output = [tmp, windows ? "keynub_flat_standin.dll" : "libkeynub_flat_standin.so"].join(sep);
  const coreInclude = [root, "core", "include"].join(sep);
  const includeDir = isFile([coreInclude, "licdongle.h"].join(sep)) ? coreInclude : [root, "include"].join(sep);
  const flatDir = [root, "bindings", "flat"].join(sep);
  const sources = [
    [flatDir, "licd_flat.c"].join(sep),
    [root, "bindings", "julia", "test", "stub", "licd_stub.c"].join(sep),
  ];
  const gccArgs = [
    "-shared",
    "-O1",
    "-DLICD_BUILD_SHARED",
    "-DLICDF_BUILD_SHARED",
    "-I" + includeDir,
    "-I" + flatDir,
    "-o",
    output,
    ...sources,
  ];
  if (!windows) gccArgs.push("-fPIC");
  const clArgs = [
    "/nologo",
    "/LD",
    "/O1",
    "/DLICD_BUILD_SHARED",
    "/DLICDF_BUILD_SHARED",
    "/I" + includeDir,
    "/I" + flatDir,
    "/Fe:" + output,
    ...sources,
  ];
  const commands: [string, string[]][] = [["cc", gccArgs], ["gcc", gccArgs], ["clang", gccArgs], ["zig", [
    "cc",
    ...gccArgs,
  ]], ["cl", clArgs]];
  for (const [command, args] of commands) {
    try {
      const result = new Deno.Command(command, { args, cwd: tmp, stdout: "null", stderr: "null" }).outputSync();
      if (result.success) return output;
    } catch {
      // not on the path
    }
  }
  console.log("the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path");
  Deno.exit(1);
}

function standIn(): string {
  return Deno.env.get(LIBRARY_ENVIRONMENT_VARIABLE) || buildStandIn();
}

// ---- the checks -------------------------------------------------------------

setLibraryPath(standIn());

const v = libraryVersion();
check(v.major === 9 && v.minor === 8 && v.patch === 7, "library version");
check(statusText(-2) === "no device", "status text");

const found = devices();
check(found.length === 1 && found[0].serial === SERIAL && found[0].path === "stub:0", "devices");
fails(Status.NoDevice, "open by unknown serial", () => Dongle.open("nope"));
fails(Status.NoDevice, "open by unknown path", () => Dongle.openPath("stub:9"));

const d = Dongle.open();
check(d.isOpen, "open");
check(d.serial === SERIAL, "serial");
const i = d.info();
check(i.protocolMajor === 1 && i.protocolMinor === 0, "protocol version");
check(i.firmwareMajor === 2 && i.firmwareMinor === 3 && i.firmwarePatch === 4, "firmware version");
check(i.secureElementReady && i.provisioned && i.isolated, "flags set");
check(!i.watchdogReboot && !i.writeAuthRotated, "flags clear");
check(i.dataCapacity === 1024 * 1024 && i.dataFree === 1_000_000, "capacity");
const g = d.verifyGenuine();
check(g.serial === SERIAL && g.provisionedDate === "2026-08-15", "genuine");
check(d.isGenuine(), "isGenuine");

fails(Status.CertInvalid, "malformed trust root", () => d.setTrustRoot(new Uint8Array([0x02, 0x01, 0x00])));
const root = new Uint8Array(132).fill(0xab);
root.set([0x30, 0x82, 0x01, 0x00]);
d.setTrustRoot(root);
fails(Status.CertInvalid, "verify against a foreign root", () => d.verifyGenuine());
check(!d.isGenuine(), "isGenuine fails closed");
root.fill(0x01, 4);
d.setTrustRoot(root);
check(d.isGenuine(), "isGenuine after the right root");

fails(Status.SessionExpired, "records without a session", () => d.records());
d.sessionOpen();
const payload = bytes("license-blob-0123456789");
fails(Status.AuthRequired, "write before the write role", () => d.writeRecord("lic", payload));
fails(Status.NotGenuine, "write role with a bad key", () => d.authorizeWrite(new Uint8Array([0x30, 0x00])));
d.authorizeWrite(FACTORY_KEY);
d.writeRecord("lic", payload);
check(equal(d.readRecord("lic"), payload), "read back");
d.writeRecord("cfg", bytes("cfgdata"));
const recs = d.records();
check(JSON.stringify(recs.map((r) => r.name).sort()) === JSON.stringify(["cfg", "lic"]), "record names");
check(recs.some((r) => r.name === "lic" && r.size === payload.length), "record size");
check(equal(d.readRecord("cfg"), bytes("cfgdata")), "second record");
fails(Status.NotFound, "read a missing record", () => d.readRecord("nope"));
fails(Status.InvalidArg, "erase with an empty name", () => d.eraseRecord(""));
check(d.records().length === 2, "two records");
d.eraseRecord("cfg");
check(JSON.stringify(d.records().map((r) => r.name)) === JSON.stringify(["lic"]), "one record left");
d.writeRecord("empty", new Uint8Array(0));
check(d.readRecord("empty").length === 0, "empty record");

const before = d.readCounter(0);
check(d.incrementCounter(0) === before + 1, "increment");
check(d.readCounter(0) === before + 1 && d.readCounter(1) === 0, "counters");
fails(Status.Range, "counter out of range", () => d.readCounter(7));

const secret = Uint8Array.from({ length: 100 }, (_, k) => (3 * k + 7) % 256);
for (const scope of [Scope.Device, Scope.Developer]) {
  const blob = d.appEncrypt(scope, secret);
  check(blob.length > secret.length, `sealed data is longer, ${Scope[scope]}`);
  check(blob[0] === scope, `scope byte, ${Scope[scope]}`);
  check(equal(d.appDecrypt(blob), secret), `round trip, ${Scope[scope]}`);
  const tampered = blob.slice();
  tampered[tampered.length - 1] ^= 1;
  fails(Status.TagMismatch, `tampered blob, ${Scope[scope]}`, () => d.appDecrypt(tampered));
}

d.eraseAllRecords();
check(d.records().length === 0, "erase all");

d.rotateWriteKey(REPLACEMENT_KEY);
d.writeRecord("lic", bytes("still-writable"));
d.sessionClose();
check(d.info().writeAuthRotated, "rotated flag");
d.sessionOpen();
fails(Status.NotGenuine, "factory key after rotation", () => d.authorizeWrite(FACTORY_KEY));
d.authorizeWrite(REPLACEMENT_KEY);
d.writeRecord("lic", bytes("new-key-writes"));
check(equal(d.readRecord("lic"), bytes("new-key-writes")), "write with the new key");
d.sessionClose();
d.close();
check(!d.isOpen, "closed");
fails(Status.InvalidArg, "serial after close", () => d.serial);

check(withDongle((dd) => dd.serial) === SERIAL, "withDongle");
// records needs a session, so a value back proves withSession opened one.
const count = withDongle((dd) => dd.withSession(() => dd.records().length), SERIAL);
check(count >= 0, "withSession");
const closed = withDongle((dd) => dd);
check(!closed.isOpen, "closed after withDongle");
let usedLater: Dongle | undefined;
{
  using u = Dongle.open();
  check(u.isOpen, "using");
  usedLater = u;
}
check(usedLater !== undefined && !usedLater.isOpen, "closed at the end of using");
check(loadedLibraryPath() === libraryPath(), "loaded path");

if (failures > 0) {
  console.log(`${failures} check(s) failed`);
  Deno.exit(1);
}
console.log("keynub_licdongle: every call passed against the ABI stand-in");
