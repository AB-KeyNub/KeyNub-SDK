:- module(keynub_licdongle,
          [ library_environment_variable/1, % -Name
            library_basename/1,         % -File
            library_candidates/1,       % -Paths
            set_library_path/1,         % +Path
            library_path/1,             % -Path
            loaded_library_path/1,      % -Path
            library_version/1,          % -version(Major, Minor, Patch)
            status_name/2,              % ?Code, ?Name
            status_text/2,              % +Code, -Text
            devices/1,                  % -Devices
            is_dongle/1,                % @Term
            dongle_open/1,              % -Dongle
            dongle_open/2,              % +Serial, -Dongle
            dongle_open_path/2,         % +Path, -Dongle
            dongle_close/1,             % +Dongle
            dongle_is_open/1,           % +Dongle
            with_dongle/2,              % -Dongle, :Goal
            with_dongle/3,              % +Options, -Dongle, :Goal
            dongle_serial/2,            % +Dongle, -Serial
            dongle_info/2,              % +Dongle, -Info
            dongle_verify_genuine/1,    % +Dongle
            dongle_verify_genuine/3,    % +Dongle, -Serial, -ProvisionedDate
            dongle_genuine/1,           % +Dongle
            set_dongle_trust_root/2,    % +Dongle, +Der
            dongle_last_error/2,        % +Dongle, -Detail
            session_open/1,             % +Dongle
            session_close/1,            % +Dongle
            with_session/2,             % +Dongle, :Goal
            authorize_write/2,          % +Dongle, +Key
            rotate_write_key/2,         % +Dongle, +Key
            dongle_records/2,           % +Dongle, -Records
            read_record/3,              % +Dongle, +Name, -Bytes
            write_record/3,             % +Dongle, +Name, +Bytes
            erase_record/2,             % +Dongle, +Name
            erase_all_records/1,        % +Dongle
            read_counter/3,             % +Dongle, +CounterId, -Value
            increment_counter/3,        % +Dongle, +CounterId, -Value
            app_encrypt/4,              % +Dongle, +Scope, +Plaintext, -Sealed
            app_decrypt/3               % +Dongle, +Sealed, -Plaintext
          ]).
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(library(option)).

/** <module> KeyNub License Dongle

Verify that a KeyNub dongle is genuine, read and write the license records
it holds, use its hardware counters and seal data so that only a dongle can
open it.

The pack calls the SDK's flat C API (`keynub_licdongle_flat`) from the
native library, which its foreign module loads at run time on the first
call that needs it. Loading this module does not need the native library.

  - Every failed call throws error(keynub_error(Status, Code, Operation,
    Detail), _): Status is an atom such as `no_device`, `not_genuine` or
    `auth_required` (`unknown` for a code this pack does not know), Code the
    raw status code, Operation the flat API function and Detail the
    library's diagnostic text, which may be empty. A library that cannot be
    loaded throws error(keynub_library_error(Message), _).
  - Byte data (records, keys, sealed data) is a list of codes 0..255, as
    read_file_to_codes/3 with type(binary) returns it. Input may also be a
    string or atom whose characters are all below 256.
  - Text from the dongle (serials, device paths, record names, detail) is a
    string; text input may be an atom, string or code list. Library file
    paths are atoms.
*/

:- use_foreign_library(foreign(keynub_licdongle4pl)).

:- meta_predicate
    with_dongle(-, 0),
    with_dongle(+, -, 0),
    with_session(+, 0).

:- multifile
    prolog:error_message//1.

:- dynamic
    chosen_path/1,
    module_folder/1.

:- prolog_load_context(directory, Dir),
   retractall(module_folder(_)),
   assertz(module_folder(Dir)).

                 /*******************************
                 *          THE LIBRARY         *
                 *******************************/

%!  library_environment_variable(-Name) is det.
%
%   The environment variable that names the library file.

