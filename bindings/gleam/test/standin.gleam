//// Every call of the package against a stand-in for the flat C API: the SDK's
//// flat layer compiled together with the C ABI stand-in
//// (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
//// into one shared library, with a C compiler from the path (cc, gcc, clang,
//// zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
//// stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the
//// test does not run inside a clone. Exit code 0 when every check passed.
////
////     gleam run -m standin      (in bindings/gleam)

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import keynub/licdongle.{
  type DongleError, type Status, CallError, DeveloperScope, DeviceScope,
  DongleRecord, Genuine, LibraryVersion,
}

const serial = "04A1B2C3D4E5F6"

@external(erlang, "standin_ffi", "stand_in")
fn stand_in() -> Result(String, String)

@external(erlang, "standin_ffi", "halt")
fn halt(code: Int) -> Nil

fn check(condition: Bool, what: String) -> Int {
  case condition {
    True -> 0
    False -> {
      io.println("  FAIL  " <> what)
      1
    }
  }
}

fn fails(result: Result(a, DongleError), status: Status, what: String) -> Int {
  case result {
    Ok(_) -> check(False, what <> ": no failure")
    Error(CallError(status: got, ..)) ->
      check(got == status, what <> ": " <> string.inspect(got))
    Error(other) -> check(False, what <> ": " <> string.inspect(other))
  }
}

fn bytes(values: List(Int)) -> BitArray {
  list.fold(values, <<>>, fn(acc, b) { <<acc:bits, b>> })
}

fn count_up(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..count_up(from + 1, to)]
  }
}

fn tamper(blob: BitArray) -> BitArray {
  let size = bit_array.byte_size(blob)
  let assert Ok(head) = bit_array.slice(blob, 0, size - 1)
  let assert Ok(<<last>>) = bit_array.slice(blob, size - 1, 1)
  <<head:bits, { int.bitwise_exclusive_or(last, 1) }>>
}

