# KeyNub SDK - Elixir sample: verify a dongle and read what it holds.
#
#     elixir samples/elixir/verify_and_read.exs      (from the repository root)
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.

Mix.install([{:keynub_licdongle, path: Path.expand("../../bindings/elixir", __DIR__)}])

defmodule Sample do
  alias KeyNub.LicDongle

  def run do
    {a, b, c} = LicDongle.library_version!()
    IO.puts("KeyNub library v#{a}.#{b}.#{c}")

    case LicDongle.devices!() do
      [] ->
        IO.puts("Connect a KeyNub dongle and re-run.")

      _ ->
        {:ok, _} =
          LicDongle.with_dongle(fn d ->
            report(d)

            LicDongle.with_session!(d, fn ->
              read_records(d)
              protect_something(d)
            end)
          end)
    end
  end

  defp report(d) do
    i = LicDongle.info!(d)
    {pa, pb} = i.protocol_version
    {fa, fb, fc} = i.firmware_version
    IO.puts("Protocol v#{pa}.#{pb}, firmware v#{fa}.#{fb}.#{fc}, #{i.data_free} of #{i.data_capacity} bytes free.")
    # The only trace a firmware hang leaves behind. Worth reporting to support.
    if i.watchdog_reboot, do: IO.puts("WARNING: this dongle's previous boot ended in a watchdog reset.")
    g = LicDongle.verify_genuine!(d)
    IO.puts("Genuine: yes (serial #{g.serial}, provisioned #{g.provisioned_date})")
  end

  defp read_records(d) do
    recs = LicDongle.records!(d)
    IO.puts("#{length(recs)} record(s) on the dongle:")
    Enum.each(recs, fn r -> IO.puts("  #{String.pad_trailing(r.name, 16)} #{r.size} bytes") end)
    # A missing record is a normal state, not an error.
    if Enum.any?(recs, &(&1.name == "license")) do
      IO.puts("Read #{byte_size(LicDongle.read_record!(d, "license"))} bytes from the license record.")
    end
  end

  # The part that actually protects something. At licence-issue time you would
  # call app_encrypt once, with a developer dongle, and ship only the sealed
  # data; the program then cannot proceed without a dongle, because it holds no
  # other copy. :developer lets any dongle you have issued decrypt it, so one
  # file serves every customer; :device locks it to one dongle.
  defp protect_something(d) do
    needed = "the data this program cannot run without"
    sealed = LicDongle.app_encrypt!(d, :developer, needed)
    recovered = LicDongle.app_decrypt!(d, sealed)
    outcome = if recovered == needed, do: "recovered intact", else: "MISMATCH"
    IO.puts("App-crypto round trip: #{byte_size(needed)} bytes -> #{byte_size(sealed)} sealed -> #{outcome}")
  end
end

try do
  Sample.run()
rescue
  e in [KeyNub.LicDongle.Error, KeyNub.LicDongle.LibraryError] ->
    IO.puts("KeyNub error: " <> Exception.message(e))
    System.halt(1)
end
