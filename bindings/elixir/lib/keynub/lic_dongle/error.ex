defmodule KeyNub.LicDongle.Error do
  @moduledoc """
  A failed dongle call: the status, the raw code, the operation (the flat API
  function) and the library's detail text, which may be empty.
  """

  defexception [:status, :code, :operation, detail: ""]

  @type status ::
          :invalid_arg
          | :no_device
          | :access_denied
          | :io
          | :timeout
          | :protocol
          | :not_genuine
          | :cert_invalid
          | :session_expired
          | :tag_mismatch
          | :range
          | :storage_full
          | :busy
          | :not_found
          | :auth_required
          | :firmware_incompatible
          | :sdk_too_old
          | :cancelled
          | :not_implemented
          | :internal
          | {:unknown, integer}

  @type t :: %__MODULE__{
          status: status,
          code: integer,
          operation: String.t(),
          detail: String.t()
        }

  @statuses %{
    -1 => :invalid_arg,
    -2 => :no_device,
    -3 => :access_denied,
    -4 => :io,
    -5 => :timeout,
    -6 => :protocol,
    -7 => :not_genuine,
    -8 => :cert_invalid,
    -9 => :session_expired,
    -10 => :tag_mismatch,
    -11 => :range,
    -12 => :storage_full,
    -13 => :busy,
    -14 => :not_found,
    -15 => :auth_required,
    -16 => :firmware_incompatible,
    -17 => :sdk_too_old,
    -18 => :cancelled,
    -19 => :not_implemented,
    -20 => :internal
  }

  @doc "The status for a raw code."
  @spec status(integer) :: status
  def status(code), do: Map.get(@statuses, code, {:unknown, code})

  @doc false
  @spec new(String.t(), integer, String.t()) :: t
  def new(operation, code, detail \\ "") do
    %__MODULE__{status: status(code), code: code, operation: operation, detail: detail}
  end

  @impl true
  def message(%__MODULE__{} = e) do
    base = "#{e.operation}: #{inspect(e.status)} (#{e.code})"
    if e.detail in [nil, ""], do: base, else: base <> ": " <> e.detail
  end
end

defmodule KeyNub.LicDongle.LibraryError do
  @moduledoc "The native library could not be loaded, or does not fit."
  defexception [:message]
end
