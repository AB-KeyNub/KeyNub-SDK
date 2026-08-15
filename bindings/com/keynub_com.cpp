// KeyNub License Dongle — COM / ActiveX server.
//
// An automation object over the flat C API (bindings/flat), for the languages that
// cannot safely call a cdecl export: VB6, twinBASIC, VBScript, and VBA hosts that
// would rather have an object than thirty Declare statements. See KeyNub.idl for
// the interface and the reasoning.
//
// DESIGN NOTES
//
// IDispatch is delegated to our own type library rather than hand-written. The
// typelib already describes every method, so ITypeInfo::Invoke can dispatch to the
// vtable for us; hand-rolling GetIDsOfNames/Invoke would duplicate that table in a
// second place and let the two drift. The cost is that the object needs its typelib
// available — either registered, or (the fallback below) read out of this DLL's own
// resources, which is why the .tlb is embedded via keynub_com.rc.
//
// Errors go out through ICreateErrorInfo/SetErrorInfo so Err.Description carries
// the SDK's diagnostic detail. The HRESULT is deliberately
// MAKE_HRESULT(SEVERITY_ERROR, FACILITY_ITF, 5000 + |status|), which VB6 reports as
// Err.Number = vbObjectError + 5000 + |status| — the exact numbering the VBA/flat
// binding already raises, so error-handling code reads the same in both.
//
// No ATL. It would shorten this file, but it is a per-Visual-Studio-install
// dependency for a DLL that has to build on any runner, and the parts used here are
// small enough to own outright.

#include <windows.h>
#include <objbase.h>
#include <oleauto.h>
#include <olectl.h> // SELFREG_E_CLASS

#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <vector>

#include "KeyNub_h.h" // MIDL-generated from KeyNub.idl
#include "licd_flat.h"

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

static HMODULE g_module = nullptr;
static LONG g_objectCount = 0; // live objects + handed-out class factories
static ITypeInfo *g_typeInfo = nullptr;
static INIT_ONCE g_typeInfoOnce = INIT_ONCE_STATIC_INIT;

// Progid and description are referenced by both the register and unregister paths.
static const wchar_t kProgId[] = L"KeyNub.Dongle";
static const wchar_t kDescription[] = L"KeyNub License Dongle";
static const wchar_t kClsidText[] = L"{335416C9-F790-454B-81B6-866020DB2A13}";

// ---------------------------------------------------------------------------
// Type information, for the delegated IDispatch
// ---------------------------------------------------------------------------

static BOOL CALLBACK LoadTypeInfoOnce(PINIT_ONCE, PVOID, PVOID *) {
    ITypeLib *lib = nullptr;

    // The registered typelib first: that is the one a client is already bound to.
    HRESULT hr = LoadRegTypeLib(LIBID_KeyNubLib, 1, 0, LOCALE_NEUTRAL, &lib);
    if (FAILED(hr)) {
        // Not registered (or registered for the other bitness). Fall back to the
        // copy embedded in this DLL, which makes the object usable from a
        // registration-free activation context where nothing is in the registry.
        wchar_t path[MAX_PATH];
        DWORD n = GetModuleFileNameW(g_module, path, MAX_PATH);
        if (n == 0 || n >= MAX_PATH) {
            return TRUE; // leaves g_typeInfo null; callers report E_UNEXPECTED
        }
        hr = LoadTypeLibEx(path, REGKIND_NONE, &lib);
    }
    if (FAILED(hr) || lib == nullptr) {
        return TRUE;
    }

    ITypeInfo *info = nullptr;
    hr = lib->GetTypeInfoOfGuid(IID_IDongle, &info);
    lib->Release();
    if (SUCCEEDED(hr)) {
        g_typeInfo = info; // released at process exit; one per module by design
    }
    return TRUE;
}

static HRESULT GetDongleTypeInfo(ITypeInfo **out) {
    InitOnceExecuteOnce(&g_typeInfoOnce, LoadTypeInfoOnce, nullptr, nullptr);
    if (g_typeInfo == nullptr) {
        return E_UNEXPECTED;
    }
    *out = g_typeInfo;
    return S_OK;
}

// ---------------------------------------------------------------------------
// Small conversions
// ---------------------------------------------------------------------------

// A BSTR is UTF-16; the flat API takes UTF-8. A null or empty BSTR becomes an empty
// string, which is what that API reads as "not specified".
static HRESULT Utf8FromBstr(BSTR src, std::string &out) {
    out.clear();
    if (src == nullptr) {
        return S_OK;
    }
    const UINT chars = SysStringLen(src);
    if (chars == 0) {
        return S_OK;
    }
    const int needed = WideCharToMultiByte(CP_UTF8, 0, src, (int)chars, nullptr, 0, nullptr, nullptr);
    if (needed <= 0) {
        return E_INVALIDARG;
    }
    out.resize((size_t)needed);
    if (WideCharToMultiByte(CP_UTF8, 0, src, (int)chars, &out[0], needed, nullptr, nullptr) <= 0) {
        return E_INVALIDARG;
    }
    return S_OK;
}

