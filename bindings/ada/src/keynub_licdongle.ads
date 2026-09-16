--  KeyNub License Dongle: verify a genuine KeyNub USB dongle, read and write
--  its license records, use its counters and encrypt data so that only a
--  dongle can decrypt it.
--
--  The crate is Ada over the SDK's C ABI. The native library is loaded at run
--  time: Set_Library_Path names it, or KEYNUB_LICDONGLE_LIBRARY in the
--  environment, or natives/<platform>/ of a clone of the SDK repository found
--  from the working directory upwards, or the bare file name along the
--  operating system's search path.
--
--  Every failure the library reports raises an exception below, with a message
--  of the form "licd_open: no device (detail)". The ones a program branches on
--  have an exception of their own; everything else is License_Dongle_Error.

with Ada.Finalization;
with Ada.Streams;
with Ada.Strings.Unbounded;
with System;

package KeyNub_LicDongle is

   --  The native library could not be loaded, or is not the KeyNub library.
   Library_Error : exception;

   --  Any failure the library reports, when no exception below is closer.
   License_Dongle_Error : exception;
   No_Device_Error : exception;
   Not_Genuine_Error : exception;
   Certificate_Invalid_Error : exception;
   Session_Expired_Error : exception;
   Not_Found_Error : exception;
   Auth_Required_Error : exception;
   Cancelled_Error : exception;

   --  The status codes the library reports (OK is zero; failures negative).
   type Status is
     (Internal_Error, Not_Implemented, Cancelled, SDK_Too_Old, Firmware_Incompatible,
      Auth_Required, Not_Found, Busy, Storage_Full, Range_Error, Tag_Mismatch,
      Session_Expired, Certificate_Invalid, Not_Genuine, Protocol_Error, Timeout, IO_Error,
      Access_Denied, No_Device, Invalid_Argument, OK);

   --  The numeric code of a status, and the status of a code (unknown codes
   --  map to Internal_Error).
   function Code (S : Status) return Integer;
   function To_Status (C : Integer) return Status;

   --  The library's short text for a status.
   function Message (S : Status) return String;

   --  The status behind the most recent exception raised by this package on
   --  the current task, for code that wants the code rather than the class.
   function Last_Status return Status;

   -----------------------------------------------------------------------------
   --  The native library
   -----------------------------------------------------------------------------

   --  Names the library file to load; must come before the first call that
   --  needs it. Raises Library_Error once a different library is loaded.
   procedure Set_Library_Path (Path : String);

   --  The library in use: the loaded one, otherwise the one the next call
   --  would load.
   function Library_Path return String;

   type Version is record
      Major, Minor, Patch : Natural;
   end record;

   --  The version of the loaded native library.
   function Library_Version return Version;

   subtype Bytes is Ada.Streams.Stream_Element_Array;
   subtype Text is Ada.Strings.Unbounded.Unbounded_String;

   function To_Bytes (S : String) return Bytes;
   function To_String (B : Bytes) return String;

   -----------------------------------------------------------------------------
   --  Context
   -----------------------------------------------------------------------------

   --  A library context: the connection to the operating system's USB layer
   --  and the dongles opened on it. One per program is usual. It closes itself
   --  when finalised, together with any dongle still open on it.
   type Context is tagged limited private;

   --  Prepares a context, loading the library if this is the first call. (Not
   --  named Initialize: that would override the controlled type's own and
   --  run at declaration, where a failure cannot be handled.)
   procedure Create (Ctx : in out Context);

   procedure Close (Ctx : in out Context);
   function Is_Open (Ctx : Context) return Boolean;

   --  The library's diagnostic text for the most recent failure.
   function Last_Error_Detail (Ctx : Context) return String;

   --  Replaces the CA root (DER) that Verify_Genuine checks against.
   --  Applications do not need this: a release build of the library embeds
   --  the KeyNub production root.
   procedure Set_Trust_Root (Ctx : in out Context; DER : Bytes);

   type Device_Info is record
      Serial     : Text;   --  hex
      Path       : Text;   --  the OS device path, accepted by Open_Path
      Vendor_Id  : Natural;
      Product_Id : Natural;
   end record;
   type Device_List is array (Positive range <>) of Device_Info;

   --  The attached dongles, without opening any.
   function Enumerate (Ctx : in out Context) return Device_List;

   -----------------------------------------------------------------------------
   --  Dongle
   -----------------------------------------------------------------------------

   --  An open connection to one dongle. Sessions are opened on it.
   type Dongle is tagged limited private;

   --  Opens the dongle with Serial, or the first one found when "". Raises
   --  No_Device_Error when none matches.
   --  Ctx is class-wide so that these are primitive operations of Dongle only.
   procedure Open (Ctx : aliased in out Context'Class; D : in out Dongle; Serial : String := "");

   --  Opens the dongle at a device path from Enumerate.
   procedure Open_Path (Ctx : aliased in out Context'Class; D : in out Dongle; Path : String);

   procedure Close (D : in out Dongle);
   function Is_Open (D : Dongle) return Boolean;

   type Info is record
      Protocol_Major, Protocol_Minor              : Natural;
      Firmware_Major, Firmware_Minor, Firmware_Patch : Natural;
      Secure_Element_Ready : Boolean;   --  the secure element responded
      Provisioned          : Boolean;   --  factory provisioning complete
      Data_Capacity        : Natural;   --  bytes
      Data_Free            : Natural;   --  bytes
      --  The dongle's *previous* boot ended in a watchdog timeout: the
      --  firmware hung and reset itself. The only trace a field hang leaves.
      Watchdog_Reboot      : Boolean;
      --  The USB code is fenced off from keys and storage (measured at boot).
      Isolated             : Boolean;
      --  The write key has been rotated away from the public factory one.
      --  Rotate on receipt, and check this before shipping a dongle.
      Write_Auth_Rotated   : Boolean;
   end record;

   function Get_Info (D : Dongle) return Info;
   function Serial (D : Dongle) return String;

   type Genuine_Result is record
      Genuine          : Boolean;
      Serial           : Text;   --  from the verified certificate
      Provisioned_Date : Text;   --  "YYYY-MM-DD" or ""
   end record;

   --  Proves authenticity: the certificate chain to the trusted root plus a
   --  live challenge-response. Raises Not_Genuine_Error (or
   --  Certificate_Invalid_Error) unless the dongle is genuine.
   function Verify_Genuine (D : Dongle) return Genuine_Result;

   --  The non-raising form for a gate. Fails closed: a missing dongle, an I/O
   --  error and an invalid certificate all give False.
   function Is_Genuine (D : Dongle) return Boolean;

   -----------------------------------------------------------------------------
   --  Session: records, counters, the write role, app-data crypto
   -----------------------------------------------------------------------------

   --  Records, counters and app-data encryption need a session: an encrypted,
   --  authenticated channel to the dongle (P-256 ECDH, HKDF-SHA256,
   --  AES-256-GCM). Writing, erasing and counter increments also need the
   --  write role, see Authorize_Write.
   procedure Session_Open (D : in out Dongle);
   procedure Session_Close (D : in out Dongle);

   --  Elevates to the write role with the dongle's write key (a P-256 private
   --  key in PKCS#8 DER). This belongs in your licence-issuing tooling; never
   --  ship that key in the application your users run. A key the dongle does
   --  not accept raises Not_Genuine_Error.
   procedure Authorize_Write (D : in out Dongle; Key : Bytes);

   --  Replaces the dongle's write key with Key, a key you hold. Needs the
   --  write role; this session keeps it, and from the next session on only
   --  the new key elevates. Do this once per dongle, when it arrives: the
   --  factory key is public.
   procedure Rotate_Write_Key (D : in out Dongle; Key : Bytes);

   type Record_Info is record
      Name : Text;
      Size : Natural;   --  bytes
   end record;
   type Record_List is array (Positive range <>) of Record_Info;

   function Records (D : Dongle) return Record_List;

   --  Reports a transfer: Done and Total in bytes. Return False to cancel,
   --  which raises Cancelled_Error. An exception raised inside cancels the
   --  transfer as well and is re-raised after the C frames have unwound.
   type Progress_Callback is access function (Done, Total : Natural) return Boolean;

   --  Reads a record; a missing one raises Not_Found_Error.
   function Read_Record
     (D : Dongle; Name : String; Progress : Progress_Callback := null) return Bytes;

   --  Atomically replaces a record. Needs the write role.
   procedure Write_Record
     (D : in out Dongle; Name : String; Data : Bytes; Progress : Progress_Callback := null);
   procedure Write_Record
     (D : in out Dongle; Name : String; Data : String; Progress : Progress_Callback := null);

   --  Erases one record (a missing one raises Not_Found_Error), or every
   --  record. Separate on purpose: to the C library a null name means "erase
   --  everything", and an accidentally empty name must not do that.
   procedure Erase_Record (D : in out Dongle; Name : String);
   procedure Erase_All_Records (D : in out Dongle);

   --  Hardware monotonic counters. Incrementing is irreversible and needs
   --  the write role.
   type Counter_Id is range 0 .. 255;
   type Counter_Value is range 0 .. 2 ** 32 - 1;

   function Read_Counter (D : Dongle; Id : Counter_Id) return Counter_Value;
   function Increment_Counter (D : in out Dongle; Id : Counter_Id) return Counter_Value;

   --  Who can decrypt data produced by App_Encrypt: only the one physical
   --  dongle, or any dongle issued by the same developer.
   type Scope is (Device, Developer);

   --  The pair to build a licence check on: put something the program needs
   --  through App_Encrypt, ship only the sealed form, and removing the check
   --  removes the data.
   function App_Encrypt (D : Dongle; Plaintext : Bytes; Which : Scope) return Bytes;
   function App_Decrypt (D : Dongle; Packed : Bytes) return Bytes;

private

   Chosen_Path : access String := null;
   Current_Status : Status := OK;

   type Context_Access is access all Context;

   type Dongle_Access is access all Dongle;
   type Dongle_Access_Array is array (1 .. 16) of Dongle_Access;

   type Context is new Ada.Finalization.Limited_Controlled with record
      Handle  : System.Address := System.Null_Address;
      Dongles : Dongle_Access_Array := (others => null);
   end record;

   overriding procedure Finalize (Ctx : in out Context);

   type Dongle is new Ada.Finalization.Limited_Controlled with record
      Handle : System.Address := System.Null_Address;
      Owner  : Context_Access := null;
   end record;

   overriding procedure Finalize (D : in out Dongle);

end KeyNub_LicDongle;
