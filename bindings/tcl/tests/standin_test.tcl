# Every call of the binding against a stand-in for the flat C API: the SDK's
# flat layer compiled together with the C ABI stand-in
# (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
# into one shared library, with a C compiler from the path (cc, gcc, clang,
# zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
# stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the
# test does not run inside a clone. Exit code 0 when every check passed.
#
#     tclsh bindings/tcl/tests/standin_test.tcl      (from the repository root)

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require keynub_licdongle

set SERIAL 04A1B2C3D4E5F6
set FACTORY_KEY [binary format cu* {0x30 0x10 0x01 0x02 0x03}]
set REPLACEMENT_KEY [binary format cu* {0x30 0x11 0x09 0x08 0x07 0x06}]
set failures 0

proc check {condition what} {
    if {![uplevel 1 [list expr $condition]]} {
        incr ::failures
        puts "  FAIL  $what"
    }
}

proc fails {status what script} {
    if {[catch {uplevel 1 $script} message options]} {
        set code [dict get $options -errorcode]
        if {[lindex $code 0] ne "KEYNUB" || [lindex $code 1] ne $status} {
            incr ::failures
            puts "  FAIL  $what: $message"
        }
    } else {
        incr ::failures
        puts "  FAIL  $what: no failure"
    }
}

# ---- the stand-in -------------------------------------------------------------

proc sdk_root {} {
    if {[info exists ::env(KEYNUB_SDK_ROOT)] && $::env(KEYNUB_SDK_ROOT) ne ""} {
        return $::env(KEYNUB_SDK_ROOT)
    }
    set dir [pwd]
    while 1 {
        if {[file isfile [file join $dir bindings flat licd_flat.c]]} {
            return $dir
        }
        set parent [file dirname $dir]
        if {$parent eq $dir} {
            break
        }
        set dir $parent
    }
    puts "the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT"
    exit 1
}

proc build_stand_in {} {
    set root [sdk_root]
    set windows [expr {$::tcl_platform(platform) eq "windows"}]
    set tmp [file normalize [expr {[info exists ::env(TEMP)] ? $::env(TEMP) : "/tmp"}]]
    # Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf
    # name even for an absolute-path dlopen, and a build tree on that path holds
    # the real library under that name.
    set output [file join $tmp [expr {$windows ? "keynub_flat_standin.dll" : "libkeynub_flat_standin.so"}]]
    set include [file join $root include]
    if {[file isfile [file join $root core include licdongle.h]]} {
        set include [file join $root core include]
    }
    set flat [file join $root bindings flat]
    set sources [list [file join $flat licd_flat.c] [file join $root bindings julia test stub licd_stub.c]]
    set gcc [list -shared -O1 -DLICD_BUILD_SHARED -DLICDF_BUILD_SHARED -I$include -I$flat -o $output {*}$sources]
    if {!$windows} {
        lappend gcc -fPIC
    }
    set cl [list /nologo /LD /O1 /DLICD_BUILD_SHARED /DLICDF_BUILD_SHARED /I$include /I$flat /Fe:$output {*}$sources]
    # Compile in the temporary folder, where the compilers leave their byproducts.
    cd $tmp
    foreach command [list [list cc {*}$gcc] [list gcc {*}$gcc] [list clang {*}$gcc] [list zig cc {*}$gcc] [list cl {*}$cl]] {
        if {![catch {exec -ignorestderr {*}$command} message] && [file isfile $output]} {
            return $output
        }
    }
    puts "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path"
    exit 1
}

proc stand_in {} {
    if {[info exists ::env(KEYNUB_LICDONGLE_FLAT_LIBRARY)] && $::env(KEYNUB_LICDONGLE_FLAT_LIBRARY) ne ""} {
        return $::env(KEYNUB_LICDONGLE_FLAT_LIBRARY)
    }
    set pwd [pwd]
    set output [build_stand_in]
    cd $pwd
    return $output
}

# ---- the checks --------------------------------------------------------------

namespace path ::keynub
licdongle library_path [stand_in]

check {[licdongle status_name -2] eq "NO_DEVICE" && [licdongle status_name -99] eq "UNKNOWN"} "status names"
check {[licdongle library_version] eq [dict create major 9 minor 8 patch 7]} "library version"
check {[licdongle status_text -2] eq "no device"} "status text"

check {[licdongle devices] eq [list [dict create serial $SERIAL path stub:0]]} "devices"
fails NO_DEVICE "open by unknown serial" { licdongle open nope }
fails NO_DEVICE "open by unknown path" { licdongle open_path stub:9 }

set d [licdongle open]
check {$d > 0} "open"
check {[licdongle serial $d] eq $SERIAL} "serial"
set i [licdongle info $d]
check {[dict get $i protocol_major] == 1 && [dict get $i protocol_minor] == 0} "protocol version"
check {[dict get $i firmware_major] == 2 && [dict get $i firmware_minor] == 3 && [dict get $i firmware_patch] == 4} "firmware version"
check {[dict get $i secure_element_ready] && [dict get $i provisioned] && [dict get $i isolated]} "flags set"
check {![dict get $i watchdog_reboot] && ![dict get $i write_auth_rotated]} "flags clear"
check {[dict get $i data_capacity] == 1048576 && [dict get $i data_free] == 1000000} "capacity"
set g [licdongle verify_genuine $d]
check {[dict get $g serial] eq $SERIAL && [dict get $g provisioned_date] eq "2026-08-15"} "genuine"
check {[licdongle is_genuine $d]} "is_genuine"

