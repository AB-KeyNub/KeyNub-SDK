# KeyNub SDK - Elixir sample: take ownership of a new dongle.
#
# A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
# so that from the next session onward only your key can write records, erase
# them or increment counters. Run it once per dongle, when it arrives.
#
# Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
#
#     openssl ecparam -name prime256v1 -genkey -noout |
#       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
#
#     elixir samples/elixir/rotate_write_key.exs keys/keynub-shipping-writeauth.key.der my-key.der
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# The replacement key is worth what your licence-signing key is worth. It
# cannot be recovered from the dongle, and a unit rotated to a key you have
# lost has to come back to be re-provisioned.

Mix.install([{:keynub_licdongle, path: Path.expand("../../bindings/elixir", __DIR__)}])

defmodule Rotate do
  alias KeyNub.LicDongle

  def run(current, replacement) do
    case LicDongle.devices!() do
      [] ->
        IO.puts("Connect a KeyNub dongle and re-run.")

      _ ->
        {:ok, _} =
          LicDongle.with_dongle(fn d ->
            IO.puts("Dongle #{LicDongle.serial!(d)}")

            if LicDongle.info!(d).write_auth_rotated do
              IO.puts("This dongle's write key has already been rotated away from the factory one.")
            end

            LicDongle.with_session!(d, fn ->
              # the key the dongle accepts today
              LicDongle.authorize_write!(d, current)
              # from the next session: only the new one
              LicDongle.rotate_write_key!(d, replacement)
            end)

            rotated = if LicDongle.info!(d).write_auth_rotated, do: "yes", else: "no"
            IO.puts("Write key rotated: #{rotated}")
          end)
    end
  end
end

case System.argv() do
  [current, replacement] ->
    try do
      Rotate.run(File.read!(current), File.read!(replacement))
    rescue
      e in [KeyNub.LicDongle.Error, KeyNub.LicDongle.LibraryError, File.Error] ->
        IO.puts("KeyNub error: " <> Exception.message(e))
        System.halt(1)
    end

  _ ->
    IO.puts("usage: rotate_write_key <current-key.der> <new-key.der>")
    System.halt(2)
end
