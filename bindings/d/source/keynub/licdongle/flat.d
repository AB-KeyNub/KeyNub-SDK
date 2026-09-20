/// The SDK's flat C API (`bindings/flat/licd_flat.h`): one function pointer
/// type per signature, and the table the loader fills from the library.
module keynub.licdongle.flat;

/// The C symbol a field of `Api` is resolved from.
struct Symbol
{
    string name;
}

// Bits in the flags value of licdf_get_info.
enum int flagSecureElementReady = 0x01;
enum int flagProvisioned = 0x02;
enum int flagWatchdogReboot = 0x04;
enum int flagIsolated = 0x08;
enum int flagWriteAuthRotated = 0x10;

// Buffer sizes (LICDF_SERIAL_SIZE, LICDF_DATE_SIZE, LICDF_PATH_SIZE,
// LICDF_ERROR_SIZE), and one for a record name.
enum int serialSize = 15;
enum int dateSize = 11;
enum int pathSize = 512;
enum int errorSize = 256;
enum int nameSize = 256;

extern (C) nothrow @nogc
{
    alias FnVersion = int function(int* major, int* minor, int* patch);
    alias FnCount = int function(int* count);
    alias FnIndexString = int function(int index, char* text, int size);
    alias FnOpen = int function(const(char)* text);
    alias FnHandle = int function(int handle);
    alias FnHandleBytes = int function(int handle, const(ubyte)* data, int length);
    alias FnHandleString = int function(int handle, char* text, int size);
    alias FnGetInfo = int function(int handle, int* protocolMajor, int* protocolMinor,
        int* firmwareMajor, int* firmwareMinor, int* firmwarePatch, int* flags,
        int* capacity, int* free);
    alias FnVerifyGenuine = int function(int handle, int* genuine, char* serial,
        int serialSize, char* date, int dateSize);
    alias FnHandleCount = int function(int handle, int* count);
    alias FnRecordName = int function(int handle, int index, char* name, int size,
        int* recordSize);
    alias FnRecordSize = int function(int handle, const(char)* name, int* size);
    alias FnRecordRead = int function(int handle, const(char)* name, ubyte* data,
        int capacity, int* length);
    alias FnRecordWrite = int function(int handle, const(char)* name,
        const(ubyte)* data, int length);
    alias FnRecordErase = int function(int handle, const(char)* name);
    alias FnCounter = int function(int handle, int counterId, int* value);
    alias FnAppEncrypt = int function(int handle, int scope_, const(ubyte)* plaintext,
        int plaintextLength, ubyte* data, int capacity, int* length);
    alias FnAppDecrypt = int function(int handle, const(ubyte)* packed, int packedLength,
        ubyte* data, int capacity, int* length);
    alias FnStrerror = int function(int status, char* text, int size);
}

/// The 28 functions of the flat API, resolved by name from the loaded library.
struct Api
{
    @Symbol("licdf_version") FnVersion version_;
    @Symbol("licdf_device_count") FnCount deviceCount;
    @Symbol("licdf_device_serial") FnIndexString deviceSerial;
    @Symbol("licdf_device_path") FnIndexString devicePath;
    @Symbol("licdf_open") FnOpen open;
    @Symbol("licdf_open_path") FnOpen openPath;
    @Symbol("licdf_close") FnHandle close;
    @Symbol("licdf_set_trust_root") FnHandleBytes setTrustRoot;
    @Symbol("licdf_get_serial") FnHandleString getSerial;
    @Symbol("licdf_get_info") FnGetInfo getInfo;
    @Symbol("licdf_verify_genuine") FnVerifyGenuine verifyGenuine;
    @Symbol("licdf_session_open") FnHandle sessionOpen;
    @Symbol("licdf_session_close") FnHandle sessionClose;
    @Symbol("licdf_write_auth") FnHandleBytes writeAuth;
    @Symbol("licdf_write_auth_rotate") FnHandleBytes writeAuthRotate;
    @Symbol("licdf_record_count") FnHandleCount recordCount;
    @Symbol("licdf_record_name") FnRecordName recordName;
    @Symbol("licdf_record_size") FnRecordSize recordSize;
    @Symbol("licdf_record_read") FnRecordRead recordRead;
    @Symbol("licdf_record_write") FnRecordWrite recordWrite;
    @Symbol("licdf_record_erase") FnRecordErase recordErase;
    @Symbol("licdf_record_erase_all") FnHandle recordEraseAll;
    @Symbol("licdf_counter_read") FnCounter counterRead;
    @Symbol("licdf_counter_increment") FnCounter counterIncrement;
    @Symbol("licdf_app_encrypt") FnAppEncrypt appEncrypt;
    @Symbol("licdf_app_decrypt") FnAppDecrypt appDecrypt;
    @Symbol("licdf_strerror") FnStrerror strerror;
    @Symbol("licdf_last_error") FnHandleString lastError;
}
