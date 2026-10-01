%% Builds the C ABI stand-in for test/standin.gleam: the SDK's flat layer and
%% bindings/julia/test/stub/licd_stub.c compiled into one shared library with the
%% first C compiler on the path (cc, gcc, clang, zig cc, cl).
-module(standin_ffi).
-export([stand_in/0, halt/1]).

stand_in() ->
    case os:getenv("KEYNUB_LICDONGLE_FLAT_LIBRARY") of
        Path when is_list(Path), Path =/= "" -> {ok, list_to_binary(Path)};
        _ -> build()
    end.

halt(Code) -> erlang:halt(Code).

build() ->
    case sdk_root() of
        {error, _} = E -> E;
        {ok, Root} ->
            Windows = element(1, os:type()) =:= win32,
            {ok, Tmp} = tmp_dir(),
            %% Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by
            %% leaf name even for an absolute-path dlopen, and a build tree on that
            %% path holds the real library under that name.
            Out = filename:join(Tmp, case Windows of
                                         true -> "keynub_flat_standin.dll";
                                         false -> "libkeynub_flat_standin.so"
                                     end),
            Include = case filelib:is_file(filename:join(Root, "core/include/licdongle.h")) of
                          true -> filename:join(Root, "core/include");
                          false -> filename:join(Root, "include")
                      end,
            Flat = filename:join(Root, "bindings/flat"),
            Sources = [filename:join(Flat, "licd_flat.c"),
                       filename:join(Root, "bindings/julia/test/stub/licd_stub.c")],
            Gcc = ["-shared", "-O1", "-DLICD_BUILD_SHARED", "-DLICDF_BUILD_SHARED", "-I" ++ Include,
                   "-I" ++ Flat, "-o", Out] ++ Sources ++ case Windows of true -> []; false -> ["-fPIC"] end,
            Cl = ["/nologo", "/LD", "/O1", "/DLICD_BUILD_SHARED", "/DLICDF_BUILD_SHARED", "/I" ++ Include,
                  "/I" ++ Flat, "/Fe:" ++ Out] ++ Sources,
            first([{"cc", Gcc}, {"gcc", Gcc}, {"clang", Gcc}, {"zig", ["cc" | Gcc]}, {"cl", Cl}], Tmp, Out)
    end.

first([], _Tmp, _Out) ->
    {error, <<"the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path">>};
first([{Exe, Args} | Rest], Tmp, Out) ->
    case os:find_executable(Exe) of
        false -> first(Rest, Tmp, Out);
        Path ->
            Port = open_port({spawn_executable, Path},
                             [{args, Args}, {cd, Tmp}, exit_status, stderr_to_stdout, binary]),
            case wait(Port) of
                0 -> {ok, list_to_binary(Out)};
                _ -> first(Rest, Tmp, Out)
            end
    end.

wait(Port) ->
    receive
        {Port, {data, _}} -> wait(Port);
        {Port, {exit_status, Status}} -> Status
    end.

sdk_root() ->
    case os:getenv("KEYNUB_SDK_ROOT") of
        Path when is_list(Path), Path =/= "" -> {ok, Path};
        _ ->
            {ok, Cwd} = file:get_cwd(),
            up(Cwd)
    end.

up(Dir) ->
    case filelib:is_file(filename:join(Dir, "bindings/flat/licd_flat.c")) of
        true -> {ok, Dir};
        false ->
            case filename:dirname(Dir) of
                Dir -> {error, <<"the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT">>};
                Parent -> up(Parent)
            end
    end.

tmp_dir() ->
    Base = case os:getenv("TMPDIR") of
               false -> case os:getenv("TEMP") of false -> "/tmp"; T -> T end;
               T -> T
           end,
    Dir = filename:join(Base, "keynub-gleam-standin-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    {ok, Dir}.