pub fn main() -> Nil {
  let path = case stand_in() {
    Ok(path) -> path
    Error(message) -> {
      io.println(message)
      halt(1)
      ""
    }
  }
  let assert Ok(Nil) = licdongle.set_library_path(path)
  let factory_key = <<0x30, 0x10, 0x01, 0x02, 0x03>>
  let replacement_key = <<0x30, 0x11, 0x09, 0x08, 0x07, 0x06>>
  let payload = <<"license-blob-0123456789":utf8>>

  let f = 0
  let f =
    f
    + check(
      licdongle.library_version() == Ok(LibraryVersion(9, 8, 7)),
      "library version",
    )
  let f = f + check(licdongle.status_text(-2) == "no device", "status text")
  let f =
    f
    + check(
      licdongle.devices() == Ok([licdongle.Device(serial, "stub:0")]),
      "devices",
    )
  let f =
    f
    + fails(
      licdongle.open(Some("nope")),
      licdongle.NoDevice,
      "open by unknown serial",
    )
  let f =
    f
    + fails(
      licdongle.open_path("stub:9"),
      licdongle.NoDevice,
      "open by unknown path",
    )

  let assert Ok(d) = licdongle.open(None)
  let f = f + check(licdongle.serial(d) == Ok(serial), "serial")
  let assert Ok(i) = licdongle.info(d)
  let f =
    f
    + check(i.protocol_major == 1 && i.protocol_minor == 0, "protocol version")
  let f =
    f
    + check(
      i.firmware_major == 2 && i.firmware_minor == 3 && i.firmware_patch == 4,
      "firmware version",
    )
  let f =
    f
    + check(i.secure_element_ready && i.provisioned && i.isolated, "flags set")
  let f = f + check(!i.watchdog_reboot && !i.write_auth_rotated, "flags clear")
  let f =
    f
    + check(
      i.data_capacity == 1024 * 1024 && i.data_free == 1_000_000,
      "capacity",
    )
  let f =
    f
    + check(
      licdongle.verify_genuine(d) == Ok(Genuine(serial, "2026-08-15")),
      "genuine",
    )
  let f = f + check(licdongle.is_genuine(d), "is_genuine")

  let f =
    f
    + fails(
      licdongle.set_trust_root(d, <<0x02, 0x01, 0x00>>),
      licdongle.CertInvalid,
      "malformed trust root",
    )
  let header = <<0x30, 0x82, 0x01, 0x00>>
  let foreign = <<header:bits, { bytes(list.repeat(0xAB, 128)) }:bits>>
  let assert Ok(Nil) = licdongle.set_trust_root(d, foreign)
  let f =
    f
    + fails(
      licdongle.verify_genuine(d),
      licdongle.CertInvalid,
      "verify against a foreign root",
    )
  let f = f + check(!licdongle.is_genuine(d), "is_genuine fails closed")
  let right = <<header:bits, { bytes(list.repeat(0x01, 128)) }:bits>>
  let assert Ok(Nil) = licdongle.set_trust_root(d, right)
  let f = f + check(licdongle.is_genuine(d), "is_genuine after the right root")

  let f =
    f
    + fails(
      licdongle.records(d),
      licdongle.SessionExpired,
      "records without a session",
    )
  let assert Ok(Nil) = licdongle.session_open(d)
  let f =
    f
    + fails(
      licdongle.write_record(d, "lic", payload),
      licdongle.AuthRequired,
      "write before the write role",
    )
  let f =
    f
    + fails(
      licdongle.authorize_write(d, <<0x30, 0x00>>),
      licdongle.NotGenuine,
      "write role with a bad key",
    )
  let assert Ok(Nil) = licdongle.authorize_write(d, factory_key)
  let assert Ok(Nil) = licdongle.write_record(d, "lic", payload)
  let f = f + check(licdongle.read_record(d, "lic") == Ok(payload), "read back")
  let assert Ok(Nil) = licdongle.write_record(d, "cfg", <<"cfgdata":utf8>>)
  let assert Ok(recs) = licdongle.records(d)
  let f =
    f
    + check(
      list.sort(list.map(recs, fn(r) { r.name }), string.compare)
        == ["cfg", "lic"],
      "record names",
    )
  let f =
    f
    + check(
      list.contains(recs, DongleRecord("lic", bit_array.byte_size(payload))),
      "record size",
    )
  let f =
    f
    + check(
      licdongle.read_record(d, "cfg") == Ok(<<"cfgdata":utf8>>),
      "second record",
    )
  let f =
    f
    + fails(
      licdongle.read_record(d, "nope"),
      licdongle.NotFound,
      "read a missing record",
    )
  let f =
    f
    + fails(
      licdongle.erase_record(d, ""),
      licdongle.InvalidArg,
      "erase with an empty name",
    )
  let assert Ok(two) = licdongle.records(d)
  let f = f + check(list.length(two) == 2, "two records")
  let assert Ok(Nil) = licdongle.erase_record(d, "cfg")
  let assert Ok(one) = licdongle.records(d)
  let f =
    f + check(list.map(one, fn(r) { r.name }) == ["lic"], "one record left")
  let assert Ok(Nil) = licdongle.write_record(d, "empty", <<>>)
  let f =
    f + check(licdongle.read_record(d, "empty") == Ok(<<>>), "empty record")

  let assert Ok(before) = licdongle.read_counter(d, 0)
  let f =
    f + check(licdongle.increment_counter(d, 0) == Ok(before + 1), "increment")
  let f =
    f
    + check(
      licdongle.read_counter(d, 0) == Ok(before + 1)
        && licdongle.read_counter(d, 1) == Ok(0),
      "counters",
    )
  let f =
    f
    + fails(
      licdongle.read_counter(d, 7),
      licdongle.Range,
      "counter out of range",
    )

  let secret = bytes(list.map(count_up(0, 99), fn(k) { { 3 * k + 7 } % 256 }))
  let f =
    list.fold(
      [#(DeviceScope, 0, "DeviceScope"), #(DeveloperScope, 1, "DeveloperScope")],
      f,
      fn(f, entry) {
        let #(scope, value, name) = entry
        let assert Ok(blob) = licdongle.app_encrypt(d, scope, secret)
        let assert <<first, _:bytes>> = blob
        let f =
          f
          + check(
            bit_array.byte_size(blob) > bit_array.byte_size(secret),
            "sealed data is longer, " <> name,
          )
        let f = f + check(first == value, "scope byte, " <> name)
        let f =
          f
          + check(
            licdongle.app_decrypt(d, blob) == Ok(secret),
            "round trip, " <> name,
          )
        f
        + fails(
          licdongle.app_decrypt(d, tamper(blob)),
          licdongle.TagMismatch,
          "tampered blob, " <> name,
        )
      },
    )

  let assert Ok(Nil) = licdongle.erase_all_records(d)
  let f = f + check(licdongle.records(d) == Ok([]), "erase all")

  let assert Ok(Nil) = licdongle.rotate_write_key(d, replacement_key)
  let assert Ok(Nil) =
    licdongle.write_record(d, "lic", <<"still-writable":utf8>>)
  let assert Ok(Nil) = licdongle.session_close(d)
  let assert Ok(rotated) = licdongle.info(d)
  let f = f + check(rotated.write_auth_rotated, "rotated flag")
  let assert Ok(Nil) = licdongle.session_open(d)
  let f =
    f
    + fails(
      licdongle.authorize_write(d, factory_key),
      licdongle.NotGenuine,
      "factory key after rotation",
    )
  let assert Ok(Nil) = licdongle.authorize_write(d, replacement_key)
  let assert Ok(Nil) =
    licdongle.write_record(d, "lic", <<"new-key-writes":utf8>>)
  let f =
    f
    + check(
      licdongle.read_record(d, "lic") == Ok(<<"new-key-writes":utf8>>),
      "write with the new key",
    )
  let assert Ok(Nil) = licdongle.session_close(d)
  let assert Ok(Nil) = licdongle.close(d)
  let f =
    f + fails(licdongle.serial(d), licdongle.InvalidArg, "serial after close")

  let f =
    f
    + check(
      licdongle.with_dongle(None, licdongle.serial) == Ok(serial),
      "with_dongle",
    )
  // records needs a session, so a value back proves with_session opened one.
  let counted =
    licdongle.with_dongle(Some(serial), fn(dd) {
      licdongle.with_session(dd, fn() {
        case licdongle.records(dd) {
          Ok(list) -> Ok(list.length(list))
          Error(e) -> Error(e)
        }
      })
    })
  let f =
    f
    + check(
      case counted {
        Ok(n) -> n >= 0
        Error(_) -> False
      },
      "with_session",
    )
  let assert Ok(kept) = licdongle.with_dongle(None, fn(dd) { Ok(dd) })
  let f =
    f
    + fails(
      licdongle.serial(kept),
      licdongle.InvalidArg,
      "closed after with_dongle",
    )
  let f =
    f + check(licdongle.loaded_library_path() == Some(path), "loaded path")

  case f {
    0 ->
      io.println("keynub_licdongle: every call passed against the ABI stand-in")
    _ -> {
      io.println(int.to_string(f) <> " check(s) failed")
      halt(1)
    }
  }
}