library_environment_variable('KEYNUB_LICDONGLE_FLAT_LIBRARY').

native_folder('win-x64').
native_folder('win-x86').
native_folder('win-arm64').
native_folder('linux-x64').
native_folder('linux-arm64').
native_folder('osx-x64').
native_folder('osx-arm64').

%!  library_basename(-File) is det.
%
%   The library's file name on this operating system.

library_basename(File) :-
    (   current_prolog_flag(windows, true)
    ->  File = 'keynub_licdongle_flat.dll'
    ;   apple
    ->  File = 'libkeynub_licdongle_flat.dylib'
    ;   File = 'libkeynub_licdongle_flat.so'
    ).

apple :-
    current_prolog_flag(apple, true),
    !.
apple :-
    current_prolog_flag(arch, Arch),
    sub_atom(Arch, _, _, _, darwin),
    !.

%!  set_library_path(+Path) is det.
%
%   Names the library file to load. Call it before the first dongle call.
%   A process loads the library once; naming a different file after that
%   throws error(keynub_library_error(Message), _).

set_library_path(Path) :-
    must_be(text, Path),
    atom_string(File, Path),
    with_mutex(keynub_licdongle, set_library_path_(File)).

set_library_path_(File) :-
    (   licd_loaded_path(Loaded),
        Loaded \== File
    ->  format(string(Message),
               "the KeyNub library is already loaded from ~w; a process loads it once",
               [Loaded]),
        throw(error(keynub_library_error(Message), _))
    ;   retractall(chosen_path(_)),
        assertz(chosen_path(File))
    ).

%!  loaded_library_path(-Path) is semidet.
%
%   The path the library was loaded from. Fails before the first call that
%   loads it.

loaded_library_path(Path) :-
    licd_loaded_path(Path).

%!  library_path(-Path) is det.
%
%   The path in use, or the first candidate while nothing is loaded.

library_path(Path) :-
    (   licd_loaded_path(Loaded)
    ->  Path = Loaded
    ;   library_candidates([Path|_])
    ).

%!  library_candidates(-Paths) is det.
%
%   The paths tried, in order: the path given to set_library_path/1, else
%   the file named by KEYNUB_LICDONGLE_FLAT_LIBRARY, else every
%   natives/<platform>/<file> found in the program's folder, the working
%   directory or this module's folder or one of their parents, followed by
%   the bare file name for the system loader.

library_candidates(Paths) :-
    chosen_path(Path),
    !,
    Paths = [Path].
library_candidates(Paths) :-
    library_environment_variable(Variable),
    getenv(Variable, Path),
    Path \== '',
    !,
    Paths = [Path].
library_candidates(Paths) :-
    library_basename(Base),
    start_folders(Starts),
    findall(File,
            ( member(Start, Starts),
              folder_and_parents(Start, Dirs),
              member(Dir, Dirs),
              native_folder(Folder),
              atomic_list_concat([natives, Folder, Base], /, Relative),
              directory_file_path(Dir, Relative, File),
              exists_file(File)
            ),
            Found0),
    list_to_set(Found0, Found),
    append(Found, [Base], Paths).

start_folders(Folders) :-
    findall(Folder,
            ( start_folder(Folder0),
              absolute_file_name(Folder0, Folder1),
              no_trailing_slash(Folder1, Folder)
            ),
            Folders0),
    list_to_set(Folders0, Folders).

start_folder(Folder) :-
    program_file(File),
    file_directory_name(File, Folder).
start_folder(Folder) :-
    working_directory(Folder, Folder).
start_folder(Folder) :-
    module_folder(Folder).

program_file(File) :-
    current_prolog_flag(associated_file, File),
    !.
program_file(File) :-
    current_prolog_flag(executable, File).

no_trailing_slash(Dir0, Dir) :-
    atom_concat(Dir1, '/', Dir0),
    Dir1 \== '',
    \+ sub_atom(Dir1, _, _, 0, ':'),
    !,
    Dir = Dir1.
