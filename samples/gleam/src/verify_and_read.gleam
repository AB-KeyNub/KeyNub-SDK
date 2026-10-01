//// KeyNub SDK - Gleam sample: verify a dongle and read what it holds.
////
////     gleam run -m verify_and_read      (in samples/gleam)
////
//// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//// In your own project: gleam add keynub_licdongle_gleam

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import keynub/licdongle.{type Dongle, type DongleError, CallError, LibraryError}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

fn report(d: Dongle) -> Result(Nil, DongleError) {
  use i <- result.try(licdongle.info(d))
  io.println(
    "Protocol v"
    <> int.to_string(i.protocol_major)
    <> "."
    <> int.to_string(i.protocol_minor)
    <> ", firmware v"
    <> int.to_string(i.firmware_major)
    <> "."
    <> int.to_string(i.firmware_minor)
    <> "."
    <> int.to_string(i.firmware_patch)
    <> ", "
    <> int.to_string(i.data_free)
    <> " of "
    <> int.to_string(i.data_capacity)
    <> " bytes free.",
  )
  // The only trace a firmware hang leaves behind. Worth reporting to support.
  case i.watchdog_reboot {
    True ->
      io.println(
        "WARNING: this dongle's previous boot ended in a watchdog reset.",
      )
    False -> Nil
  }
  use g <- result.try(licdongle.verify_genuine(d))
  io.println(
    "Genuine: yes (serial "
    <> g.serial
    <> ", provisioned "
    <> g.provisioned_date
    <> ")",
  )
  Ok(Nil)
}

fn read_records(d: Dongle) -> Result(Nil, DongleError) {
  use recs <- result.try(licdongle.records(d))
  io.println(int.to_string(list.length(recs)) <> " record(s) on the dongle:")
  list.each(recs, fn(r) {
    io.println(
      "  "
      <> string.pad_end(r.name, 16, " ")
      <> " "
      <> int.to_string(r.size)
      <> " bytes",
    )
  })
  // A missing record is a normal state, not an error.
  case list.any(recs, fn(r) { r.name == "license" }) {
    True -> {
      use data <- result.try(licdongle.read_record(d, "license"))
      io.println(
        "Read "
        <> int.to_string(bit_array.byte_size(data))
        <> " bytes from the license record.",
      )
      Ok(Nil)
    }
    False -> Ok(Nil)
  }
}

// The part that protects something. At licence-issue time you would
// call app_encrypt once, with a developer dongle, and ship only the sealed data;
// the program then cannot proceed without a dongle, because it holds no other
// copy. DeveloperScope lets any dongle you have issued decrypt it, so one file
// serves every customer; DeviceScope locks it to one dongle.
fn protect_something(d: Dongle) -> Result(Nil, DongleError) {
  let needed = <<"the data this program cannot run without":utf8>>
  use sealed <- result.try(licdongle.app_encrypt(
    d,
    licdongle.DeveloperScope,
    needed,
  ))
  use recovered <- result.try(licdongle.app_decrypt(d, sealed))
  io.println(
    "App-crypto round trip: "
    <> int.to_string(bit_array.byte_size(needed))
    <> " bytes -> "
    <> int.to_string(bit_array.byte_size(sealed))
    <> " sealed -> "
    <> case recovered == needed {
      True -> "recovered intact"
      False -> "MISMATCH"
    },
  )
  Ok(Nil)
}

fn run() -> Result(Nil, DongleError) {
  use v <- result.try(licdongle.library_version())
  io.println(
    "KeyNub library v"
    <> int.to_string(v.major)
    <> "."
    <> int.to_string(v.minor)
    <> "."
    <> int.to_string(v.patch),
  )
  use found <- result.try(licdongle.devices())
  case found {
    [] -> {
      io.println("Connect a KeyNub dongle and re-run.")
      Ok(Nil)
    }
    _ -> {
      // first dongle, or with_dongle(Some("serial"), ...)
      use d <- licdongle.with_dongle(None)
      use _ <- result.try(report(d))
      // closed on every exit path
      use <- licdongle.with_session(d)
      use _ <- result.try(read_records(d))
      protect_something(d)
    }
  }
}

pub fn main() -> Nil {
  case run() {
    Ok(Nil) -> Nil
    Error(CallError(..) as e) -> {
      io.println(
        "KeyNub error: "
        <> e.operation
        <> ": "
        <> string.inspect(e.status)
        <> " ("
        <> int.to_string(e.code)
        <> ")",
      )
      halt(1)
    }
    Error(LibraryError(message)) -> {
      io.println("KeyNub error: " <> message)
      halt(1)
    }
  }
}
