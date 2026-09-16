--  The POSIX loader: dlopen, dlsym, dlerror.

with Interfaces.C.Strings;

package body KeyNub_LicDongle.Thin.OS is

   use Interfaces.C.Strings;

   RTLD_NOW   : constant int := 2;
   RTLD_LOCAL : constant int := 0;

   function C_dlopen (File : chars_ptr; Mode : int) return System.Address
     with Import, Convention => C, External_Name => "dlopen";
   function C_dlsym (Handle : System.Address; Symbol : chars_ptr) return System.Address
     with Import, Convention => C, External_Name => "dlsym";
   function C_dlerror return chars_ptr
     with Import, Convention => C, External_Name => "dlerror";

   function Open (Path : String) return System.Address is
      C_Path : chars_ptr := New_String (Path);
      Handle : System.Address;
   begin
      Handle := C_dlopen (C_Path, RTLD_NOW + RTLD_LOCAL);
      Free (C_Path);
      return Handle;
   end Open;

   function Symbol (Handle : System.Address; Name : String) return System.Address is
      C_Name : chars_ptr := New_String (Name);
      Result : System.Address;
   begin
      Result := C_dlsym (Handle, C_Name);
      Free (C_Name);
      return Result;
   end Symbol;

   function Last_Error return String is
      Text : constant chars_ptr := C_dlerror;
   begin
      if Text = Null_Ptr then
         return "unknown error";
      end if;
      return Value (Text);
   end Last_Error;

end KeyNub_LicDongle.Thin.OS;