static HRESULT BstrFromUtf8(const char *src, BSTR *out) {
    *out = nullptr;
    if (src == nullptr || *src == '\0') {
        *out = SysAllocString(L""); // an empty BSTR, never null: VB6 prefers ""
        return (*out != nullptr) ? S_OK : E_OUTOFMEMORY;
    }
    const int chars = MultiByteToWideChar(CP_UTF8, 0, src, -1, nullptr, 0);
    if (chars <= 0) {
        return E_INVALIDARG;
    }
    // chars includes the NUL; SysAllocStringLen wants the length without it.
    BSTR result = SysAllocStringLen(nullptr, (UINT)(chars - 1));
    if (result == nullptr) {
        return E_OUTOFMEMORY;
    }
    if (MultiByteToWideChar(CP_UTF8, 0, src, -1, result, chars) <= 0) {
        SysFreeString(result);
        return E_INVALIDARG;
    }
    *out = result;
    return S_OK;
}

// Copies a one-dimensional byte SAFEARRAY out. A null array is an empty buffer, not
// an error: that is what an undimensioned VB6 `Dim b() As Byte` arrives as.
static HRESULT BytesFromSafeArray(SAFEARRAY *sa, std::vector<uint8_t> &out) {
    out.clear();
    if (sa == nullptr) {
        return S_OK;
    }
    if (SafeArrayGetDim(sa) != 1) {
        return E_INVALIDARG;
    }
    VARTYPE vt = VT_EMPTY;
    if (FAILED(SafeArrayGetVartype(sa, &vt)) || (vt != VT_UI1 && vt != VT_I1)) {
        return E_INVALIDARG;
    }
    LONG lo = 0, hi = 0;
    if (FAILED(SafeArrayGetLBound(sa, 1, &lo)) || FAILED(SafeArrayGetUBound(sa, 1, &hi))) {
        return E_INVALIDARG;
    }
    if (hi < lo) {
        return S_OK; // a legitimately empty array
    }
    const size_t count = (size_t)(hi - lo + 1);
    void *data = nullptr;
    HRESULT hr = SafeArrayAccessData(sa, &data);
    if (FAILED(hr)) {
        return hr;
    }
    out.assign((const uint8_t *)data, (const uint8_t *)data + count);
    SafeArrayUnaccessData(sa);
    return S_OK;
}

// Builds a 0-based byte SAFEARRAY, which is what VB6 `Byte()` expects to receive.
static HRESULT SafeArrayFromBytes(const uint8_t *data, size_t len, SAFEARRAY **out) {
    *out = nullptr;
    SAFEARRAY *sa = SafeArrayCreateVector(VT_UI1, 0, (ULONG)len);
    if (sa == nullptr) {
        return E_OUTOFMEMORY;
    }
    if (len > 0) {
        void *dest = nullptr;
        HRESULT hr = SafeArrayAccessData(sa, &dest);
        if (FAILED(hr)) {
            SafeArrayDestroy(sa);
            return hr;
        }
        memcpy(dest, data, len);
        SafeArrayUnaccessData(sa);
    }
    *out = sa;
    return S_OK;
}

// ---------------------------------------------------------------------------
// The object
// ---------------------------------------------------------------------------

class Dongle final : public IDongle, public ISupportErrorInfo {
  public:
    Dongle() : m_ref(1), m_handle(0), m_provisionedDate{} {
        InterlockedIncrement(&g_objectCount);
    }

