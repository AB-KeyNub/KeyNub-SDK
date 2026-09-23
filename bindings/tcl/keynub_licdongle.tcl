# KeyNub License Dongle: verify that a dongle is genuine, read and write the
# license records it holds, use its hardware counters and encrypt data so that
# only a dongle can decrypt it. Calls the SDK's flat C API through cffi, with
# the native library loaded at run time; nothing is compiled.
#
#     package require keynub_licdongle
#     keynub::licdongle with_dongle d {
#         keynub::licdongle verify_genuine $d
#         keynub::licdongle with_session $d {
#             set license [keynub::licdongle read_record $d license]
#         }
#     }
#
# Failures raise an error whose -errorcode is {KEYNUB <STATUS> <code> <operation>},
# for example {KEYNUB NO_DEVICE -2 licdf_open}; loading problems raise
# {KEYNUB LIBRARY}.

package require Tcl 8.6-
package require cffi 2.0

namespace eval ::keynub::licdongle {
    variable version 1.1.1

    # The folder this file lives in; natives/ of an SDK clone is found from here.
    variable here [file dirname [file normalize [::info script]]]

    # The environment variable that names the library file.
    variable environment_variable KEYNUB_LICDONGLE_FLAT_LIBRARY

    variable chosen ""
    variable loaded ""

    variable native_folders {win-x64 win-x86 win-arm64 linux-x64 linux-arm64 osx-x64 osx-arm64}

    # Bits in the flags value of licdf_get_info.
    variable FLAG_SE_READY 0x01
    variable FLAG_PROVISIONED 0x02
    variable FLAG_WATCHDOG_REBOOT 0x04
    variable FLAG_ISOLATED 0x08
    variable FLAG_WRITEAUTH_ROTATED 0x10

    # Buffer sizes (LICDF_SERIAL_SIZE, LICDF_DATE_SIZE, LICDF_PATH_SIZE,
    # LICDF_ERROR_SIZE), and one for a record name.
    variable SERIAL_SIZE 15
    variable DATE_SIZE 11
    variable PATH_SIZE 512
    variable ERROR_SIZE 256
    variable NAME_SIZE 256

    # The SDK's status codes (licd_status).
    variable status_names {
        0 OK -1 INVALID_ARG -2 NO_DEVICE -3 ACCESS_DENIED -4 IO -5 TIMEOUT
        -6 PROTOCOL -7 NOT_GENUINE -8 CERT_INVALID -9 SESSION_EXPIRED
        -10 TAG_MISMATCH -11 RANGE -12 STORAGE_FULL -13 BUSY -14 NOT_FOUND
        -15 AUTH_REQUIRED -16 FIRMWARE_INCOMPATIBLE -17 SDK_TOO_OLD
        -18 CANCELLED -19 NOT_IMPLEMENTED -20 INTERNAL
    }

    # The 28 functions of the flat API as cffi declarations.
    variable functions {
        licdf_version {major {int out} minor {int out} patch {int out}}
        licdf_device_count {count {int out}}
        licdf_device_serial {index int out {chars[size] out} size int}
        licdf_device_path {index int out {chars[size] out} size int}
        licdf_open {serial string}
        licdf_open_path {path string}
        licdf_close {handle int}
        licdf_set_trust_root {handle int der {bytes[len] novaluechecks} len int}
        licdf_get_serial {handle int out {chars[size] out} size int}
        licdf_get_info {handle int proto_major {int out} proto_minor {int out}
            fw_major {int out} fw_minor {int out} fw_patch {int out} flags {int out}
            capacity {int out} free {int out}}
        licdf_verify_genuine {handle int genuine {int out} serial {chars[serial_size] out}
            serial_size int date {chars[date_size] out} date_size int}
        licdf_session_open {handle int}
        licdf_session_close {handle int}
        licdf_write_auth {handle int der {bytes[len] novaluechecks} len int}
        licdf_write_auth_rotate {handle int der {bytes[len] novaluechecks} len int}
        licdf_record_count {handle int count {int out}}
        licdf_record_name {handle int index int out {chars[size] out} size int record_size {int out}}
        licdf_record_size {handle int name string size {int out}}
        licdf_record_read {handle int name string out {bytes[cap] out novaluechecks} cap int
            len {int out}}
        licdf_record_write {handle int name string data {bytes[len] novaluechecks} len int}
        licdf_record_erase {handle int name string}
        licdf_record_erase_all {handle int}
        licdf_counter_read {handle int counter int value {int out}}
        licdf_counter_increment {handle int counter int value {int out}}
        licdf_app_encrypt {handle int scope int plaintext {bytes[plain_len] novaluechecks}
            plain_len int out {bytes[cap] out novaluechecks} cap int len {int out}}
        licdf_app_decrypt {handle int packed {bytes[packed_len] novaluechecks} packed_len int
            out {bytes[cap] out novaluechecks} cap int len {int out}}
        licdf_strerror {status int out {chars[size] out} size int}
        licdf_last_error {handle int out {chars[size] out} size int}
    }

