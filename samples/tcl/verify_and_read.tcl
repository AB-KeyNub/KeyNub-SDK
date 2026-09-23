# KeyNub SDK - Tcl sample: verify a dongle and read what it holds.
#
#     tclsh samples/tcl/verify_and_read.tcl      (from the repository root)
#
# Needs Tcl 8.6 or later with the cffi package. Targets real hardware: with no
# dongle attached it prints guidance and exits 0.
lappend auto_path [file join [file dirname [file normalize [info script]]] .. .. bindings tcl]
package require keynub_licdongle

namespace path ::keynub

proc report {d} {
    set i [licdongle info $d]
    puts [format "Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free." \
        [dict get $i protocol_major] [dict get $i protocol_minor] \
        [dict get $i firmware_major] [dict get $i firmware_minor] [dict get $i firmware_patch] \
        [dict get $i data_free] [dict get $i data_capacity]]
    # The only trace a firmware hang leaves behind. Worth reporting to support.
    if {[dict get $i watchdog_reboot]} {
        puts "WARNING: this dongle's previous boot ended in a watchdog reset."
    }
    set g [licdongle verify_genuine $d]
    puts "Genuine: yes (serial [dict get $g serial], provisioned [dict get $g provisioned_date])"
}

proc read_records {d} {
    set recs [licdongle records $d]
    puts "[llength $recs] record(s) on the dongle:"
    foreach r $recs {
        puts [format "  %-16s %d bytes" [dict get $r name] [dict get $r size]]
    }
    # A missing record is a normal state, not an error.
    if {[lsearch -exact [lmap r $recs {dict get $r name}] license] >= 0} {
        puts "Read [string length [licdongle read_record $d license]] bytes from the license record."
    }
}

# The part that protects something. At licence-issue time you would call
# app_encrypt once, with a developer dongle, and ship only the sealed data; the
# program then cannot proceed without a dongle, because it holds no other copy.
# Scope developer lets any dongle you have issued decrypt it, so one file serves
# every customer; scope device locks it to one dongle.
proc protect_something {d} {
    set needed [encoding convertto utf-8 "the data this program cannot run without"]
    set sealed [licdongle app_encrypt $d developer $needed]
    set recovered [licdongle app_decrypt $d $sealed]
    puts "App-crypto round trip: [string length $needed] bytes -> [string length $sealed] sealed -> [expr {$recovered eq $needed ? {recovered intact} : {MISMATCH}}]"
}

try {
    set v [licdongle library_version]
    puts "KeyNub library v[dict get $v major].[dict get $v minor].[dict get $v patch]"
    if {[llength [licdongle devices]] == 0} {
        puts "Connect a KeyNub dongle and re-run."
        exit 0
    }
    licdongle with_dongle d {
        # first dongle, or: licdongle with_dongle d <serial> {...}
        report $d
        licdongle with_session $d {
            # closed on every exit path
            read_records $d
            protect_something $d
        }
    }
} trap KEYNUB {message} {
    puts "KeyNub error: $message"
    exit 1
}
