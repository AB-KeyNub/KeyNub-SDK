with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Unchecked_Conversion;
with Interfaces.C.Strings;

with Keynub_Licdongle_Config;
with KeyNub_LicDongle.Thin.OS;

package body KeyNub_LicDongle.Thin is

   Table  : aliased API;
   Bound  : Boolean := False;
   Loaded : access String := null;

   ----------------------------------------------------------------------------
   --  Discovery
   ----------------------------------------------------------------------------

   --  The host, as Alire's configuration package recorded it at build time.
   Host_OS   : constant String := Keynub_Licdongle_Config.Alire_Host_OS;
   Host_Arch : constant String := Keynub_Licdongle_Config.Alire_Host_Arch;

   --  The comparisons below are decided at compile time on a given host, and
   --  GNAT says so; that is the point of them.
   pragma Warnings (Off, "condition is always*");

   function Platform return String is
      OS_Name : constant String :=
        (if Host_OS = "windows" then "win" elsif Host_OS = "macos" then "osx" else "linux");
      CPU : constant String :=
        (if Host_Arch = "x86_64" or else Host_Arch = "x86-64" or else Host_Arch = "amd64" then "x64"
         elsif Host_Arch = "aarch64" or else Host_Arch = "arm64" then "arm64"
         elsif Host_Arch = "i686" or else Host_Arch = "i386" or else Host_Arch = "x86" then "x86"
         else "unknown");
   begin
      return OS_Name & "-" & CPU;
   end Platform;

   function Default_Basename return String is
   begin
      if Host_OS = "windows" then
         return "keynub_licdongle.dll";
      elsif Host_OS = "macos" then
         return "libkeynub_licdongle.dylib";
      else
         return "libkeynub_licdongle.so";
      end if;
   end Default_Basename;

   pragma Warnings (On, "condition is always*");

   function Resolved_Path return String is
      use Ada.Directories;
      Env_Name : constant String := "KEYNUB_LICDONGLE_LIBRARY";
   begin
      if Ada.Environment_Variables.Exists (Env_Name)
        and then Ada.Environment_Variables.Value (Env_Name) /= ""
      then
         return Ada.Environment_Variables.Value (Env_Name);
      end if;
      --  A clone of the SDK repository keeps the library in natives/<platform>;
      --  the working directory or one of its parents is that clone when a
      --  sample runs.
      declare
         Dir : String := Current_Directory;
      begin
         for Level in 1 .. 8 loop
            declare
               Candidate : constant String :=
                 Compose (Compose (Compose (Dir, "natives"), Platform), Default_Basename);
            begin
               if Exists (Candidate) then
                  return Candidate;
               end if;
            end;
            declare
               Parent : constant String := Containing_Directory (Dir);
            begin
               exit when Parent = Dir;
               Dir := Parent;
            end;
         end loop;
      exception
         when others =>
            null;  --  an odd working directory: fall through to the bare name
      end;
      return Default_Basename;
   end Resolved_Path;

   function Loaded_Path return String is
   begin
      if Loaded = null then
         return "";
      end if;
      return Loaded.all;
   end Loaded_Path;

   ----------------------------------------------------------------------------
   --  Binding
   ----------------------------------------------------------------------------

   generic
      type Fn is private;
   function Bind (Handle : System.Address; Name : String; Path : String) return Fn;

   function Bind (Handle : System.Address; Name : String; Path : String) return Fn is
      function Convert is new Ada.Unchecked_Conversion (System.Address, Fn);
      Address : constant System.Address := OS.Symbol (Handle, Name);
      use type System.Address;
   begin
      if Address = System.Null_Address then
         raise Library_Error with
           "'" & Path & "' is not the KeyNub core library: " & Name & " is missing";
      end if;
      return Convert (Address);
   end Bind;

   function Get return access constant API is
   begin
      if Bound then
         return Table'Access;
      end if;
      declare
         Path   : constant String := (if Chosen_Path = null then Resolved_Path else Chosen_Path.all);
         Handle : constant System.Address := OS.Open (Path);
         use type System.Address;

         function B_Version is new Bind (Version_Fn);
         function B_Init is new Bind (Init_Fn);
         function B_Free is new Bind (Free_Fn);
         function B_Bytes is new Bind (Bytes_Fn);
         function B_Enumerate is new Bind (Enumerate_Fn);
         function B_Free_List is new Bind (Free_List_Fn);
         function B_Open is new Bind (Open_Fn);
         function B_Get_Info is new Bind (Get_Info_Fn);
         function B_Get_Serial is new Bind (Get_Serial_Fn);
         function B_Verify is new Bind (Verify_Fn);
         function B_Device is new Bind (Device_Fn);
         function B_Record_List is new Bind (Record_List_Fn);
         function B_Free_Record_List is new Bind (Free_Record_List_Fn);
         function B_Record_Read is new Bind (Record_Read_Fn);
         function B_Record_Write is new Bind (Record_Write_Fn);
         function B_Record_Erase is new Bind (Record_Erase_Fn);
         function B_Counter is new Bind (Counter_Fn);
         function B_App_Encrypt is new Bind (App_Encrypt_Fn);
         function B_App_Decrypt is new Bind (App_Decrypt_Fn);
         function B_Free_Buffer is new Bind (Free_Buffer_Fn);
         function B_Strerror is new Bind (Strerror_Fn);
         function B_Error_Detail is new Bind (Error_Detail_Fn);
      begin
         if Handle = System.Null_Address then
            raise Library_Error with
              "could not load the KeyNub library '" & Path & "': " & OS.Last_Error;
         end if;
         Table.Version           := B_Version (Handle, "licd_version", Path);
         Table.Init              := B_Init (Handle, "licd_init", Path);
         Table.Free              := B_Free (Handle, "licd_free", Path);
         Table.Set_Trust_Root    := B_Bytes (Handle, "licd_set_trust_root", Path);
         Table.Enumerate         := B_Enumerate (Handle, "licd_enumerate", Path);
         Table.Free_Device_List  := B_Free_List (Handle, "licd_free_device_list", Path);
         Table.Open              := B_Open (Handle, "licd_open", Path);
         Table.Open_Path         := B_Open (Handle, "licd_open_path", Path);
         Table.Close             := B_Free (Handle, "licd_close", Path);
         Table.Get_Info          := B_Get_Info (Handle, "licd_get_info", Path);
         Table.Get_Serial        := B_Get_Serial (Handle, "licd_get_serial", Path);
         Table.Verify_Genuine    := B_Verify (Handle, "licd_verify_genuine", Path);
         Table.Session_Open      := B_Device (Handle, "licd_session_open", Path);
         Table.Session_Close     := B_Device (Handle, "licd_session_close", Path);
         Table.Write_Auth        := B_Bytes (Handle, "licd_write_auth", Path);
         Table.Write_Auth_Rotate := B_Bytes (Handle, "licd_write_auth_rotate", Path);
         Table.Record_List       := B_Record_List (Handle, "licd_record_list", Path);
         Table.Free_Record_List  := B_Free_Record_List (Handle, "licd_free_record_list", Path);
         Table.Record_Read       := B_Record_Read (Handle, "licd_record_read", Path);
         Table.Record_Write      := B_Record_Write (Handle, "licd_record_write", Path);
         Table.Record_Erase      := B_Record_Erase (Handle, "licd_record_erase", Path);
         Table.Counter_Read      := B_Counter (Handle, "licd_counter_read", Path);
         Table.Counter_Increment := B_Counter (Handle, "licd_counter_increment", Path);
         Table.App_Encrypt       := B_App_Encrypt (Handle, "licd_app_encrypt", Path);
         Table.App_Decrypt       := B_App_Decrypt (Handle, "licd_app_decrypt", Path);
         Table.Free_Buffer       := B_Free_Buffer (Handle, "licd_free_buffer", Path);
         Table.Strerror          := B_Strerror (Handle, "licd_strerror", Path);
         Table.Error_Detail      := B_Error_Detail (Handle, "licd_error_detail", Path);
         Loaded := new String'(Path);
         Bound := True;
         return Table'Access;
      end;
   end Get;

   ----------------------------------------------------------------------------
   --  Strings
   ----------------------------------------------------------------------------

   function To_Ada (Chars : char_array) return String is
   begin
      for I in Chars'Range loop
         if Chars (I) = nul then
            return To_Ada (Chars (Chars'First .. I), Trim_Nul => True);
         end if;
      end loop;
      return To_Ada (Chars, Trim_Nul => False);
   end To_Ada;

   function String_At (Address : System.Address) return String is
      use type System.Address;
      function Convert is new Ada.Unchecked_Conversion
        (System.Address, Interfaces.C.Strings.chars_ptr);
   begin
      if Address = System.Null_Address then
         return "";
      end if;
      return Interfaces.C.Strings.Value (Convert (Address));
   end String_At;

end KeyNub_LicDongle.Thin;
