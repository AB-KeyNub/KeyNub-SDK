// Unit tests that need neither the native library nor a dongle.
//
//	odin test bindings/odin/test/unit      (from the repository root)
package keynub_licdongle_unit_test

import "core:os"
import "core:strings"
import "core:testing"
import kn "../../keynub_licdongle"

@(test)
names_status_codes :: proc(t: ^testing.T) {
	status, ok := kn.status_from_code(-2)
	testing.expect(t, ok && status == .No_Device)
	status, ok = kn.status_from_code(0)
	testing.expect(t, ok && status == .Ok)
	status, ok = kn.status_from_code(-99)
	testing.expect(t, !ok && status == .Unknown)
	_, ok = kn.status_from_code(1)
	testing.expect(t, !ok)
	testing.expect_value(t, i32(kn.Status.Not_Found), -14)
	testing.expect_value(t, i32(kn.Status.Internal), -20)
}

@(test)
turns_codes_into_errors :: proc(t: ^testing.T) {
	testing.expect(t, kn.error_from_code(0) == nil)
	testing.expect(t, kn.error_from_code(-2) == kn.Status.No_Device)
	testing.expect(t, kn.error_from_code(-14) == kn.Status.Not_Found)
	testing.expect(t, kn.error_from_code(-99) == kn.Status.Unknown)
	library: kn.Error = kn.Library_Error.Load_Failed
	testing.expect(t, library != nil)
	_, is_status := library.(kn.Status)
	testing.expect(t, !is_status)
	testing.expect_value(t, kn.status_of(library), kn.Status.Unknown)
	testing.expect_value(t, kn.status_of(kn.error_from_code(-7)), kn.Status.Not_Genuine)
	testing.expect_value(t, kn.status_of(nil), kn.Status.Ok)
}

@(test)
names_the_library_for_this_operating_system :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		testing.expect_value(t, kn.LIBRARY_BASENAME, "keynub_licdongle_flat.dll")
	} else when ODIN_OS == .Darwin {
		testing.expect_value(t, kn.LIBRARY_BASENAME, "libkeynub_licdongle_flat.dylib")
	} else {
		testing.expect_value(t, kn.LIBRARY_BASENAME, "libkeynub_licdongle_flat.so")
	}
	testing.expect_value(t, kn.LIBRARY_ENVIRONMENT_VARIABLE, "KEYNUB_LICDONGLE_FLAT_LIBRARY")
}

// The environment, the working directory and the chosen path are process
// state, so these checks run in one test, one after the other.
@(test)
looks_for_the_library_in_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, kn.loaded_library_path(context.temp_allocator), "")
	testing.expect_value(t, kn.library_error_detail(context.temp_allocator), "")

	saved, had := os.lookup_env(kn.LIBRARY_ENVIRONMENT_VARIABLE, context.temp_allocator)
	defer {
		if had {
			_ = os.set_env(kn.LIBRARY_ENVIRONMENT_VARIABLE, saved)
		} else {
			os.unset_env(kn.LIBRARY_ENVIRONMENT_VARIABLE)
		}
	}

	// The bare file name is the last resort.
	os.unset_env(kn.LIBRARY_ENVIRONMENT_VARIABLE)
	all := kn.library_candidates(context.temp_allocator)
	testing.expect(t, len(all) > 0 && all[len(all) - 1] == kn.LIBRARY_BASENAME)

	// The environment names the file.
	testing.expect(t, os.set_env(kn.LIBRARY_ENVIRONMENT_VARIABLE, "/opt/keynub/stand-in.so") == nil)
	all = kn.library_candidates(context.temp_allocator)
	testing.expect(t, len(all) == 1 && all[0] == "/opt/keynub/stand-in.so")
	testing.expect_value(t, kn.library_path(context.temp_allocator), "/opt/keynub/stand-in.so")

	// set_library_path wins over the environment until it is cleared.
	testing.expect(t, kn.set_library_path("chosen-library") == nil)
	all = kn.library_candidates(context.temp_allocator)
	testing.expect(t, len(all) == 1 && all[0] == "chosen-library")
	testing.expect(t, kn.set_library_path("") == nil)
	os.unset_env(kn.LIBRARY_ENVIRONMENT_VARIABLE)

	// natives/<platform>/ above the current directory.
	root, err := os.make_directory_temp("", "keynub-natives-*", context.temp_allocator)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer os.remove_all(root)
	folder, _ := os.join_path({root, "natives", "linux-arm64"}, context.temp_allocator)
	below, _ := os.join_path({root, "app", "bin"}, context.temp_allocator)
	library, _ := os.join_path({folder, kn.LIBRARY_BASENAME}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(folder) == nil)
	testing.expect(t, os.make_directory_all(below) == nil)
	testing.expect(t, os.write_entire_file(library, "") == nil)
	working, _ := os.get_working_directory(context.temp_allocator)
	defer _ = os.set_working_directory(working)
	testing.expect(t, os.set_working_directory(below) == nil)
	all = kn.library_candidates(context.temp_allocator)
	wanted, _ := os.stat(library, context.temp_allocator)
	found := false
	for candidate in all {
		if strings.contains(candidate, "linux-arm64") && os.is_file(candidate) {
			info, stat_err := os.stat(candidate, context.temp_allocator)
			if stat_err == nil && os.same_file(info, wanted) {
				found = true
			}
		}
	}
	testing.expect(t, found)
	testing.expect_value(t, all[len(all) - 1], kn.LIBRARY_BASENAME)

	// Nothing above was loaded.
	testing.expect_value(t, kn.loaded_library_path(context.temp_allocator), "")
}

@(test)
closing_twice_does_nothing :: proc(t: ^testing.T) {
	d: kn.Dongle
	testing.expect(t, !kn.is_open(d))
	kn.close(&d)
	kn.close(&d)
	testing.expect(t, !kn.is_open(d))
}
