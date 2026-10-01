package keynub_licdongle

// Where the native library (keynub_licdongle_flat) comes from, and the table
// of the flat C API's functions.
//
// The path given to `set_library_path`, then KEYNUB_LICDONGLE_FLAT_LIBRARY in
// the environment, then natives/<platform>/ of an SDK clone from the program's
// folder, the current directory and this package's folder upwards, then the
// bare file name for the system loader. The library is loaded on the first
// call that needs it, and a process loads it once.

import "base:runtime"
import "core:dynlib"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:sync"

// LIBRARY_ENVIRONMENT_VARIABLE is the environment variable that names the
// library file.
LIBRARY_ENVIRONMENT_VARIABLE :: "KEYNUB_LICDONGLE_FLAT_LIBRARY"

// LIBRARY_BASENAME is the library's file name on this operating system.
when ODIN_OS == .Windows {
	LIBRARY_BASENAME :: "keynub_licdongle_flat.dll"
} else when ODIN_OS == .Darwin {
	LIBRARY_BASENAME :: "libkeynub_licdongle_flat.dylib"
} else {
	LIBRARY_BASENAME :: "libkeynub_licdongle_flat.so"
}

@(private)
NATIVE_FOLDERS :: [?]string{"win-x64", "win-x86", "win-arm64", "linux-x64", "linux-arm64", "osx-x64", "osx-arm64"}

@(private)
PACKAGE_DIRECTORY :: #directory

// Every function of the flat API, named as exported without the licdf_ prefix.
@(private)
Api :: struct {
	__handle:          dynlib.Library,
	version:           proc "c" (major, minor, patch: ^i32) -> i32,
	device_count:      proc "c" (count: ^i32) -> i32,
	device_serial:     proc "c" (index: i32, out: [^]u8, out_size: i32) -> i32,
	device_path:       proc "c" (index: i32, out: [^]u8, out_size: i32) -> i32,
	open:              proc "c" (serial: cstring) -> i32,
	open_path:         proc "c" (path: cstring) -> i32,
	close:             proc "c" (handle: i32) -> i32,
	set_trust_root:    proc "c" (handle: i32, der: [^]u8, der_len: i32) -> i32,
	get_serial:        proc "c" (handle: i32, out: [^]u8, out_size: i32) -> i32,
	get_info:          proc "c" (handle: i32, proto_major, proto_minor, fw_major, fw_minor, fw_patch, flags, capacity, free: ^i32) -> i32,
	verify_genuine:    proc "c" (handle: i32, genuine: ^i32, serial: [^]u8, serial_size: i32, date: [^]u8, date_size: i32) -> i32,
	session_open:      proc "c" (handle: i32) -> i32,
	session_close:     proc "c" (handle: i32) -> i32,
	write_auth:        proc "c" (handle: i32, der: [^]u8, der_len: i32) -> i32,
	write_auth_rotate: proc "c" (handle: i32, der: [^]u8, der_len: i32) -> i32,
	record_count:      proc "c" (handle: i32, count: ^i32) -> i32,
	record_name:       proc "c" (handle, index: i32, out: [^]u8, out_size: i32, record_size: ^i32) -> i32,
	record_size:       proc "c" (handle: i32, name: cstring, size: ^i32) -> i32,
	record_read:       proc "c" (handle: i32, name: cstring, out: [^]u8, out_cap: i32, out_len: ^i32) -> i32,
	record_write:      proc "c" (handle: i32, name: cstring, data: [^]u8, data_len: i32) -> i32,
	record_erase:      proc "c" (handle: i32, name: cstring) -> i32,
	record_erase_all:  proc "c" (handle: i32) -> i32,
	counter_read:      proc "c" (handle, counter_id: i32, value: ^i32) -> i32,
	counter_increment: proc "c" (handle, counter_id: i32, value: ^i32) -> i32,
	app_encrypt:       proc "c" (handle, scope: i32, plaintext: [^]u8, plaintext_len: i32, out: [^]u8, out_cap: i32, out_len: ^i32) -> i32,
	app_decrypt:       proc "c" (handle: i32, packed: [^]u8, packed_len: i32, out: [^]u8, out_cap: i32, out_len: ^i32) -> i32,
	strerror:          proc "c" (status: i32, out: [^]u8, out_size: i32) -> i32,
	last_error:        proc "c" (handle: i32, out: [^]u8, out_size: i32) -> i32,
}

@(private)
API_FUNCTIONS :: 28

// The process-wide library state; its strings are on the heap allocator.
@(private)
Library_State :: struct {
	mutex:  sync.Mutex,
	chosen: string,
	loaded: string,
	detail: string,
	ready:  bool,
	api:    Api,
}

@(private)
library_state: Library_State

// set_library_path names the library file to load. Call it before the first
// dongle call; once a library is loaded, a different path returns
// `.Already_Loaded`.
@(require_results)
set_library_path :: proc(path: string) -> Error {
	s := &library_state
	sync.mutex_guard(&s.mutex)
	if s.loaded != "" && s.loaded != path {
		set_detail(s, "the KeyNub library is already loaded from ", s.loaded, "; a process loads it once")
		return .Already_Loaded
	}
	delete(s.chosen, runtime.heap_allocator())
	s.chosen = strings.clone(path, runtime.heap_allocator())
	return nil
}

// loaded_library_path returns the path of the loaded library; empty before
// the first call.
loaded_library_path :: proc(allocator := context.allocator) -> string {
	s := &library_state
	sync.mutex_guard(&s.mutex)
	return strings.clone(s.loaded, allocator)
}

