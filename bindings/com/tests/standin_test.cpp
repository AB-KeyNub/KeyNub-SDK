// Every member of the COM object (bindings/com) against a stand-in for the C ABI:
// the server built from keynub_com.cpp over bindings/flat/licd_flat.c and
// bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory.
// Each call goes through the vtable, the way `Dim d As New KeyNub.Dongle` binds,
// and the object is driven a second time through IDispatch, the way
// CreateObject("KeyNub.Dongle") binds in VB6, twinBASIC, VBScript and VBA. The
// object is activated through DllGetClassObject, so nothing is registered.
// Exit code 0 when every check passed.
//
//     cmake -S bindings/com/tests -B build-com-standin -A x64      (or -A Win32)
//     cmake --build build-com-standin --config Release
//     ctest --test-dir build-com-standin -C Release

#include <windows.h>
#include <objbase.h>
#include <oleauto.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>

#include "KeyNub_h.h"
#include "licdongle.h"

static int failures = 0;

static void check(bool condition, const char *what) {
    if (!condition) {
        failures++;
        printf("  FAIL  %s\n", what);
    }
}

// Failures arrive as MAKE_HRESULT(SEVERITY_ERROR, FACILITY_ITF, 5000 + |status|),
// which VB reports as Err.Number = vbObjectError + 5000 + |status|.
static HRESULT status_hr(int status) {
    return MAKE_HRESULT(SEVERITY_ERROR, FACILITY_ITF, 5000 + (status < 0 ? -status : status));
}

static bool description_contains(const wchar_t *part) {
    IErrorInfo *info = nullptr;
    if (GetErrorInfo(0, &info) != S_OK || info == nullptr) {
        return false;
    }
    BSTR text = nullptr;
    info->GetDescription(&text);
    const bool found = text != nullptr && SysStringLen(text) > 0 && (part == nullptr || wcsstr(text, part) != nullptr);
    SysFreeString(text);
    info->Release();
    return found;
}

// A failure must carry the status and a description (Err.Description).
static void expect_status(HRESULT hr, int status, const char *what) {
    if (hr != status_hr(status)) {
        failures++;
        printf("  FAIL  %s: 0x%08lX, expected 0x%08lX\n", what, (unsigned long)hr, (unsigned long)status_hr(status));
        return;
    }
    if (!description_contains(nullptr)) {
        failures++;
        printf("  FAIL  %s: no error description\n", what);
    }
}

static void expect_ok(HRESULT hr, const char *what) {
    if (FAILED(hr)) {
        failures++;
        printf("  FAIL  %s: 0x%08lX\n", what, (unsigned long)hr);
    }
}

static bool text_is(BSTR text, const wchar_t *want) {
    return text != nullptr && wcscmp(text, want) == 0;
}

static SAFEARRAY *bytes(const void *data, size_t len) {
    SAFEARRAY *sa = SafeArrayCreateVector(VT_UI1, 0, (ULONG)len);
    void *dest = nullptr;
    if (sa != nullptr && len > 0 && SUCCEEDED(SafeArrayAccessData(sa, &dest))) {
        memcpy(dest, data, len);
        SafeArrayUnaccessData(sa);
    }
    return sa;
}

static size_t length(SAFEARRAY *sa) {
    LONG lo = 0, hi = -1;
    if (sa == nullptr || FAILED(SafeArrayGetLBound(sa, 1, &lo)) || FAILED(SafeArrayGetUBound(sa, 1, &hi))) {
        return 0;
    }
    return (size_t)(hi - lo + 1);
}

static bool same(SAFEARRAY *sa, const void *want, size_t len) {
    if (length(sa) != len) {
        return false;
    }
    if (len == 0) {
        return true;
    }
    void *data = nullptr;
    if (FAILED(SafeArrayAccessData(sa, &data))) {
        return false;
    }
    const bool equal = memcmp(data, want, len) == 0;
    SafeArrayUnaccessData(sa);
    return equal;
}