    // --- IUnknown ---------------------------------------------------------
    STDMETHODIMP QueryInterface(REFIID riid, void **ppv) override {
        if (ppv == nullptr) {
            return E_POINTER;
        }
        if (riid == IID_IUnknown || riid == IID_IDispatch || riid == IID_IDongle) {
            *ppv = static_cast<IDongle *>(this);
        } else if (riid == IID_ISupportErrorInfo) {
            *ppv = static_cast<ISupportErrorInfo *>(this);
        } else {
            *ppv = nullptr;
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }

    STDMETHODIMP_(ULONG) AddRef() override { return (ULONG)InterlockedIncrement(&m_ref); }

    STDMETHODIMP_(ULONG) Release() override {
        const LONG n = InterlockedDecrement(&m_ref);
        if (n == 0) {
            delete this;
        }
        return (ULONG)n;
    }

    // --- ISupportErrorInfo ------------------------------------------------
    // Without this, VB6 discards the IErrorInfo we set and Err.Description falls
    // back to a generic "Automation error".
    STDMETHODIMP InterfaceSupportsErrorInfo(REFIID riid) override {
        return (riid == IID_IDongle) ? S_OK : S_FALSE;
    }

    // --- IDispatch, delegated to the typelib ------------------------------
    STDMETHODIMP GetTypeInfoCount(UINT *count) override {
        if (count == nullptr) {
            return E_POINTER;
        }
        *count = 1;
        return S_OK;
    }

    STDMETHODIMP GetTypeInfo(UINT index, LCID, ITypeInfo **out) override {
        if (out == nullptr) {
            return E_POINTER;
        }
        *out = nullptr;
        if (index != 0) {
            return DISP_E_BADINDEX;
        }
        ITypeInfo *info = nullptr;
        HRESULT hr = GetDongleTypeInfo(&info);
        if (FAILED(hr)) {
            return hr;
        }
        info->AddRef();
        *out = info;
        return S_OK;
    }

    STDMETHODIMP GetIDsOfNames(REFIID, LPOLESTR *names, UINT count, LCID,
                               DISPID *ids) override {
        ITypeInfo *info = nullptr;
        HRESULT hr = GetDongleTypeInfo(&info);
        if (FAILED(hr)) {
            return hr;
        }
        return info->GetIDsOfNames(names, count, ids);
    }

    STDMETHODIMP Invoke(DISPID id, REFIID, LCID, WORD flags, DISPPARAMS *params,
                        VARIANT *result, EXCEPINFO *excep, UINT *argErr) override {
        ITypeInfo *info = nullptr;
        HRESULT hr = GetDongleTypeInfo(&info);
        if (FAILED(hr)) {
            return hr;
        }
        return info->Invoke(static_cast<IDongle *>(this), id, flags, params, result, excep,
                            argErr);
    }

    // --- discovery --------------------------------------------------------
    STDMETHODIMP get_DeviceCount(long *value) override {
        if (value == nullptr) {
            return E_POINTER;
        }
        *value = 0;
        int32_t count = 0;
        const int32_t st = licdf_device_count(&count);
        if (st != LICD_OK) {
            return Fail(st, "could not enumerate dongles");
        }
        *value = count;
        return S_OK;
    }

    STDMETHODIMP DeviceSerial(long index, BSTR *value) override {
        return StringOut(value, [&](char *buf, int32_t cap) {
            return licdf_device_serial((int32_t)index, buf, cap);
        }, LICDF_SERIAL_SIZE, "no dongle at that index; read DeviceCount first");
    }

    STDMETHODIMP DevicePath(long index, BSTR *value) override {
        return StringOut(value, [&](char *buf, int32_t cap) {
            return licdf_device_path((int32_t)index, buf, cap);
        }, LICDF_PATH_SIZE, "no dongle at that index; read DeviceCount first");
    }

    // --- lifetime ---------------------------------------------------------
    STDMETHODIMP Open(BSTR serial) override {
        std::string wanted;
        HRESULT hr = Utf8FromBstr(serial, wanted);
        if (FAILED(hr)) {
            return hr;
        }
        if (m_handle > 0) {
            licdf_close(m_handle); // reopening is not an error; the old one is done
            m_handle = 0;
        }
        const int32_t rc = licdf_open(wanted.c_str());
        if (rc < 0) {
            return FailNoHandle(rc, "no KeyNub dongle could be opened");
        }
        m_handle = rc;
        return S_OK;
    }

    STDMETHODIMP OpenPath(BSTR path) override {
        std::string wanted;
        HRESULT hr = Utf8FromBstr(path, wanted);
        if (FAILED(hr)) {
            return hr;
        }
        if (wanted.empty()) {
            return FailNoHandle(LICD_E_INVALID_ARG, "OpenPath needs a device path");
        }
        if (m_handle > 0) {
            licdf_close(m_handle);
            m_handle = 0;
        }
        const int32_t rc = licdf_open_path(wanted.c_str());
        if (rc < 0) {
            return FailNoHandle(rc, "no KeyNub dongle at that path");
        }
        m_handle = rc;
        return S_OK;
    }

    STDMETHODIMP Close() override {
        if (m_handle > 0) {
            licdf_close(m_handle);
            m_handle = 0;
        }
        return S_OK; // idempotent on purpose: it belongs in an error handler
    }

    STDMETHODIMP get_IsOpen(VARIANT_BOOL *value) override {
        if (value == nullptr) {
            return E_POINTER;
        }
        *value = (m_handle > 0) ? VARIANT_TRUE : VARIANT_FALSE;
        return S_OK;
    }

    // --- info -------------------------------------------------------------
    STDMETHODIMP get_Serial(BSTR *value) override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        return StringOut(value, [&](char *buf, int32_t cap) {
            return licdf_get_serial(h, buf, cap);
        }, LICDF_SERIAL_SIZE, "could not read the serial");
    }

    STDMETHODIMP get_FirmwareVersion(BSTR *value) override {
        Info info;
        HRESULT hr = ReadInfo(&info);
        if (FAILED(hr)) {
            return hr;
        }
        char text[48];
        _snprintf_s(text, sizeof(text), _TRUNCATE, "%d.%d.%d", (int)info.fwMajor,
                    (int)info.fwMinor, (int)info.fwPatch);
        return BstrFromUtf8(text, value);
    }

    STDMETHODIMP get_ProtocolVersion(BSTR *value) override {
        Info info;
        HRESULT hr = ReadInfo(&info);
        if (FAILED(hr)) {
            return hr;
        }
        char text[32];
        _snprintf_s(text, sizeof(text), _TRUNCATE, "%d.%d", (int)info.protoMajor,
                    (int)info.protoMinor);
        return BstrFromUtf8(text, value);
    }

    STDMETHODIMP get_Flags(long *value) override {
        Info info;
        HRESULT hr = ReadInfo(&info);
        if (FAILED(hr)) {
            return hr;
        }
        if (value == nullptr) {
            return E_POINTER;
        }
        *value = info.flags;
        return S_OK;
    }

