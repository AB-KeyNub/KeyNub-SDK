defmodule KeyNub.LicDongle do
  @moduledoc """
  Client for the KeyNub USB license dongle.

      {:ok, secret} =
        KeyNub.LicDongle.with_dongle(fn d ->
          KeyNub.LicDongle.verify_genuine!(d)
          KeyNub.LicDongle.with_session!(d, fn -> KeyNub.LicDongle.app_decrypt!(d, sealed) end)
        end)

  Every call returns `{:ok, value}`, `:ok` or `{:error, %KeyNub.LicDongle.Error{}}`;
  the `!` variants return the value and raise the error instead. The package
  calls the SDK's flat companion API through a small NIF that loads the native
  library at run time; see `KeyNub.LicDongle.Library` for where that library
  comes from.
  """

  alias KeyNub.LicDongle.{Error, Library, Nif}

  defmodule Dongle do
    @moduledoc "An open dongle, from `KeyNub.LicDongle.open/1`."
    @enforce_keys [:handle]
    defstruct [:handle]
    @type t :: %__MODULE__{handle: pos_integer}
  end

  defmodule Device do
    @moduledoc "An attached dongle, from `KeyNub.LicDongle.devices/0`."
    defstruct [:serial, :path]
    @type t :: %__MODULE__{serial: String.t(), path: String.t()}
  end

  defmodule Info do
    @moduledoc "Plaintext device information, from `KeyNub.LicDongle.info/1`."
    defstruct [
      :protocol_version,
      :firmware_version,
      :secure_element_ready,
      :provisioned,
      :watchdog_reboot,
      :isolated,
      :write_auth_rotated,
      :data_capacity,
      :data_free
    ]

    @type t :: %__MODULE__{
            protocol_version: {non_neg_integer, non_neg_integer},
            firmware_version: {non_neg_integer, non_neg_integer, non_neg_integer},
            secure_element_ready: boolean,
            provisioned: boolean,
            watchdog_reboot: boolean,
            isolated: boolean,
            write_auth_rotated: boolean,
            data_capacity: non_neg_integer,
            data_free: non_neg_integer
          }
  end

  defmodule Genuine do
    @moduledoc "The result of a successful `KeyNub.LicDongle.verify_genuine/1`."
    defstruct [:serial, :provisioned_date]
    @type t :: %__MODULE__{serial: String.t(), provisioned_date: String.t()}
  end

  defmodule Record do
    @moduledoc "A record on the dongle, from `KeyNub.LicDongle.records/1`."
    defstruct [:name, :size]
    @type t :: %__MODULE__{name: String.t(), size: non_neg_integer}
  end

  @typedoc "`:device` seals to this dongle only; `:developer` to any dongle issued by the same developer."
  @type scope :: :device | :developer

  @type result(value) :: {:ok, value} | {:error, Error.t()}
  @type status_result :: :ok | {:error, Error.t()}

  @range -11
  @not_genuine -7

  # ---- the library -----------------------------------------------------------

  @doc "Names the native library file to load. See `KeyNub.LicDongle.Library`."
  defdelegate set_library_path(path), to: Library

  @doc "The library path in use, or the first candidate when nothing is loaded yet."
  defdelegate library_path(), to: Library

  @doc "The path of the loaded library, or `nil` before the first call."
  defdelegate loaded_library_path(), to: Library

  @doc "The native library's version as `{major, minor, patch}`."
  @spec library_version() :: result({integer, integer, integer})
  def library_version do
    Library.ensure_loaded!()
    result("licdf_version", Nif.version())
  end

  @doc "Human-readable text for a status code."
  @spec status_text(integer) :: String.t()
  def status_text(code) when is_integer(code) do
    Library.ensure_loaded!()
    Nif.strerror(code)
  end

  @doc "Diagnostic detail for the most recent failure on this dongle (may be empty)."
  @spec last_error_detail(Dongle.t()) :: String.t()
  def last_error_detail(%Dongle{handle: h}) do
    Library.ensure_loaded!()
    Nif.last_error(h)
  end

  # ---- discovery, open, close --------------------------------------------------

  @doc "The attached dongles."
  @spec devices() :: result([Device.t()])
  def devices do
    Library.ensure_loaded!()

    with {:ok, n} <- result("licdf_device_count", Nif.device_count()) do
      map_ok(indices(n), fn i ->
        with {:ok, serial} <- result("licdf_device_serial", Nif.device_serial(i)),
             {:ok, path} <- result("licdf_device_path", Nif.device_path(i)) do
          {:ok, %Device{serial: serial, path: path}}
        end
      end)
    end
  end

  @doc "Opens the dongle with this serial, or the first one found when `nil`."
  @spec open(String.t() | nil) :: result(Dongle.t())
  def open(serial \\ nil) when is_binary(serial) or is_nil(serial) do
    Library.ensure_loaded!()
    handle("licdf_open", Nif.open(serial || ""))
  end

  @doc "Opens the dongle at this device path (from `devices/0`)."
  @spec open_path(String.t()) :: result(Dongle.t())
  def open_path(path) when is_binary(path) do
    Library.ensure_loaded!()
    handle("licdf_open_path", Nif.open_path(path))
  end

  @doc "Closes the dongle. Every further call on it fails."
  @spec close(Dongle.t()) :: status_result
  def close(%Dongle{handle: h}), do: result("licdf_close", Nif.close(h))

  @doc """
  Opens a dongle (by serial, or the first one when `nil`), runs `fun` with it
  and closes it on every exit path. Returns `{:ok, fun_result}`, or the error
  from opening.
  """
  @spec with_dongle(String.t() | nil, (Dongle.t() -> value)) :: result(value) when value: term
  def with_dongle(serial \\ nil, fun) when is_function(fun, 1) do
    case open(serial) do
      {:ok, d} ->
        try do
          {:ok, fun.(d)}
        after
          close(d)
        end

      {:error, _} = e ->
        e
    end
  end

  # ---- plaintext info ------------------------------------------------------------

  @doc "The dongle's serial number (14 hex digits)."
  @spec serial(Dongle.t()) :: result(String.t())
  def serial(%Dongle{handle: h}), do: result("licdf_get_serial", h, Nif.get_serial(h))

  @doc "Plaintext device information."
  @spec info(Dongle.t()) :: result(Info.t())
  def info(%Dongle{handle: h}) do
    with {:ok, {pa, pb, fa, fb, fc, flags, capacity, free}} <-
           result("licdf_get_info", h, Nif.get_info(h)) do
      flag = fn bit -> Bitwise.band(flags, bit) != 0 end

      {:ok,
       %Info{
         protocol_version: {pa, pb},
         firmware_version: {fa, fb, fc},
         secure_element_ready: flag.(0x01),
         provisioned: flag.(0x02),
         watchdog_reboot: flag.(0x04),
         isolated: flag.(0x08),
         write_auth_rotated: flag.(0x10),
         data_capacity: capacity,
         data_free: free
       }}
    end
  end

  @doc """
  Proves the dongle is genuine: certificate chain to the trusted root plus a
  live challenge-response. `{:ok, %Genuine{}}` only when it is.
  """
  @spec verify_genuine(Dongle.t()) :: result(Genuine.t())
  def verify_genuine(%Dongle{handle: h}) do
    case Nif.verify_genuine(h) do
      {0, genuine, serial, date} when genuine != 0 ->
        {:ok, %Genuine{serial: serial, provisioned_date: date}}

      {0, _, _, _} ->
        {:error, Error.new("licdf_verify_genuine", @not_genuine)}

      {rc, _, _, _} ->
        {:error, error("licdf_verify_genuine", h, rc)}
    end
  end

  @doc "The non-raising gate: `true` only when `verify_genuine/1` succeeds. Fails closed."
  @spec genuine?(Dongle.t()) :: boolean
  def genuine?(%Dongle{} = d) do
    match?({:ok, _}, verify_genuine(d))
  rescue
    _ -> false
  end

  @doc "Overrides the CA root that `verify_genuine/1` checks against (DER)."
  @spec set_trust_root(Dongle.t(), binary) :: status_result
  def set_trust_root(%Dongle{handle: h}, der) when is_binary(der) do
    result("licdf_set_trust_root", h, Nif.set_trust_root(h, der))
  end

  # ---- session -------------------------------------------------------------------

  @doc "Opens an authenticated session; records, counters and app crypto need one."
  @spec session_open(Dongle.t()) :: status_result
  def session_open(%Dongle{handle: h}), do: result("licdf_session_open", h, Nif.session_open(h))

  @doc "Closes the session."
  @spec session_close(Dongle.t()) :: status_result
  def session_close(%Dongle{handle: h}),
    do: result("licdf_session_close", h, Nif.session_close(h))

  @doc "Opens a session, runs `fun` and closes the session on every exit path."
  @spec with_session(Dongle.t(), (-> value)) :: result(value) when value: term
  def with_session(%Dongle{} = d, fun) when is_function(fun, 0) do
    case session_open(d) do
      :ok ->
        try do
          {:ok, fun.()}
        after
          session_close(d)
        end

      {:error, _} = e ->
        e
    end
  end

  @doc """
  Elevates the session to the write role with a write-auth key (P-256 PKCS#8
  DER). Belongs in licence-issuing tooling, never in the application users run.
  """
  @spec authorize_write(Dongle.t(), binary) :: status_result
  def authorize_write(%Dongle{handle: h}, key) when is_binary(key) do
    result("licdf_write_auth", h, Nif.write_auth(h, key))
  end

  @doc """
  Replaces the dongle's write-auth key with `key` (P-256 PKCS#8 DER). Call
  `authorize_write/2` first. From the next session on, only the new key elevates.
  """
  @spec rotate_write_key(Dongle.t(), binary) :: status_result
  def rotate_write_key(%Dongle{handle: h}, key) when is_binary(key) do
    result("licdf_write_auth_rotate", h, Nif.write_auth_rotate(h, key))
  end

  # ---- records -------------------------------------------------------------------

  @doc "The records on the dongle, with their sizes."
  @spec records(Dongle.t()) :: result([Record.t()])
  def records(%Dongle{handle: h}) do
    with {:ok, n} <- result("licdf_record_count", h, Nif.record_count(h)) do
      map_ok(indices(n), fn i ->
        case Nif.record_name(h, i) do
          {0, name, size} -> {:ok, %Record{name: name, size: size}}
          {rc, _, _} -> {:error, error("licdf_record_name", h, rc)}
        end
      end)
    end
  end

  @doc "The record's bytes."
  @spec read_record(Dongle.t(), String.t()) :: result(binary)
  def read_record(%Dongle{handle: h}, name) when is_binary(name) do
    read_bytes("licdf_record_read", h, &Nif.record_read(h, name, &1))
  end

  @doc "Writes (creates or replaces) the record. Needs the write role."
  @spec write_record(Dongle.t(), String.t(), binary) :: status_result
  def write_record(%Dongle{handle: h}, name, data) when is_binary(name) and is_binary(data) do
    result("licdf_record_write", h, Nif.record_write(h, name, data))
  end

  @doc "Erases one record by name. An empty name is refused."
  @spec erase_record(Dongle.t(), String.t()) :: status_result
  def erase_record(%Dongle{handle: h}, name) when is_binary(name) do
    result("licdf_record_erase", h, Nif.record_erase(h, name))
  end

  @doc "Erases every record."
  @spec erase_all_records(Dongle.t()) :: status_result
  def erase_all_records(%Dongle{handle: h}) do
    result("licdf_record_erase_all", h, Nif.record_erase_all(h))
  end

  # ---- counters ------------------------------------------------------------------

  @doc "The value of a hardware monotonic counter."
  @spec read_counter(Dongle.t(), non_neg_integer) :: result(non_neg_integer)
  def read_counter(%Dongle{handle: h}, id) when is_integer(id) do
    result("licdf_counter_read", h, Nif.counter_read(h, id))
  end

  @doc "Increments a counter and returns its new value. Needs the write role."
  @spec increment_counter(Dongle.t(), non_neg_integer) :: result(non_neg_integer)
  def increment_counter(%Dongle{handle: h}, id) when is_integer(id) do
    result("licdf_counter_increment", h, Nif.counter_increment(h, id))
  end

  # ---- app-data envelope encryption ------------------------------------------

  @doc """
  Seals `plaintext` so that only a dongle can open it: this one (`:device`) or
  any dongle issued by the same developer (`:developer`). Build the licence
  check on this pair: route data the program needs through it.
  """
  @spec app_encrypt(Dongle.t(), scope, binary) :: result(binary)
  def app_encrypt(%Dongle{handle: h}, scope, plaintext)
      when scope in [:device, :developer] and is_binary(plaintext) do
    code = if scope == :device, do: 0, else: 1
    read_bytes("licdf_app_encrypt", h, &Nif.app_encrypt(h, code, plaintext, &1))
  end

  @doc "Opens data sealed with `app_encrypt/3`."
  @spec app_decrypt(Dongle.t(), binary) :: result(binary)
  def app_decrypt(%Dongle{handle: h}, packed) when is_binary(packed) do
    read_bytes("licdf_app_decrypt", h, &Nif.app_decrypt(h, packed, &1))
  end

  # ---- the raising variants --------------------------------------------------------

  for {name, arity} <- [
        library_version: 0,
        devices: 0,
        open: 0,
        open: 1,
        open_path: 1,
        close: 1,
        with_dongle: 1,
        with_dongle: 2,
        serial: 1,
        info: 1,
        verify_genuine: 1,
        set_trust_root: 2,
        session_open: 1,
        session_close: 1,
        with_session: 2,
        authorize_write: 2,
        rotate_write_key: 2,
        records: 1,
        read_record: 2,
        write_record: 3,
        erase_record: 2,
        erase_all_records: 1,
        read_counter: 2,
        increment_counter: 2,
        app_encrypt: 3,
        app_decrypt: 2
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc "Like `#{name}/#{arity}`, returning the value (or `:ok`) and raising `KeyNub.LicDongle.Error` on failure."
    def unquote(:"#{name}!")(unquote_splicing(args)) do
      unwrap!(unquote(name)(unquote_splicing(args)))
    end
  end

  defp unwrap!(:ok), do: :ok
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, %Error{} = e}), do: raise(e)

  # ---- helpers -------------------------------------------------------------------

  defp indices(n) when n <= 0, do: []
  defp indices(n), do: Enum.to_list(0..(n - 1))

  defp map_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      e -> e
    end
  end

  defp error(operation, h, rc), do: Error.new(operation, rc, Nif.last_error(h))

  defp handle(_operation, h) when h > 0, do: {:ok, %Dongle{handle: h}}
  defp handle(operation, rc), do: {:error, Error.new(operation, rc)}

  # A raw status, or {status, value}, without a handle for the detail text.
  defp result(_operation, 0), do: :ok
  defp result(operation, rc) when is_integer(rc), do: {:error, Error.new(operation, rc)}
  defp result(_operation, {0, value}), do: {:ok, value}
  defp result(operation, {rc, _}), do: {:error, Error.new(operation, rc)}

  # The same, with the dongle's detail text on failure.
  defp result(_operation, _h, 0), do: :ok
  defp result(operation, h, rc) when is_integer(rc), do: {:error, error(operation, h, rc)}
  defp result(_operation, _h, {0, value}), do: {:ok, value}
  defp result(operation, h, {rc, _}), do: {:error, error(operation, h, rc)}

  # Bytes of unknown length: ask with a capacity of 0, the library answers
  # :range and the size needed, then read into that size.
  defp read_bytes(operation, h, call) do
    case call.(0) do
      {0, bytes} ->
        {:ok, bytes}

      {@range, needed} ->
        case call.(needed) do
          {0, bytes} -> {:ok, bytes}
          {rc, _} -> {:error, error(operation, h, rc)}
        end

      {rc, _} ->
        {:error, error(operation, h, rc)}
    end
  end
end