fails CERT_INVALID "malformed trust root" { licdongle set_trust_root $d [binary format cu* {0x02 0x01 0x00}] }
set root [binary format cu* {0x30 0x82 0x01 0x00}][string repeat [binary format cu 0xAB] 128]
licdongle set_trust_root $d $root
fails CERT_INVALID "verify against a foreign root" { licdongle verify_genuine $d }
check {![licdongle is_genuine $d]} "is_genuine fails closed"
set root [binary format cu* {0x30 0x82 0x01 0x00}][string repeat [binary format cu 0x01] 128]
licdongle set_trust_root $d $root
check {[licdongle is_genuine $d]} "is_genuine after the right root"

fails SESSION_EXPIRED "records without a session" { licdongle records $d }
licdongle session_open $d
set payload license-blob-0123456789
fails AUTH_REQUIRED "write before the write role" { licdongle write_record $d lic $payload }
fails NOT_GENUINE "write role with a bad key" { licdongle authorize_write $d [binary format cu* {0x30 0x00}] }
licdongle authorize_write $d $FACTORY_KEY
licdongle write_record $d lic $payload
check {[licdongle read_record $d lic] eq $payload} "read back"
licdongle write_record $d cfg cfgdata
set recs [licdongle records $d]
check {[lsort [lmap r $recs {dict get $r name}]] eq {cfg lic}} "record names"
check {[lsearch -exact $recs [dict create name lic size [string length $payload]]] >= 0} "record size"
check {[licdongle read_record $d cfg] eq "cfgdata"} "second record"
fails NOT_FOUND "read a missing record" { licdongle read_record $d nope }
fails INVALID_ARG "erase with an empty name" { licdongle erase_record $d "" }
check {[llength [licdongle records $d]] == 2} "two records"
licdongle erase_record $d cfg
check {[lmap r [licdongle records $d] {dict get $r name}] eq {lic}} "one record left"
licdongle write_record $d empty ""
check {[licdongle read_record $d empty] eq ""} "empty record"
set big [string repeat [binary format cu 0x5A] 1000]
licdongle write_record $d big $big
check {[licdongle read_record $d big] eq $big} "record larger than the first buffer"
licdongle erase_record $d big

set before [licdongle read_counter $d 0]
check {[licdongle increment_counter $d 0] == $before + 1} "increment"
check {[licdongle read_counter $d 0] == $before + 1 && [licdongle read_counter $d 1] == 0} "counters"
fails RANGE "counter out of range" { licdongle read_counter $d 7 }

set secret ""
for {set k 0} {$k < 100} {incr k} {
    append secret [binary format cu [expr {(3 * $k + 7) % 256}]]
}
foreach {scope byte} {device 0 developer 1} {
    set blob [licdongle app_encrypt $d $scope $secret]
    check {[string length $blob] > [string length $secret]} "sealed data is longer, $scope"
    binary scan $blob cu first
    check {$first == $byte} "scope byte, $scope"
    check {[licdongle app_decrypt $d $blob] eq $secret} "round trip, $scope"
    binary scan [string index $blob end] cu last
    set tampered [string replace $blob end end [binary format cu [expr {$last ^ 1}]]]
    fails TAG_MISMATCH "tampered blob, $scope" { licdongle app_decrypt $d $tampered }
}
fails INVALID_ARG "unknown scope" { licdongle app_encrypt $d everyone $secret }

licdongle erase_all_records $d
check {[llength [licdongle records $d]] == 0} "erase all"

licdongle rotate_write_key $d $REPLACEMENT_KEY
licdongle write_record $d lic still-writable
licdongle session_close $d
check {[dict get [licdongle info $d] write_auth_rotated]} "rotated flag"
licdongle session_open $d
fails NOT_GENUINE "factory key after rotation" { licdongle authorize_write $d $FACTORY_KEY }
licdongle authorize_write $d $REPLACEMENT_KEY
licdongle write_record $d lic new-key-writes
check {[licdongle read_record $d lic] eq "new-key-writes"} "write with the new key"
licdongle session_close $d
licdongle close $d
fails INVALID_ARG "serial after close" { licdongle serial $d }

set via [licdongle with_dongle dd { licdongle serial $dd }]
check {$via eq $SERIAL} "with_dongle"
# records needs a session, so a value back proves with_session opened one.
set count [licdongle with_dongle dd $SERIAL { licdongle with_session $dd { llength [licdongle records $dd] } }]
check {$count >= 0} "with_session"
set kept [licdongle with_dongle dd { set dd }]
fails INVALID_ARG "closed after with_dongle" { licdongle serial $kept }
catch {licdongle with_dongle dd { error boom }} message
check {$message eq "boom"} "with_dongle passes the error on"
check {[licdongle loaded_library_path] eq [licdongle library_path]} "loaded path"
fails LIBRARY "library path after loading" { licdongle library_path /elsewhere/lib.so }

if {$failures} {
    puts "$failures check(s) failed"
    exit 1
}
puts "keynub_licdongle: every call passed against the ABI stand-in"