    STDMETHODIMP get_Capacity(long *value) override {
        Info info;
        HRESULT hr = ReadInfo(&info);
        if (FAILED(hr)) {
            return hr;
        }
        if (value == nullptr) {
            return E_POINTER;
        }
        *value = info.capacity;
        return S_OK;
    }

    STDMETHODIMP get_FreeBytes(long *value) override {
        Info info;
        HRESULT hr = ReadInfo(&info);
        if (FAILED(hr)) {
            return hr;
        }
        if (value == nullptr) {
            return E_POINTER;
        }
        *value = info.freeBytes;
        return S_OK;
    }

    // --- authenticity -----------------------------------------------------
    STDMETHODIMP get_IsGenuine(VARIANT_BOOL *value) override {
        if (value == nullptr) {
            return E_POINTER;
        }
        // The documented exception to the raising rule, and it fails closed: any
        // failure at all — not open, I/O, bad certificate — reports False.
        *value = VARIANT_FALSE;
        if (m_handle <= 0) {
            return S_OK;
        }
        int32_t genuine = 0;
        char serial[LICDF_SERIAL_SIZE] = {0};
        const int32_t st = licdf_verify_genuine(m_handle, &genuine, serial, sizeof(serial),
                                                nullptr, 0);
        if (st == LICD_OK && genuine != 0) {
            *value = VARIANT_TRUE;
        }
        return S_OK;
    }

    STDMETHODIMP VerifyGenuine(BSTR *certificateSerial) override {
        if (certificateSerial == nullptr) {
            return E_POINTER;
        }
        *certificateSerial = nullptr;
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        int32_t genuine = 0;
        char serial[LICDF_SERIAL_SIZE] = {0};
        const int32_t st = licdf_verify_genuine(h, &genuine, serial, sizeof(serial),
                                                m_provisionedDate, sizeof(m_provisionedDate));
        if (st != LICD_OK) {
            return Fail(st, "the dongle's identity could not be verified");
        }
        if (genuine == 0) {
            return Fail(LICD_E_NOT_GENUINE, "this dongle is not a genuine KeyNub dongle");
        }
        return BstrFromUtf8(serial, certificateSerial);
    }


