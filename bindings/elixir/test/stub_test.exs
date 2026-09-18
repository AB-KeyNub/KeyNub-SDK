defmodule KeyNub.LicDongle.StubTest do
  # Every call of the binding against a stand-in for the flat C API: the SDK's
  # flat layer compiled together with the C ABI stand-in
  # (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
  # into one shared library, with a C compiler from the path (cc, gcc, clang,
  # zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
  # stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the
  # test does not run inside a clone.
  use ExUnit.Case, async: false

  import Bitwise

  alias KeyNub.LicDongle, as: LD
  alias KeyNub.LicDongle.{Device, Error}

  @serial "04A1B2C3D4E5F6"
  @factory_key <<0x30, 0x10, 0x01, 0x02, 0x03>>
  @replacement_key <<0x30, 0x11, 0x09, 0x08, 0x07, 0x06>>

  setup_all do
    LD.set_library_path(stand_in())
    :ok
  end

  defp fails(status, {:error, %Error{status: got}}), do: assert(got == status)
  defp fails(status, other), do: flunk("expected #{inspect(status)}, got #{inspect(other)}")

  test "every call against the ABI stand-in" do
    assert LD.library_version!() == {9, 8, 7}
    assert LD.status_text(-2) == "no device"

    assert LD.devices!() == [%Device{serial: @serial, path: "stub:0"}]
    fails(:no_device, LD.open("nope"))
    fails(:no_device, LD.open_path("stub:9"))

    d = LD.open!()
    assert LD.serial!(d) == @serial
    i = LD.info!(d)
    assert i.protocol_version == {1, 0} and i.firmware_version == {2, 3, 4}
    assert i.secure_element_ready and i.provisioned and i.isolated
    refute i.watchdog_reboot or i.write_auth_rotated
    assert i.data_capacity == 1024 * 1024 and i.data_free == 1_000_000
    g = LD.verify_genuine!(d)
    assert g.serial == @serial and g.provisioned_date == "2026-08-15"
    assert LD.genuine?(d)

    fails(:cert_invalid, LD.set_trust_root(d, <<0x02, 0x01, 0x00>>))
    :ok = LD.set_trust_root!(d, <<0x30, 0x82, 0x01, 0x00>> <> :binary.copy(<<0xAB>>, 128))
    fails(:cert_invalid, LD.verify_genuine(d))
    refute LD.genuine?(d)
    :ok = LD.set_trust_root!(d, <<0x30, 0x82, 0x01, 0x00>> <> :binary.copy(<<0x01>>, 128))
    assert LD.genuine?(d)

    fails(:session_expired, LD.records(d))
    :ok = LD.session_open!(d)
    payload = "license-blob-0123456789"
    fails(:auth_required, LD.write_record(d, "lic", payload))
    fails(:not_genuine, LD.authorize_write(d, <<0x30, 0x00>>))
    :ok = LD.authorize_write!(d, @factory_key)
    :ok = LD.write_record!(d, "lic", payload)
    assert LD.read_record!(d, "lic") == payload
    :ok = LD.write_record!(d, "cfg", "cfgdata")
    recs = LD.records!(d)
    assert Enum.sort(Enum.map(recs, & &1.name)) == ["cfg", "lic"]
    assert Enum.any?(recs, &(&1.name == "lic" and &1.size == byte_size(payload)))
    assert LD.read_record!(d, "cfg") == "cfgdata"
    fails(:not_found, LD.read_record(d, "nope"))
    fails(:invalid_arg, LD.erase_record(d, ""))
    assert length(LD.records!(d)) == 2
    :ok = LD.erase_record!(d, "cfg")
    assert Enum.map(LD.records!(d), & &1.name) == ["lic"]
    :ok = LD.write_record!(d, "empty", "")
    assert LD.read_record!(d, "empty") == ""

    before = LD.read_counter!(d, 0)
    assert LD.increment_counter!(d, 0) == before + 1
    assert LD.read_counter!(d, 0) == before + 1 and LD.read_counter!(d, 1) == 0
    fails(:range, LD.read_counter(d, 7))

    secret = for k <- 0..99, into: <<>>, do: <<rem(3 * k + 7, 256)>>

    for {scope, byte} <- [device: 0, developer: 1] do
      blob = LD.app_encrypt!(d, scope, secret)
      assert byte_size(blob) > byte_size(secret), "sealed data is longer, #{scope}"
      assert :binary.first(blob) == byte, "scope byte #{scope}"
      assert LD.app_decrypt!(d, blob) == secret, "round trip #{scope}"
      head = binary_part(blob, 0, byte_size(blob) - 1)
      tampered = head <> <<bxor(:binary.last(blob), 1)>>
      fails(:tag_mismatch, LD.app_decrypt(d, tampered))
    end

    :ok = LD.erase_all_records!(d)
    assert LD.records!(d) == []

    :ok = LD.rotate_write_key!(d, @replacement_key)
    :ok = LD.write_record!(d, "lic", "still-writable")
    :ok = LD.session_close!(d)
    assert LD.info!(d).write_auth_rotated
    :ok = LD.session_open!(d)
    fails(:not_genuine, LD.authorize_write(d, @factory_key))
    :ok = LD.authorize_write!(d, @replacement_key)
    :ok = LD.write_record!(d, "lic", "new-key-writes")
    assert LD.read_record!(d, "lic") == "new-key-writes"
    :ok = LD.session_close!(d)
    :ok = LD.close!(d)
    assert match?({:error, %Error{}}, LD.serial(d))

    assert {:ok, {9, 8, 7}} = LD.with_dongle(fn dd -> LD.library_version!() |> tap(fn _ -> LD.serial!(dd) end) end)
    assert LD.loaded_library_path() == LD.library_path()

    IO.puts("keynub_licdongle: every call passed against the ABI stand-in")
  end

  # ---- the stand-in ------------------------------------------------------------

  defp stand_in do
    case System.get_env("KEYNUB_LICDONGLE_FLAT_LIBRARY") do
      path when is_binary(path) and path != "" -> path
      _ -> build_stand_in()
    end
  end

  defp build_stand_in do
    root = sdk_root()
    windows? = match?({:win32, _}, :os.type())
    tmp = System.tmp_dir!()
    # Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by
    # leaf name even for an absolute-path dlopen, and a build tree on that
    # path holds the real library under that name.
    out = Path.join(tmp, if(windows?, do: "keynub_flat_standin.dll", else: "libkeynub_flat_standin.so"))

    include =
      if File.exists?(Path.join(root, "core/include/licdongle.h")),
        do: Path.join(root, "core/include"),
        else: Path.join(root, "include")

    sources = [Path.join(root, "bindings/flat/licd_flat.c"), Path.join(root, "bindings/julia/test/stub/licd_stub.c")]

    gcc_args =
      [
        "-shared",
        "-O1",
        "-DLICD_BUILD_SHARED",
        "-DLICDF_BUILD_SHARED",
        "-I" <> include,
        "-I" <> Path.join(root, "bindings/flat"),
        "-o",
        out
      ] ++
        sources ++ if(windows?, do: [], else: ["-fPIC"])

    cl_args =
      [
        "/nologo",
        "/LD",
        "/O1",
        "/DLICD_BUILD_SHARED",
        "/DLICDF_BUILD_SHARED",
        "/I" <> include,
        "/I" <> Path.join(root, "bindings/flat"),
        "/Fe:" <> out
      ] ++
        sources

    compilers = [{"cc", gcc_args}, {"gcc", gcc_args}, {"clang", gcc_args}, {"zig", ["cc" | gcc_args]}, {"cl", cl_args}]

    Enum.find_value(compilers, fn {exe, args} ->
      with path when is_binary(path) <- System.find_executable(exe),
           {_, 0} <- System.cmd(path, args, cd: tmp, stderr_to_stdout: true) do
        out
      else
        _ -> nil
      end
    end) ||
      flunk("the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path")
  end

  defp sdk_root do
    case System.get_env("KEYNUB_SDK_ROOT") do
      path when is_binary(path) and path != "" -> path
      _ -> up(File.cwd!())
    end
  end

  defp up(dir) do
    if File.exists?(Path.join(dir, "bindings/flat/licd_flat.c")) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir,
        do: flunk("the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT"),
        else: up(parent)
    end
  end
end
