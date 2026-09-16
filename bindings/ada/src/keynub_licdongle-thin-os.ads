--  The operating system's dynamic loader, one body per OS (src/os/<os>/).

with System;

private package KeyNub_LicDongle.Thin.OS is

   --  Loads a shared library; Null_Address when it could not be loaded.
   function Open (Path : String) return System.Address;

   --  A function's address in a loaded library; Null_Address when absent.
   function Symbol (Handle : System.Address; Name : String) return System.Address;

   --  The loader's text for the last failure.
   function Last_Error return String;

end KeyNub_LicDongle.Thin.OS;