no_trailing_slash(Dir, Dir).

folder_and_parents(Dir, [Dir|Parents]) :-
    file_directory_name(Dir, Parent0),
    drive_root(Parent0, Parent),
    (   ( Parent == Dir ; Parent == '.' ; Parent == '' )
    ->  Parents = []
    ;   folder_and_parents(Parent, Parents)
    ).

drive_root(Dir, Root) :-
    atom_length(Dir, 2),
    sub_atom(Dir, 1, 1, 0, ':'),
    !,
    atom_concat(Dir, '/', Root).
drive_root(Dir, Dir).

ensure_library :-
    licd_loaded_path(_),
    !.
ensure_library :-
    with_mutex(keynub_licdongle, load_library).

load_library :-
    licd_loaded_path(_),
    !.
load_library :-
    library_candidates(Candidates),
    load_first(Candidates, []).

load_first([], Reasons0) :-
    reverse(Reasons0, Reasons),
    atomic_list_concat(Reasons, ', ', Tried),
    format(string(Message), "cannot load the KeyNub library; tried ~w", [Tried]),
    throw(error(keynub_library_error(Message), _)).
load_first([Path|Paths], Reasons) :-
    os_path(Path, OsPath),
    licd_load_library(OsPath, Path, Result),
    (   Result == true
    ->  true
    ;   format(string(Reason), "~w (~w)", [Path, Result]),
        load_first(Paths, [Reason|Reasons])
    ).

os_path(Path, OsPath) :-
    (   sub_atom(Path, _, _, _, /)
    ->  prolog_to_os_filename(Path, OsPath)
    ;   OsPath = Path
    ).

%!  library_version(-Version) is det.
%
%   The native library's version as version(Major, Minor, Patch).

library_version(version(Major, Minor, Patch)) :-
    ensure_library,
    licd_version(Rc, Major, Minor, Patch),
    check(licdf_version, none, Rc).

                 /*******************************
                 *         STATUS CODES         *
                 *******************************/

%!  status_name(?Code, ?Name) is nondet.
%
%   Name is the atom for the status code Code (`licd_status` in the SDK's C
%   header).

status_name(0, ok).
status_name(-1, invalid_arg).
status_name(-2, no_device).
status_name(-3, access_denied).
status_name(-4, io).
status_name(-5, timeout).
status_name(-6, protocol).
status_name(-7, not_genuine).
status_name(-8, cert_invalid).
status_name(-9, session_expired).
status_name(-10, tag_mismatch).
status_name(-11, range).
status_name(-12, storage_full).
status_name(-13, busy).
status_name(-14, not_found).
status_name(-15, auth_required).
status_name(-16, fw_incompatible).
status_name(-17, sdk_too_old).
status_name(-18, cancelled).
status_name(-19, not_implemented).
status_name(-20, internal).

%!  status_text(+Code, -Text) is det.
%
%   Human-readable text for a status code, as a string; needs no dongle.

status_text(Code, Text) :-
    must_be(integer, Code),
    ensure_library,
    licd_strerror(Code, Rc, Text0),
    (   Rc == 0
    ->  Text = Text0
    ;   status_atom(Code, Name),
        atom_string(Name, Text)
    ).

status_atom(Code, Name) :-
    (   status_name(Code, Name0)
    ->  Name = Name0
    ;   Name = unknown
    ).

%   keynub_error(+Operation, +Code, +Detail, -Error)
%
%   The exception term for a failed call.

keynub_error(Operation, Code, Detail,
             error(keynub_error(Status, Code, Operation, Detail), _)) :-
    status_atom(Code, Status).

check(_, _, 0) :-
    !.
check(Operation, Dongle, Rc) :-
    detail_of(Dongle, Detail),
    keynub_error(Operation, Rc, Detail, Error),
    throw(Error).

