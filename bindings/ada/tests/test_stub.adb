--  Tests against a stand-in for the C ABI: one imaginary dongle held in
--  memory, compiled by tests/run.sh from the SDK's
--  bindings/julia/test/stub/licd_stub.c and named through
--  KEYNUB_LICDONGLE_LIBRARY. Every call of the crate runs end to end without
--  hardware. Exit code 0 when every check passed.

with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with KeyNub_LicDongle;

procedure Test_Stub is

   use Ada.Text_IO;
   use Ada.Strings.Unbounded;
   use KeyNub_LicDongle;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element_Array;

   Failures : Natural := 0;

   procedure Check (Condition : Boolean; What : String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Put_Line ("  FAIL  " & What);
      end if;
   end Check;

   Factory_Key : constant Bytes := (16#30#, 16#10#, 16#01#, 16#02#, 16#03#);
   Replacement_Key : constant Bytes := (16#30#, 16#11#, 16#09#, 16#08#, 16#07#, 16#06#);
   Serial_Text : constant String := "04A1B2C3D4E5F6";

   --  Runs Body and requires the named exception.
   generic
      with procedure Action;
   procedure Expect (Id : Ada.Exceptions.Exception_Id; What : String);

   procedure Expect (Id : Ada.Exceptions.Exception_Id; What : String) is
      use Ada.Exceptions;
   begin
      Action;
      Check (False, What & ": no exception was raised");
   exception
      when E : others =>
         Check (Exception_Identity (E) = Id,
                What & ": raised " & Exception_Name (E) & " (" & Exception_Message (E) & ")");
   end Expect;

   procedure Test_Status is
   begin
      Check (Library_Version = (9, 8, 7), "the stand-in reports 9.8.7");
      Check (Message (No_Device) = "no device", "strerror text");
      for S in Status loop
         Check (Message (S) /= "", "every status has a text: " & Status'Image (S));
      end loop;
      Check (To_Status (-2) = No_Device and Code (No_Device) = -2, "code mapping");
      Check (To_Status (-99) = Internal_Error, "unknown code");
   end Test_Status;

   procedure Test_Enumerate_And_Open is
      Ctx : aliased Context;
      D : Dongle;
   begin
      Create (Ctx);
      Check (Is_Open (Ctx), "a new context is open");
      declare
         Devices : constant Device_List := Enumerate (Ctx);
      begin
         Check (Devices'Length = 1, "one stand-in device");
         Check (To_String (Devices (1).Serial) = Serial_Text, "enumerated serial");
         Check (To_String (Devices (1).Path) = "stub:0", "enumerated path");
         Check (Devices (1).Vendor_Id = 16#1234# and Devices (1).Product_Id = 16#ABCD#, "usb ids");
      end;
      declare
         procedure Bad_Serial is
         begin
            Open (Ctx, D, "nope");
         end Bad_Serial;
         procedure Run is new Expect (Bad_Serial);
      begin
         Run (No_Device_Error'Identity, "open with a wrong serial");
         Check (Last_Status = No_Device, "Last_Status after the failure");
         Check (Last_Error_Detail (Ctx) = "no dongle with that serial", "error detail");
      end;
      declare
         procedure Bad_Path is
         begin
            Open_Path (Ctx, D, "stub:9");
         end Bad_Path;
         procedure Run is new Expect (Bad_Path);
      begin
         Run (No_Device_Error'Identity, "open at a wrong path");
      end;
      Open (Ctx, D);
      Check (Is_Open (D) and Serial (D) = Serial_Text, "open the first dongle");
      Close (D);
      Close (D);
      Check (not Is_Open (D), "a closed dongle is closed");
      declare
         procedure Use_Closed is
            S : constant String := Serial (D);
            pragma Unreferenced (S);
         begin
            null;
         end Use_Closed;
         procedure Run is new Expect (Use_Closed);
      begin
         Run (License_Dongle_Error'Identity, "a closed dongle refuses calls");
      end;
      Open (Ctx, D, Serial_Text);
      Check (Serial (D) = Serial_Text, "open by serial");
      Close (D);
      Open_Path (Ctx, D, "stub:0");
      Check (Serial (D) = Serial_Text, "open by path");
      Close (Ctx);
      Check (not Is_Open (Ctx), "a closed context is closed");
      Check (not Is_Open (D), "closing the context closes its dongles");
   end Test_Enumerate_And_Open;

   procedure Test_Info_And_Genuine is
      Ctx : aliased Context;
      D : Dongle;
   begin
      Create (Ctx);
      Open (Ctx, D);
      declare
         I : constant Info := Get_Info (D);
         G : constant Genuine_Result := Verify_Genuine (D);
      begin
         Check (I.Protocol_Major = 1 and I.Protocol_Minor = 0, "protocol version");
         Check (I.Firmware_Major = 2 and I.Firmware_Minor = 3 and I.Firmware_Patch = 4, "firmware");
         Check (I.Secure_Element_Ready and I.Provisioned and I.Isolated, "flags set");
         Check (I.Data_Capacity = 1024 * 1024 and I.Data_Free = 1_000_000, "storage");
         Check (not I.Watchdog_Reboot and not I.Write_Auth_Rotated, "flags clear");
         Check (G.Genuine and To_String (G.Serial) = Serial_Text, "genuine result");
         Check (To_String (G.Provisioned_Date) = "2026-08-15", "provisioned date");
         Check (Is_Genuine (D), "Is_Genuine");
      end;
      --  Trust root
      declare
         procedure Empty_Root is
         begin
            Set_Trust_Root (Ctx, (1 .. 0 => 0));
         end Empty_Root;
         procedure Run is new Expect (Empty_Root);
      begin
         Run (License_Dongle_Error'Identity, "an empty root is refused");
      end;
      declare
         procedure Bad_Root is
         begin
            Set_Trust_Root (Ctx, (16#02#, 16#01#, 16#00#));
         end Bad_Root;
         procedure Run is new Expect (Bad_Root);
      begin
         Run (Certificate_Invalid_Error'Identity, "a non-DER root is refused");
      end;
      declare
         Foreign : constant Bytes := (16#30#, 16#82#, 16#01#, 16#00#) & Bytes'(1 .. 128 => 16#AB#);
         Issuer : constant Bytes := (16#30#, 16#82#, 16#01#, 16#00#) & Bytes'(1 .. 128 => 16#01#);
         procedure Verify_Foreign is
            G : constant Genuine_Result := Verify_Genuine (D);
            pragma Unreferenced (G);
         begin
            null;
         end Verify_Foreign;
         procedure Run is new Expect (Verify_Foreign);
      begin
         Set_Trust_Root (Ctx, Foreign);
         Run (Certificate_Invalid_Error'Identity, "verification under a foreign root");
         Check (not Is_Genuine (D), "Is_Genuine fails closed");
         Set_Trust_Root (Ctx, Issuer);
         Check (Is_Genuine (D), "genuine again under the issuing root");
      end;
   end Test_Info_And_Genuine;

   procedure Test_Records is
      Ctx : aliased Context;
      D : Dongle;
      Payload : constant Bytes := To_Bytes ("license-blob-0123456789");
   begin
      Create (Ctx);
      Open (Ctx, D);
      declare
         procedure No_Session is
            R : constant Record_List := Records (D);
            pragma Unreferenced (R);
         begin
            null;
         end No_Session;
         procedure Run is new Expect (No_Session);
      begin
         Run (Session_Expired_Error'Identity, "records need a session");
      end;
      Session_Open (D);
      declare
         procedure Write_Unauthorised is
         begin
            Write_Record (D, "lic", Payload);
         end Write_Unauthorised;
         procedure Run is new Expect (Write_Unauthorised);
      begin
         Run (Auth_Required_Error'Identity, "writing needs the write role");
      end;
      declare
         procedure Wrong_Key is
         begin
            Authorize_Write (D, (16#30#, 16#00#));
         end Wrong_Key;
         procedure Run is new Expect (Wrong_Key);
      begin
         Run (Not_Genuine_Error'Identity, "a wrong key does not elevate");
      end;
      Authorize_Write (D, Factory_Key);
      Write_Record (D, "lic", Payload);
      Check (Read_Record (D, "lic") = Payload, "read back what was written");
      Write_Record (D, "cfg", "cfgdata");
      declare
         R : constant Record_List := Records (D);
      begin
         Check (R'Length = 2, "two records listed");
         for I in R'Range loop
            if To_String (R (I).Name) = "lic" then
               Check (R (I).Size = Payload'Length, "record size");
            end if;
         end loop;
      end;
      Check (To_String (Read_Record (D, "cfg")) = "cfgdata", "a string stored as its bytes");
      declare
         procedure Missing is
            B : constant Bytes := Read_Record (D, "nope");
            pragma Unreferenced (B);
         begin
            null;
         end Missing;
         procedure Run is new Expect (Missing);
      begin
         Run (Not_Found_Error'Identity, "reading a missing record");
      end;
      declare
         procedure Empty_Name is
         begin
            Erase_Record (D, "");
         end Empty_Name;
         procedure Run is new Expect (Empty_Name);
      begin
         Run (License_Dongle_Error'Identity, "an empty name never erases");
      end;
      Check (Records (D)'Length = 2, "nothing was erased by mistake");
      Erase_Record (D, "cfg");
      Check (Records (D)'Length = 1, "one record after the erase");
      Write_Record (D, "empty", Bytes'(1 .. 0 => 0));
      Check (Read_Record (D, "empty")'Length = 0, "an empty record reads back empty");

      declare
         Before : constant Counter_Value := Read_Counter (D, 0);
      begin
         Check (Increment_Counter (D, 0) = Before + 1, "increment returns the new value");
         Check (Read_Counter (D, 0) = Before + 1, "the counter went up by one");
         Check (Read_Counter (D, 1) = 0, "counter 1 untouched");
      end;
      declare
         procedure Counter_7 is
            V : constant Counter_Value := Read_Counter (D, 7);
            pragma Unreferenced (V);
         begin
            null;
         end Counter_7;
         procedure Run is new Expect (Counter_7);
      begin
         Run (License_Dongle_Error'Identity, "a counter the dongle lacks");
         Check (Last_Status = Range_Error, "range status for counter 7");
      end;

      declare
         Secret : Bytes (1 .. 100);
      begin
         for I in Secret'Range loop
            Secret (I) := Ada.Streams.Stream_Element ((Natural (I - 1) * 3 + 7) mod 256);
         end loop;
         for Which in Scope loop
            declare
               Blob : constant Bytes := App_Encrypt (D, Secret, Which);
               Tampered : Bytes := Blob;
               procedure Decrypt_Tampered is
                  B : constant Bytes := App_Decrypt (D, Tampered);
                  pragma Unreferenced (B);
               begin
                  null;
               end Decrypt_Tampered;
               procedure Run is new Expect (Decrypt_Tampered);
            begin
               Check (Blob'Length > Secret'Length, "sealed data is longer");
               Check (Natural (Blob (Blob'First)) = (if Which = Device then 0 else 1), "scope byte");
               Check (App_Decrypt (D, Blob) = Secret, "round trip " & Scope'Image (Which));
               Tampered (Tampered'Last) := Tampered (Tampered'Last) xor 1;
               Run (License_Dongle_Error'Identity, "tampered data");
               Check (Last_Status = Tag_Mismatch, "tag mismatch status");
            end;
         end loop;
         Check (To_String (App_Decrypt (D, App_Encrypt (D, To_Bytes ("text"), Device))) = "text",
                "a string round-trips");
      end;
      Erase_All_Records (D);
      Check (Records (D)'Length = 0, "erase all leaves nothing");
      Session_Close (D);
      Close (Ctx);
   end Test_Records;

   procedure Test_Rotation is
      Ctx : aliased Context;
      D : Dongle;
   begin
      Create (Ctx);
      Open (Ctx, D);
      Session_Open (D);
      declare
         procedure Rotate_Unauthorised is
         begin
            Rotate_Write_Key (D, Replacement_Key);
         end Rotate_Unauthorised;
         procedure Run is new Expect (Rotate_Unauthorised);
      begin
         Run (Auth_Required_Error'Identity, "rotation needs the write role");
      end;
      Authorize_Write (D, Factory_Key);
      Rotate_Write_Key (D, Replacement_Key);
      Write_Record (D, "lic", "still-writable");
      Session_Close (D);
      Check (Get_Info (D).Write_Auth_Rotated, "the rotation flag is set");
      Session_Open (D);
      declare
         procedure Old_Key is
         begin
            Authorize_Write (D, Factory_Key);
         end Old_Key;
         procedure Run is new Expect (Old_Key);
      begin
         Run (Not_Genuine_Error'Identity, "the factory key no longer elevates");
      end;
      Authorize_Write (D, Replacement_Key);
      Write_Record (D, "lic", "new-key-writes");
      Check (To_String (Read_Record (D, "lic")) = "new-key-writes", "the new key writes");
      Session_Close (D);
      Close (Ctx);
   end Test_Rotation;

   Ticks : Natural := 0;
   Last_Done, Last_Total : Natural := 0;

   function Count_Progress (Done, Total : Natural) return Boolean is
   begin
      Ticks := Ticks + 1;
      Last_Done := Done;
      Last_Total := Total;
      return True;
   end Count_Progress;

   function Cancel_Progress (Done, Total : Natural) return Boolean is
      pragma Unreferenced (Done, Total);
   begin
      return False;
   end Cancel_Progress;

   Boom : exception;

   function Raise_Progress (Done, Total : Natural) return Boolean is
      pragma Unreferenced (Done, Total);
   begin
      raise Boom;
      return True;
   end Raise_Progress;

   procedure Test_Progress is
      Ctx : aliased Context;
      D : Dongle;
      Blob : Bytes (1 .. 2000);
   begin
      for I in Blob'Range loop
         Blob (I) := Ada.Streams.Stream_Element ((Natural (I - 1) * 31 + 5) mod 256);
      end loop;
      Create (Ctx);
      Open (Ctx, D);
      Session_Open (D);
      Authorize_Write (D, Factory_Key);
      Ticks := 0;
      Write_Record (D, "big", Blob, Count_Progress'Unrestricted_Access);
      Check (Last_Done = 2000 and Last_Total = 2000, "write progress reaches the total");
      declare
         procedure Cancelled_Write is
         begin
            Write_Record (D, "big2", Blob, Cancel_Progress'Unrestricted_Access);
         end Cancelled_Write;
         procedure Run is new Expect (Cancelled_Write);
      begin
         Run (Cancelled_Error'Identity, "a False from progress cancels a write");
      end;
      Ticks := 0;
      Check (Read_Record (D, "big", Count_Progress'Unrestricted_Access) = Blob, "read with progress returns the data");
      Check (Ticks = 4 and Last_Done = 2000, "one tick per chunk");
      declare
         procedure Cancelled_Read is
            B : constant Bytes := Read_Record (D, "big", Cancel_Progress'Unrestricted_Access);
            pragma Unreferenced (B);
         begin
            null;
         end Cancelled_Read;
         procedure Run is new Expect (Cancelled_Read);
      begin
         Run (Cancelled_Error'Identity, "a False from progress cancels a read");
      end;
      declare
         procedure Raising_Read is
            B : constant Bytes := Read_Record (D, "big", Raise_Progress'Unrestricted_Access);
            pragma Unreferenced (B);
         begin
            null;
         end Raising_Read;
         procedure Run is new Expect (Raising_Read);
      begin
         Run (Boom'Identity, "an exception inside progress is re-raised after the transfer");
      end;
      Check (Read_Record (D, "big") = Blob, "the dongle is usable afterwards");
      Session_Close (D);
      Close (Ctx);
   end Test_Progress;

begin
   declare
      Lib : constant String := Ada.Environment_Variables.Value ("KEYNUB_LICDONGLE_LIBRARY", "");
   begin
      if Lib = "" then
         Put_Line ("KEYNUB_LICDONGLE_LIBRARY must name the compiled stand-in");
         Ada.Command_Line.Set_Exit_Status (2);
         return;
      end if;
      Set_Library_Path (Lib);
      Check (Library_Path = Lib, "Library_Path reports the chosen library");
   end;
   Test_Status;
   Test_Enumerate_And_Open;
   Test_Info_And_Genuine;
   Test_Records;
   Test_Rotation;
   Test_Progress;
   if Failures = 0 then
      Put_Line ("keynub_licdongle: every call passed against the ABI stand-in");
   else
      Put_Line (Natural'Image (Failures) & " check(s) failed");
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Test_Stub;
