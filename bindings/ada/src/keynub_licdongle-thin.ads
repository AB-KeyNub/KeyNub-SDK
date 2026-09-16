--  The C ABI of the KeyNub library as Ada sees it: the plain structures with
--  Convention C (so the compiler lays them out as C does), the function
--  profiles, and the table of function pointers bound by name from the
--  library loaded at run time. Not part of the crate's API.

with Interfaces.C;
with System;

private package KeyNub_LicDongle.Thin is

   use Interfaces.C;

   Serial_Hex_Len : constant := 14;

   type Device_Info_C is record
      Serial     : char_array (0 .. Serial_Hex_Len);
      Path       : char_array (0 .. 511);
      Vendor_Id  : unsigned_short;
      Product_Id : unsigned_short;
   end record
     with Convention => C;

   type Info_C is record
      Proto_Version_Major : unsigned_char;
      Proto_Version_Minor : unsigned_char;
      Fw_Version_Major    : unsigned_char;
      Fw_Version_Minor    : unsigned_char;
      Fw_Version_Patch    : unsigned_char;
      Se_Ready            : int;
      Provisioned         : int;
      Data_Capacity       : unsigned;
      Data_Free           : unsigned;
      Watchdog_Reboot     : int;
      Isolated            : int;
      Writeauth_Rotated   : int;
   end record
     with Convention => C;

   type Genuine_Result_C is record
      Genuine          : int;
      Serial           : char_array (0 .. Serial_Hex_Len);
      Provisioned_Date : char_array (0 .. 10);
   end record
     with Convention => C;

   type Progress_Cb is access function
     (Done, Total : unsigned; User : System.Address) return int
     with Convention => C;

   --  System.Address stands for every pointer of the C ABI: licd_ctx*,
   --  licd_device*, buffers and strings alike.

   type Version_Fn is access procedure (Major, Minor, Patch : access int)
     with Convention => C;
   type Init_Fn is access function (Out_Ctx : access System.Address) return int
     with Convention => C;
   type Free_Fn is access procedure (Handle : System.Address)
     with Convention => C;
   type Bytes_Fn is access function
     (Handle : System.Address; Data : System.Address; Len : size_t) return int
     with Convention => C;
   type Enumerate_Fn is access function
     (Ctx : System.Address; Out_List : access System.Address; Out_Count : access size_t)
      return int
     with Convention => C;
   type Free_List_Fn is access procedure (List : System.Address; Count : size_t)
     with Convention => C;
   type Open_Fn is access function
     (Ctx : System.Address; Name : System.Address; Out_Dev : access System.Address)
      return int
     with Convention => C;
   type Get_Info_Fn is access function
     (Dev : System.Address; Info : access Info_C) return int
     with Convention => C;
   type Get_Serial_Fn is access function
     (Dev : System.Address; Buffer : System.Address; Size : size_t) return int
     with Convention => C;
   type Verify_Fn is access function
     (Dev : System.Address; Result : access Genuine_Result_C) return int
     with Convention => C;
   type Device_Fn is access function (Dev : System.Address) return int
     with Convention => C;
   type Record_List_Fn is access function
     (Dev       : System.Address;
      Out_Names : access System.Address;
      Out_Sizes : access System.Address;
      Out_Count : access size_t) return int
     with Convention => C;
   type Free_Record_List_Fn is access procedure
     (Names : System.Address; Sizes : System.Address; Count : size_t)
     with Convention => C;
   type Record_Read_Fn is access function
     (Dev       : System.Address;
      Name      : System.Address;
      Offset    : unsigned;
      Buffer    : System.Address;
      Buf_Size  : unsigned;
      Out_Len   : access unsigned;
      Out_Total : access unsigned;
      Progress  : Progress_Cb;
      User      : System.Address) return int
     with Convention => C;
   type Record_Write_Fn is access function
     (Dev      : System.Address;
      Name     : System.Address;
      Data     : System.Address;
      Len      : unsigned;
      Progress : Progress_Cb;
      User     : System.Address) return int
     with Convention => C;
   type Record_Erase_Fn is access function
     (Dev : System.Address; Name : System.Address) return int
     with Convention => C;
   type Counter_Fn is access function
     (Dev : System.Address; Id : unsigned_char; Out_Value : access unsigned) return int
     with Convention => C;
   type App_Encrypt_Fn is access function
     (Dev       : System.Address;
      Scope     : int;
      Plaintext : System.Address;
      Len       : unsigned;
      Out_Buf   : access System.Address;
      Out_Len   : access unsigned) return int
     with Convention => C;
   type App_Decrypt_Fn is access function
     (Dev        : System.Address;
      Packed     : System.Address;
      Packed_Len : unsigned;
      Out_Buf    : access System.Address;
      Out_Len    : access unsigned) return int
     with Convention => C;
   type Free_Buffer_Fn is access procedure (Buffer : System.Address)
     with Convention => C;
   type Strerror_Fn is access function (Status : int) return System.Address
     with Convention => C;
   type Error_Detail_Fn is access function
     (Ctx : System.Address) return System.Address
     with Convention => C;

   type API is record
      Version           : Version_Fn;
      Init              : Init_Fn;
      Free              : Free_Fn;
      Set_Trust_Root    : Bytes_Fn;
      Enumerate         : Enumerate_Fn;
      Free_Device_List  : Free_List_Fn;
      Open              : Open_Fn;
      Open_Path         : Open_Fn;
      Close             : Free_Fn;
      Get_Info          : Get_Info_Fn;
      Get_Serial        : Get_Serial_Fn;
      Verify_Genuine    : Verify_Fn;
      Session_Open      : Device_Fn;
      Session_Close     : Device_Fn;
      Write_Auth        : Bytes_Fn;
      Write_Auth_Rotate : Bytes_Fn;
      Record_List       : Record_List_Fn;
      Free_Record_List  : Free_Record_List_Fn;
      Record_Read       : Record_Read_Fn;
      Record_Write      : Record_Write_Fn;
      Record_Erase      : Record_Erase_Fn;
      Counter_Read      : Counter_Fn;
      Counter_Increment : Counter_Fn;
      App_Encrypt       : App_Encrypt_Fn;
      App_Decrypt       : App_Decrypt_Fn;
      Free_Buffer       : Free_Buffer_Fn;
      Strerror          : Strerror_Fn;
      Error_Detail      : Error_Detail_Fn;
   end record;

   --  The bound library, loaded on the first call. Raises Library_Error.
   function Get return access constant API;

   --  The path the process loaded, or "" before the first call.
   function Loaded_Path return String;

   --  The path the next load would use.
   function Resolved_Path return String;

   --  The natives/<platform> folder name for this process.
   function Platform return String;

   --  A NUL-terminated char_array as a String.
   function To_Ada (Chars : char_array) return String;

   --  A NUL-terminated C string at an address as a String ("" for null).
   function String_At (Address : System.Address) return String;

end KeyNub_LicDongle.Thin;