    // --- session ----------------------------------------------------------
    STDMETHODIMP SessionOpen() override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        const int32_t st = licdf_session_open(h);
        return (st == LICD_OK) ? S_OK : Fail(st, "could not open a session");
    }

    STDMETHODIMP SessionClose() override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        const int32_t st = licdf_session_close(h);
        return (st == LICD_OK) ? S_OK : Fail(st, "could not close the session");
    }

    STDMETHODIMP AuthorizeWrite(SAFEARRAY *der) override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        std::vector<uint8_t> key;
        hr = BytesFromSafeArray(der, key);
        if (FAILED(hr)) {
            return hr;
        }
        if (key.empty()) {
            return Fail(LICD_E_INVALID_ARG, "AuthorizeWrite needs the developer key");
        }
        const int32_t st = licdf_write_auth(h, key.data(), (int32_t)key.size());
        return (st == LICD_OK) ? S_OK : Fail(st, "the developer key was not accepted");
    }

    STDMETHODIMP RotateWriteKey(SAFEARRAY *der) override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        std::vector<uint8_t> key;
        hr = BytesFromSafeArray(der, key);
        if (FAILED(hr)) {
            return hr;
        }
        if (key.empty()) {
            return Fail(LICD_E_INVALID_ARG, "RotateWriteKey needs the replacement key");
        }
        const int32_t st = licdf_write_auth_rotate(h, key.data(), (int32_t)key.size());
        return (st == LICD_OK) ? S_OK : Fail(st, "the replacement key was not accepted");
    }

    // --- records ----------------------------------------------------------
    STDMETHODIMP get_RecordCount(long *value) override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        if (value == nullptr) {
            return E_POINTER;
        }
        int32_t count = 0;
        const int32_t st = licdf_record_count(h, &count);
        if (st != LICD_OK) {
            return Fail(st, "could not list the records");
        }
        *value = count;
        return S_OK;
    }

    STDMETHODIMP RecordName(long index, BSTR *value) override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        int32_t size = 0;
        return StringOut(value, [&](char *buf, int32_t cap) {
            return licdf_record_name(h, (int32_t)index, buf, cap, &size);
        }, 64, "no record at that index");
    }

    STDMETHODIMP RecordSize(BSTR name, long *value) override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        if (value == nullptr) {
            return E_POINTER;
        }
        std::string key;
        hr = Utf8FromBstr(name, key);
        if (FAILED(hr)) {
            return hr;
        }
        int32_t size = 0;
        const int32_t st = licdf_record_size(h, key.c_str(), &size);
        if (st != LICD_OK) {
            return Fail(st, "could not read that record's size");
        }
        *value = size;
        return S_OK;
    }

    STDMETHODIMP RecordRead(BSTR name, SAFEARRAY **value) override {
        if (value == nullptr) {
            return E_POINTER;
        }
        *value = nullptr;
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        std::string key;
        hr = Utf8FromBstr(name, key);
        if (FAILED(hr)) {
            return hr;
        }

        // The flat API's two-call protocol: asking with no buffer reports the size
        // and LICD_E_RANGE. A zero-length record answers LICD_OK straight away, so
        // both outcomes are successes here.
        int32_t needed = 0;
        int32_t st = licdf_record_read(h, key.c_str(), nullptr, 0, &needed);
        if (st == LICD_OK) {
            return SafeArrayFromBytes(nullptr, 0, value);
        }
        if (st != LICD_E_RANGE) {
            return Fail(st, "could not read that record");
        }
        std::vector<uint8_t> buffer((size_t)needed);
        int32_t got = 0;
        st = licdf_record_read(h, key.c_str(), buffer.data(), needed, &got);
        if (st != LICD_OK) {
            return Fail(st, "could not read that record");
        }
        return SafeArrayFromBytes(buffer.data(), (size_t)got, value);
    }

    STDMETHODIMP RecordWrite(BSTR name, SAFEARRAY *data) override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        std::string key;
        hr = Utf8FromBstr(name, key);
        if (FAILED(hr)) {
            return hr;
        }
        std::vector<uint8_t> payload;
        hr = BytesFromSafeArray(data, payload);
        if (FAILED(hr)) {
            return hr;
        }
        const int32_t st = licdf_record_write(h, key.c_str(), payload.data(),
                                              (int32_t)payload.size());
        return (st == LICD_OK) ? S_OK : Fail(st, "could not write that record");
    }

    STDMETHODIMP RecordErase(BSTR name) override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        std::string key;
        hr = Utf8FromBstr(name, key);
        if (FAILED(hr)) {
            return hr;
        }
        // Guarded here as well as in the C library: an empty name must never be
        // read as "erase everything".
        if (key.empty()) {
            return Fail(LICD_E_INVALID_ARG,
                        "RecordErase needs a name; use RecordEraseAll to erase everything");
        }
        const int32_t st = licdf_record_erase(h, key.c_str());
        return (st == LICD_OK) ? S_OK : Fail(st, "could not erase that record");
    }

    STDMETHODIMP RecordEraseAll() override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        const int32_t st = licdf_record_erase_all(h);
        return (st == LICD_OK) ? S_OK : Fail(st, "could not erase the records");
    }

    // --- counters ---------------------------------------------------------
    STDMETHODIMP CounterRead(long counterId, long *value) override {
        return CounterOp(counterId, value, false);
    }

    STDMETHODIMP CounterIncrement(long counterId, long *value) override {
        return CounterOp(counterId, value, true);
    }

    // --- app crypto -------------------------------------------------------
    STDMETHODIMP AppEncrypt(KeyNubScope scope, SAFEARRAY *plaintext,
                            SAFEARRAY **value) override {
        if (value == nullptr) {
            return E_POINTER;
        }
        *value = nullptr;
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        std::vector<uint8_t> input;
        hr = BytesFromSafeArray(plaintext, input);
        if (FAILED(hr)) {
            return hr;
        }
        if (input.empty()) {
            return Fail(LICD_E_INVALID_ARG, "AppEncrypt needs something to encrypt");
        }
        int32_t needed = 0;
        int32_t st = licdf_app_encrypt(h, (int32_t)scope, input.data(), (int32_t)input.size(),
                                        nullptr, 0, &needed);
        if (st != LICD_E_RANGE) {
            return Fail(st == LICD_OK ? LICD_E_INTERNAL : st, "could not encrypt");
        }
        std::vector<uint8_t> out((size_t)needed);
        int32_t got = 0;
        st = licdf_app_encrypt(h, (int32_t)scope, input.data(), (int32_t)input.size(), out.data(),
                                needed, &got);
        if (st != LICD_OK) {
            return Fail(st, "could not encrypt");
        }
        return SafeArrayFromBytes(out.data(), (size_t)got, value);
    }

    STDMETHODIMP AppDecrypt(SAFEARRAY *packed, SAFEARRAY **value) override {
        if (value == nullptr) {
            return E_POINTER;
        }
        *value = nullptr;
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        std::vector<uint8_t> input;
        hr = BytesFromSafeArray(packed, input);
        if (FAILED(hr)) {
            return hr;
        }
        if (input.empty()) {
            return Fail(LICD_E_INVALID_ARG, "AppDecrypt needs an envelope to decrypt");
        }
        int32_t needed = 0;
        int32_t st =
            licdf_app_decrypt(h, input.data(), (int32_t)input.size(), nullptr, 0, &needed);
        if (st == LICD_OK) {
            return SafeArrayFromBytes(nullptr, 0, value);
        }
        if (st != LICD_E_RANGE) {
            return Fail(st, "the envelope could not be decrypted");
        }
        std::vector<uint8_t> out((size_t)needed);
        int32_t got = 0;
        st = licdf_app_decrypt(h, input.data(), (int32_t)input.size(), out.data(), needed, &got);
        if (st != LICD_OK) {
            return Fail(st, "the envelope could not be decrypted");
        }
        return SafeArrayFromBytes(out.data(), (size_t)got, value);
    }

    // --- diagnostics ------------------------------------------------------
    STDMETHODIMP SetTrustRoot(SAFEARRAY *der) override {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        std::vector<uint8_t> root;
        hr = BytesFromSafeArray(der, root);
        if (FAILED(hr)) {
            return hr;
        }
        if (root.empty()) {
            return Fail(LICD_E_INVALID_ARG, "SetTrustRoot needs a DER certificate");
        }
        const int32_t st = licdf_set_trust_root(h, root.data(), (int32_t)root.size());
        return (st == LICD_OK) ? S_OK : Fail(st, "that trust root was not accepted");
    }

    // "YYYY-MM-DD" for the dongle VerifyGenuine last confirmed, or "" when it
    // reported none or has not been called. Informational: no licensing decision
    // should turn on it.
    STDMETHODIMP get_ProvisionedDate(BSTR *value) override {
        if (value == nullptr) {
            return E_POINTER;
        }
        return StringOut(value, [&](char *buf, int32_t cap) {
            // Same convention as the flat layer's copy_string: RANGE when the
            // buffer cannot hold the value, rather than a truncated date.
            if (cap < (int32_t)sizeof(m_provisionedDate)) {
                return (int32_t)LICD_E_RANGE;
            }
            memcpy(buf, m_provisionedDate, sizeof(m_provisionedDate));
            return (int32_t)LICD_OK;
        }, LICDF_DATE_SIZE, "could not read the personalisation date");
    }

    STDMETHODIMP get_LastError(BSTR *value) override {
        char detail[LICDF_ERROR_SIZE] = {0};
        if (m_handle > 0) {
            licdf_last_error(m_handle, detail, sizeof(detail));
        }
        return BstrFromUtf8(detail, value);
    }

    STDMETHODIMP get_Version(BSTR *value) override {
        int32_t major = 0, minor = 0, patch = 0;
        const int32_t st = licdf_version(&major, &minor, &patch);
        if (st != LICD_OK) {
            return Fail(st, "could not read the SDK version");
        }
        char text[48];
        _snprintf_s(text, sizeof(text), _TRUNCATE, "%d.%d.%d", (int)major, (int)minor,
                    (int)patch);
        return BstrFromUtf8(text, value);
    }

  private:
    ~Dongle() {
        // The point of the object model: a dropped reference releases the dongle,
        // so a VB6 Exit Sub that skips Close cannot leak a handle out of the
        // library's 32-slot table.
        if (m_handle > 0) {
            licdf_close(m_handle);
        }
        InterlockedDecrement(&g_objectCount);
    }

    struct Info {
        int32_t protoMajor, protoMinor, fwMajor, fwMinor, fwPatch;
        int32_t flags, capacity, freeBytes;
    };

    HRESULT RequireOpen(int32_t *out) {
        if (m_handle <= 0) {
            return FailNoHandle(LICD_E_NO_DEVICE, "no dongle is open; call Open first");
        }
        *out = m_handle;
        return S_OK;
    }

    HRESULT ReadInfo(Info *out) {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        memset(out, 0, sizeof(*out));
        const int32_t st =
            licdf_get_info(h, &out->protoMajor, &out->protoMinor, &out->fwMajor, &out->fwMinor,
                           &out->fwPatch, &out->flags, &out->capacity, &out->freeBytes);
        return (st == LICD_OK) ? S_OK : Fail(st, "could not read the dongle's information");
    }

    HRESULT CounterOp(long counterId, long *value, bool increment) {
        int32_t h = 0;
        HRESULT hr = RequireOpen(&h);
        if (FAILED(hr)) {
            return hr;
        }
        if (value == nullptr) {
            return E_POINTER;
        }
        int32_t result = 0;
        const int32_t st = increment ? licdf_counter_increment(h, (int32_t)counterId, &result)
                                     : licdf_counter_read(h, (int32_t)counterId, &result);
        if (st != LICD_OK) {
            return Fail(st, increment ? "could not increment that counter"
                                      : "could not read that counter");
        }
        *value = result;
        return S_OK;
    }

    // Wraps the flat API's fixed-buffer string calls. `hint` is the size that
    // should always be enough; LICD_E_RANGE still retries at the reported size so a
    // grown buffer in the C library cannot truncate here.
    template <typename Call>
    HRESULT StringOut(BSTR *value, Call call, int32_t hint, const char *whatFailed) {
        if (value == nullptr) {
            return E_POINTER;
        }
        *value = nullptr;
        std::vector<char> buffer((size_t)(hint > 0 ? hint : 64));
        int32_t st = call(buffer.data(), (int32_t)buffer.size());
        if (st == LICD_E_RANGE) {
            buffer.assign(buffer.size() * 4, '\0');
            st = call(buffer.data(), (int32_t)buffer.size());
        }
        if (st != LICD_OK) {
            return Fail(st, whatFailed);
        }
        buffer.back() = '\0';
        return BstrFromUtf8(buffer.data(), value);
    }

    // Reports a failure the way VB6 expects: an HRESULT it maps to Err.Number, plus
    // IErrorInfo carrying the SDK's own detail for Err.Description. Prefers the
    // per-handle diagnostic, falls back to the generic text for the status code, and
    // finally to the caller's description.
    HRESULT Fail(int32_t status, const char *whatFailed) {
        char detail[LICDF_ERROR_SIZE] = {0};
        if (m_handle > 0) {
            licdf_last_error(m_handle, detail, sizeof(detail));
        }
        return RaiseStatus(status, whatFailed, detail);
    }

    // The same, for the paths where there is no handle to ask (Open itself, and the
    // not-open guard).
    static HRESULT FailNoHandle(int32_t status, const char *whatFailed) {
        return RaiseStatus(status, whatFailed, "");
    }

    static HRESULT RaiseStatus(int32_t status, const char *whatFailed, const char *detail) {
        char generic[LICDF_ERROR_SIZE] = {0};
        licdf_strerror(status, generic, sizeof(generic));

        std::string message = (whatFailed != nullptr && *whatFailed != '\0')
                                  ? std::string(whatFailed)
                                  : std::string(generic);
        if (detail != nullptr && *detail != '\0') {
            message += " (";
            message += detail;
            message += ")";
        } else if (whatFailed != nullptr && *whatFailed != '\0' && generic[0] != '\0') {
            message += " (";
            message += generic;
            message += ")";
        }

        ICreateErrorInfo *create = nullptr;
        if (SUCCEEDED(CreateErrorInfo(&create)) && create != nullptr) {
            BSTR text = nullptr;
            if (SUCCEEDED(BstrFromUtf8(message.c_str(), &text))) {
                create->SetDescription(text);
                SysFreeString(text);
            }
            BSTR source = SysAllocString(kProgId);
            if (source != nullptr) {
                create->SetSource(source);
                SysFreeString(source);
            }
            create->SetGUID(IID_IDongle);
            IErrorInfo *errorInfo = nullptr;
            if (SUCCEEDED(create->QueryInterface(IID_IErrorInfo, (void **)&errorInfo))) {
                SetErrorInfo(0, errorInfo);
                errorInfo->Release();
            }
            create->Release();
        }

        const int32_t magnitude = (status < 0) ? -status : status;
        // 5000 + |status| matches the numbering the VBA binding raises, so error
        // handlers written against either one read identically.
        return MAKE_HRESULT(SEVERITY_ERROR, FACILITY_ITF, (unsigned)(5000 + magnitude));
    }

    LONG m_ref;
    int32_t m_handle;
    // Filled by VerifyGenuine, read by get_ProvisionedDate. Cached rather than
    // re-fetched because the property must not silently perform a full identity
    // check -- a caller reading a date should not pay for a round trip it did
    // not ask for, nor get a different answer than the VerifyGenuine it just ran.
    char m_provisionedDate[LICDF_DATE_SIZE];
};