detail_of(Dongle, Detail) :-
    (   Dongle \== none,
        catch(dongle_last_error(Dongle, Detail0), _, fail)
    ->  Detail = Detail0
    ;   Detail = ""
    ).

prolog:error_message(keynub_error(Status, Code, Operation, Detail)) -->
    [ '~w: ~w (~w)'-[Operation, Status, Code] ],
    (   { Detail == "" }
    ->  []
    ;   [ ': ~w'-[Detail] ]
    ).
prolog:error_message(keynub_library_error(Message)) -->
    [ '~w'-[Message] ].

                 /*******************************
                 *     DISCOVERY AND OPENING    *
                 *******************************/

%!  devices(-Devices) is det.
%
%   The attached dongles, as a list of device(Serial, Path).

devices(Devices) :-
    ensure_library,
    licd_device_count(Rc, Count),
    check(licdf_device_count, none, Rc),
    Last is Count - 1,
    findall(device(Serial, Path),
            ( between(0, Last, Index),
              licd_device_serial(Index, Rc1, Serial0),
              check(licdf_device_serial, none, Rc1),
              licd_device_path(Index, Rc2, Path0),
              check(licdf_device_path, none, Rc2),
              Serial = Serial0,
              Path = Path0
            ),
            Devices).

%!  is_dongle(@Term) is semidet.
%
%   True when Term is a dongle from dongle_open/1,2 or dongle_open_path/2,
%   open or closed.

is_dongle(Term) :-
    licd_is_dongle(Term).

must_be_dongle(Dongle) :-
    (   licd_is_dongle(Dongle)
    ->  true
    ;   var(Dongle)
    ->  instantiation_error(Dongle)
    ;   type_error(keynub_dongle, Dongle)
    ).

%!  dongle_open(-Dongle) is det.
%!  dongle_open(+Serial, -Dongle) is det.
%
%   Opens the dongle with this serial, or the first one found when Serial
%   is empty or not given. The dongle is closed by dongle_close/1, or when
%   it is garbage collected.

dongle_open(Dongle) :-
    dongle_open("", Dongle).

dongle_open(Serial, Dongle) :-
    must_be(text, Serial),
    ensure_library,
    licd_open(Serial, Rc, Dongle0),
    check(licdf_open, none, Rc),
    Dongle = Dongle0.

%!  dongle_open_path(+Path, -Dongle) is det.
%
%   Opens the dongle at this device path (from devices/1).

dongle_open_path(Path, Dongle) :-
    must_be(text, Path),
    ensure_library,
    licd_open_path(Path, Rc, Dongle0),
    check(licdf_open_path, none, Rc),
    Dongle = Dongle0.

%!  dongle_is_open(+Dongle) is semidet.
%
%   True when dongle_close/1 has not been called on Dongle yet.

dongle_is_open(Dongle) :-
    must_be_dongle(Dongle),
    licd_dongle_handle(Dongle, Handle),
    Handle > 0.

%!  dongle_close(+Dongle) is det.
%
%   Closes the dongle. Closing it again does nothing; other calls on it
%   throw a keynub_error with status `invalid_arg`.

dongle_close(Dongle) :-
    must_be_dongle(Dongle),
    licd_close(Dongle, Rc),
    check(licdf_close, none, Rc).

close_quietly(Dongle) :-
    catch(dongle_close(Dongle), _, true).

%!  with_dongle(-Dongle, :Goal) is semidet.
%!  with_dongle(+Options, -Dongle, :Goal) is semidet.
%
%   Opens a dongle, calls Goal as once/1 and closes the dongle on every
%   exit path, exceptions included. Options select the dongle:
%   serial(Serial) or path(Path); without either, the first one found.

with_dongle(Dongle, Goal) :-
    with_dongle([], Dongle, Goal).

