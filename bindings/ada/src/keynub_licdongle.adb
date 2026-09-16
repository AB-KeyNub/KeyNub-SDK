with Ada.Exceptions;
with Ada.Unchecked_Conversion;
with Interfaces.C.Strings;

with KeyNub_LicDongle.Thin;

package body KeyNub_LicDongle is

   use Interfaces.C;
   use type System.Address;
   use type Ada.Streams.Stream_Element_Offset;
   use Ada.Strings.Unbounded;

   -----------------------------------------------------------------------------
   --  Status
   -----------------------------------------------------------------------------

   Codes : constant array (Status) of Integer :=
     (Internal_Error => -20, Not_Implemented => -19, Cancelled => -18, SDK_Too_Old => -17,
      Firmware_Incompatible => -16, Auth_Required => -15, Not_Found => -14, Busy => -13,
      Storage_Full => -12, Range_Error => -11, Tag_Mismatch => -10, Session_Expired => -9,
      Certificate_Invalid => -8, Not_Genuine => -7, Protocol_Error => -6, Timeout => -5,
      IO_Error => -4, Access_Denied => -3, No_Device => -2, Invalid_Argument => -1, OK => 0);

   function Code (S : Status) return Integer is (Codes (S));

   function To_Status (C : Integer) return Status is
   begin
      for S in Status loop
         if Codes (S) = C then
            return S;
         end if;
      end loop;
      return Internal_Error;
   end To_Status;

   function Message (S : Status) return String is
      API : constant access constant Thin.API := Thin.Get;
   begin
      return Thin.String_At (API.Strerror (int (Codes (S))));
   end Message;

   function Last_Status return Status is (Current_Status);

   --  Raises the exception for a status, with "operation: text (detail)".
   procedure Fail (Code : int; Operation : String; Detail : String) is
      S : constant Status := To_Status (Integer (Code));
      Full : constant String :=
        Operation & ": " & Message (S) & (if Detail = "" then "" else " (" & Detail & ")");
   begin
      Current_Status := S;
      case S is
         when No_Device           => raise No_Device_Error with Full;
         when Not_Genuine         => raise Not_Genuine_Error with Full;
         when Certificate_Invalid => raise Certificate_Invalid_Error with Full;
         when Session_Expired     => raise Session_Expired_Error with Full;
         when Not_Found           => raise Not_Found_Error with Full;
         when Auth_Required       => raise Auth_Required_Error with Full;
         when Cancelled           => raise Cancelled_Error with Full;
         when others              => raise License_Dongle_Error with Full;
      end case;
   end Fail;

   procedure Check (Code : int; Operation : String; Ctx : System.Address) is
      API : constant access constant Thin.API := Thin.Get;
   begin
      if Code /= 0 then
         Fail (Code, Operation,
               (if Ctx = System.Null_Address then "" else Thin.String_At (API.Error_Detail (Ctx))));
      end if;
   end Check;

   -----------------------------------------------------------------------------
   --  Library
   -----------------------------------------------------------------------------

   procedure Set_Library_Path (Path : String) is
   begin
      if Thin.Loaded_Path /= "" and then Thin.Loaded_Path /= Path then
         raise Library_Error with
           "the KeyNub library is already loaded from '" & Thin.Loaded_Path
           & "'; a process loads it once";
      end if;
      Chosen_Path := new String'(Path);
   end Set_Library_Path;

   function Library_Path return String is
   begin
      if Thin.Loaded_Path /= "" then
         return Thin.Loaded_Path;
      elsif Chosen_Path /= null then
         return Chosen_Path.all;
      else
         return Thin.Resolved_Path;
      end if;
   end Library_Path;

   function Library_Version return Version is
      API : constant access constant Thin.API := Thin.Get;
      Major, Minor, Patch : aliased int := 0;
   begin
      API.Version (Major'Access, Minor'Access, Patch'Access);
      return (Natural (Major), Natural (Minor), Natural (Patch));
   end Library_Version;

   function To_Bytes (S : String) return Bytes is
      Result : Bytes (1 .. S'Length);
   begin
      for I in S'Range loop
         Result (Ada.Streams.Stream_Element_Offset (I - S'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (S (I)));
      end loop;
      return Result;
   end To_Bytes;

   function To_String (B : Bytes) return String is
      Result : String (1 .. B'Length);
   begin
      for I in B'Range loop
         Result (Integer (I - B'First) + 1) := Character'Val (B (I));
      end loop;
      return Result;
   end To_String;

   --  The address of a byte array's first element, or null when empty.
   function Address_Of (B : Bytes) return System.Address is
   begin
      if B'Length = 0 then
         return System.Null_Address;
      end if;
      return B (B'First)'Address;
   end Address_Of;

   --  Copies Count bytes at Address into a fresh array.
   function Copy_Bytes (Address : System.Address; Count : Natural) return Bytes is
      subtype Source is Bytes (1 .. Ada.Streams.Stream_Element_Offset (Count));
      Src : Source with Import, Address => Address;
   begin
      if Count = 0 or else Address = System.Null_Address then
         return Bytes'(1 .. 0 => 0);
      end if;
      return Src;
   end Copy_Bytes;

   -----------------------------------------------------------------------------
   --  Context
   -----------------------------------------------------------------------------

   procedure Create (Ctx : in out Context) is
      API : constant access constant Thin.API := Thin.Get;
      Out_Ctx : aliased System.Address := System.Null_Address;
      Code : int;
   begin
      Close (Ctx);
      Code := API.Init (Out_Ctx'Access);
      if Code /= 0 then
         Fail (Code, "licd_init", "");
      end if;
      Ctx.Handle := Out_Ctx;
   end Create;

   procedure Close (Ctx : in out Context) is
   begin
      for I in Ctx.Dongles'Range loop
         if Ctx.Dongles (I) /= null then
            Close (Ctx.Dongles (I).all);
            Ctx.Dongles (I) := null;
         end if;
      end loop;
      if Ctx.Handle /= System.Null_Address then
         Thin.Get.Free (Ctx.Handle);
         Ctx.Handle := System.Null_Address;
      end if;
   end Close;

   overriding procedure Finalize (Ctx : in out Context) is
   begin
      Close (Ctx);
   exception
      when others => null;   --  a finaliser must not propagate
   end Finalize;

   function Is_Open (Ctx : Context) return Boolean is (Ctx.Handle /= System.Null_Address);

   function Require (Ctx : Context) return System.Address is
   begin
      if Ctx.Handle = System.Null_Address then
         Fail (int (Codes (Invalid_Argument)), "licd_ctx", "the context has been closed");
      end if;
      return Ctx.Handle;
   end Require;

   function Last_Error_Detail (Ctx : Context) return String is
   begin
      if Ctx.Handle = System.Null_Address then
         return "";
      end if;
      return Thin.String_At (Thin.Get.Error_Detail (Ctx.Handle));
   end Last_Error_Detail;

   procedure Set_Trust_Root (Ctx : in out Context; DER : Bytes) is
      H : constant System.Address := Require (Ctx);
   begin
      Check (Thin.Get.Set_Trust_Root (H, Address_Of (DER), size_t (DER'Length)),
             "licd_set_trust_root", H);
   end Set_Trust_Root;

   function Enumerate (Ctx : in out Context) return Device_List is
      API : constant access constant Thin.API := Thin.Get;
      H : constant System.Address := Require (Ctx);
      List : aliased System.Address := System.Null_Address;
      Count : aliased size_t := 0;
   begin
      Check (API.Enumerate (H, List'Access, Count'Access), "licd_enumerate", H);
      declare
         N : constant Natural := Natural (Count);
         type Raw_List is array (1 .. N) of Thin.Device_Info_C;
         Raw : Raw_List with Import, Address => List;
         Result : Device_List (1 .. N);
      begin
         for I in 1 .. N loop
            Result (I) :=
              (Serial     => To_Unbounded_String (Thin.To_Ada (Raw (I).Serial)),
               Path       => To_Unbounded_String (Thin.To_Ada (Raw (I).Path)),
               Vendor_Id  => Natural (Raw (I).Vendor_Id),
               Product_Id => Natural (Raw (I).Product_Id));
         end loop;
         API.Free_Device_List (List, Count);
         return Result;
      end;
   end Enumerate;

   -----------------------------------------------------------------------------
   --  Dongle
   -----------------------------------------------------------------------------

   procedure Register (Ctx : aliased in out Context; D : in out Dongle; Dev : System.Address) is
   begin
      Close (D);
      D.Handle := Dev;
      D.Owner := Ctx'Unchecked_Access;
      for I in Ctx.Dongles'Range loop
         if Ctx.Dongles (I) = null then
            Ctx.Dongles (I) := D'Unchecked_Access;
            return;
         end if;
      end loop;
      --  More than the table holds are open: this one is not tracked and must
      --  be closed by its owner before the context goes.
   end Register;

   procedure Open (Ctx : aliased in out Context'Class; D : in out Dongle; Serial : String := "") is
      API : constant access constant Thin.API := Thin.Get;
      H : constant System.Address := Require (Context (Ctx));
      Dev : aliased System.Address := System.Null_Address;
      C_Serial : Strings.chars_ptr :=
        (if Serial = "" then Strings.Null_Ptr else Strings.New_String (Serial));
      function To_Address is new Ada.Unchecked_Conversion (Strings.chars_ptr, System.Address);
      Code : int;
   begin
      Code := API.Open (H, To_Address (C_Serial), Dev'Access);
      Strings.Free (C_Serial);
      Check (Code, "licd_open", H);
      Register (Context (Ctx), D, Dev);
   end Open;

   procedure Open_Path (Ctx : aliased in out Context'Class; D : in out Dongle; Path : String) is
      API : constant access constant Thin.API := Thin.Get;
      H : constant System.Address := Require (Context (Ctx));
      Dev : aliased System.Address := System.Null_Address;
      C_Path : Strings.chars_ptr := Strings.New_String (Path);
      function To_Address is new Ada.Unchecked_Conversion (Strings.chars_ptr, System.Address);
      Code : int;
   begin
      Code := API.Open_Path (H, To_Address (C_Path), Dev'Access);
      Strings.Free (C_Path);
      Check (Code, "licd_open_path", H);
      Register (Context (Ctx), D, Dev);
   end Open_Path;

   procedure Close (D : in out Dongle) is
   begin
      if D.Handle /= System.Null_Address then
         Thin.Get.Close (D.Handle);
         D.Handle := System.Null_Address;
      end if;
      if D.Owner /= null then
         for I in D.Owner.Dongles'Range loop
            if D.Owner.Dongles (I) = D'Unchecked_Access then
               D.Owner.Dongles (I) := null;
            end if;
         end loop;
         D.Owner := null;
      end if;
   end Close;

   overriding procedure Finalize (D : in out Dongle) is
   begin
      Close (D);
   exception
      when others => null;
   end Finalize;

   function Is_Open (D : Dongle) return Boolean is (D.Handle /= System.Null_Address);

   function Require (D : Dongle) return System.Address is
   begin
      if D.Handle = System.Null_Address or else D.Owner = null then
         Fail (int (Codes (Invalid_Argument)), "licd_device", "the dongle has been closed");
      end if;
      return D.Handle;
   end Require;

   function Ctx_Of (D : Dongle) return System.Address is
     (if D.Owner = null then System.Null_Address else D.Owner.Handle);

   function Get_Info (D : Dongle) return Info is
      Dev : constant System.Address := Require (D);
      Raw : aliased Thin.Info_C;
   begin
      Check (Thin.Get.Get_Info (Dev, Raw'Access), "licd_get_info", Ctx_Of (D));
      return
        (Protocol_Major       => Natural (Raw.Proto_Version_Major),
         Protocol_Minor       => Natural (Raw.Proto_Version_Minor),
         Firmware_Major       => Natural (Raw.Fw_Version_Major),
         Firmware_Minor       => Natural (Raw.Fw_Version_Minor),
         Firmware_Patch       => Natural (Raw.Fw_Version_Patch),
         Secure_Element_Ready => Raw.Se_Ready /= 0,
         Provisioned          => Raw.Provisioned /= 0,
         Data_Capacity        => Natural (Raw.Data_Capacity),
         Data_Free            => Natural (Raw.Data_Free),
         Watchdog_Reboot      => Raw.Watchdog_Reboot /= 0,
         Isolated             => Raw.Isolated /= 0,
         Write_Auth_Rotated   => Raw.Writeauth_Rotated /= 0);
   end Get_Info;

   function Serial (D : Dongle) return String is
      Dev : constant System.Address := Require (D);
      Buffer : aliased char_array (0 .. Thin.Serial_Hex_Len) := (others => nul);
   begin
      Check (Thin.Get.Get_Serial (Dev, Buffer'Address, Buffer'Length), "licd_get_serial", Ctx_Of (D));
      return Thin.To_Ada (Buffer);
   end Serial;

   function Verify_Genuine (D : Dongle) return Genuine_Result is
      Dev : constant System.Address := Require (D);
      Raw : aliased Thin.Genuine_Result_C;
   begin
      Check (Thin.Get.Verify_Genuine (Dev, Raw'Access), "licd_verify_genuine", Ctx_Of (D));
      if Raw.Genuine = 0 then
         Fail (int (Codes (Not_Genuine)), "licd_verify_genuine", "");
      end if;
      return
        (Genuine          => True,
         Serial           => To_Unbounded_String (Thin.To_Ada (Raw.Serial)),
         Provisioned_Date => To_Unbounded_String (Thin.To_Ada (Raw.Provisioned_Date)));
   end Verify_Genuine;

   function Is_Genuine (D : Dongle) return Boolean is
      Result : Genuine_Result;
      pragma Unreferenced (Result);
   begin
      Result := Verify_Genuine (D);
      return True;
   exception
      when others => return False;
   end Is_Genuine;

   -----------------------------------------------------------------------------
   --  Session
   -----------------------------------------------------------------------------

   procedure Session_Open (D : in out Dongle) is
      Dev : constant System.Address := Require (D);
   begin
      Check (Thin.Get.Session_Open (Dev), "licd_session_open", Ctx_Of (D));
   end Session_Open;

   procedure Session_Close (D : in out Dongle) is
      Dev : constant System.Address := Require (D);
   begin
      Check (Thin.Get.Session_Close (Dev), "licd_session_close", Ctx_Of (D));
   end Session_Close;

   procedure Authorize_Write (D : in out Dongle; Key : Bytes) is
      Dev : constant System.Address := Require (D);
   begin
      Check (Thin.Get.Write_Auth (Dev, Address_Of (Key), size_t (Key'Length)),
             "licd_write_auth", Ctx_Of (D));
   end Authorize_Write;

   procedure Rotate_Write_Key (D : in out Dongle; Key : Bytes) is
      Dev : constant System.Address := Require (D);
   begin
      Check (Thin.Get.Write_Auth_Rotate (Dev, Address_Of (Key), size_t (Key'Length)),
             "licd_write_auth_rotate", Ctx_Of (D));
   end Rotate_Write_Key;

   function Records (D : Dongle) return Record_List is
      API : constant access constant Thin.API := Thin.Get;
      Dev : constant System.Address := Require (D);
      Names : aliased System.Address := System.Null_Address;
      Sizes : aliased System.Address := System.Null_Address;
      Count : aliased size_t := 0;
   begin
      Check (API.Record_List (Dev, Names'Access, Sizes'Access, Count'Access),
             "licd_record_list", Ctx_Of (D));
      declare
         N : constant Natural := Natural (Count);
         type Name_Array is array (1 .. N) of System.Address;
         type Size_Array is array (1 .. N) of unsigned;
         Raw_Names : Name_Array with Import, Address => Names;
         Raw_Sizes : Size_Array with Import, Address => Sizes;
         Result : Record_List (1 .. N);
      begin
         for I in 1 .. N loop
            Result (I) := (Name => To_Unbounded_String (Thin.String_At (Raw_Names (I))),
                           Size => Natural (Raw_Sizes (I)));
         end loop;
         API.Free_Record_List (Names, Sizes, Count);
         return Result;
      end;
   end Records;

   --  Progress callbacks. The Ada callback travels through the C `user`
   --  pointer as the address of this record; the one C-convention shim finds
   --  it again. An exception raised by the callback is saved and the transfer
   --  cancelled; it is re-raised once the C call has returned.
   type Progress_State is record
      Callback : Progress_Callback;
      Failed   : Boolean := False;
      Error    : Ada.Exceptions.Exception_Occurrence_Access := null;
   end record;
   type Progress_State_Access is access all Progress_State;

   function Progress_Shim (Done, Total : unsigned; User : System.Address) return int
     with Convention => C;

   function Progress_Shim (Done, Total : unsigned; User : System.Address) return int is
      function To_State is new Ada.Unchecked_Conversion (System.Address, Progress_State_Access);
      State : constant Progress_State_Access := To_State (User);
   begin
      if State = null or else State.Callback = null then
         return 1;
      end if;
      begin
         return (if State.Callback (Natural (Done), Natural (Total)) then 1 else 0);
      exception
         when E : others =>
            State.Failed := True;
            State.Error := Ada.Exceptions.Save_Occurrence (E);
            return 0;
      end;
   end Progress_Shim;

   procedure Rethrow (State : in out Progress_State) is
      use Ada.Exceptions;
   begin
      if State.Error /= null then
         declare
            Occurrence : constant Exception_Occurrence_Access := State.Error;
         begin
            State.Error := null;
            Reraise_Occurrence (Occurrence.all);
         end;
      end if;
   end Rethrow;

   procedure Require_Name (Name : String) is
   begin
      if Name = "" then
         Fail (int (Codes (Invalid_Argument)), "licd_record", "the record name must not be empty");
      end if;
   end Require_Name;

   function Read_Record
     (D : Dongle; Name : String; Progress : Progress_Callback := null) return Bytes
   is
      API : constant access constant Thin.API := Thin.Get;
      Dev : constant System.Address := Require (D);
      C_Name : Strings.chars_ptr;
      function To_Address is new Ada.Unchecked_Conversion (Strings.chars_ptr, System.Address);
      Probe : aliased unsigned_char := 0;
      Got, Total : aliased unsigned := 0;
      Code : int;
   begin
      Require_Name (Name);
      C_Name := Strings.New_String (Name);
      --  Probe for the size first, so progress runs from 0 to the total once.
      Code := API.Record_Read (Dev, To_Address (C_Name), 0, Probe'Address, 1,
                               Got'Access, Total'Access, null, System.Null_Address);
      if Code /= 0 then
         Strings.Free (C_Name);
         Check (Code, "licd_record_read", Ctx_Of (D));
      end if;
      if Total = 0 then
         Strings.Free (C_Name);
         return Bytes'(1 .. 0 => 0);
      end if;
      declare
         Buffer : aliased Bytes (1 .. Ada.Streams.Stream_Element_Offset (Total));
         State  : aliased Progress_State := (Callback => Progress, others => <>);
      begin
         Code := API.Record_Read
           (Dev, To_Address (C_Name), 0, Buffer'Address, Total, Got'Access, Total'Access,
            (if Progress = null then null else Progress_Shim'Access),
            (if Progress = null then System.Null_Address else State'Address));
         Strings.Free (C_Name);
         Rethrow (State);
         Check (Code, "licd_record_read", Ctx_Of (D));
         return Buffer (1 .. Ada.Streams.Stream_Element_Offset (Got));
      end;
   end Read_Record;

   procedure Write_Record
     (D : in out Dongle; Name : String; Data : Bytes; Progress : Progress_Callback := null)
   is
      API : constant access constant Thin.API := Thin.Get;
      Dev : constant System.Address := Require (D);
      C_Name : Strings.chars_ptr;
      function To_Address is new Ada.Unchecked_Conversion (Strings.chars_ptr, System.Address);
      State : aliased Progress_State := (Callback => Progress, others => <>);
      Code : int;
   begin
      Require_Name (Name);
      C_Name := Strings.New_String (Name);
      Code := API.Record_Write
        (Dev, To_Address (C_Name), Address_Of (Data), unsigned (Data'Length),
         (if Progress = null then null else Progress_Shim'Access),
         (if Progress = null then System.Null_Address else State'Address));
      Strings.Free (C_Name);
      Rethrow (State);
      Check (Code, "licd_record_write", Ctx_Of (D));
   end Write_Record;

   procedure Write_Record
     (D : in out Dongle; Name : String; Data : String; Progress : Progress_Callback := null) is
   begin
      Write_Record (D, Name, To_Bytes (Data), Progress);
   end Write_Record;

   procedure Erase_Record (D : in out Dongle; Name : String) is
      Dev : constant System.Address := Require (D);
      C_Name : Strings.chars_ptr;
      function To_Address is new Ada.Unchecked_Conversion (Strings.chars_ptr, System.Address);
      Code : int;
   begin
      Require_Name (Name);
      C_Name := Strings.New_String (Name);
      Code := Thin.Get.Record_Erase (Dev, To_Address (C_Name));
      Strings.Free (C_Name);
      Check (Code, "licd_record_erase", Ctx_Of (D));
   end Erase_Record;

   procedure Erase_All_Records (D : in out Dongle) is
      Dev : constant System.Address := Require (D);
   begin
      Check (Thin.Get.Record_Erase (Dev, System.Null_Address), "licd_record_erase", Ctx_Of (D));
   end Erase_All_Records;

   function Read_Counter (D : Dongle; Id : Counter_Id) return Counter_Value is
      Dev : constant System.Address := Require (D);
      Value : aliased unsigned := 0;
   begin
      Check (Thin.Get.Counter_Read (Dev, unsigned_char (Id), Value'Access),
             "licd_counter_read", Ctx_Of (D));
      return Counter_Value (Value);
   end Read_Counter;

   function Increment_Counter (D : in out Dongle; Id : Counter_Id) return Counter_Value is
      Dev : constant System.Address := Require (D);
      Value : aliased unsigned := 0;
   begin
      Check (Thin.Get.Counter_Increment (Dev, unsigned_char (Id), Value'Access),
             "licd_counter_increment", Ctx_Of (D));
      return Counter_Value (Value);
   end Increment_Counter;

   function App_Encrypt (D : Dongle; Plaintext : Bytes; Which : Scope) return Bytes is
      API : constant access constant Thin.API := Thin.Get;
      Dev : constant System.Address := Require (D);
      Out_Buf : aliased System.Address := System.Null_Address;
      Out_Len : aliased unsigned := 0;
   begin
      Check (API.App_Encrypt (Dev, (if Which = Device then 0 else 1), Address_Of (Plaintext),
                              unsigned (Plaintext'Length), Out_Buf'Access, Out_Len'Access),
             "licd_app_encrypt", Ctx_Of (D));
      return Result : constant Bytes := Copy_Bytes (Out_Buf, Natural (Out_Len)) do
         API.Free_Buffer (Out_Buf);
      end return;
   end App_Encrypt;

   function App_Decrypt (D : Dongle; Packed : Bytes) return Bytes is
      API : constant access constant Thin.API := Thin.Get;
      Dev : constant System.Address := Require (D);
      Out_Buf : aliased System.Address := System.Null_Address;
      Out_Len : aliased unsigned := 0;
   begin
      Check (API.App_Decrypt (Dev, Address_Of (Packed), unsigned (Packed'Length),
                              Out_Buf'Access, Out_Len'Access),
             "licd_app_decrypt", Ctx_Of (D));
      return Result : constant Bytes := Copy_Bytes (Out_Buf, Natural (Out_Len)) do
         API.Free_Buffer (Out_Buf);
      end return;
   end App_Decrypt;

end KeyNub_LicDongle;