// ---------------------------------------------------------------------------
// Class factory
// ---------------------------------------------------------------------------

class DongleFactory final : public IClassFactory {
  public:
    STDMETHODIMP QueryInterface(REFIID riid, void **ppv) override {
        if (ppv == nullptr) {
            return E_POINTER;
        }
        if (riid == IID_IUnknown || riid == IID_IClassFactory) {
            *ppv = static_cast<IClassFactory *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    // A single static instance, so its lifetime is the module's. LockServer still
    // moves the object count, which is what DllCanUnloadNow reads.
    STDMETHODIMP_(ULONG) AddRef() override { return 1; }
    STDMETHODIMP_(ULONG) Release() override { return 1; }

    STDMETHODIMP CreateInstance(IUnknown *outer, REFIID riid, void **ppv) override {
        if (ppv == nullptr) {
            return E_POINTER;
        }
        *ppv = nullptr;
        if (outer != nullptr) {
            return CLASS_E_NOAGGREGATION;
        }
        Dongle *object = new (std::nothrow) Dongle();
        if (object == nullptr) {
            return E_OUTOFMEMORY;
        }
        const HRESULT hr = object->QueryInterface(riid, ppv);
        object->Release();
        return hr;
    }

    STDMETHODIMP LockServer(BOOL lock) override {
        if (lock) {
            InterlockedIncrement(&g_objectCount);
        } else {
            InterlockedDecrement(&g_objectCount);
        }
        return S_OK;
    }
};

static DongleFactory g_factory;

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

// Writes one string value, creating the key. Returns a Win32 error code.
static LONG WriteKey(HKEY root, const wchar_t *subKey, const wchar_t *name,
                     const wchar_t *value) {
    HKEY key = nullptr;
    LONG rc = RegCreateKeyExW(root, subKey, 0, nullptr, REG_OPTION_NON_VOLATILE, KEY_WRITE,
                              nullptr, &key, nullptr);
    if (rc != ERROR_SUCCESS) {
        return rc;
    }
    rc = RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)value,
                        (DWORD)((wcslen(value) + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
    return rc;
}

// Registers every key under one root, so the whole set lands in the same place.
// `classes` is either HKLM\Software\Classes (machine-wide, needs elevation) or
// HKCU\Software\Classes (this user, no elevation).
static LONG RegisterUnder(HKEY classes, const wchar_t *modulePath) {
    std::wstring clsidKey = std::wstring(L"CLSID\\") + kClsidText;

    LONG rc = WriteKey(classes, clsidKey.c_str(), nullptr, kDescription);
    if (rc != ERROR_SUCCESS) {
        return rc;
    }
    rc = WriteKey(classes, (clsidKey + L"\\InprocServer32").c_str(), nullptr, modulePath);
    if (rc != ERROR_SUCCESS) {
        return rc;
    }
    // Apartment: VB6 and VBA are STA hosts, and the flat API serializes its own
    // calls, so there is nothing to gain from claiming Both.
    rc = WriteKey(classes, (clsidKey + L"\\InprocServer32").c_str(), L"ThreadingModel",
                  L"Apartment");
    if (rc != ERROR_SUCCESS) {
        return rc;
    }
    rc = WriteKey(classes, (clsidKey + L"\\ProgID").c_str(), nullptr, kProgId);
    if (rc != ERROR_SUCCESS) {
        return rc;
    }
    rc = WriteKey(classes, (clsidKey + L"\\VersionIndependentProgID").c_str(), nullptr, kProgId);
    if (rc != ERROR_SUCCESS) {
        return rc;
    }
    rc = WriteKey(classes, (clsidKey + L"\\TypeLib").c_str(), nullptr,
                  L"{2C529A65-017E-422C-A515-BD9FEB0AA6EB}");
    if (rc != ERROR_SUCCESS) {
        return rc;
    }
    rc = WriteKey(classes, (clsidKey + L"\\Version").c_str(), nullptr, L"1.0");
    if (rc != ERROR_SUCCESS) {
        return rc;
    }
    rc = WriteKey(classes, kProgId, nullptr, kDescription);
    if (rc != ERROR_SUCCESS) {
        return rc;
    }
    return WriteKey(classes, (std::wstring(kProgId) + L"\\CLSID").c_str(), nullptr, kClsidText);
}

static void DeleteTreeUnder(HKEY classes) {
    std::wstring clsidKey = std::wstring(L"CLSID\\") + kClsidText;
    RegDeleteTreeW(classes, clsidKey.c_str());
    RegDeleteTreeW(classes, kProgId);
}

// Opens HKLM\Software\Classes for writing, or nullptr if not permitted.
static HKEY OpenMachineClasses() {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, L"Software\\Classes", 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &key,
                        nullptr) == ERROR_SUCCESS) {
        return key;
    }
    return nullptr;
}

static HKEY OpenUserClasses() {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes", 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &key,
                        nullptr) == ERROR_SUCCESS) {
        return key;
    }
    return nullptr;
}

