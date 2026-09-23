# KeyNub SDK - Tcl sample: take ownership of a new dongle.
#
# A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
# so that from the next session onward only your key can write records, erase
# them or increment counters. Run it once per dongle, when it arrives.
#
# Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
#
#     openssl ecparam -name prime256v1 -genkey -noout |
#       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
#
#     tclsh samples/tcl/rotate_write_key.tcl keys/keynub-shipping-writeauth.key.der my-key.der
#
# Needs Tcl 8.6 or later with the cffi package. Targets real hardware: with no
# dongle attached it prints guidance and exits 0.
#
# The replacement key is worth what your licence-signing key is worth. It
# cannot be recovered from the dongle, and a unit rotated to a key you have
# lost has to come back to be re-provisioned.
lappend auto_path [file join [file dirname [file normalize [info script]]] .. .. bindings tcl]
package require keynub_licdongle

namespace path ::keynub

proc read_file {path} {
    set f [open $path rb]
    try {
        return [read $f]
    } finally {
        close $f
    }
}

if {[llength $argv] != 2} {
    puts "usage: rotate_write_key <current-key.der> <new-key.der>"
    exit 2
}

try {
    set current [read_file [lindex $argv 0]]
    set replacement [read_file [lindex $argv 1]]
    if {[llength [licdongle devices]] == 0} {
        puts "Connect a KeyNub dongle and re-run."
        exit 0
    }
    licdongle with_dongle d {
        puts "Dongle [licdongle serial $d]"
        if {[dict get [licdongle info $d] write_auth_rotated]} {
            puts "This dongle's write key has already been rotated away from the factory one."
        }
        licdongle with_session $d {
            licdongle authorize_write $d $current       ;# the key the dongle accepts today
            licdongle rotate_write_key $d $replacement  ;# from the next session: only the new one
        }
        puts "Write key rotated: [expr {[dict get [licdongle info $d] write_auth_rotated] ? {yes} : {no}}]"
    }
} trap KEYNUB {message} {
    puts "KeyNub error: $message"
    exit 1
} trap {POSIX} {message} {
    puts "KeyNub error: $message"
    exit 1
}
