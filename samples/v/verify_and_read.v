// KeyNub SDK - V sample: verify a dongle and read what it holds.
//
//     v -path "@vlib|@vmodules|bindings/v" run samples/v/verify_and_read.v      (from the repository root)
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
// -path makes bindings/v/keynub_licdongle importable as keynub_licdongle.
module main

import keynub_licdongle as licdongle

fn report(d &licdongle.Dongle) ! {
	i := d.info()!
	println('Protocol v${i.protocol_major}.${i.protocol_minor}, firmware v${i.firmware_major}.${i.firmware_minor}.${i.firmware_patch}, ${i.data_free} of ${i.data_capacity} bytes free.')
	// The only trace a firmware hang leaves behind. Report it to support.
	if i.watchdog_reboot {
		println("WARNING: this dongle's previous boot ended in a watchdog reset.")
	}
	g := d.verify_genuine()!
	println('Genuine: yes (serial ${g.serial}, provisioned ${g.provisioned_date})')
}

fn read_records(d &licdongle.Dongle) ! {
	records := d.records()!
	println('${records.len} record(s) on the dongle:')
	for r in records {
		println('  ${r.name:-16} ${r.size} bytes')
	}
	// A missing record is a normal state, not an error.
	if records.any(it.name == 'license') {
		println('Read ${d.read_record('license')!.len} bytes from the license record.')
	}
}

// The part that protects something. At licence-issue time you would call
// app_encrypt once, with a developer dongle, and ship only the sealed data;
// the program then cannot proceed without a dongle, because it holds no other
// copy. .developer lets any dongle you have issued decrypt it, so one file
// serves every customer; .device locks it to one dongle.
fn protect_something(d &licdongle.Dongle) ! {
	needed := 'the data this program cannot run without'.bytes()
	sealed := d.app_encrypt(.developer, needed)!
	recovered := d.app_decrypt(sealed)!
	outcome := if recovered == needed { 'recovered intact' } else { 'MISMATCH' }
	println('App-crypto round trip: ${needed.len} bytes -> ${sealed.len} sealed -> ${outcome}')
}

fn run() ! {
	println('KeyNub library v${licdongle.library_version()!}')
	if licdongle.devices()!.len == 0 {
		println('Connect a KeyNub dongle and re-run.')
		return
	}
	mut d := licdongle.open('')! // first dongle, or open('<serial>')
	defer {
		d.close()
	}
	report(d)!
	d.open_session()!
	defer {
		d.close_session()
	}
	read_records(d)!
	protect_something(d)!
}

fn main() {
	run() or {
		println('KeyNub error: ${err.msg()}')
		exit(1)
	}
}