extern "C" HRESULT __stdcall DllRegisterServer(void) {
    wchar_t modulePath[MAX_PATH];
    DWORD n = GetModuleFileNameW(g_module, modulePath, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
        return SELFREG_E_CLASS;
    }

    ITypeLib *lib = nullptr;
    if (FAILED(LoadTypeLibEx(modulePath, REGKIND_NONE, &lib)) || lib == nullptr) {
        return SELFREG_E_TYPELIB;
    }

    // Machine-wide if we can, this user only if we cannot. An unelevated
    // regsvr32 therefore installs for the current user instead of failing, which
    // is what a developer on a locked-down machine needs.
    bool perUser = false;
    HKEY classes = OpenMachineClasses();
    if (classes == nullptr) {
        classes = OpenUserClasses();
        perUser = true;
    }
    if (classes == nullptr) {
        lib->Release();
        return SELFREG_E_CLASS;
    }

    LONG rc = RegisterUnder(classes, modulePath);
    RegCloseKey(classes);

    HRESULT hr = S_OK;
    if (rc != ERROR_SUCCESS) {
        hr = SELFREG_E_CLASS;
    } else {
        hr = perUser ? RegisterTypeLibForUser(lib, modulePath, nullptr)
                     : RegisterTypeLib(lib, modulePath, nullptr);
        if (FAILED(hr)) {
            hr = SELFREG_E_TYPELIB;
        }
    }
    lib->Release();
    return hr;
}