static uint8_t byte_at(SAFEARRAY *sa, LONG index) {
    uint8_t b = 0;
    SafeArrayGetElement(sa, &index, &b);
    return b;
}

static void flip_last(SAFEARRAY *sa) {
    LONG index = (LONG)length(sa) - 1;
    uint8_t b = byte_at(sa, index) ^ 1;
    SafeArrayPutElement(sa, &index, &b);
}

static const wchar_t SERIAL[] = L"04A1B2C3D4E5F6";
static const uint8_t FACTORY_KEY[] = {0x30, 0x10, 0x01, 0x02, 0x03};
static const uint8_t REPLACEMENT_KEY[] = {0x30, 0x11, 0x09, 0x08, 0x07, 0x06};

typedef HRESULT(__stdcall *GetClassObjectFn)(REFCLSID, REFIID, void **);
static GetClassObjectFn get_class_object = nullptr;

static IDongle *create_dongle() {
    IClassFactory *factory = nullptr;
    if (FAILED(get_class_object(CLSID_Dongle, IID_IClassFactory, (void **)&factory)) || factory == nullptr) {
        return nullptr;
    }
    IDongle *d = nullptr;
    HRESULT hr = factory->CreateInstance(nullptr, IID_IDongle, (void **)&d);
    factory->Release();
    return SUCCEEDED(hr) ? d : nullptr;
}

// --- late binding -----------------------------------------------------------

static DISPID dispid_of(IDispatch *disp, const wchar_t *name) {
    LPOLESTR n = (LPOLESTR)name;
    DISPID id = DISPID_UNKNOWN;
    if (FAILED(disp->GetIDsOfNames(IID_NULL, &n, 1, LOCALE_USER_DEFAULT, &id))) {
        printf("  FAIL  GetIDsOfNames(%ls)\n", name);
        failures++;
    }
    return id;
}

// Calls a member by name. `args` are in call order; IDispatch wants them reversed.
static HRESULT invoke(IDispatch *disp, const wchar_t *name, WORD kind, VARIANT *args, UINT count, VARIANT *result,
                      EXCEPINFO *ex) {
    VARIANT reversed[4];
    for (UINT i = 0; i < count; i++) {
        reversed[i] = args[count - 1 - i];
    }
    DISPPARAMS params = {count ? reversed : nullptr, nullptr, count, 0};
    if (result != nullptr) {
        VariantInit(result);
    }
    memset(ex, 0, sizeof(*ex));
    return disp->Invoke(dispid_of(disp, name), IID_NULL, LOCALE_USER_DEFAULT, kind, &params, result, ex, nullptr);
}

static void clear_excepinfo(EXCEPINFO *ex) {
    SysFreeString(ex->bstrSource);
    SysFreeString(ex->bstrDescription);
    SysFreeString(ex->bstrHelpFile);
    memset(ex, 0, sizeof(*ex));
}

