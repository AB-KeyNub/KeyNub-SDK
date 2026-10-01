// Unit tests that need neither the native library nor a dongle.
//
//     v test bindings/v      (from the repository root)
module keynub_licdongle

import os
import rand

fn test_names_status_codes() {
	assert status_from_code(-2)? == .no_device
	assert status_from_code(0)? == .ok
	assert status_from_code(-99) == none
	assert status_from_code(1) == none
	assert Status.not_found.code() == -14
}

fn test_builds_the_error_text_from_operation_status_and_detail() {
	e := dongle_error('licdf_open', -2, '')
	assert e.status == .no_device
	assert e.code() == -2
	assert e.operation == 'licdf_open'
	assert e.detail == ''
	assert e.msg() == 'licdf_open: no_device (-2)'
	f := dongle_error('licdf_record_read', -14, 'no such record')
	assert f.msg() == 'licdf_record_read: not_found (-14): no such record'
	g := dongle_error('x', -99, '')
	assert g.status == .unknown
	assert g.msg() == 'x: unknown (-99)'
}

fn test_errors_are_ierrors() {
	err := IError(dongle_error('licdf_open', -2, ''))
	assert err is DongleError
	if err is DongleError {
		assert err.status == .no_device
	}
	library := IError(LibraryError{
		detail: 'cannot load'
	})
	assert library is LibraryError
	assert library.msg() == 'cannot load'
}

fn test_keeps_the_bare_file_name_as_the_last_resort() {
	all := library_candidates()
	assert all.len > 0
	if os.getenv(library_environment_variable) == '' {
		assert all.last() == library_basename()
	}
}

fn test_names_the_library_for_this_operating_system() {
	$if windows {
		assert library_basename() == 'keynub_licdongle_flat.dll'
	} $else $if macos {
		assert library_basename() == 'libkeynub_licdongle_flat.dylib'
	} $else {
		assert library_basename() == 'libkeynub_licdongle_flat.so'
	}
}

fn with_environment(value string, f fn ()) {
	saved := os.getenv(library_environment_variable)
	os.setenv(library_environment_variable, value, true)
	defer {
		os.setenv(library_environment_variable, saved, true)
	}
	f()
}

fn test_takes_the_library_path_from_the_environment() {
	with_environment('/opt/keynub/stand-in.so', fn () {
		assert library_candidates() == ['/opt/keynub/stand-in.so']
	})
}

fn test_finds_natives_above_the_current_directory() {
	root := os.join_path(os.temp_dir(), 'keynub-natives-${rand.ulid()}')
	folder := os.join_path(root, 'natives', 'linux-arm64')
	below := os.join_path(root, 'app', 'bin')
	os.mkdir_all(folder) or { panic(err) }
	os.mkdir_all(below) or { panic(err) }
	library := os.join_path(folder, library_basename())
	os.write_file(library, '') or { panic(err) }
	saved := os.getwd()
	defer {
		os.chdir(saved) or {}
		os.rmdir_all(root) or {}
	}
	with_environment('', fn [below, library] () {
		os.chdir(below) or { panic(err) }
		all := library_candidates()
		assert os.real_path(library) in all
		assert all.last() == library_basename()
	})
}

fn test_reads_a_nul_terminated_buffer() {
	assert c_string([u8(0x61), 0x62, 0, 0x63]) == 'ab'
	assert c_string([u8(0x61), 0x62]) == 'ab'
	assert c_string([u8(0)]) == ''
	assert c_text('ab') == [u8(0x61), 0x62, 0]
}

fn test_loads_nothing_on_its_own() {
	assert loaded_library_path() == ''
	assert input([]u8{}).len == 1
}