extern "C" HRESULT __stdcall DllUnregisterServer(void) {
    // Both roots are cleaned regardless of which one was used: a DLL registered
    // per-user and later unregistered elevated (or the reverse) should not leave
    // half a registration behind.
    HKEY machine = OpenMachineClasses();
    if (machine != nullptr) {
        DeleteTreeUnder(machine);
        RegCloseKey(machine);
    }
    HKEY user = OpenUserClasses();
    if (user != nullptr) {
        DeleteTreeUnder(user);
        RegCloseKey(user);
    }

    // Both SYSKINDs, because the 64-bit server registers its typelib as SYS_WIN64
    // and asking for SYS_WIN32 removes nothing. The one that was never there
    // returns an error that is correctly ignored; leaving the key behind is the
    // failure that matters, since the next client binds to it.
    for (SYSKIND kind : {SYS_WIN32, SYS_WIN64}) {
        UnRegisterTypeLib(LIBID_KeyNubLib, 1, 0, LOCALE_NEUTRAL, kind);
        UnRegisterTypeLibForUser(LIBID_KeyNubLib, 1, 0, LOCALE_NEUTRAL, kind);
    }
    return S_OK;
}

// ---------------------------------------------------------------------------
// DLL entry points
// ---------------------------------------------------------------------------

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID rclsid, REFIID riid, void **ppv) {
    if (ppv == nullptr) {
        return E_POINTER;
    }
    *ppv = nullptr;
    if (rclsid != CLSID_Dongle) {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    return g_factory.QueryInterface(riid, ppv);
}

extern "C" HRESULT __stdcall DllCanUnloadNow(void) {
    return (InterlockedCompareExchange(&g_objectCount, 0, 0) == 0) ? S_OK : S_FALSE;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = (HMODULE)instance;
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}