    namespace ensemble create -subcommands {
        library_path loaded_library_path library_candidates library_version
        status_name status_text devices open open_path close serial info
        verify_genuine is_genuine set_trust_root session_open session_close
        with_dongle with_session authorize_write rotate_write_key records
        read_record write_record erase_record erase_all_records read_counter
        increment_counter app_encrypt app_decrypt last_error_detail
    }
}

# ---- the library -------------------------------------------------------------

# Names the library file to load, or returns the path in use (the first
# candidate while nothing is loaded). Set it before the first dongle call.
proc ::keynub::licdongle::library_path {{path ""}} {
    variable chosen
    variable loaded
    if {$path eq ""} {
        if {$loaded ne ""} {
            return $loaded
        }
        return [lindex [library_candidates] 0]
    }
    if {$loaded ne "" && $loaded ne $path} {
        throw {KEYNUB LIBRARY} "the KeyNub library is already loaded from $loaded; a process loads it once"
    }
    set chosen $path
}

# The path of the loaded library; empty before the first call.
proc ::keynub::licdongle::loaded_library_path {} {
    variable loaded
    return $loaded
}

# The library's file name on this operating system.
proc ::keynub::licdongle::LibraryBasename {} {
    if {$::tcl_platform(platform) eq "windows"} {
        return keynub_licdongle_flat.dll
    }
    if {$::tcl_platform(os) eq "Darwin"} {
        return libkeynub_licdongle_flat.dylib
    }
    return libkeynub_licdongle_flat.so
}

# The paths tried, in order: the path set with library_path, then the
# environment variable, then natives/<platform>/ of an SDK clone from the
# executable's folder, the working directory and this package's folder
# upwards, then the bare file name for the system loader.
proc ::keynub::licdongle::library_candidates {} {
    variable chosen
    variable environment_variable
    variable native_folders
    variable here
    if {$chosen ne ""} {
        return [list $chosen]
    }
    if {[::info exists ::env($environment_variable)] && $::env($environment_variable) ne ""} {
        return [list $::env($environment_variable)]
    }
    set base [LibraryBasename]
    set found {}
    set starts {}
    foreach start [list [file dirname [::info nameofexecutable]] [pwd] $here] {
        set start [file normalize $start]
        if {$start ni $starts} {
            lappend starts $start
        }
    }
    foreach dir $starts {
        while 1 {
            foreach folder $native_folders {
                set path [file join $dir natives $folder $base]
                if {$path ni $found && [file isfile $path]} {
                    lappend found $path
                }
            }
            set parent [file dirname $dir]
            if {$parent eq $dir} {
                break
            }
            set dir $parent
        }
    }
    lappend found $base
    return $found
}

