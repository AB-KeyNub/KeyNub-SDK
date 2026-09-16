--  KeyNub dongle check from Ada: enumerate -> open -> verify -> session ->
--  read a record -> app-crypto round trip.
--
--    alr build && ./bin/verify_and_read       (from samples/ada)
--
--  Run from this checkout the crate finds the native library in
--  natives/<platform> on its own; elsewhere set KEYNUB_LICDONGLE_LIBRARY or
--  call Set_Library_Path first.
--
--  Targets real hardware: with no dongle attached it prints guidance and exits 0.
--
--  READ FIRST: docs/integration-security.md. This sample prints whether the
--  dongle is genuine, which is the one thing a real licence check must not do:
--  a printed boolean is a deleted line away from nothing. Protect_Something
--  shows the shape that actually protects something.

with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with KeyNub_LicDongle;

procedure Verify_And_Read is

   use Ada.Text_IO;
   use Ada.Strings.Unbounded;
   use KeyNub_LicDongle;

   function Img (N : Natural) return String is
      S : constant String := Natural'Image (N);
   begin
      return S (S'First + 1 .. S'Last);
   end Img;

   procedure Report (D : Dongle) is
      I : constant Info := Get_Info (D);
   begin
      Put_Line ("Protocol v" & Img (I.Protocol_Major) & "." & Img (I.Protocol_Minor)
                & ", firmware v" & Img (I.Firmware_Major) & "." & Img (I.Firmware_Minor)
                & "." & Img (I.Firmware_Patch) & ", " & Img (I.Data_Free) & " of "
                & Img (I.Data_Capacity) & " bytes free.");
      if I.Watchdog_Reboot then
         --  The only trace a firmware hang leaves behind. Worth reporting to support.
         Put_Line ("WARNING: this dongle's previous boot ended in a watchdog reset.");
      end if;
      declare
         G : constant Genuine_Result := Verify_Genuine (D);
      begin
         Put_Line ("Genuine: " & Boolean'Image (G.Genuine) & " (serial " & To_String (G.Serial)
                   & ", provisioned " & To_String (G.Provisioned_Date) & ")");
      end;
   end Report;

   procedure Read_Records (D : Dongle) is
      List : constant Record_List := Records (D);
   begin
      Put_Line (Img (List'Length) & " record(s) on the dongle:");
      for R of List loop
         Put_Line ("  " & To_String (R.Name) & " " & Img (R.Size) & " bytes");
      end loop;
      --  A missing record is a normal state, not an error.
      for R of List loop
         if To_String (R.Name) = "license" then
            declare
               Data : constant Bytes := Read_Record (D, "license");
            begin
               Put_Line ("Read " & Img (Data'Length) & " bytes from the license record.");
            end;
         end if;
      end loop;
   end Read_Records;

   --  The part that actually protects something. At licence-issue time you
   --  would call App_Encrypt once, with a developer dongle, and ship only the
   --  sealed data; the program then cannot proceed without a dongle, because
   --  it holds no other copy. Developer lets any dongle you have issued decrypt
   --  it, so one file serves every customer; Device locks it to one dongle.
   procedure Protect_Something (D : Dongle) is
      Needed : constant String := "the data this program cannot run without";
      Sealed : constant Bytes := App_Encrypt (D, To_Bytes (Needed), Developer);
      Recovered : constant String := To_String (App_Decrypt (D, Sealed));
   begin
      Put_Line ("App-crypto round trip: " & Img (Needed'Length) & " bytes -> "
                & Img (Sealed'Length) & " sealed -> "
                & (if Recovered = Needed then "recovered intact" else "MISMATCH"));
   end Protect_Something;

   Ctx : aliased Context;
   D : Dongle;
begin
   declare
      V : constant Version := Library_Version;
   begin
      Put_Line ("KeyNub SDK " & Img (V.Major) & "." & Img (V.Minor) & "." & Img (V.Patch)
                & " (" & Library_Path & ")");
   end;
   Create (Ctx);
   declare
      Devices : constant Device_List := Enumerate (Ctx);
   begin
      Put_Line ("Found " & Img (Devices'Length) & " KeyNub dongle(s).");
      for I in Devices'Range loop
         Put_Line ("  [" & Img (I - 1) & "] serial " & To_String (Devices (I).Serial));
      end loop;
      if Devices'Length = 0 then
         Put_Line ("No dongle attached; nothing to do.");
         return;
      end if;
   end;

   Open (Ctx, D);                    -- first dongle, or Open (Ctx, D, Serial)
   Report (D);
   Session_Open (D);
   Read_Records (D);
   Protect_Something (D);
   Session_Close (D);
exception
   when E : others =>
      --  Every failure carries the SDK's detail, which is what tells "no
      --  dongle" from "certificate rejected".
      Put_Line (Standard_Error, "KeyNub error: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (1);
end Verify_And_Read;
