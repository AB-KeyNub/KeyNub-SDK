/*  Unit tests that need neither the KeyNub library nor a dongle; only the
    pack's foreign module, found through the `foreign` search path.

        swipl -p foreign=<folder of keynub_licdongle4pl> test/unit_test.pl

    Exit code 0 when every test passed.
*/

:- use_module(library(plunit)).
:- use_module(library(filesex)).
:- use_module('../prolog/keynub_licdongle').

:- initialization(main, main).

main :-
    (   run_tests
    ->  halt(0)
    ;   halt(1)
    ).

error_text(Term, Text) :-
    phrase(prolog:error_message(Term), Lines),
    with_output_to(string(Text),
                   forall(member(Format-Args, Lines), format(Format, Args))).

%   Calls Goal with the environment variable Name set to Value (`none`:
%   empty, which the pack treats as unset), then restores the old value.
with_environment(Name, Value, Goal) :-
    (   getenv(Name, Old)
    ->  true
    ;   Old = ''
    ),
    (   Value == none
    ->  New = ''
    ;   New = Value
    ),
    setup_call_cleanup(setenv(Name, New), Goal, setenv(Name, Old)).

:- begin_tests(keynub_licdongle).

test(names_status_codes) :-
    status_name(-2, no_device),
    status_name(0, ok),
    \+ status_name(-99, _),
    status_name(Code, not_found),
    Code == -14,
    \+ status_name(_, no_such_status).

test(builds_the_error_term) :-
    keynub_licdongle:keynub_error(licdf_open, -2, "", E),
    E = error(keynub_error(Status, Code, Operation, Detail), _),
    Status == no_device,
    Code == -2,
    Operation == licdf_open,
    Detail == "",
    keynub_licdongle:keynub_error(x, -99, "", G),
    G = error(keynub_error(unknown, -99, x, ""), _).

test(builds_the_error_text) :-
    error_text(keynub_error(no_device, -2, licdf_open, ""), T1),
    T1 == "licdf_open: no_device (-2)",
    error_text(keynub_error(not_found, -14, licdf_record_read, "no such record"), T2),
    T2 == "licdf_record_read: not_found (-14): no such record",
    error_text(keynub_error(unknown, -99, x, ""), T3),
    T3 == "x: unknown (-99)",
    error_text(keynub_library_error("cannot load"), T4),
    T4 == "cannot load".

test(keeps_the_bare_file_name_as_the_last_resort) :-
    library_environment_variable(Name),
    with_environment(Name, none,
                     ( library_candidates(All),
                       last(All, Last),
                       library_basename(Last) )).

test(names_the_library_for_this_operating_system) :-
    library_basename(File),
    (   current_prolog_flag(windows, true)
    ->  File == 'keynub_licdongle_flat.dll'
    ;   current_prolog_flag(apple, true)
    ->  File == 'libkeynub_licdongle_flat.dylib'
    ;   File == 'libkeynub_licdongle_flat.so'
    ).

test(takes_the_library_path_from_the_environment) :-
    library_environment_variable(Name),
    with_environment(Name, '/opt/keynub/stand-in.so',
                     library_candidates(All)),
    All == ['/opt/keynub/stand-in.so'].

test(finds_natives_above_the_working_directory) :-
    library_environment_variable(Name),
    library_basename(Base),
    tmp_file(keynub_natives, Root),
    directory_file_path(Root, 'natives/linux-arm64', Folder),
    directory_file_path(Folder, Base, Library),
    directory_file_path(Root, 'app/bin', Below),
    setup_call_cleanup(
        ( make_directory_path(Folder),
          make_directory_path(Below),
          setup_call_cleanup(open(Library, write, Out), true, close(Out)),
          absolute_file_name(Library, Expected),
          working_directory(Old, Below)
        ),
        with_environment(Name, none, library_candidates(All)),
        ( working_directory(_, Old),
          delete_directory_and_contents(Root)
        )),
    memberchk(Expected, All),
    last(All, Base).

test(checks_arguments_before_loading_the_library) :-
    catch(read_counter(not_a_dongle, 0, _), E1, true),
    E1 = error(type_error(keynub_dongle, not_a_dongle), _),
    catch(status_text(no_device, _), E2, true),
    E2 = error(type_error(integer, no_device), _),
    catch(dongle_open(42, _), E3, true),
    E3 = error(type_error(text, 42), _),
    catch(set_library_path(42), E4, true),
    E4 = error(type_error(text, 42), _),
    catch(app_encrypt(not_a_dongle, device, [1], _), E5, true),
    E5 = error(type_error(keynub_dongle, not_a_dongle), _),
    \+ is_dongle(not_a_dongle),
    \+ loaded_library_path(_).

:- end_tests(keynub_licdongle).