with_dongle(Options, Dongle, Goal) :-
    must_be(list, Options),
    (   option(serial(Serial), Options),
        option(path(Path), Options)
    ->  domain_error(serial_or_path, [serial(Serial), path(Path)])
    ;   true
    ),
    setup_call_cleanup(
        open_by_options(Options, Dongle),
        once(Goal),
        close_quietly(Dongle)).

open_by_options(Options, Dongle) :-
    (   option(path(Path), Options)
    ->  dongle_open_path(Path, Dongle)
    ;   option(serial(Serial), Options, ""),
        dongle_open(Serial, Dongle)
    ).

                 /*******************************
                 *    INFORMATION, AUTHENTICITY *
                 *******************************/

%!  dongle_serial(+Dongle, -Serial) is det.
%
%   The dongle's serial number (14 hex digits) as a string.

dongle_serial(Dongle, Serial) :-
    must_be_dongle(Dongle),
    ensure_library,
    licd_get_serial(Dongle, Rc, Serial0),
    check(licdf_get_serial, Dongle, Rc),
    Serial = Serial0.

%!  dongle_info(+Dongle, -Info) is det.
%
%   Plaintext device information, as a dict with the keys
%   `protocol_major`, `protocol_minor`, `firmware_major`, `firmware_minor`,
%   `firmware_patch` and `data_capacity`, `data_free` (bytes), and the
%   booleans (`true` or `false`) `secure_element_ready`, `provisioned`,
%   `watchdog_reboot`, `isolated` and `write_auth_rotated`.

dongle_info(Dongle, Info) :-
    must_be_dongle(Dongle),
    ensure_library,
    licd_get_info(Dongle, Rc, Raw),
    check(licdf_get_info, Dongle, Rc),
    Raw = info(PMajor, PMinor, FMajor, FMinor, FPatch, Flags, Capacity, Free),
    flag_value(Flags, 0x01, SecureElementReady),
    flag_value(Flags, 0x02, Provisioned),
    flag_value(Flags, 0x04, WatchdogReboot),
    flag_value(Flags, 0x08, Isolated),
    flag_value(Flags, 0x10, WriteAuthRotated),
    dict_create(Info, dongle_info,
                [ protocol_major-PMajor,
                  protocol_minor-PMinor,
                  firmware_major-FMajor,
                  firmware_minor-FMinor,
                  firmware_patch-FPatch,
                  secure_element_ready-SecureElementReady,
                  provisioned-Provisioned,
                  watchdog_reboot-WatchdogReboot,
                  isolated-Isolated,
                  write_auth_rotated-WriteAuthRotated,
                  data_capacity-Capacity,
                  data_free-Free
                ]).

flag_value(Flags, Bit, Value) :-
    (   Flags /\ Bit =\= 0
    ->  Value = true
    ;   Value = false
    ).

%!  dongle_verify_genuine(+Dongle) is det.
%!  dongle_verify_genuine(+Dongle, -Serial, -ProvisionedDate) is det.
%
%   Proves the dongle is genuine: certificate chain to the trusted root
%   plus a live challenge-response. Succeeds only when it is and throws
%   otherwise. Serial is the verified serial; ProvisionedDate is the day
%   the unit was personalised ("YYYY-MM-DD"), or "" when it reports none.

dongle_verify_genuine(Dongle) :-
    dongle_verify_genuine(Dongle, _, _).

dongle_verify_genuine(Dongle, Serial, ProvisionedDate) :-
    must_be_dongle(Dongle),
    ensure_library,
    licd_verify_genuine(Dongle, Rc, Genuine, Serial0, Date0),
    check(licdf_verify_genuine, Dongle, Rc),
    (   Genuine =:= 0
    ->  keynub_error(licdf_verify_genuine, -7, "", Error),
        throw(Error)
    ;   Serial = Serial0,
        ProvisionedDate = Date0
    ).

%!  dongle_genuine(+Dongle) is semidet.
%
%   The test for a gate: succeeds only when dongle_verify_genuine/1
%   succeeds. Fails closed: every error makes it fail.

