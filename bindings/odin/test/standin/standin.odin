// Every call of the package against a stand-in for the flat C API: the SDK's
// flat layer compiled together with the C ABI stand-in
// (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
// into one shared library, with a C compiler from the path (cc, gcc, clang,
// zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
// stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the test
// does not run inside a clone. Exit code 0 when every check passed.
//
//	odin run bindings/odin/test/standin      (from the repository root)
package main

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import kn "../../keynub_licdongle"

SERIAL :: "04A1B2C3D4E5F6"
FACTORY_KEY := [?]u8{0x30, 0x10, 0x01, 0x02, 0x03}
REPLACEMENT_KEY := [?]u8{0x30, 0x11, 0x09, 0x08, 0x07, 0x06}

Checks :: struct {
	failures: int,
}

check :: proc(c: ^Checks, condition: bool, what: string) {
	if !condition {
		c.failures += 1
		fmt.printfln("  FAIL  %s", what)
	}
}

// fails checks that a call failed with this status.
fails :: proc(c: ^Checks, status: kn.Status, what: string, err: kn.Error) {
	if err == nil {
		check(c, false, fmt.tprintf("%s: no failure", what))
		return
	}
	check(c, err == status, fmt.tprintf("%s: %v", what, err))
}

// ---- the stand-in ------------------------------------------------------------

has_flat_sources :: proc(dir: string) -> bool {
	file, _ := os.join_path({dir, "bindings", "flat", "licd_flat.c"}, context.temp_allocator)
	return os.is_file(file)
}

search_upwards :: proc(start: string) -> (root: string, ok: bool) {
	dir, err := os.get_absolute_path(start, context.temp_allocator)
	if err != nil {
		return "", false
	}
	for {
		if has_flat_sources(dir) {
			return dir, true
		}
		parent, _ := os.split_path(dir)
		if parent == dir || parent == "" || parent == "." {
			return "", false
		}
		dir = parent
	}
}

sdk_root :: proc() -> string {
	given := os.get_env("KEYNUB_SDK_ROOT", context.temp_allocator)
	if given != "" {
		return given
	}
	working, _ := os.get_working_directory(context.temp_allocator)
	if root, ok := search_upwards(working); ok {
		return root
	}
	if root, ok := search_upwards(#directory); ok {
		return root
	}
	fmt.println("the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT")
	os.exit(1)
}

// run_quietly runs `command` in `dir` with its output discarded; true when it
// exited 0.
run_quietly :: proc(command: []string, dir: string) -> bool {
	process, err := os.process_start({command = command, working_dir = dir})
	if err != nil {
		return false
	}
	state, wait_err := os.process_wait(process)
	return wait_err == nil && state.exited && state.exit_code == 0
}

build_stand_in :: proc() -> string {
	root := sdk_root()
	tmp, _ := os.temp_directory(context.temp_allocator)
	// A file name other than the library's own (keynub_licdongle_flat).
	name := "keynub_flat_standin.dll" when ODIN_OS == .Windows else "libkeynub_flat_standin.so"
	output, _ := os.join_path({tmp, name}, context.temp_allocator)
	header, _ := os.join_path({root, "core", "include", "licdongle.h"}, context.temp_allocator)
	include_dir, _ := os.join_path({root, "include"}, context.temp_allocator)
	if os.is_file(header) {
		include_dir, _ = os.split_path(header)
	}
	flat_dir, _ := os.join_path({root, "bindings", "flat"}, context.temp_allocator)
	flat_c, _ := os.join_path({flat_dir, "licd_flat.c"}, context.temp_allocator)
	stub_c, _ := os.join_path({root, "bindings", "julia", "test", "stub", "licd_stub.c"}, context.temp_allocator)
	gcc_args := make([dynamic]string, context.temp_allocator)
	append(&gcc_args, "-shared", "-O1", "-DLICD_BUILD_SHARED", "-DLICDF_BUILD_SHARED")
	append(&gcc_args, strings.concatenate({"-I", include_dir}, context.temp_allocator))
	append(&gcc_args, strings.concatenate({"-I", flat_dir}, context.temp_allocator))
	append(&gcc_args, "-o", output, flat_c, stub_c)
	when ODIN_OS != .Windows {
		append(&gcc_args, "-fPIC")
	}
	cl_args := []string {
		"cl",
		"/nologo",
		"/LD",
		"/O1",
		"/DLICD_BUILD_SHARED",
		"/DLICDF_BUILD_SHARED",
		strings.concatenate({"/I", include_dir}, context.temp_allocator),
		strings.concatenate({"/I", flat_dir}, context.temp_allocator),
		strings.concatenate({"/Fe:", output}, context.temp_allocator),
		flat_c,
		stub_c,
	}
	for compiler in ([]string{"cc", "gcc", "clang"}) {
		command := slice.concatenate([][]string{{compiler}, gcc_args[:]}, context.temp_allocator)
		if run_quietly(command, tmp) {
			return output
		}
	}
	if run_quietly(slice.concatenate([][]string{{"zig", "cc"}, gcc_args[:]}, context.temp_allocator), tmp) {
		return output
	}
	if run_quietly(cl_args, tmp) {
		return output
	}
	fmt.println("the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path")
	os.exit(1)
}

