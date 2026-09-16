--  KeyNub SDK - Ada sample: take ownership of a new dongle.
--
--  A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
--  so that from the next session onward only your key can write records, erase
--  them or increment counters. Run it once per dongle, when it arrives.
--
--  Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
--
--    openssl ecparam -name prime256v1 -genkey -noout |
--      openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
--
--    alr build && ./bin/rotate_write_key ../../keys/keynub-shipping-writeauth.key.der my-key.der
--
--  Targets real hardware: with no dongle attached it prints guidance and exits 0.
--
--  The replacement key is worth what your licence-signing key is worth. It
--  cannot be recovered from the dongle, and a unit rotated to a key you have
--  lost has to come back to be re-provisioned.

with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

with KeyNub_LicDongle;

procedure Rotate_Write_Key is

   use Ada.Text_IO;
   use KeyNub_LicDongle;

   function Read_Key (Path : String) return Bytes is
      package SIO renames Ada.Streams.Stream_IO;
      File : SIO.File_Type;
      Size : constant Ada.Streams.Stream_Element_Offset :=
        Ada.Streams.Stream_Element_Offset (Ada.Directories.Size (Path));
      Data : Bytes (1 .. Size);
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      SIO.Open (File, SIO.In_File, Path);
      SIO.Read (File, Data, Last);
      SIO.Close (File);
      return Data (1 .. Last);
   end Read_Key;

   Ctx : aliased Context;
   D : Dongle;
begin
   if Ada.Command_Line.Argument_Count /= 2 then
      Put_Line (Standard_Error, "usage: rotate_write_key <current-key.der> <new-key.der>");
      Ada.Command_Line.Set_Exit_Status (2);
      return;
   end if;
   declare
      Current : constant Bytes := Read_Key (Ada.Command_Line.Argument (1));
      Replacement : constant Bytes := Read_Key (Ada.Command_Line.Argument (2));
   begin
      Create (Ctx);
      if Enumerate (Ctx)'Length = 0 then
         Put_Line ("Connect a KeyNub dongle and re-run.");
         return;
      end if;
      Open (Ctx, D);
      Put_Line ("Dongle " & Serial (D));
      if Get_Info (D).Write_Auth_Rotated then
         Put_Line ("This dongle's write key has already been rotated away from the factory one.");
      end if;

      Session_Open (D);
      Authorize_Write (D, Current);          -- the key the dongle accepts today
      Rotate_Write_Key (D, Replacement);     -- from the next session: only the new one
      Session_Close (D);

      Put_Line ("Write key rotated: " & (if Get_Info (D).Write_Auth_Rotated then "yes" else "no"));
   end;
exception
   when E : others =>
      Put_Line (Standard_Error, "KeyNub error: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (1);
end Rotate_Write_Key;
