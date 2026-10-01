// Every call of the module against a stand-in for the flat C API: the SDK's
// flat layer compiled together with the C ABI stand-in
// (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
// into one shared library, with a C compiler from the path (cc, gcc, clang,
// zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
// stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the test
// does not run inside a clone. Exit code 0 when every check passed.
//
//     v -path "@vlib|@vmodules|bindings/v" run bindings/v/test/standin.v      (from the repository root)
module main

import os
import keynub_licdongle as licdongle

const serial = '04A1B2C3D4E5F6'
const factory_key = [u8(0x30), 0x10, 0x01, 0x02, 0x03]!
const replacement_key = [u8(0x30), 0x11, 0x09, 0x08, 0x07, 0x06]!

struct Checks {
mut:
	failures int
}

fn (mut c Checks) check(condition bool, what string) {
	if !condition {
		c.failures++
		println('  FAIL  ${what}')
	}
}

// fails checks that `f` fails with this status.
fn (mut c Checks) fails(status licdongle.Status, what string, f fn () !) {
	f() or {
		if err is licdongle.DongleError {
			c.check(err.status == status, '${what}: ${err.status}')
		} else {
			c.check(false, '${what}: ${err.msg()}')
		}
		return
	}
	c.check(false, '${what}: no failure')
}

// ---- the stand-in ------------------------------------------------------------

fn has_flat_sources(dir string) bool {
	return os.is_file(os.join_path(dir, 'bindings', 'flat', 'licd_flat.c'))
}

fn search_upwards(start string) ?string {
	mut dir := os.real_path(start)
	for {
		if has_flat_sources(dir) {
			return dir
		}
		parent := os.dir(dir)
		if parent == dir || parent == '' || parent == '.' {
			return none
		}
		dir = parent
	}
	return none
}

fn sdk_root() string {
	given := os.getenv('KEYNUB_SDK_ROOT')
	if given != '' {
		return given
	}
	if root := search_upwards(os.getwd()) {
		return root
	}
	if root := search_upwards(@DIR) {
		return root
	}
	println('the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT')
	exit(1)
}

// run_quietly runs `command` with `args` in `dir`, output discarded; true when
// it exited 0.
fn run_quietly(command string, args []string, dir string) bool {
	program := os.find_abs_path_of_executable(command) or { return false }
	mut p := os.new_process(program)
	p.set_args(args)
	p.set_work_folder(dir)
	p.set_redirect_stdio()
	p.run()
	p.stdout_slurp()
	p.stderr_slurp()
	p.wait()
	code := p.code
	p.close()
	return code == 0
}

fn build_stand_in() string {
	root := sdk_root()
	tmp := os.temp_dir()
	// A file name other than the library's own (keynub_licdongle_flat).
	output := os.join_path(tmp, $if windows {
		'keynub_flat_standin.dll'
	} $else {
		'libkeynub_flat_standin.so'
	})
	include_dir := if os.is_file(os.join_path(root, 'core', 'include', 'licdongle.h')) {
		os.join_path(root, 'core', 'include')
	} else {
		os.join_path(root, 'include')
	}
	flat_dir := os.join_path(root, 'bindings', 'flat')
	sources := [os.join_path(flat_dir, 'licd_flat.c'),
		os.join_path(root, 'bindings', 'julia', 'test', 'stub', 'licd_stub.c')]
	mut gcc_args := ['-shared', '-O1', '-DLICD_BUILD_SHARED', '-DLICDF_BUILD_SHARED',
		'-I${include_dir}', '-I${flat_dir}', '-o', output]
	gcc_args << sources
	$if !windows {
		gcc_args << '-fPIC'
	}
	mut cl_args := ['/nologo', '/LD', '/O1', '/DLICD_BUILD_SHARED', '/DLICDF_BUILD_SHARED',
		'/I${include_dir}', '/I${flat_dir}', '/Fe:${output}']
	cl_args << sources
	mut zig_args := ['cc']
	zig_args << gcc_args
	commands := [['cc'], ['gcc'], ['clang'], ['zig'], ['cl']]
	arguments := [gcc_args, gcc_args, gcc_args, zig_args, cl_args]
	for i, command in commands {
		if run_quietly(command[0], arguments[i], tmp) {
			return output
		}
	}
	println('the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path')
	exit(1)
}

fn stand_in() string {
	given := os.getenv(licdongle.library_environment_variable)
	return if given != '' { given } else { build_stand_in() }
}

// ---- the checks --------------------------------------------------------------