stand_in :: proc() -> string {
	given := os.get_env(kn.LIBRARY_ENVIRONMENT_VARIABLE, context.temp_allocator)
	return given if given != "" else build_stand_in()
}

// ---- the checks --------------------------------------------------------------

run :: proc(c: ^Checks) -> kn.Error {
	context.allocator = context.temp_allocator
	kn.set_library_path(stand_in()) or_return

	version := kn.library_version() or_return
	check(c, version == kn.Version{9, 8, 7}, "library version")
	check(c, kn.status_text(.No_Device) == "no device", "status text")
	check(c, kn.error_message(kn.Status.No_Device) == "no device", "error message")
	check(c, kn.error_message(nil) == "", "error message for nil")

	all := kn.devices() or_return
	check(c, len(all) == 1 && all[0].serial == SERIAL && all[0].path == "stub:0", "devices")
	_, err := kn.open("nope")
	fails(c, .No_Device, "open by unknown serial", err)
	_, err = kn.open_path("stub:9")
	fails(c, .No_Device, "open by unknown path", err)

	d := kn.open() or_return
	check(c, kn.is_open(d), "open")
	check(c, (kn.serial(d) or_return) == SERIAL, "serial")
	i := kn.info(d) or_return
	check(c, i.protocol_major == 1 && i.protocol_minor == 0, "protocol version")
	check(c, i.firmware_major == 2 && i.firmware_minor == 3 && i.firmware_patch == 4, "firmware version")
	check(c, i.secure_element_ready && i.provisioned && i.isolated, "flags set")
	check(c, !i.watchdog_reboot && !i.write_auth_rotated, "flags clear")
	check(c, i.data_capacity == 1024 * 1024 && i.data_free == 1000000, "capacity")
	g := kn.verify_genuine(d) or_return
	check(c, g.serial == SERIAL && g.provisioned_date == "2026-08-15", "genuine")
	check(c, kn.is_genuine(d), "is_genuine")

	fails(c, .Cert_Invalid, "malformed trust root", kn.set_trust_root(d, {0x02, 0x01, 0x00}))
	root: [132]u8
	slice.fill(root[:], 0xAB)
	root[0], root[1], root[2], root[3] = 0x30, 0x82, 0x01, 0x00
	kn.set_trust_root(d, root[:]) or_return
	_, err = kn.verify_genuine(d)
	fails(c, .Cert_Invalid, "verify against a foreign root", err)
	check(c, !kn.is_genuine(d), "is_genuine fails closed")
	slice.fill(root[4:], 0x01)
	kn.set_trust_root(d, root[:]) or_return
	check(c, kn.is_genuine(d), "is_genuine after the right root")

	_, err = kn.records(d)
	fails(c, .Session_Expired, "records without a session", err)
	kn.open_session(d) or_return
	payload := transmute([]u8)string("license-blob-0123456789")
	fails(c, .Auth_Required, "write before the write role", kn.write_record(d, "lic", payload))
	fails(c, .Not_Genuine, "write role with a bad key", kn.authorize_write(d, {0x30, 0x00}))
	kn.authorize_write(d, FACTORY_KEY[:]) or_return
	kn.write_record(d, "lic", payload) or_return
	check(c, bytes.equal(kn.read_record(d, "lic") or_return, payload), "read back")
	kn.write_record(d, "cfg", transmute([]u8)string("cfgdata")) or_return
	recs := kn.records(d) or_return
	names := make([]string, len(recs))
	size_ok := false
	for r, k in recs {
		names[k] = r.name
		if r.name == "lic" && r.size == len(payload) {
			size_ok = true
		}
	}
	slice.sort(names)
	check(c, slice.equal(names, []string{"cfg", "lic"}), "record names")
	check(c, size_ok, "record size")
	check(c, string(kn.read_record(d, "cfg") or_return) == "cfgdata", "second record")
	_, err = kn.read_record(d, "nope")
	fails(c, .Not_Found, "read a missing record", err)
	fails(c, .Invalid_Arg, "erase with an empty name", kn.erase_record(d, ""))
	check(c, len(kn.records(d) or_return) == 2, "two records")
	kn.erase_record(d, "cfg") or_return
	recs = kn.records(d) or_return
	check(c, len(recs) == 1 && recs[0].name == "lic", "one record left")
	kn.write_record(d, "empty", nil) or_return
	check(c, len(kn.read_record(d, "empty") or_return) == 0, "empty record")

	before := kn.read_counter(d, 0) or_return
	check(c, (kn.increment_counter(d, 0) or_return) == before + 1, "increment")
	check(c, (kn.read_counter(d, 0) or_return) == before + 1 && (kn.read_counter(d, 1) or_return) == 0, "counters")
	_, err = kn.read_counter(d, 7)
	fails(c, .Range, "counter out of range", err)

	secret: [100]u8
	for &b, k in secret {
		b = u8((3 * k + 7) % 256)
	}
	for scope in ([]kn.Scope{.Device, .Developer}) {
		blob := kn.app_encrypt(d, scope, secret[:]) or_return
		check(c, len(blob) > len(secret), fmt.tprintf("sealed data is longer, %v", scope))
		check(c, blob[0] == u8(scope), fmt.tprintf("scope byte, %v", scope))
		check(c, bytes.equal(kn.app_decrypt(d, blob) or_return, secret[:]), fmt.tprintf("round trip, %v", scope))
		tampered := slice.clone(blob)
		tampered[len(tampered) - 1] ~= 1
		_, err = kn.app_decrypt(d, tampered)
		fails(c, .Tag_Mismatch, fmt.tprintf("tampered blob, %v", scope), err)
	}

	kn.erase_all_records(d) or_return
	check(c, len(kn.records(d) or_return) == 0, "erase all")

	kn.rotate_write_key(d, REPLACEMENT_KEY[:]) or_return
	kn.write_record(d, "lic", transmute([]u8)string("still-writable")) or_return
	kn.close_session(d)
	check(c, (kn.info(d) or_return).write_auth_rotated, "rotated flag")
	kn.open_session(d) or_return
	fails(c, .Not_Genuine, "factory key after rotation", kn.authorize_write(d, FACTORY_KEY[:]))
	kn.authorize_write(d, REPLACEMENT_KEY[:]) or_return
	kn.write_record(d, "lic", transmute([]u8)string("new-key-writes")) or_return
	check(c, string(kn.read_record(d, "lic") or_return) == "new-key-writes", "write with the new key")
	kn.close_session(d)
	kn.close(&d)
	check(c, !kn.is_open(d), "closed")
	_, err = kn.serial(d)
	fails(c, .Invalid_Arg, "serial after close", err)
	kn.close(&d)

	// records needs a session, so a value back proves the deferred pair
	// opened one.
	count := count_with_defer() or_return
	check(c, count >= 0, "session with defer")
	check(c, kn.loaded_library_path() == kn.library_path(), "loaded path")
	err = kn.set_library_path("another-library")
	check(c, err == kn.Library_Error.Already_Loaded, fmt.tprintf("the library is loaded once: %v", err))
	check(c, strings.contains(kn.library_error_detail(), "loads it once"), "the library is loaded once: detail")
	return nil
}

count_with_defer :: proc() -> (count: int, err: kn.Error) {
	d := kn.open(SERIAL) or_return
	defer kn.close(&d)
	kn.open_session(d) or_return
	defer kn.close_session(d)
	list := kn.records(d, context.temp_allocator) or_return
	return len(list), nil
}

main :: proc() {
	c: Checks
	if err := run(&c); err != nil {
		check(&c, false, fmt.tprintf("unexpected error: %v %s", err, kn.library_error_detail(context.temp_allocator)))
	}
	free_all(context.temp_allocator)
	if c.failures > 0 {
		fmt.printfln("%d check(s) failed", c.failures)
		os.exit(1)
	}
	fmt.println("keynub_licdongle: every call passed against the ABI stand-in")
}