# Loads the library on the first call.
proc ::keynub::licdongle::Api {} {
    variable loaded
    variable functions
    if {$loaded ne ""} {
        return
    }
    set reasons {}
    foreach path [library_candidates] {
        catch {Lib destroy}
        if {[catch {cffi::Wrapper create [namespace current]::Lib $path} message]} {
            lappend reasons "$path ($message)"
            continue
        }
        set missing ""
        dict for {name params} $functions {
            if {[catch {Lib function [list $name [namespace current]::C::$name] int $params}]} {
                set missing $name
                break
            }
        }
        if {$missing ne ""} {
            Lib destroy
            lappend reasons "$path (does not export $missing)"
            continue
        }
        set loaded $path
        return
    }
    throw {KEYNUB LIBRARY} "cannot load the KeyNub library; tried [join $reasons {, }]"
}

namespace eval ::keynub::licdongle::C {}

# ---- errors ------------------------------------------------------------------

# The name of a status code; UNKNOWN for one this binding does not know.
proc ::keynub::licdongle::status_name {code} {
    variable status_names
    if {[dict exists $status_names $code]} {
        return [dict get $status_names $code]
    }
    return UNKNOWN
}

# Human-readable text for a status code; needs no dongle.
proc ::keynub::licdongle::status_text {code} {
    variable ERROR_SIZE
    Api
    if {[C::licdf_strerror $code text $ERROR_SIZE] != 0} {
        return [status_name $code]
    }
    return $text
}

proc ::keynub::licdongle::Fail {operation code {detail ""}} {
    set name [status_name $code]
    set message "$operation: $name ($code)"
    if {$detail ne ""} {
        append message ": $detail"
    }
    throw [list KEYNUB $name $code $operation] $message
}

proc ::keynub::licdongle::Check {operation handle rc} {
    if {$rc != 0} {
        Fail $operation $rc [expr {$handle > 0 ? [Detail $handle] : ""}]
    }
}

proc ::keynub::licdongle::Detail {handle} {
    variable ERROR_SIZE
    if {[catch {C::licdf_last_error $handle text $ERROR_SIZE} rc] || $rc != 0} {
        return ""
    }
    return $text
}

# The two-call convention: ask with a buffer, and again with the size the
# library reports when it was too small. script takes the buffer variable
# name, the capacity and the length variable name.
proc ::keynub::licdongle::ReadBytes {operation handle script} {
    set rc [{*}$script buffer 256 length]
    if {$rc == -11} {
        set rc [{*}$script buffer $length length]
    }
    Check $operation $handle $rc
    return [string range $buffer 0 [expr {$length - 1}]]
}

# ---- calls without a dongle --------------------------------------------------

# The native library's version: a dict with major, minor, patch.
proc ::keynub::licdongle::library_version {} {
    Api
    Check licdf_version 0 [C::licdf_version major minor patch]
    return [dict create major $major minor $minor patch $patch]
}

# The attached dongles: a list of dicts with serial and path.
proc ::keynub::licdongle::devices {} {
    variable PATH_SIZE
    Api
    Check licdf_device_count 0 [C::licdf_device_count count]
    set found {}
    for {set i 0} {$i < $count} {incr i} {
        Check licdf_device_serial 0 [C::licdf_device_serial $i serial $PATH_SIZE]
        Check licdf_device_path 0 [C::licdf_device_path $i path $PATH_SIZE]
        lappend found [dict create serial $serial path $path]
    }
    return $found
}

# ---- opening and closing -------------------------------------------------------

# Opens the dongle with this serial, or the first one found; returns its handle.
proc ::keynub::licdongle::open {{serial ""}} {
    Api
    set handle [C::licdf_open $serial]
    if {$handle < 0} {
        Fail licdf_open $handle
    }
    return $handle
}

# Opens the dongle at this device path (from devices); returns its handle.
proc ::keynub::licdongle::open_path {path} {
    Api
    set handle [C::licdf_open_path $path]
    if {$handle < 0} {
        Fail licdf_open_path $handle
    }
    return $handle
}

