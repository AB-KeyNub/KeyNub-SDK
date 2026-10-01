/*  KeyNub SDK - SWI-Prolog sample: take ownership of a new dongle.

    A dongle ships holding KeyNub's write-auth key. This replaces it with
    yours, so that from the next session onward only your key can write
    records, erase them or increment counters. Run it once per dongle, when
    it arrives.

    Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:

        openssl ecparam -name prime256v1 -genkey -noout |
          openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der

        swipl samples/prolog/rotate_write_key.pl keys/keynub-shipping-writeauth.key.der my-key.der

    Targets real hardware: with no dongle attached it prints guidance and
    exits 0. Needs the pack (swipl pack install keynub_licdongle).

    Guard the replacement key as you guard your licence-signing key. It
    cannot be recovered from the dongle, and a unit rotated to a key you
    have lost has to come back to be re-provisioned.
*/

:- use_module(library(keynub_licdongle)).
:- use_module(library(readutil)).

:- initialization(main, main).

main :-
    current_prolog_flag(argv, Argv),
    (   Argv = [CurrentFile, ReplacementFile]
    ->  catch(rotate(CurrentFile, ReplacementFile), Error,
              ( print_message(error, Error),
                halt(1)
              ))
    ;   writeln("usage: rotate_write_key <current-key.der> <new-key.der>"),
        halt(2)
    ).

rotate(CurrentFile, ReplacementFile) :-
    read_file_to_codes(CurrentFile, Current, [type(binary)]),
    read_file_to_codes(ReplacementFile, Replacement, [type(binary)]),
    devices(Devices),
    (   Devices == []
    ->  writeln("Connect a KeyNub dongle and re-run.")
    ;   with_dongle(D, take_ownership(D, Current, Replacement))
    ).

take_ownership(D, Current, Replacement) :-
    dongle_serial(D, Serial),
    format("Dongle ~w~n", [Serial]),
    dongle_info(D, Before),
    (   Before.write_auth_rotated == true
    ->  writeln("This dongle's write key has already been rotated away from the factory one.")
    ;   true
    ),
    with_session(D,
                 ( authorize_write(D, Current),        % the key the dongle accepts today
                   rotate_write_key(D, Replacement)    % from the next session: only the new one
                 )),
    dongle_info(D, After),
    (   After.write_auth_rotated == true
    ->  Rotated = yes
    ;   Rotated = no
    ),
    format("Write key rotated: ~w~n", [Rotated]).
