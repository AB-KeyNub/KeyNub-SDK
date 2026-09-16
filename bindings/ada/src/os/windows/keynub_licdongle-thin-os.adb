--  The Windows loader: LoadLibraryA, GetProcAddress, GetLastError.

with Interfaces.C.Strings;

package body KeyNub_LicDongle.Thin.OS is

   use Interfaces.C.Strings;

   function LoadLibraryA (File : chars_ptr) return System.Address
     with Import, Convention => Stdcall, External_Name => "LoadLibraryA";
   function GetProcAddress (Module : System.Address; Name : chars_ptr) return System.Address
     with Import, Convention => Stdcall, External_Name => "GetProcAddress";
   function GetLastError return unsigned_long
     with Import, Convention => Stdcall, External_Name => "GetLastError";

   function Open (Path : String) return System.Address is
      C_Path : chars_ptr := New_String (Path);
      Handle : System.Address;
   begin
      Handle := LoadLibraryA (C_Path);
      Free (C_Path);
      return Handle;
   end Open;

   function Symbol (Handle : System.Address; Name : String) return System.Address is
      C_Name : chars_ptr := New_String (Name);
      Result : System.Address;
   begin
      Result := GetProcAddress (Handle, C_Name);
      Free (C_Name);
      return Result;
   end Symbol;

   function Last_Error return String is
   begin
      return "Windows error" & unsigned_long'Image (GetLastError);
   end Last_Error;

end KeyNub_LicDongle.Thin.OS;
