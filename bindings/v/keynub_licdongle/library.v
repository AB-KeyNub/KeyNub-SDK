module keynub_licdongle

// Where the native library (keynub_licdongle_flat) comes from, and the table
// of the flat C API's functions.
//
// The path given to `set_library_path`, then KEYNUB_LICDONGLE_FLAT_LIBRARY in
// the environment, then natives/<platform>/ of an SDK clone from the program's
// folder, the current directory and this module's folder upwards, then the
// bare file name for the system loader. The library is loaded on the first
// call that needs it, and a process loads it once.
import dl
import os
import sync

// library_environment_variable is the environment variable that names the
// library file.
pub const library_environment_variable = 'KEYNUB_LICDONGLE_FLAT_LIBRARY'

const native_folders = ['win-x64', 'win-x86', 'win-arm64', 'linux-x64', 'linux-arm64', 'osx-x64',
	'osx-arm64']!

type FnVersion = fn (&i32, &i32, &i32) i32

type FnOutInt = fn (&i32) i32

type FnIntText = fn (i32, &u8, i32) i32

type FnText = fn (&u8) i32

type FnInt = fn (i32) i32

type FnGetInfo = fn (i32, &i32, &i32, &i32, &i32, &i32, &i32, &i32, &i32) i32

type FnVerify = fn (i32, &i32, &u8, i32, &u8, i32) i32

type FnIntOutInt = fn (i32, &i32) i32

type FnRecordName = fn (i32, i32, &u8, i32, &i32) i32

type FnRecordSize = fn (i32, &u8, &i32) i32

type FnRecordRead = fn (i32, &u8, &u8, i32, &i32) i32

type FnRecordWrite = fn (i32, &u8, &u8, i32) i32

type FnIntName = fn (i32, &u8) i32

type FnCounter = fn (i32, i32, &i32) i32

type FnEncrypt = fn (i32, i32, &u8, i32, &u8, i32, &i32) i32

type FnDecrypt = fn (i32, &u8, i32, &u8, i32, &i32) i32

// Every function of the flat API.
struct Api {
	version           FnVersion     @[required]
	device_count      FnOutInt      @[required]
	device_serial     FnIntText     @[required]
	device_path       FnIntText     @[required]
	open              FnText        @[required]
	open_path         FnText        @[required]
	close             FnInt         @[required]
	set_trust_root    FnIntText     @[required]
	get_serial        FnIntText     @[required]
	get_info          FnGetInfo     @[required]
	verify_genuine    FnVerify      @[required]
	session_open      FnInt         @[required]
	session_close     FnInt         @[required]
	write_auth        FnIntText     @[required]
	write_auth_rotate FnIntText     @[required]
	record_count      FnIntOutInt   @[required]
	record_name       FnRecordName  @[required]
	record_size       FnRecordSize  @[required]
	record_read       FnRecordRead  @[required]
	record_write      FnRecordWrite @[required]
	record_erase      FnIntName     @[required]
	record_erase_all  FnInt         @[required]
	counter_read      FnCounter     @[required]
	counter_increment FnCounter     @[required]
	app_encrypt       FnEncrypt     @[required]
	app_decrypt       FnDecrypt     @[required]
	strerror          FnIntText     @[required]
	last_error        FnIntText     @[required]
}

struct LibraryState {
mut:
	mutex  &sync.Mutex = sync.new_mutex()
	chosen string
	loaded string
	api    &Api = unsafe { nil }
}

const library_state = &LibraryState{}

fn state() &LibraryState {
	return library_state
}

// library_basename returns the library's file name on this operating system.
pub fn library_basename() string {
	$if windows {
		return 'keynub_licdongle_flat.dll'
	} $else $if macos {
		return 'libkeynub_licdongle_flat.dylib'
	} $else {
		return 'libkeynub_licdongle_flat.so'
	}
}

// set_library_path names the library file to load. Call it before the first
// dongle call; once a library is loaded, a different path is an error.
pub fn set_library_path(path string) ! {
	mut s := unsafe { state() }
	s.mutex.lock()
	defer {
		s.mutex.unlock()
	}
	if s.loaded != '' && s.loaded != path {
		return LibraryError{
			detail: 'the KeyNub library is already loaded from ${s.loaded}; a process loads it once'
		}
	}
	s.chosen = path
}

// loaded_library_path returns the path of the loaded library; empty before
// the first call.
pub fn loaded_library_path() string {
	mut s := unsafe { state() }
	s.mutex.lock()
	defer {
		s.mutex.unlock()
	}
	return s.loaded
}

// library_path returns the path in use, or the first candidate when nothing is
// loaded yet.
pub fn library_path() string {
	mut s := unsafe { state() }
	s.mutex.lock()
	defer {
		s.mutex.unlock()
	}
	if s.loaded != '' {
		return s.loaded
	}
	return candidates(s.chosen)[0]
}

