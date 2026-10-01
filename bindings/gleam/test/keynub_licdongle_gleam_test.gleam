//// Unit tests that need no native library: `gleam test`.

import gleeunit
import keynub/licdongle

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn status_from_code_test() {
  assert licdongle.status_from_code(-2) == licdongle.NoDevice
  assert licdongle.status_from_code(-7) == licdongle.NotGenuine
  assert licdongle.status_from_code(-17) == licdongle.SdkTooOld
  assert licdongle.status_from_code(-20) == licdongle.Internal
  assert licdongle.status_from_code(-99) == licdongle.Unknown(-99)
}

pub fn error_fields_test() {
  let e = licdongle.CallError(licdongle.NoDevice, -2, "licdf_open", "")
  assert e.status == licdongle.NoDevice
  assert e.code == -2
  assert e.operation == "licdf_open"
}
