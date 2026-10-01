%% Calls into the keynub_licdongle Hex package (module 'Elixir.KeyNub.LicDongle')
%% and turns its structs and error tuples into the records of keynub/licdongle.
-module(keynub_licdongle_ffi).
-export([call/2, call_value/2, library_version/0, open/1, with_dongle/2, with_session/2,
         loaded_library_path/0]).

-define(LD, 'Elixir.KeyNub.LicDongle').

%% A call returning {ok, Value}, ok or {error, Error}: Value converted.
call(Function, Args) ->
    guard(fun() -> result(erlang:apply(?LD, binary_to_atom(Function), Args)) end).

%% A call returning a plain value.
call_value(Function, Args) ->
    erlang:apply(?LD, binary_to_atom(Function), Args).

library_version() ->
    guard(fun() ->
        case ?LD:library_version() of
            {ok, {Major, Minor, Patch}} -> {ok, {library_version, Major, Minor, Patch}};
            Other -> result(Other)
        end
    end).

open({some, Serial}) -> call(<<"open">>, [Serial]);
open(none) -> call(<<"open">>, [nil]).

%% Body returns a Gleam Result; it comes back as it is, or the error from opening.
with_dongle(Serial, Body) ->
    S = case Serial of {some, Value} -> Value; none -> nil end,
    guard(fun() -> unwrap(?LD:with_dongle(S, Body)) end).

with_session(Dongle, Body) ->
    guard(fun() -> unwrap(?LD:with_session(Dongle, Body)) end).

loaded_library_path() ->
    case ?LD:loaded_library_path() of
        nil -> none;
        Path -> {some, Path}
    end.

unwrap({ok, Inner}) -> Inner;
unwrap(Other) -> result(Other).

guard(F) ->
    try
        F()
    catch
        error:#{'__struct__' := 'Elixir.KeyNub.LicDongle.LibraryError', message := Message} ->
            {error, {library_error, Message}}
    end.

result(ok) -> {ok, nil};
result({ok, Value}) -> {ok, value(Value)};
result({error, #{'__struct__' := 'Elixir.KeyNub.LicDongle.Error'} = E}) ->
    #{status := Status, code := Code, operation := Operation, detail := Detail} = E,
    {error, {call_error, Status, Code, text(Operation), text(Detail)}}.

value(List) when is_list(List) -> [value(V) || V <- List];
value(#{'__struct__' := 'Elixir.KeyNub.LicDongle.Info'} = I) ->
    #{protocol_version := {PMajor, PMinor}, firmware_version := {FMajor, FMinor, FPatch},
      secure_element_ready := Ready, provisioned := Provisioned, watchdog_reboot := Watchdog,
      isolated := Isolated, write_auth_rotated := Rotated, data_capacity := Capacity,
      data_free := Free} = I,
    {info, PMajor, PMinor, FMajor, FMinor, FPatch, Ready, Provisioned, Watchdog, Isolated, Rotated,
     Capacity, Free};
value(#{'__struct__' := 'Elixir.KeyNub.LicDongle.Device', serial := Serial, path := Path}) ->
    {device, Serial, Path};
value(#{'__struct__' := 'Elixir.KeyNub.LicDongle.Genuine', serial := Serial, provisioned_date := Date}) ->
    {genuine, Serial, text(Date)};
value(#{'__struct__' := 'Elixir.KeyNub.LicDongle.Record', name := Name, size := Size}) ->
    {dongle_record, Name, Size};
value(Other) -> Other.

text(nil) -> <<>>;
text(Binary) when is_binary(Binary) -> Binary.