dongle_genuine(Dongle) :-
    catch(dongle_verify_genuine(Dongle), Error, genuine_failure(Error)).

genuine_failure(Error) :-
    (   control_exception(Error)
    ->  throw(Error)
    ;   fail
    ).

control_exception(Error) :-
    var(Error),
    !,
    fail.
control_exception('$aborted').
control_exception(unwind(_)).
control_exception(time_limit_exceeded).
control_exception(time_limit_exceeded(_)).

%!  set_dongle_trust_root(+Dongle, +Der) is det.
%
%   Overrides the CA root (DER bytes) that dongle_verify_genuine/1 checks
%   against. Applications do not need this: the library embeds the KeyNub
%   production root.

set_dongle_trust_root(Dongle, Der) :-
    must_be_dongle(Dongle),
    must_be(text, Der),
    ensure_library,
    licd_set_trust_root(Dongle, Der, Rc),
    check(licdf_set_trust_root, Dongle, Rc).

%!  dongle_last_error(+Dongle, -Detail) is det.
%
%   Diagnostic detail for the most recent failure on this dongle, as a
%   string; may be empty.

dongle_last_error(Dongle, Detail) :-
    must_be_dongle(Dongle),
    ensure_library,
    licd_last_error(Dongle, Rc, Detail0),
    (   Rc == 0
    ->  Detail = Detail0
    ;   Detail = ""
    ).

                 /*******************************
                 *   SESSIONS AND WRITE ROLE    *
                 *******************************/

%!  session_open(+Dongle) is det.
%
%   Opens an authenticated session; records, counters and app encryption
%   need one.

session_open(Dongle) :-
    must_be_dongle(Dongle),
    ensure_library,
    licd_session_open(Dongle, Rc),
    check(licdf_session_open, Dongle, Rc).

%!  session_close(+Dongle) is det.
%
%   Closes the session.

session_close(Dongle) :-
    must_be_dongle(Dongle),
    ensure_library,
    licd_session_close(Dongle, Rc),
    check(licdf_session_close, Dongle, Rc).

%!  with_session(+Dongle, :Goal) is semidet.
%
%   Opens a session, calls Goal as once/1 and closes the session on every
%   exit path, exceptions included.

with_session(Dongle, Goal) :-
    setup_call_cleanup(
        session_open(Dongle),
        once(Goal),
        catch(session_close(Dongle), _, true)).

%!  authorize_write(+Dongle, +Key) is det.
%
%   Elevates the session to the write role with a write-auth key (P-256
%   PKCS#8 DER bytes).

authorize_write(Dongle, Key) :-
    must_be_dongle(Dongle),
    must_be(text, Key),
    ensure_library,
    licd_write_auth(Dongle, Key, Rc),
    check(licdf_write_auth, Dongle, Rc).

%!  rotate_write_key(+Dongle, +Key) is det.
%
%   Replaces the dongle's write-auth key with Key (P-256 PKCS#8 DER
%   bytes). Call authorize_write/2 first. From the next session on, only
%   the new key elevates.

rotate_write_key(Dongle, Key) :-
    must_be_dongle(Dongle),
    must_be(text, Key),
    ensure_library,
    licd_write_auth_rotate(Dongle, Key, Rc),
    check(licdf_write_auth_rotate, Dongle, Rc).

                 /*******************************
                 *            RECORDS           *
                 *******************************/

%!  dongle_records(+Dongle, -Records) is det.
%
%   The records on the dongle, as a list of record(Name, Size).

dongle_records(Dongle, Records) :-
    must_be_dongle(Dongle),
    ensure_library,
    licd_record_count(Dongle, Rc, Count),
    check(licdf_record_count, Dongle, Rc),
    Last is Count - 1,
    findall(record(Name, Size),
            ( between(0, Last, Index),
              licd_record_name(Dongle, Index, Rc1, Name0, Size0),
              check(licdf_record_name, Dongle, Rc1),
              Name = Name0,
              Size = Size0
            ),
            Records).

