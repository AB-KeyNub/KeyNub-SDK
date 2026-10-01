//// KeyNub SDK - Gleam sample: take ownership of a new dongle.
////
//// A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
//// so that from the next session onward only your key can write records, erase
//// them or increment counters. Run it once per dongle, when it arrives.
////
//// Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
////
////     openssl ecparam -name prime256v1 -genkey -noout |
////       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
////
////     gleam run -m rotate_write_key -- ../../keys/keynub-shipping-writeauth.key.der my-key.der      (in samples/gleam)
////
//// Targets real hardware: with no dongle attached it prints guidance and exits 0.
////
//// The replacement key is worth what your licence-signing key is worth. It
//// cannot be recovered from the dongle, and a unit rotated to a key you have
//// lost has to come back to be re-provisioned.

import gleam/int
import gleam/io
import gleam/option.{None}
import gleam/result
import gleam/string
import keynub/licdongle.{type DongleError, CallError, LibraryError}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "init", "get_plain_arguments")
fn plain_arguments() -> List(Charlist)

type Charlist

@external(erlang, "unicode", "characters_to_binary")
fn to_string(text: Charlist) -> String

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, ReadError)

type ReadError

fn rotate(
  current: BitArray,
  replacement: BitArray,
) -> Result(Nil, DongleError) {
  use found <- result.try(licdongle.devices())
  case found {
    [] -> {
      io.println("Connect a KeyNub dongle and re-run.")
      Ok(Nil)
    }
    _ -> {
      use d <- licdongle.with_dongle(None)
      use serial <- result.try(licdongle.serial(d))
      io.println("Dongle " <> serial)
      use before <- result.try(licdongle.info(d))
      case before.write_auth_rotated {
        True ->
          io.println(
            "This dongle's write key has already been rotated away from the factory one.",
          )
        False -> Nil
      }
      use _ <- result.try({
        use <- licdongle.with_session(d)
        // the key the dongle accepts today
        use _ <- result.try(licdongle.authorize_write(d, current))
        // from the next session: only the new one
        licdongle.rotate_write_key(d, replacement)
      })
      use after <- result.try(licdongle.info(d))
      io.println(
        "Write key rotated: "
        <> case after.write_auth_rotated {
          True -> "yes"
          False -> "no"
        },
      )
      Ok(Nil)
    }
  }
}

pub fn main() -> Nil {
  case list_of_strings(plain_arguments()) {
    [current_path, replacement_path] ->
      case read_file(current_path), read_file(replacement_path) {
        Ok(current), Ok(replacement) ->
          case rotate(current, replacement) {
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
        _, _ -> {
          io.println("KeyNub error: cannot read the key files")
          halt(1)
        }
      }
    _ -> {
      io.println("usage: rotate_write_key <current-key.der> <new-key.der>")
      halt(2)
    }
  }
}

fn list_of_strings(arguments: List(Charlist)) -> List(String) {
  case arguments {
    [] -> []
    [first, ..rest] -> [to_string(first), ..list_of_strings(rest)]
  }
}
