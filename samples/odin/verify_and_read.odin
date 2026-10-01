// KeyNub SDK - Odin sample: verify a dongle and read what it holds.
//
//	odin run samples/odin/verify_and_read.odin -file -collection:keynub=bindings/odin      (from the repository root)
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
// -collection:keynub=bindings/odin makes the package importable as
// "keynub:keynub_licdongle".
package main

import "core:bytes"
import "core:fmt"
import "core:os"
import kn "keynub:keynub_licdongle"

report :: proc(d: kn.Dongle) -> kn.Error {
	i := kn.info(d) or_return
	fmt.printfln(
		"Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free.",
		i.protocol_major,
		i.protocol_minor,
		i.firmware_major,
		i.firmware_minor,
		i.firmware_patch,
		i.data_free,
		i.data_capacity,
	)
	// The only trace a firmware hang leaves behind. Report it to support.
	if i.watchdog_reboot {
		fmt.println("WARNING: this dongle's previous boot ended in a watchdog reset.")
	}
	g := kn.verify_genuine(d) or_return
	defer kn.delete_verification(g)
	fmt.printfln("Genuine: yes (serial %s, provisioned %s)", g.serial, g.provisioned_date)
	return nil
}

read_records :: proc(d: kn.Dongle) -> kn.Error {
	records := kn.records(d) or_return
	defer kn.delete_records(records)
	fmt.printfln("%d record(s) on the dongle:", len(records))
	has_license := false
	for r in records {
		fmt.printfln("  %-16s %d bytes", r.name, r.size)
		if r.name == "license" {
			has_license = true
		}
	}
	// A missing record is a normal state, not an error.
	if has_license {
		data := kn.read_record(d, "license") or_return
		defer delete(data)
		fmt.printfln("Read %d bytes from the license record.", len(data))
	}
	return nil
}

// The part that protects something. At licence-issue time you would call
// app_encrypt once, with a developer dongle, and ship only the sealed data;
// the program then cannot proceed without a dongle, because it holds no other
// copy. .Developer lets any dongle you have issued decrypt it, so one file
// serves every customer; .Device locks it to one dongle.
protect_something :: proc(d: kn.Dongle) -> kn.Error {
	needed := transmute([]u8)string("the data this program cannot run without")
	sealed := kn.app_encrypt(d, .Developer, needed) or_return
	defer delete(sealed)
	recovered := kn.app_decrypt(d, sealed) or_return
	defer delete(recovered)
	outcome := "recovered intact" if bytes.equal(recovered, needed) else "MISMATCH"
	fmt.printfln("App-crypto round trip: %d bytes -> %d sealed -> %s", len(needed), len(sealed), outcome)
	return nil
}

run :: proc() -> kn.Error {
	v := kn.library_version() or_return
	fmt.printfln("KeyNub library v%d.%d.%d", v.major, v.minor, v.patch)
	devices := kn.devices() or_return
	count := len(devices)
	kn.delete_devices(devices)
	if count == 0 {
		fmt.println("Connect a KeyNub dongle and re-run.")
		return nil
	}
	d := kn.open() or_return // first dongle, or kn.open("<serial>")
	defer kn.close(&d)
	report(d) or_return
	kn.open_session(d) or_return
	defer kn.close_session(d)
	read_records(d) or_return
	protect_something(d) or_return
	return nil
}

main :: proc() {
	if err := run(); err != nil {
		fmt.printfln("KeyNub error: %v: %s", err, kn.error_message(err, context.temp_allocator))
		os.exit(1)
	}
}
