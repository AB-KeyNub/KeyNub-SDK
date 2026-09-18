defmodule KeyNub.LicDongle.Library do
  @moduledoc """
  Where the native library (`keynub_licdongle_flat`) comes from.

  The path given to `set_library_path/1`, then `KEYNUB_LICDONGLE_FLAT_LIBRARY`
  in the environment, then `natives/<platform>/` of an SDK clone from the
  working directory upwards, then the bare file name for the system loader.
  A process loads the library once.
  """

  alias KeyNub.LicDongle.{LibraryError, Nif}

  @env "KEYNUB_LICDONGLE_FLAT_LIBRARY"
  @folders ~w(win-x64 win-x86 win-arm64 linux-x64 linux-arm64 osx-x64 osx-arm64)
  @chosen {__MODULE__, :chosen}

  @doc "Names the library file to load. Call it before the first dongle call."
  @spec set_library_path(String.t()) :: :ok
  def set_library_path(path) when is_binary(path) do
    case Nif.loaded_path() do
      loaded when is_binary(loaded) and loaded != path ->
        raise LibraryError,
          message: "the KeyNub library is already loaded from #{loaded}; a process loads it once"

      _ ->
        :persistent_term.put(@chosen, path)
    end
  end

  @doc "The path in use, or the first candidate when nothing is loaded yet."
  @spec library_path() :: String.t()
  def library_path do
    case Nif.loaded_path() do
      loaded when is_binary(loaded) -> loaded
      _ -> List.first(candidates())
    end
  end

  @doc "The path of the loaded library, or `nil` before the first call."
  @spec loaded_library_path() :: String.t() | nil
  def loaded_library_path do
    case Nif.loaded_path() do
      loaded when is_binary(loaded) -> loaded
      _ -> nil
    end
  end

  @doc false
  @spec ensure_loaded!() :: :ok
  def ensure_loaded! do
    case Nif.loaded_path() do
      loaded when is_binary(loaded) ->
        :ok

      _ ->
        all = candidates()
        load_first(all, all)
    end
  end

  defp load_first([], all) do
    raise LibraryError, message: "cannot load the KeyNub library (tried #{Enum.join(all, ", ")})"
  end

  defp load_first([path | rest], all) do
    case Nif.load(path) do
      :ok -> :ok
      {:error, _} -> load_first(rest, all)
    end
  end

  @doc "The paths tried, in order."
  @spec candidates() :: [String.t()]
  def candidates do
    case :persistent_term.get(@chosen, nil) do
      nil ->
        case System.get_env(@env) do
          path when is_binary(path) and path != "" -> [path]
          _ -> natives_candidates() ++ basenames()
        end

      path ->
        [path]
    end
  end

  @doc "The library's file name(s) on this operating system."
  @spec basenames() :: [String.t()]
  def basenames do
    case :os.type() do
      {:win32, _} -> ["keynub_licdongle_flat.dll"]
      _ -> ["libkeynub_licdongle_flat.so", "libkeynub_licdongle_flat.dylib"]
    end
  end

  defp natives_candidates do
    for dir <- ancestors(File.cwd!()),
        folder <- @folders,
        base <- basenames(),
        path = Path.join([dir, "natives", folder, base]),
        File.regular?(path),
        do: path
  end

  defp ancestors(dir) do
    parent = Path.dirname(dir)
    if parent == dir, do: [dir], else: [dir | ancestors(parent)]
  end
end
