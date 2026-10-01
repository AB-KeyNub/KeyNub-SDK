// Unit tests that need no native library: run with `deno test` from bindings/deno.
import { assertEquals, assertStringIncludes } from "@std/assert";
import { libraryBasename, LicDongleError, Scope, Status, statusName, VERSION } from "../mod.ts";

Deno.test("status names", () => {
  assertEquals(statusName(0), "Ok");
  assertEquals(statusName(-2), "NoDevice");
  assertEquals(statusName(-20), "Internal");
  assertEquals(statusName(-99), "Unknown");
});

Deno.test("error fields and message", () => {
  const e = new LicDongleError("licdf_open", -2, "nothing attached");
  assertEquals(e.status, Status.NoDevice);
  assertEquals(e.code, -2);
  assertEquals(e.operation, "licdf_open");
  assertEquals(e.detail, "nothing attached");
  assertEquals(e.message, "licdf_open: NoDevice (-2): nothing attached");
  assertEquals(new LicDongleError("x", -99).status, undefined);
});

Deno.test("scope values", () => {
  assertEquals(Scope.Device, 0);
  assertEquals(Scope.Developer, 1);
});

Deno.test("library file name", () => {
  assertStringIncludes(libraryBasename(), "keynub_licdongle_flat");
});

Deno.test("version", () => {
  assertEquals(VERSION, "1.1.1");
});