%!  read_record(+Dongle, +Name, -Bytes) is det.
%
%   The content of a record, as a list of codes 0..255.

read_record(Dongle, Name, Bytes) :-
    must_be_dongle(Dongle),
    must_be(text, Name),
    ensure_library,
    licd_record_read(Dongle, Name, Rc, Bytes0),
    check(licdf_record_read, Dongle, Rc),
    Bytes = Bytes0.

%!  write_record(+Dongle, +Name, +Bytes) is det.
%
%   Writes a record, replacing one of the same name. Needs the write role.

write_record(Dongle, Name, Bytes) :-
    must_be_dongle(Dongle),
    must_be(text, Name),
    must_be(text, Bytes),
    ensure_library,
    licd_record_write(Dongle, Name, Bytes, Rc),
    check(licdf_record_write, Dongle, Rc).

%!  erase_record(+Dongle, +Name) is det.
%
%   Erases the one record Name. Needs the write role.

erase_record(Dongle, Name) :-
    must_be_dongle(Dongle),
    must_be(text, Name),
    ensure_library,
    licd_record_erase(Dongle, Name, Rc),
    check(licdf_record_erase, Dongle, Rc).

%!  erase_all_records(+Dongle) is det.
%
%   Erases every record. Needs the write role.

erase_all_records(Dongle) :-
    must_be_dongle(Dongle),
    ensure_library,
    licd_record_erase_all(Dongle, Rc),
    check(licdf_record_erase_all, Dongle, Rc).

                 /*******************************
                 *           COUNTERS           *
                 *******************************/

%!  read_counter(+Dongle, +CounterId, -Value) is det.
%
%   The value of a hardware monotonic counter.

read_counter(Dongle, CounterId, Value) :-
    must_be_dongle(Dongle),
    must_be(integer, CounterId),
    ensure_library,
    licd_counter_read(Dongle, CounterId, Rc, Value0),
    check(licdf_counter_read, Dongle, Rc),
    Value = Value0.

%!  increment_counter(+Dongle, +CounterId, -Value) is det.
%
%   Increments a counter and returns the new value. Needs the write role.

increment_counter(Dongle, CounterId, Value) :-
    must_be_dongle(Dongle),
    must_be(integer, CounterId),
    ensure_library,
    licd_counter_increment(Dongle, CounterId, Rc, Value0),
    check(licdf_counter_increment, Dongle, Rc),
    Value = Value0.

                 /*******************************
                 *      APP-DATA ENCRYPTION     *
                 *******************************/

%!  app_encrypt(+Dongle, +Scope, +Plaintext, -Sealed) is det.
%
%   Seals Plaintext so that only a dongle can open it: this one (Scope
%   `device`) or any dongle issued by the same developer (Scope
%   `developer`). Sealed is a list of codes 0..255.

app_encrypt(Dongle, Scope, Plaintext, Sealed) :-
    must_be_dongle(Dongle),
    must_be(oneof([device, developer]), Scope),
    must_be(text, Plaintext),
    scope_value(Scope, Value),
    ensure_library,
    licd_app_encrypt(Dongle, Value, Plaintext, Rc, Sealed0),
    check(licdf_app_encrypt, Dongle, Rc),
    Sealed = Sealed0.

scope_value(device, 0).
scope_value(developer, 1).

%!  app_decrypt(+Dongle, +Sealed, -Plaintext) is det.
%
%   Opens data sealed with app_encrypt/4. Plaintext is a list of codes
%   0..255.

app_decrypt(Dongle, Sealed, Plaintext) :-
    must_be_dongle(Dongle),
    must_be(text, Sealed),
    ensure_library,
    licd_app_decrypt(Dongle, Sealed, Rc, Plaintext0),
    check(licdf_app_decrypt, Dongle, Rc),
    Plaintext = Plaintext0.