// library_candidates returns the paths tried, in order.
pub fn library_candidates() []string {
	mut s := unsafe { state() }
	s.mutex.lock()
	defer {
		s.mutex.unlock()
	}
	return candidates(s.chosen)
}

fn candidates(chosen string) []string {
	if chosen != '' {
		return [chosen]
	}
	from_environment := os.getenv(library_environment_variable)
	if from_environment != '' {
		return [from_environment]
	}
	base := library_basename()
	mut starts := []string{}
	for start in [os.dir(os.executable()), os.getwd(), @DIR] {
		if start == '' {
			continue
		}
		full := os.real_path(start)
		if full !in starts {
			starts << full
		}
	}
	mut found := []string{}
	for start in starts {
		for dir in folder_and_parents(start) {
			for folder in native_folders {
				file := os.join_path(dir, 'natives', folder, base)
				if os.is_file(file) && file !in found {
					found << file
				}
			}
		}
	}
	found << base
	return found
}

// folder_and_parents returns `folder`, its parent, and so on up to the root.
fn folder_and_parents(folder string) []string {
	mut out := []string{}
	mut dir := folder
	for dir != '' && dir !in out {
		out << dir
		parent := os.dir(dir)
		if parent == dir || parent == '.' {
			break
		}
		dir = parent
	}
	return out
}

fn symbol(handle voidptr, name string) !voidptr {
	return dl.sym_opt(handle, name) or { error('does not export ${name}') }
}

// try_load returns the table of every function from the library at `path`.
fn try_load(path string) !&Api {
	mut native := path
	$if windows {
		native = path.replace('/', '\\')
	}
	h := dl.open_opt(native, dl.rtld_now)!
	return &Api{
		version:           FnVersion(symbol(h, 'licdf_version')!)
		device_count:      FnOutInt(symbol(h, 'licdf_device_count')!)
		device_serial:     FnIntText(symbol(h, 'licdf_device_serial')!)
		device_path:       FnIntText(symbol(h, 'licdf_device_path')!)
		open:              FnText(symbol(h, 'licdf_open')!)
		open_path:         FnText(symbol(h, 'licdf_open_path')!)
		close:             FnInt(symbol(h, 'licdf_close')!)
		set_trust_root:    FnIntText(symbol(h, 'licdf_set_trust_root')!)
		get_serial:        FnIntText(symbol(h, 'licdf_get_serial')!)
		get_info:          FnGetInfo(symbol(h, 'licdf_get_info')!)
		verify_genuine:    FnVerify(symbol(h, 'licdf_verify_genuine')!)
		session_open:      FnInt(symbol(h, 'licdf_session_open')!)
		session_close:     FnInt(symbol(h, 'licdf_session_close')!)
		write_auth:        FnIntText(symbol(h, 'licdf_write_auth')!)
		write_auth_rotate: FnIntText(symbol(h, 'licdf_write_auth_rotate')!)
		record_count:      FnIntOutInt(symbol(h, 'licdf_record_count')!)
		record_name:       FnRecordName(symbol(h, 'licdf_record_name')!)
		record_size:       FnRecordSize(symbol(h, 'licdf_record_size')!)
		record_read:       FnRecordRead(symbol(h, 'licdf_record_read')!)
		record_write:      FnRecordWrite(symbol(h, 'licdf_record_write')!)
		record_erase:      FnIntName(symbol(h, 'licdf_record_erase')!)
		record_erase_all:  FnInt(symbol(h, 'licdf_record_erase_all')!)
		counter_read:      FnCounter(symbol(h, 'licdf_counter_read')!)
		counter_increment: FnCounter(symbol(h, 'licdf_counter_increment')!)
		app_encrypt:       FnEncrypt(symbol(h, 'licdf_app_encrypt')!)
		app_decrypt:       FnDecrypt(symbol(h, 'licdf_app_decrypt')!)
		strerror:          FnIntText(symbol(h, 'licdf_strerror')!)
		last_error:        FnIntText(symbol(h, 'licdf_last_error')!)
	}
}

// api returns the flat API, loading the library on the first call.
fn api() !&Api {
	mut s := unsafe { state() }
	s.mutex.lock()
	defer {
		s.mutex.unlock()
	}
	if s.api != unsafe { nil } {
		return s.api
	}
	mut reasons := []string{}
	for path in candidates(s.chosen) {
		table := try_load(path) or {
			reasons << '${path} (${err.msg().trim_space()})'
			continue
		}
		s.api = table
		s.loaded = path
		return table
	}
	return LibraryError{
		detail: 'cannot load the KeyNub library; tried ${reasons.join(', ')}'
	}
}