fn run(mut c Checks) ! {
	licdongle.set_library_path(stand_in())!

	version := licdongle.library_version()!
	c.check(version.major == 9 && version.minor == 8 && version.patch == 7, 'library version')
	c.check(version.str() == '9.8.7', 'version text')
	c.check(licdongle.status_text(-2) == 'no device', 'status text')

	all := licdongle.devices()!
	c.check(all.len == 1 && all[0].serial == serial && all[0].path == 'stub:0', 'devices')
	c.fails(.no_device, 'open by unknown serial', fn () ! {
		_ := licdongle.open('nope')!
	})
	c.fails(.no_device, 'open by unknown path', fn () ! {
		_ := licdongle.open_path('stub:9')!
	})

	mut d := licdongle.open('')!
	c.check(d.is_open(), 'open')
	c.check(d.serial()! == serial, 'serial')
	i := d.info()!
	c.check(i.protocol_major == 1 && i.protocol_minor == 0, 'protocol version')
	c.check(i.firmware_major == 2 && i.firmware_minor == 3 && i.firmware_patch == 4,
		'firmware version')
	c.check(i.secure_element_ready && i.provisioned && i.isolated, 'flags set')
	c.check(!i.watchdog_reboot && !i.write_auth_rotated, 'flags clear')
	c.check(i.data_capacity == 1024 * 1024 && i.data_free == 1000000, 'capacity')
	g := d.verify_genuine()!
	c.check(g.serial == serial && g.provisioned_date == '2026-08-15', 'genuine')
	c.check(d.is_genuine(), 'is_genuine')

	c.fails(.cert_invalid, 'malformed trust root', fn [d] () ! {
		d.set_trust_root([u8(0x02), 0x01, 0x00])!
	})
	mut root := []u8{len: 132, init: 0xAB}
	root[0] = 0x30
	root[1] = 0x82
	root[2] = 0x01
	root[3] = 0x00
	d.set_trust_root(root)!
	c.fails(.cert_invalid, 'verify against a foreign root', fn [d] () ! {
		_ := d.verify_genuine()!
	})
	c.check(!d.is_genuine(), 'is_genuine fails closed')
	for k in 4 .. root.len {
		root[k] = 0x01
	}
	d.set_trust_root(root)!
	c.check(d.is_genuine(), 'is_genuine after the right root')

	c.fails(.session_expired, 'records without a session', fn [d] () ! {
		_ := d.records()!
	})
	d.open_session()!
	payload := 'license-blob-0123456789'.bytes()
	c.fails(.auth_required, 'write before the write role', fn [d, payload] () ! {
		d.write_record('lic', payload)!
	})
	c.fails(.not_genuine, 'write role with a bad key', fn [d] () ! {
		d.authorize_write([u8(0x30), 0x00])!
	})
	d.authorize_write(factory_key[..])!
	d.write_record('lic', payload)!
	c.check(d.read_record('lic')! == payload, 'read back')
	d.write_record('cfg', 'cfgdata'.bytes())!
	recs := d.records()!
	mut names := recs.map(it.name)
	names.sort()
	c.check(names == ['cfg', 'lic'], 'record names')
	c.check(recs.any(it.name == 'lic' && it.size == payload.len), 'record size')
	c.check(d.read_record('cfg')! == 'cfgdata'.bytes(), 'second record')
	c.fails(.not_found, 'read a missing record', fn [d] () ! {
		_ := d.read_record('nope')!
	})
	c.fails(.invalid_arg, 'erase with an empty name', fn [d] () ! {
		d.erase_record('')!
	})
	c.check(d.records()!.len == 2, 'two records')
	d.erase_record('cfg')!
	c.check(d.records()!.map(it.name) == ['lic'], 'one record left')
	d.write_record('empty', []u8{})!
	c.check(d.read_record('empty')!.len == 0, 'empty record')

	before := d.read_counter(0)!
	c.check(d.increment_counter(0)! == before + 1, 'increment')
	c.check(d.read_counter(0)! == before + 1 && d.read_counter(1)! == 0, 'counters')
	c.fails(.range, 'counter out of range', fn [d] () ! {
		_ := d.read_counter(7)!
	})

	secret := []u8{len: 100, init: u8((3 * index + 7) % 256)}
	for scope in [licdongle.Scope.device, .developer] {
		scope_value := if scope == .device { u8(0) } else { u8(1) }
		blob := d.app_encrypt(scope, secret)!
		c.check(blob.len > secret.len, 'sealed data is longer, ${scope}')
		c.check(blob[0] == scope_value, 'scope byte, ${scope}')
		c.check(d.app_decrypt(blob)! == secret, 'round trip, ${scope}')
		mut tampered := blob.clone()
		tampered[tampered.len - 1] ^= 1
		c.fails(.tag_mismatch, 'tampered blob, ${scope}', fn [d, tampered] () ! {
			_ := d.app_decrypt(tampered)!
		})
	}

	d.erase_all_records()!
	c.check(d.records()!.len == 0, 'erase all')

	d.rotate_write_key(replacement_key[..])!
	d.write_record('lic', 'still-writable'.bytes())!
	d.close_session()
	c.check(d.info()!.write_auth_rotated, 'rotated flag')
	d.open_session()!
	c.fails(.not_genuine, 'factory key after rotation', fn [d] () ! {
		d.authorize_write(factory_key[..])!
	})
	d.authorize_write(replacement_key[..])!
	d.write_record('lic', 'new-key-writes'.bytes())!
	c.check(d.read_record('lic')! == 'new-key-writes'.bytes(), 'write with the new key')
	d.close_session()
	d.close()
	c.check(!d.is_open(), 'closed')
	c.fails(.invalid_arg, 'serial after close', fn [d] () ! {
		_ := d.serial()!
	})
	d.close()

	// records needs a session, so a value back proves the deferred pair
	// opened one.
	count := count_with_defer()!
	c.check(count >= 0, 'session with defer')
	c.check(licdongle.loaded_library_path() == licdongle.library_path(), 'loaded path')
	licdongle.set_library_path('another-library') or {
		c.check(err is licdongle.LibraryError, 'the library is loaded once: ${err.msg()}')
		return
	}
	c.check(false, 'the library is loaded once: no failure')
}

fn count_with_defer() !int {
	mut d := licdongle.open(serial)!
	defer {
		d.close()
	}
	d.open_session()!
	defer {
		d.close_session()
	}
	return d.records()!.len
}

fn main() {
	mut c := Checks{}
	run(mut c) or { c.check(false, 'unexpected error: ${err.msg()}') }
	if c.failures > 0 {
		println('${c.failures} check(s) failed')
		exit(1)
	}
	println('keynub_licdongle: every call passed against the ABI stand-in')
}