// library_path returns the path in use, or the first candidate when nothing is
// loaded yet.
library_path :: proc(allocator := context.allocator) -> string {
	s := &library_state
	sync.mutex_guard(&s.mutex)
	if s.loaded != "" {
		return strings.clone(s.loaded, allocator)
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = is_temp(allocator))
	all := candidates(s.chosen, context.temp_allocator)
	return strings.clone(all[0], allocator)
}

// library_candidates returns the paths tried, in order. Free each string and
// the slice with `allocator`.
library_candidates :: proc(allocator := context.allocator) -> []string {
	s := &library_state
	sync.mutex_guard(&s.mutex)
	return candidates(s.chosen, allocator)
}

// library_error_detail returns what was tried and why it failed, for the most
// recent `Library_Error`; empty when there was none.
library_error_detail :: proc(allocator := context.allocator) -> string {
	s := &library_state
	sync.mutex_guard(&s.mutex)
	return strings.clone(s.detail, allocator)
}

@(private)
is_temp :: proc(allocator: runtime.Allocator) -> bool {
	return allocator.data == context.temp_allocator.data && allocator.procedure == context.temp_allocator.procedure
}

@(private)
set_detail :: proc(s: ^Library_State, parts: ..string) {
	delete(s.detail, runtime.heap_allocator())
	s.detail = strings.concatenate(parts, runtime.heap_allocator())
}

@(private)
candidates :: proc(chosen: string, allocator: runtime.Allocator) -> []string {
	found := make([dynamic]string, allocator)
	if chosen != "" {
		append(&found, strings.clone(chosen, allocator))
		return found[:]
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = is_temp(allocator))
	from_environment := os.get_env(LIBRARY_ENVIRONMENT_VARIABLE, context.temp_allocator)
	if from_environment != "" {
		append(&found, strings.clone(from_environment, allocator))
		return found[:]
	}
	executable_dir, _ := os.get_executable_directory(context.temp_allocator)
	working_dir, _ := os.get_working_directory(context.temp_allocator)
	starts := make([dynamic]string, context.temp_allocator)
	for start in ([]string{executable_dir, working_dir, PACKAGE_DIRECTORY}) {
		if start == "" {
			continue
		}
		full, err := os.get_absolute_path(start, context.temp_allocator)
		if err != nil {
			continue
		}
		full = trim_separators(full)
		if !contains(starts[:], full) {
			append(&starts, full)
		}
	}
	for start in starts {
		dir := start
		for {
			for folder in NATIVE_FOLDERS {
				file, _ := os.join_path({dir, "natives", folder, LIBRARY_BASENAME}, context.temp_allocator)
				if os.is_file(file) && !contains(found[:], file) {
					append(&found, strings.clone(file, allocator))
				}
			}
			parent, _ := os.split_path(dir)
			parent = trim_separators(parent)
			if parent == dir || parent == "" || parent == "." {
				break
			}
			dir = parent
		}
	}
	append(&found, strings.clone(LIBRARY_BASENAME, allocator))
	return found[:]
}

// trim_separators drops trailing path separators, keeping a root ("/", "C:\").
@(private)
trim_separators :: proc(path: string) -> string {
	out := path
	for len(out) > 1 && os.is_path_separator(out[len(out) - 1]) {
		if len(out) == 3 && out[1] == ':' {
			break
		}
		out = out[:len(out) - 1]
	}
	return out
}

@(private)
contains :: proc(list: []string, item: string) -> bool {
	for entry in list {
		if entry == item {
			return true
		}
	}
	return false
}

// try_load fills `table` from the library at `path`; on failure it returns
// the reason and leaves `table` empty.
@(private)
try_load :: proc(table: ^Api, path: string) -> (reason: string, ok: bool) {
	native := path
	when ODIN_OS == .Windows {
		native, _ = strings.replace_all(path, "/", "\\", context.temp_allocator)
	}
	count, _ := dynlib.initialize_symbols(table, native, "licdf_")
	if count < 0 {
		return strings.clone(dynlib.last_error(), context.temp_allocator), false
	}
	if count == API_FUNCTIONS {
		return "", true
	}
	missing := ""
	for field in reflect.struct_fields_zipped(Api) {
		if field.name == "__handle" {
			continue
		}
		if (^rawptr)(uintptr(table) + field.offset)^ == nil {
			missing = strings.concatenate({"does not export licdf_", field.name}, context.temp_allocator)
			break
		}
	}
	dynlib.unload_library(table.__handle)
	table^ = {}
	return missing, false
}

// api returns the flat API, loading the library on the first call.
@(private)
api :: proc() -> (^Api, Error) {
	s := &library_state
	sync.mutex_guard(&s.mutex)
	if s.ready {
		return &s.api, nil
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	reasons := make([dynamic]string, context.temp_allocator)
	for path in candidates(s.chosen, context.temp_allocator) {
		reason, ok := try_load(&s.api, path)
		if ok {
			delete(s.loaded, runtime.heap_allocator())
			s.loaded = strings.clone(path, runtime.heap_allocator())
			s.ready = true
			return &s.api, nil
		}
		append(&reasons, strings.concatenate({path, " (", strings.trim_space(reason), ")"}, context.temp_allocator))
	}
	set_detail(s, "cannot load the KeyNub library; tried ", strings.join(reasons[:], ", ", context.temp_allocator))
	return nil, .Load_Failed
}