# Closes the dongle. Further calls with the handle fail with INVALID_ARG.
proc ::keynub::licdongle::close {handle} {
    Api
    Check licdf_close 0 [C::licdf_close $handle]
}

# with_dongle varName ?serial? script: opens the first dongle (or the one with
# serial), sets varName to its handle, evaluates script and closes the dongle
# on every exit path. Returns what the script returns.
proc ::keynub::licdongle::with_dongle {varName args} {
    switch [llength $args] {
        1 { set serial ""; set script [lindex $args 0] }
        2 { lassign $args serial script }
        default { return -code error "wrong # args: should be \"with_dongle varName ?serial? script\"" }
    }
    upvar 1 $varName handle
    set handle [open $serial]
    try {
        uplevel 1 $script
    } finally {
        catch {close $handle}
    }
}

# ---- the dongle ----------------------------------------------------------------

# The dongle's serial number (14 hex digits).
proc ::keynub::licdongle::serial {handle} {
    variable SERIAL_SIZE
    Api
    Check licdf_get_serial $handle [C::licdf_get_serial $handle text $SERIAL_SIZE]
    return $text
}

# Plaintext device information, as a dict: protocol_major, protocol_minor,
# firmware_major, firmware_minor, firmware_patch, secure_element_ready,
# provisioned, watchdog_reboot (the previous boot ended in a watchdog reset),
# isolated, write_auth_rotated (the write-auth key is no longer the factory
# one), data_capacity, data_free.
proc ::keynub::licdongle::info {handle} {
    variable FLAG_SE_READY
    variable FLAG_PROVISIONED
    variable FLAG_WATCHDOG_REBOOT
    variable FLAG_ISOLATED
    variable FLAG_WRITEAUTH_ROTATED
    Api
    Check licdf_get_info $handle [C::licdf_get_info $handle pa pb fa fb fc flags capacity free]
    return [dict create \
        protocol_major $pa protocol_minor $pb \
        firmware_major $fa firmware_minor $fb firmware_patch $fc \
        secure_element_ready [expr {($flags & $FLAG_SE_READY) != 0}] \
        provisioned [expr {($flags & $FLAG_PROVISIONED) != 0}] \
        watchdog_reboot [expr {($flags & $FLAG_WATCHDOG_REBOOT) != 0}] \
        isolated [expr {($flags & $FLAG_ISOLATED) != 0}] \
        write_auth_rotated [expr {($flags & $FLAG_WRITEAUTH_ROTATED) != 0}] \
        data_capacity $capacity data_free $free]
}

# Proves the dongle is genuine: certificate chain to the trusted root plus a
# live challenge-response. Returns a dict with serial and provisioned_date
# ("YYYY-MM-DD", or empty when the dongle reports none) only when it is;
# raises otherwise.
proc ::keynub::licdongle::verify_genuine {handle} {
    variable SERIAL_SIZE
    variable DATE_SIZE
    Api
    Check licdf_verify_genuine $handle \
        [C::licdf_verify_genuine $handle genuine serial $SERIAL_SIZE date $DATE_SIZE]
    if {!$genuine} {
        Fail licdf_verify_genuine -7
    }
    return [dict create serial $serial provisioned_date $date]
}

# The boolean form for a gate: 1 only when verify_genuine succeeds. Fails
# closed: every failure gives 0.
proc ::keynub::licdongle::is_genuine {handle} {
    expr {![catch {verify_genuine $handle}]}
}

# Overrides the CA root that verify_genuine checks against (DER bytes).
proc ::keynub::licdongle::set_trust_root {handle der} {
    Api
    Check licdf_set_trust_root $handle [C::licdf_set_trust_root $handle $der [string length $der]]
}

# Opens an authenticated session; records, counters and app crypto need one.
proc ::keynub::licdongle::session_open {handle} {
    Api
    Check licdf_session_open $handle [C::licdf_session_open $handle]
}