static void late_binding(IDongle *d) {
    IDispatch *disp = nullptr;
    check(SUCCEEDED(d->QueryInterface(IID_IDispatch, (void **)&disp)) && disp != nullptr, "the object is an IDispatch");
    if (disp == nullptr) {
        return;
    }
    UINT infos = 0;
    check(SUCCEEDED(disp->GetTypeInfoCount(&infos)) && infos == 1, "type information advertised");
    ITypeInfo *type_info = nullptr;
    check(SUCCEEDED(disp->GetTypeInfo(0, LOCALE_USER_DEFAULT, &type_info)) && type_info != nullptr, "GetTypeInfo");
    if (type_info != nullptr) {
        type_info->Release();
    }

    EXCEPINFO ex;
    VARIANT result;
    // Open with its optional argument left out, as `d.Open` is written.
    expect_ok(invoke(disp, L"Open", DISPATCH_METHOD, nullptr, 0, nullptr, &ex), "late Open()");
    expect_ok(invoke(disp, L"Serial", DISPATCH_PROPERTYGET, nullptr, 0, &result, &ex), "late Serial");
    check(V_VT(&result) == VT_BSTR && text_is(V_BSTR(&result), SERIAL), "late Serial value");
    VariantClear(&result);
    expect_ok(invoke(disp, L"IsGenuine", DISPATCH_PROPERTYGET, nullptr, 0, &result, &ex), "late IsGenuine");
    check(V_VT(&result) == VT_BOOL && V_BOOL(&result) == VARIANT_TRUE, "late IsGenuine value");
    VariantClear(&result);
    expect_ok(invoke(disp, L"SessionOpen", DISPATCH_METHOD, nullptr, 0, nullptr, &ex), "late SessionOpen");

    VARIANT args[2];
    V_VT(&args[0]) = VT_ARRAY | VT_UI1;
    V_ARRAY(&args[0]) = bytes(FACTORY_KEY, sizeof(FACTORY_KEY));
    expect_ok(invoke(disp, L"AuthorizeWrite", DISPATCH_METHOD, args, 1, nullptr, &ex), "late AuthorizeWrite");
    VariantClear(&args[0]);

    const char payload[] = "late-bound";
    V_VT(&args[0]) = VT_BSTR;
    V_BSTR(&args[0]) = SysAllocString(L"late");
    V_VT(&args[1]) = VT_ARRAY | VT_UI1;
    V_ARRAY(&args[1]) = bytes(payload, 10);
    expect_ok(invoke(disp, L"RecordWrite", DISPATCH_METHOD, args, 2, nullptr, &ex), "late RecordWrite");
    VariantClear(&args[1]);
    expect_ok(invoke(disp, L"RecordRead", DISPATCH_METHOD, args, 1, &result, &ex), "late RecordRead");
    check(V_VT(&result) == (VT_ARRAY | VT_UI1) && same(V_ARRAY(&result), payload, 10), "late RecordRead value");
    VariantClear(&result);
    VariantClear(&args[0]);

    // A failure through IDispatch: VB sees DISP_E_EXCEPTION with the status in scode.
    V_VT(&args[0]) = VT_BSTR;
    V_BSTR(&args[0]) = SysAllocString(L"nope");
    HRESULT hr = invoke(disp, L"RecordRead", DISPATCH_METHOD, args, 1, &result, &ex);
    check(hr == DISP_E_EXCEPTION && ex.scode == status_hr(LICD_E_NOT_FOUND), "late RecordRead of a missing record");
    check(ex.bstrDescription != nullptr && wcsstr(ex.bstrDescription, L"no such record") != nullptr,
          "late error description");
    clear_excepinfo(&ex);
    VariantClear(&result);
    VariantClear(&args[0]);

    V_VT(&args[0]) = VT_I4;
    V_I4(&args[0]) = keynubScopeDeveloper;
    V_VT(&args[1]) = VT_ARRAY | VT_UI1;
    V_ARRAY(&args[1]) = bytes(payload, 10);
    expect_ok(invoke(disp, L"AppEncrypt", DISPATCH_METHOD, args, 2, &result, &ex), "late AppEncrypt");
    VariantClear(&args[1]);
    VARIANT sealed = result;
    VARIANT plain;
    expect_ok(invoke(disp, L"AppDecrypt", DISPATCH_METHOD, &sealed, 1, &plain, &ex), "late AppDecrypt");
    check(V_VT(&plain) == (VT_ARRAY | VT_UI1) && same(V_ARRAY(&plain), payload, 10), "late round trip");
    VariantClear(&plain);
    VariantClear(&sealed);

    // CounterRead with a Variant holding a String, as a script engine may pass it.
    V_VT(&args[0]) = VT_BSTR;
    V_BSTR(&args[0]) = SysAllocString(L"1");
    expect_ok(invoke(disp, L"CounterRead", DISPATCH_METHOD, args, 1, &result, &ex), "late CounterRead coerces");
    check(V_VT(&result) == VT_I4 && V_I4(&result) == 0, "late CounterRead value");
    VariantClear(&args[0]);

    expect_ok(invoke(disp, L"RecordEraseAll", DISPATCH_METHOD, nullptr, 0, nullptr, &ex), "late RecordEraseAll");
    expect_ok(invoke(disp, L"Close", DISPATCH_METHOD, nullptr, 0, nullptr, &ex), "late Close");

    LPOLESTR unknown = (LPOLESTR)L"NoSuchMember";
    DISPID id = 0;
    check(disp->GetIDsOfNames(IID_NULL, &unknown, 1, LOCALE_USER_DEFAULT, &id) == DISP_E_UNKNOWNNAME,
          "an unknown member name is refused");
    disp->Release();
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path to the stand-in COM server DLL>\n", argv[0]);
        return 2;
    }
    // A single-threaded apartment, as VB6, VBA and the script hosts use.
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) {
        fprintf(stderr, "CoInitializeEx failed\n");
        return 2;
    }
    HMODULE server = LoadLibraryA(argv[1]);
    if (server == nullptr) {
        fprintf(stderr, "cannot load %s (error %lu)\n", argv[1], GetLastError());
        return 2;
    }
    get_class_object = (GetClassObjectFn)GetProcAddress(server, "DllGetClassObject");
    check(GetProcAddress(server, "DllRegisterServer") != nullptr, "DllRegisterServer exported");
    check(GetProcAddress(server, "licdf_open") == nullptr, "the flat API is not exported");
    if (get_class_object == nullptr) {
        printf("  FAIL  DllGetClassObject is not exported\n");
        return 1;
    }

    IDongle *d = create_dongle();
    if (d == nullptr) {
        printf("  FAIL  IClassFactory::CreateInstance\n");
        return 1;
    }
    ISupportErrorInfo *support = nullptr;
    check(SUCCEEDED(d->QueryInterface(IID_ISupportErrorInfo, (void **)&support)) && support != nullptr &&
              support->InterfaceSupportsErrorInfo(IID_IDongle) == S_OK,
          "rich errors advertised for IDongle");
    if (support != nullptr) {
        support->Release();
    }

    BSTR text = nullptr;
    long value = 0;
    VARIANT_BOOL flag = VARIANT_TRUE;
    HRESULT hr;

    // --- without an open dongle ------------------------------------------------
    expect_ok(d->get_Version(&text), "Version");
    check(text_is(text, L"9.8.7"), "library version");
    SysFreeString(text);
    expect_ok(d->get_DeviceCount(&value), "DeviceCount");
    check(value == 1, "one device");
    expect_ok(d->DeviceSerial(0, &text), "DeviceSerial");
    check(text_is(text, SERIAL), "device serial");
    SysFreeString(text);
    expect_ok(d->DevicePath(0, &text), "DevicePath");
    check(text_is(text, L"stub:0"), "device path");
    SysFreeString(text);
    expect_status(d->DeviceSerial(1, &text), LICD_E_RANGE, "device index out of range");
    check(SUCCEEDED(d->get_IsOpen(&flag)) && flag == VARIANT_FALSE, "not open yet");
    check(SUCCEEDED(d->get_IsGenuine(&flag)) && flag == VARIANT_FALSE, "IsGenuine is False with nothing open");
    expect_status(d->get_Serial(&text), LICD_E_NO_DEVICE, "Serial before Open");
    expect_status(d->SessionOpen(), LICD_E_NO_DEVICE, "SessionOpen before Open");
    expect_ok(d->Close(), "Close before Open");

    BSTR arg = SysAllocString(L"nope");
    expect_status(d->Open(arg), LICD_E_NO_DEVICE, "open by unknown serial");
    SysFreeString(arg);
    arg = SysAllocString(L"stub:9");
    expect_status(d->OpenPath(arg), LICD_E_NO_DEVICE, "open by unknown path");
    SysFreeString(arg);
    arg = SysAllocString(L"");
    expect_status(d->OpenPath(arg), LICD_E_INVALID_ARG, "OpenPath with an empty path");
    SysFreeString(arg);

    // --- open and identify -----------------------------------------------------
    arg = SysAllocString(L"stub:0");
    expect_ok(d->OpenPath(arg), "OpenPath");
    SysFreeString(arg);
    arg = SysAllocString(L"");
    expect_ok(d->Open(arg), "Open the first dongle (reopens)");
    SysFreeString(arg);
    check(SUCCEEDED(d->get_IsOpen(&flag)) && flag == VARIANT_TRUE, "open");
    expect_ok(d->get_Serial(&text), "Serial");
    check(text_is(text, SERIAL), "serial");
    SysFreeString(text);
    expect_ok(d->get_FirmwareVersion(&text), "FirmwareVersion");
    check(text_is(text, L"2.3.4"), "firmware version");
    SysFreeString(text);
    expect_ok(d->get_ProtocolVersion(&text), "ProtocolVersion");
    check(text_is(text, L"1.0"), "protocol version");
    SysFreeString(text);
    expect_ok(d->get_Flags(&value), "Flags");
    check((value & keynubFlagSeReady) && (value & keynubFlagProvisioned) && (value & keynubFlagIsolated), "flags set");
    check(!(value & keynubFlagWatchdogReboot) && !(value & keynubFlagWriteAuthRotated), "flags clear");
    expect_ok(d->get_Capacity(&value), "Capacity");
    check(value == 1024 * 1024, "capacity");
    expect_ok(d->get_FreeBytes(&value), "FreeBytes");
    check(value == 1000000, "free bytes");

    // --- genuineness and the trust root ---------------------------------------
    check(SUCCEEDED(d->get_IsGenuine(&flag)) && flag == VARIANT_TRUE, "IsGenuine");
    expect_ok(d->VerifyGenuine(&text), "VerifyGenuine");
    check(text_is(text, SERIAL), "certificate serial");
    SysFreeString(text);
    expect_ok(d->get_ProvisionedDate(&text), "ProvisionedDate");
    check(text_is(text, L"2026-08-15"), "provisioned date");
    SysFreeString(text);

    const uint8_t bad_root[] = {0x02, 0x01, 0x00};
    SAFEARRAY *sa = bytes(bad_root, sizeof(bad_root));
    expect_status(d->SetTrustRoot(sa), LICD_E_CERT_INVALID, "malformed trust root");
    SafeArrayDestroy(sa);
    uint8_t root[132];
    memset(root, 0xAB, sizeof(root));
    root[0] = 0x30, root[1] = 0x82, root[2] = 0x01, root[3] = 0x00;
    sa = bytes(root, sizeof(root));
    expect_ok(d->SetTrustRoot(sa), "foreign trust root");
    SafeArrayDestroy(sa);
    expect_status(d->VerifyGenuine(&text), LICD_E_CERT_INVALID, "verify against a foreign root");
    check(SUCCEEDED(d->get_IsGenuine(&flag)) && flag == VARIANT_FALSE, "IsGenuine fails closed");
    memset(root + 4, 0x01, sizeof(root) - 4);
    sa = bytes(root, sizeof(root));
    expect_ok(d->SetTrustRoot(sa), "right trust root");
    SafeArrayDestroy(sa);
    expect_ok(d->VerifyGenuine(&text), "verify after the right root");
    SysFreeString(text);

    // --- session, write role, records -----------------------------------------
    expect_status(d->get_RecordCount(&value), LICD_E_SESSION_EXPIRED, "records without a session");
    expect_ok(d->SessionOpen(), "SessionOpen");
    const char payload[] = "license-blob-0123456789";
    const size_t plen = strlen(payload);
    BSTR lic = SysAllocString(L"lic");
    SAFEARRAY *data = bytes(payload, plen);
    expect_status(d->RecordWrite(lic, data), LICD_E_AUTH_REQUIRED, "write before the write role");
    const uint8_t bad_key[] = {0x30, 0x00};
    sa = bytes(bad_key, sizeof(bad_key));
    expect_status(d->AuthorizeWrite(sa), LICD_E_NOT_GENUINE, "write role with a bad key");
    SafeArrayDestroy(sa);
    SAFEARRAY *factory = bytes(FACTORY_KEY, sizeof(FACTORY_KEY));
    expect_ok(d->AuthorizeWrite(factory), "AuthorizeWrite");
    expect_ok(d->RecordWrite(lic, data), "RecordWrite");

    SAFEARRAY *read = nullptr;
    expect_ok(d->RecordRead(lic, &read), "RecordRead");
    check(same(read, payload, plen), "read back");
    SafeArrayDestroy(read);
    expect_ok(d->RecordSize(lic, &value), "RecordSize");
    check(value == (long)plen, "record size");
    BSTR cfg = SysAllocString(L"cfg");
    sa = bytes("cfgdata", 7);
    expect_ok(d->RecordWrite(cfg, sa), "second record");
    SafeArrayDestroy(sa);
    expect_ok(d->get_RecordCount(&value), "RecordCount");
    check(value == 2, "two records");
    int seen = 0;
    for (long i = 0; i < value; i++) {
        expect_ok(d->RecordName(i, &text), "RecordName");
        seen |= text_is(text, L"lic") ? 1 : text_is(text, L"cfg") ? 2 : 0;
        SysFreeString(text);
    }
    check(seen == 3, "record names");
    expect_status(d->RecordName(5, &text), LICD_E_RANGE, "record index out of range");

    BSTR nope = SysAllocString(L"nope");
    read = nullptr;
    expect_status(d->RecordRead(nope, &read), LICD_E_NOT_FOUND, "read a missing record");
    read = nullptr;
    d->RecordRead(nope, &read);
    check(description_contains(L"no such record"), "the description carries the detail");
    expect_ok(d->get_LastError(&text), "LastError");
    check(text_is(text, L"no such record"), "LastError text");
    SysFreeString(text);
    SysFreeString(nope);

    BSTR empty = SysAllocString(L"");
    expect_status(d->RecordErase(empty), LICD_E_INVALID_ARG, "erase with an empty name");
    SysFreeString(empty);
    expect_ok(d->RecordErase(cfg), "RecordErase");
    expect_ok(d->get_RecordCount(&value), "RecordCount");
    check(value == 1, "one record left");
    SysFreeString(cfg);

    // An undimensioned VB `Dim b() As Byte` arrives as a null SAFEARRAY.
    BSTR none = SysAllocString(L"empty");
    expect_ok(d->RecordWrite(none, nullptr), "empty record");
    read = nullptr;
    expect_ok(d->RecordRead(none, &read), "read the empty record");
    check(read != nullptr && length(read) == 0, "an empty record reads as an empty array");
    SafeArrayDestroy(read);
    SysFreeString(none);

    // --- counters ----------------------------------------------------------------
    long before = 0, after = 0;
    expect_ok(d->CounterRead(0, &before), "CounterRead");
    expect_ok(d->CounterIncrement(0, &after), "CounterIncrement");
    check(after == before + 1, "increment");
    expect_ok(d->CounterRead(1, &value), "second counter");
    check(value == 0, "counters");
    expect_status(d->CounterRead(7, &value), LICD_E_RANGE, "counter out of range");

    // --- app crypto --------------------------------------------------------------
    uint8_t secret[100];
    for (int k = 0; k < 100; k++) {
        secret[k] = (uint8_t)((3 * k + 7) % 256);
    }
    SAFEARRAY *plain = bytes(secret, sizeof(secret));
    for (int scope = 0; scope <= 1; scope++) {
        SAFEARRAY *sealed = nullptr, *opened = nullptr;
        expect_ok(d->AppEncrypt((KeyNubScope)scope, plain, &sealed), "AppEncrypt");
        check(length(sealed) > sizeof(secret) && byte_at(sealed, 0) == scope, "sealed data and scope byte");
        expect_ok(d->AppDecrypt(sealed, &opened), "AppDecrypt");
        check(same(opened, secret, sizeof(secret)), "round trip");
        SafeArrayDestroy(opened);
        opened = nullptr;
        flip_last(sealed);
        expect_status(d->AppDecrypt(sealed, &opened), LICD_E_TAG_MISMATCH, "tampered envelope");
        SafeArrayDestroy(sealed);
    }
    SAFEARRAY *sealed = nullptr;
    expect_status(d->AppEncrypt((KeyNubScope)7, plain, &sealed), LICD_E_INVALID_ARG, "unknown scope");
    SafeArrayDestroy(plain);

    expect_ok(d->RecordEraseAll(), "RecordEraseAll");
    expect_ok(d->get_RecordCount(&value), "RecordCount");
    check(value == 0, "erase all");

    // --- write-key rotation ------------------------------------------------------
    SAFEARRAY *replacement = bytes(REPLACEMENT_KEY, sizeof(REPLACEMENT_KEY));
    expect_ok(d->RotateWriteKey(replacement), "RotateWriteKey");
    expect_ok(d->RecordWrite(lic, data), "still writable");
    expect_ok(d->SessionClose(), "SessionClose");
    expect_ok(d->get_Flags(&value), "Flags");
    check((value & keynubFlagWriteAuthRotated) != 0, "rotated flag");
    expect_ok(d->SessionOpen(), "second session");
    expect_status(d->AuthorizeWrite(factory), LICD_E_NOT_GENUINE, "factory key after rotation");
    expect_status(d->RotateWriteKey(replacement), LICD_E_AUTH_REQUIRED, "rotation without the write role");
    expect_ok(d->AuthorizeWrite(replacement), "new key");
    expect_ok(d->RecordWrite(lic, data), "write with the new key");
    expect_ok(d->RecordEraseAll(), "cleanup");
    expect_ok(d->SessionClose(), "SessionClose");
    SafeArrayDestroy(replacement);
    SafeArrayDestroy(factory);
    SafeArrayDestroy(data);
    SysFreeString(lic);

    // --- close -------------------------------------------------------------------
    expect_ok(d->Close(), "Close");
    expect_ok(d->Close(), "Close twice");
    check(SUCCEEDED(d->get_IsOpen(&flag)) && flag == VARIANT_FALSE, "closed");
    expect_status(d->get_Serial(&text), LICD_E_NO_DEVICE, "Serial after Close");

    late_binding(d);
    check(d->Release() == 0, "the last reference destroys the object");

    // Dropping an open object closes its handle: more objects than the 32-slot
    // handle table, none of them closed.
    bool exhausted = false;
    for (int i = 0; i < 40 && !exhausted; i++) {
        IDongle *temp = create_dongle();
        BSTR s = SysAllocString(SERIAL);
        exhausted = temp == nullptr || FAILED(temp->Open(s));
        SysFreeString(s);
        if (temp != nullptr) {
            temp->Release();
        }
    }
    check(!exhausted, "40 objects dropped without Close do not exhaust the handles");

    typedef HRESULT(__stdcall * CanUnloadFn)(void);
    CanUnloadFn can_unload = (CanUnloadFn)GetProcAddress(server, "DllCanUnloadNow");
    check(can_unload != nullptr && can_unload() == S_OK, "DllCanUnloadNow once every object is gone");
    CoUninitialize();

    if (failures) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("KeyNub.Dongle: every call passed against the ABI stand-in\n");
    return 0;
}
