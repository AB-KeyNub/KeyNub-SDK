/*  Every call of the pack against a stand-in for the flat C API: the SDK's
    flat layer compiled together with the C ABI stand-in
    (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in
    memory) into one shared library, with a C compiler from the path (cc,
    gcc, clang, zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an
    already compiled stand-in skips the build; KEYNUB_SDK_ROOT names the SDK
    sources when the test does not run inside a clone. Needs the pack's
    foreign module on the `foreign` search path. Exit code 0 when every
    check passed.

        swipl -p foreign=<folder of keynub_licdongle4pl> bindings/prolog/test/standin_test.pl
*/

:- use_module(library(process)).
:- use_module(library(filesex)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module('../prolog/keynub_licdongle').

:- initialization(main, main).

serial("04A1B2C3D4E5F6").
factory_key([0x30, 0x10, 0x01, 0x02, 0x03]).
replacement_key([0x30, 0x11, 0x09, 0x08, 0x07, 0x06]).

check(Goal, What) :-
    (   catch(Goal, Error, (print_message(error, Error), fail))
    ->  true
    ;   flag(keynub_failures, N, N + 1),
        format("  FAIL  ~w~n", [What])
    ).

info_has(Info, Pairs) :-
    forall(member(Key-Value, Pairs), get_dict(Key, Info, Value)).

fails(Status, What, Goal) :-
    catch(( Goal, Outcome = no_failure ),
          error(keynub_error(Got, _, _, _), _),
          Outcome = status(Got)),
    (   Outcome == status(Status)
    ->  true
    ;   flag(keynub_failures, N, N + 1),
        format("  FAIL  ~w: ~w~n", [What, Outcome])
    ).

                 /*******************************
                 *          THE STAND-IN        *
                 *******************************/

has_flat_sources(Dir) :-
    directory_file_path(Dir, 'bindings/flat/licd_flat.c', File),
    exists_file(File).

search_upwards(Start, Root) :-
    absolute_file_name(Start, Dir),
    search_upwards_(Dir, Root).

search_upwards_(Dir, Root) :-
    (   has_flat_sources(Dir)
    ->  Root = Dir
    ;   file_directory_name(Dir, Parent),
        Parent \== Dir,
        Parent \== '.',
        search_upwards_(Parent, Root)
    ).

:- prolog_load_context(directory, Dir),
   assertz(test_folder(Dir)).

sdk_root(Root) :-
    getenv('KEYNUB_SDK_ROOT', Given),
    Given \== '',
    !,
    prolog_to_os_filename(Root, Given).
sdk_root(Root) :-
    working_directory(Cwd, Cwd),
    search_upwards(Cwd, Root),
    !.
sdk_root(Root) :-
    test_folder(Dir),
    search_upwards(Dir, Root),
    !.
sdk_root(_) :-
    writeln("the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT"),
    halt(1).

%   Runs Program with Args in Dir, output discarded; true when it exited 0.
run_quietly(Program, Args, Dir) :-
    catch(( process_create(path(Program), Args,
                           [ cwd(Dir), stdin(null), stdout(null), stderr(null),
                             process(Pid)
                           ]),
            process_wait(Pid, exit(0))
          ),
          _, fail).

build_stand_in(Output) :-
    sdk_root(Root),
    current_prolog_flag(tmp_dir, Tmp),
    % A file name other than the library's own (keynub_licdongle_flat).
    (   current_prolog_flag(windows, true)
    ->  Name = 'keynub_flat_standin.dll'
    ;   Name = 'libkeynub_flat_standin.so'
    ),
    directory_file_path(Tmp, Name, Output),
    (   directory_file_path(Root, 'core/include/licdongle.h', Header),
        exists_file(Header)
    ->  directory_file_path(Root, 'core/include', IncludeDir)
    ;   directory_file_path(Root, include, IncludeDir)
    ),
    directory_file_path(Root, 'bindings/flat', FlatDir),
    directory_file_path(FlatDir, 'licd_flat.c', FlatSource),
    directory_file_path(Root, 'bindings/julia/test/stub/licd_stub.c', StubSource),
    maplist(prolog_to_os_filename,
            [Output, IncludeDir, FlatDir, FlatSource, StubSource],
            [OsOutput, OsInclude, OsFlat, OsFlatSource, OsStubSource]),
    atom_concat('-I', OsInclude, IncludeFlag),
    atom_concat('-I', OsFlat, FlatFlag),
    (   current_prolog_flag(windows, true)
    ->  Pic = []
    ;   Pic = ['-fPIC']
    ),
    append([ ['-shared', '-O1', '-DLICD_BUILD_SHARED', '-DLICDF_BUILD_SHARED',
              IncludeFlag, FlatFlag, '-o', OsOutput, OsFlatSource, OsStubSource],
             Pic
           ], GccArgs),
    atom_concat('/I', OsInclude, ClInclude),
    atom_concat('/I', OsFlat, ClFlat),
    atom_concat('/Fe:', OsOutput, ClOutput),
    ClArgs = ['/nologo', '/LD', '/O1', '/DLICD_BUILD_SHARED', '/DLICDF_BUILD_SHARED',
              ClInclude, ClFlat, ClOutput, OsFlatSource, OsStubSource],
    (   member(Program-Args,
               [ cc-GccArgs, gcc-GccArgs, clang-GccArgs, zig-[cc|GccArgs], cl-ClArgs ]),
        run_quietly(Program, Args, Tmp)
    ->  true
    ;   writeln("the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path"),
        halt(1)
    ).

stand_in(Path) :-
    library_environment_variable(Variable),
    getenv(Variable, Given),
    Given \== '',
    !,
    Path = Given.
stand_in(Path) :-
    build_stand_in(Path).

                 /*******************************
                 *          THE CHECKS          *
                 *******************************/

main :-
    flag(keynub_failures, _, 0),
    stand_in(Library),
    set_library_path(Library),
    checks,
    flag(keynub_failures, Failures, Failures),
    (   Failures > 0
    ->  format("~d check(s) failed~n", [Failures]),
        halt(1)
    ;   writeln("keynub_licdongle: every call passed against the ABI stand-in"),
        halt(0)
    ).

checks :-
    serial(Serial),
    factory_key(FactoryKey),
    replacement_key(ReplacementKey),

    check(library_version(version(9, 8, 7)), "library version"),
    check(status_text(-2, "no device"), "status text"),

    check(devices([device(Serial, "stub:0")]), "devices"),
    fails(no_device, "open by unknown serial", dongle_open(nope, _)),
    fails(no_device, "open by unknown path", dongle_open_path("stub:9", _)),

    dongle_open(D),
    check(dongle_is_open(D), "open"),
    check(dongle_serial(D, Serial), "serial"),
    dongle_info(D, I),
    check(info_has(I, [protocol_major-1, protocol_minor-0]), "protocol version"),
    check(info_has(I, [firmware_major-2, firmware_minor-3, firmware_patch-4]),
          "firmware version"),
    check(info_has(I, [secure_element_ready-true, provisioned-true, isolated-true]),
          "flags set"),
    check(info_has(I, [watchdog_reboot-false, write_auth_rotated-false]), "flags clear"),
    check(info_has(I, [data_capacity-1048576, data_free-1000000]), "capacity"),
    check(( dongle_verify_genuine(D, GSerial, GDate),
            GSerial == Serial,
            GDate == "2026-08-15" ),
          "genuine"),
    check(dongle_genuine(D), "genuine/1"),

    fails(cert_invalid, "malformed trust root", set_dongle_trust_root(D, [0x02, 0x01, 0x00])),
    length(Tail, 128),
    maplist(=(0xAB), Tail),
    ForeignRoot = [0x30, 0x82, 0x01, 0x00|Tail],
    set_dongle_trust_root(D, ForeignRoot),
    fails(cert_invalid, "verify against a foreign root", dongle_verify_genuine(D)),
    check(\+ dongle_genuine(D), "genuine/1 fails closed"),
    length(RightTail, 128),
    maplist(=(0x01), RightTail),
    set_dongle_trust_root(D, [0x30, 0x82, 0x01, 0x00|RightTail]),
    check(dongle_genuine(D), "genuine/1 after the right root"),

    fails(session_expired, "records without a session", dongle_records(D, _)),
    session_open(D),
    string_codes("license-blob-0123456789", Payload),
    fails(auth_required, "write before the write role", write_record(D, lic, Payload)),
    fails(not_genuine, "write role with a bad key", authorize_write(D, [0x30, 0x00])),
    authorize_write(D, FactoryKey),
    write_record(D, lic, Payload),
    check(read_record(D, lic, Payload), "read back"),
    write_record(D, "cfg", "cfgdata"),
    dongle_records(D, Records),
    check(( findall(N, member(record(N, _), Records), Names0),
            msort(Names0, Names),
            Names == ["cfg", "lic"] ),
          "record names"),
    length(Payload, PayloadLength),
    check(memberchk(record("lic", PayloadLength), Records), "record size"),
    check(( read_record(D, cfg, Cfg), string_codes("cfgdata", Cfg) ), "second record"),
    fails(not_found, "read a missing record", read_record(D, nope, _)),
    fails(invalid_arg, "erase with an empty name", erase_record(D, "")),
    check(( dongle_records(D, R2), length(R2, 2) ), "two records"),
    erase_record(D, cfg),
    check(dongle_records(D, [record("lic", _)]), "one record left"),
    write_record(D, empty, []),
    check(read_record(D, empty, []), "empty record"),

    read_counter(D, 0, Before),
    After is Before + 1,
    check(increment_counter(D, 0, After), "increment"),
    check(( read_counter(D, 0, After), read_counter(D, 1, 0) ), "counters"),
    fails(range, "counter out of range", read_counter(D, 7, _)),

    numlist(0, 99, Ks),
    maplist([K, B]>>(B is (3 * K + 7) mod 256), Ks, Secret),
    forall(member(Scope-ScopeValue, [device-0, developer-1]),
           check_scope(D, Scope, ScopeValue, Secret)),

    erase_all_records(D),
    check(dongle_records(D, []), "erase all"),

    rotate_write_key(D, ReplacementKey),
    write_record(D, lic, "still-writable"),
    session_close(D),
    check(( dongle_info(D, I2), info_has(I2, [write_auth_rotated-true]) ), "rotated flag"),
    session_open(D),
    fails(not_genuine, "factory key after rotation", authorize_write(D, FactoryKey)),
    authorize_write(D, ReplacementKey),
    write_record(D, lic, "new-key-writes"),
    check(( read_record(D, lic, NewKeyWrites), string_codes("new-key-writes", NewKeyWrites) ),
          "write with the new key"),
    session_close(D),
    dongle_close(D),
    check(\+ dongle_is_open(D), "closed"),
    fails(invalid_arg, "serial after close", dongle_serial(D, _)),

    check(( with_dongle(DD, dongle_serial(DD, ViaBlock)), ViaBlock == Serial ),
          "open with a block"),
    % dongle_records/2 needs a session, so a value back proves with_session/2
    % opened one.
    check(( with_dongle([serial(Serial)], DS,
                        with_session(DS, ( dongle_records(DS, Rs), length(Rs, Count) ))),
            Count >= 0 ),
          "session with a block"),
    check(( with_dongle(Closed, true), \+ dongle_is_open(Closed) ), "closed after the block"),
    check(( loaded_library_path(Loaded), library_path(Loaded) ), "loaded path").

check_scope(D, Scope, ScopeValue, Secret) :-
    app_encrypt(D, Scope, Secret, Blob),
    length(Blob, BlobLength),
    length(Secret, SecretLength),
    check(BlobLength > SecretLength, "sealed data is longer"-Scope),
    check(Blob = [ScopeValue|_], "scope byte"-Scope),
    check(app_decrypt(D, Blob, Secret), "round trip"-Scope),
    append(Front, [Last], Blob),
    Flipped is Last xor 1,
    append(Front, [Flipped], Tampered),
    fails(tag_mismatch, "tampered blob"-Scope, app_decrypt(D, Tampered, _)).