# Closes the session.
proc ::keynub::licdongle::session_close {handle} {
    Api
    Check licdf_session_close $handle [C::licdf_session_close $handle]
}

# Opens a session, evaluates script and closes the session on every exit
# path. Returns what the script returns.
proc ::keynub::licdongle::with_session {handle script} {
    session_open $handle
    try {
        uplevel 1 $script
    } finally {
        catch {session_close $handle}
    }
}

# Elevates the session to the write role with a write-auth key (P-256 PKCS#8
# DER bytes). Belongs in licence-issuing tooling, not in the application your
# users run.
proc ::keynub::licdongle::authorize_write {handle key} {
    Api
    Check licdf_write_auth $handle [C::licdf_write_auth $handle $key [string length $key]]
}

# Replaces the dongle's write-auth key with key (P-256 PKCS#8 DER bytes).
# Call authorize_write first. From the next session on, only the new key
# elevates.
proc ::keynub::licdongle::rotate_write_key {handle key} {
    Api
    Check licdf_write_auth_rotate $handle [C::licdf_write_auth_rotate $handle $key [string length $key]]
}

# The records on the dongle: a list of dicts with name and size.
proc ::keynub::licdongle::records {handle} {
    variable NAME_SIZE
    Api
    Check licdf_record_count $handle [C::licdf_record_count $handle count]
    set found {}
    for {set i 0} {$i < $count} {incr i} {
        Check licdf_record_name $handle [C::licdf_record_name $handle $i name $NAME_SIZE size]
        lappend found [dict create name $name size $size]
    }
    return $found
}

# The content of a record, as bytes.
proc ::keynub::licdongle::read_record {handle name} {
    Api
    ReadBytes licdf_record_read $handle [list C::licdf_record_read $handle $name]
}

# Writes a record, replacing one of the same name. Needs the write role.
proc ::keynub::licdongle::write_record {handle name data} {
    Api
    Check licdf_record_write $handle [C::licdf_record_write $handle $name $data [string length $data]]
}

# Erases one record. Needs the write role.
proc ::keynub::licdongle::erase_record {handle name} {
    Api
    Check licdf_record_erase $handle [C::licdf_record_erase $handle $name]
}

# Erases every record. Separate from erase_record so that an accidentally
# empty name cannot wipe the dongle.
proc ::keynub::licdongle::erase_all_records {handle} {
    Api
    Check licdf_record_erase_all $handle [C::licdf_record_erase_all $handle]
}

# The value of a hardware monotonic counter.
proc ::keynub::licdongle::read_counter {handle counter} {
    Api
    Check licdf_counter_read $handle [C::licdf_counter_read $handle $counter value]
    return $value
}

# Increments a counter and returns the new value. Needs the write role.
proc ::keynub::licdongle::increment_counter {handle counter} {
    Api
    Check licdf_counter_increment $handle [C::licdf_counter_increment $handle $counter value]
    return $value
}

# Seals data so that only a dongle can open it: this one (scope device) or any
# dongle issued by the same developer (scope developer). Build the licence
# check on this pair: put something the program needs through it, so removing
# the check removes the data.
proc ::keynub::licdongle::app_encrypt {handle scope plaintext} {
    switch -- $scope {
        device - 0 { set scope 0 }
        developer - 1 { set scope 1 }
        default { Fail argument -1 "scope must be device or developer" }
    }
    Api
    ReadBytes licdf_app_encrypt $handle \
        [list C::licdf_app_encrypt $handle $scope $plaintext [string length $plaintext]]
}

# Opens data sealed with app_encrypt.
proc ::keynub::licdongle::app_decrypt {handle packed} {
    Api
    ReadBytes licdf_app_decrypt $handle \
        [list C::licdf_app_decrypt $handle $packed [string length $packed]]
}

# Diagnostic detail for the most recent failure on this dongle; may be empty.
proc ::keynub::licdongle::last_error_detail {handle} {
    Api
    Detail $handle
}

package provide keynub_licdongle $::keynub::licdongle::version
