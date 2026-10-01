/*  KeyNub SDK - SWI-Prolog sample: verify a dongle and read what it holds.

        swipl samples/prolog/verify_and_read.pl      (from the repository root)

    Targets real hardware: with no dongle attached it prints guidance and
    exits 0. Needs the pack (swipl pack install keynub_licdongle).
*/

:- use_module(library(keynub_licdongle)).

:- initialization(main, main).

main :-
    catch(run, Error,
          ( print_message(error, Error),
            halt(1)
          )).

run :-
    library_version(version(Major, Minor, Patch)),
    format("KeyNub library v~w.~w.~w~n", [Major, Minor, Patch]),
    devices(Devices),
    (   Devices == []
    ->  writeln("Connect a KeyNub dongle and re-run.")
    ;   with_dongle(D,                  % first dongle, or with_dongle([serial(S)], D, Goal)
                    ( report(D),
                      with_session(D,   % closed on every exit path
                                   ( read_records(D),
                                     protect_something(D)
                                   ))
                    ))
    ).

report(D) :-
    dongle_info(D, I),
    format("Protocol v~w.~w, firmware v~w.~w.~w, ~w of ~w bytes free.~n",
           [ I.protocol_major, I.protocol_minor,
             I.firmware_major, I.firmware_minor, I.firmware_patch,
             I.data_free, I.data_capacity
           ]),
    % The only trace a firmware hang leaves behind. Report it to support.
    (   I.watchdog_reboot == true
    ->  writeln("WARNING: this dongle's previous boot ended in a watchdog reset.")
    ;   true
    ),
    dongle_verify_genuine(D, Serial, Provisioned),  % throws unless genuine
    format("Genuine: yes (serial ~w, provisioned ~w)~n", [Serial, Provisioned]).

read_records(D) :-
    dongle_records(D, Records),
    length(Records, Count),
    format("~d record(s) on the dongle:~n", [Count]),
    forall(member(record(Name, Size), Records),
           format("  ~w~t~19|~d bytes~n", [Name, Size])),
    % A missing record is a normal state, not an error.
    (   memberchk(record("license", _), Records)
    ->  read_record(D, license, Bytes),
        length(Bytes, Length),
        format("Read ~d bytes from the license record.~n", [Length])
    ;   true
    ).

%   The part that protects something. At licence-issue time you would call
%   app_encrypt/4 once, with a developer dongle, and ship only the sealed
%   data; the program then cannot proceed without a dongle, because it holds
%   no other copy. `developer` lets any dongle you have issued decrypt it, so
%   one file serves every customer; `device` locks it to one dongle.
protect_something(D) :-
    string_codes("the data this program cannot run without", Needed),
    app_encrypt(D, developer, Needed, Sealed),
    app_decrypt(D, Sealed, Recovered),
    length(Needed, NeededLength),
    length(Sealed, SealedLength),
    (   Recovered == Needed
    ->  Outcome = "recovered intact"
    ;   Outcome = "MISMATCH"
    ),
    format("App-crypto round trip: ~d bytes -> ~d sealed -> ~w~n",
           [NeededLength, SealedLength, Outcome]).
