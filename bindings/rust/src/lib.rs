//! Rust binding for the KeyNub USB-C license dongle.
//!
//! ```no_run
//! use keynub_licdongle::{Context, Scope};
//!
//! # fn main() -> Result<(), keynub_licdongle::Error> {
//! let ctx = Context::new()?;
//! let dongle = ctx.open(None)?;          // first dongle, or Some("serial")
//! dongle.verify_genuine()?;              // errors unless genuine
//!
//! let session = dongle.open_session()?;
//! let sealed = session.app_encrypt(Scope::Developer, b"what the program needs")?;
//! let data = session.app_decrypt(&sealed)?; // <- build the licence check on this
//! # let _ = data;
//! # Ok(())
//! # }
//! ```
//!
//! No dependencies beyond `std`. Everything closes itself in the right order, and
//! the lifetimes make the ordering a compile error rather than a runtime one: a
//! [`Session`] borrows its [`Dongle`], which borrows its [`Context`], so the
//! use-after-free that every other binding has to defend against at runtime cannot
//! be written here at all.
//!
//! # Where the licence check goes
//!
//! Read `docs/integration-security.md` before writing one. `if
//! dongle.is_genuine()` compiles to a conditional jump, and patching one of those
//! in a release binary is a beginner exercise — Rust's safety guarantees stop at
//! the machine code, and they were never about an adversary with a debugger. Route
//! something the program genuinely needs through [`Session::app_encrypt`] and
//! [`Session::app_decrypt`], so removing the check removes the data.

#![warn(missing_docs)]

pub mod sys;

use core::ffi::{c_char, c_int, c_void};
use std::ffi::{CStr, CString};
use std::fmt;
use std::marker::PhantomData;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

// ============================================================================
// Errors
// ============================================================================

/// Why an operation failed. Mirrors `licd_status`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum Status {
    /// A bad argument from the caller.
    InvalidArgument,
    /// No matching dongle found, or none present.
    NoDevice,
    /// The OS denied access to the device (udev rule missing, or macOS TCC).
    AccessDenied,
    /// Transport read/write failure.
    Io,
    /// The device did not respond in time.
    Timeout,
    /// A malformed or unexpected protocol response.
    Protocol,
    /// The authenticity check failed.
    NotGenuine,
    /// The device certificate or its chain to the trusted root was invalid.
    CertificateInvalid,
    /// No session, or the session expired.
    SessionExpired,
    /// AEAD tag verification failed — the data was tampered with.
    TagMismatch,
    /// Offset or length out of range.
    Range,
    /// The dongle's data area is full.
    StorageFull,
    /// The device is busy with a prior operation.
    Busy,
    /// The named record does not exist.
    NotFound,
    /// The operation needs the write role (see [`Session::authorize_write`]).
    AuthRequired,
    /// The firmware speaks a newer protocol than this SDK.
    FirmwareIncompatible,
    /// The same condition, from the SDK's point of view.
    SdkTooOld,
    /// Cancelled from a progress callback.
    Cancelled,
    /// Declared but not implemented in this build.
    NotImplemented,
    /// Internal or unrecognised failure.
    Internal,
}

impl Status {
    fn from_raw(status: c_int) -> Self {
        match status {
            sys::LICD_E_INVALID_ARG => Status::InvalidArgument,
            sys::LICD_E_NO_DEVICE => Status::NoDevice,
            sys::LICD_E_ACCESS_DENIED => Status::AccessDenied,
            sys::LICD_E_IO => Status::Io,
            sys::LICD_E_TIMEOUT => Status::Timeout,
            sys::LICD_E_PROTOCOL => Status::Protocol,
            sys::LICD_E_NOT_GENUINE => Status::NotGenuine,
            sys::LICD_E_CERT_INVALID => Status::CertificateInvalid,
            sys::LICD_E_SESSION_EXPIRED => Status::SessionExpired,
            sys::LICD_E_TAG_MISMATCH => Status::TagMismatch,
            sys::LICD_E_RANGE => Status::Range,
            sys::LICD_E_STORAGE_FULL => Status::StorageFull,
            sys::LICD_E_BUSY => Status::Busy,
            sys::LICD_E_NOT_FOUND => Status::NotFound,
            sys::LICD_E_AUTH_REQUIRED => Status::AuthRequired,
            sys::LICD_E_FW_INCOMPATIBLE => Status::FirmwareIncompatible,
            sys::LICD_E_SDK_TOO_OLD => Status::SdkTooOld,
            sys::LICD_E_CANCELLED => Status::Cancelled,
            sys::LICD_E_NOT_IMPLEMENTED => Status::NotImplemented,
            _ => Status::Internal,
        }
    }
}

/// A failed dongle operation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    /// Which failure this is. Match on it rather than on the message.
    pub status: Status,
    /// The C function that failed.
    pub operation: &'static str,
    /// The SDK's diagnostic detail, or empty. Log it; do not parse it.
    pub detail: String,
    message: String,
}

impl Error {
    fn new(status: c_int, operation: &'static str, detail: String) -> Self {
        let message = unsafe { cstr_to_string(sys::licd_strerror(status)) };
        Error {
            status: Status::from_raw(status),
            operation,
            detail,
            message,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.operation, self.message)?;
        if !self.detail.is_empty() {
            write!(f, " ({})", self.detail)?;
        }
        Ok(())
    }
}

impl std::error::Error for Error {}

/// The result of every fallible operation in this crate.
pub type Result<T> = std::result::Result<T, Error>;

// ============================================================================
// Plain data
// ============================================================================

/// Who can decrypt data produced by [`Session::app_encrypt`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// Only this one physical dongle.
    Device,
    /// Any dongle issued by the same developer — one blob for every customer.
    Developer,
}

/// The SDK's semantic version.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Version {
    /// Major.
    pub major: i32,
    /// Minor.
    pub minor: i32,
    /// Patch.
    pub patch: i32,
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// One discovered dongle, from [`Context::enumerate`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceInfo {
    /// Serial as hex, or empty when unavailable.
    pub serial: String,
    /// Opaque platform path; pass to [`Context::open_path`].
    pub path: String,
    /// USB vendor id.
    pub vendor_id: u16,
    /// USB product id.
    pub product_id: u16,
}

/// Plaintext device info, from [`Dongle::info`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Info {
    /// Wire protocol version, `(major, minor)`.
    pub protocol_version: (u8, u8),
    /// Firmware version, `(major, minor, patch)`.
    pub firmware_version: (u8, u8, u8),
    /// The secure element responded.
    pub se_ready: bool,
    /// Factory provisioning is complete.
    pub provisioned: bool,
    /// Data area size in bytes.
    pub data_capacity: u32,
    /// Bytes still free.
    pub data_free: u32,
    /// The dongle's *previous* boot ended in a watchdog timeout: the firmware
    /// hung and reset itself. The only trace a field hang leaves behind, and a
    /// power cycle clears it — worth logging.
    pub watchdog_reboot: bool,
    /// Whether the dongle confirmed at boot that its USB and parsing code is fenced off
    /// from keys and storage. Anything that is not a dongle reports false.
    pub isolated: bool,
    /// Whether the write-auth key has been rotated away from the factory one. That key
    /// is public, so a dongle reporting false accepts writes from anyone holding it.
    pub writeauth_rotated: bool,
}

/// The verified identity from [`Dongle::verify_genuine`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenuineResult {
    /// True when authenticity was proven.
    pub genuine: bool,
    /// Device serial, taken from the certificate.
    pub serial: String,
    /// `YYYY-MM-DD`, or empty.
    pub provisioned_date: String,
}

/// A record stored on the dongle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordInfo {
    /// Record name.
    pub name: String,
    /// Size in bytes.
    pub size: u32,
}

// ============================================================================
// Internals
// ============================================================================

unsafe fn cstr_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        String::new()
    } else {
        CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}

fn fixed_to_string(buf: &[c_char]) -> String {
    let bytes: Vec<u8> = buf
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

fn c_name(name: &str, operation: &'static str) -> Result<CString> {
    CString::new(name).map_err(|_| Error {
        status: Status::InvalidArgument,
        operation,
        detail: String::new(),
        message: "the name must not contain a NUL byte".to_string(),
    })
}

/// Carries a Rust closure across the C callback boundary, holding a panic until
/// the SDK has unwound its own transfer.
struct ProgressBridge<'a> {
    callback: &'a mut dyn FnMut(u32, u32) -> bool,
    panic: Option<Box<dyn std::any::Any + Send>>,
}

unsafe extern "C" fn progress_trampoline(done: u32, total: u32, user: *mut c_void) -> c_int {
    let bridge = &mut *(user as *mut ProgressBridge);
    if bridge.panic.is_some() {
        return 0;
    }
    // Unwinding across an "extern C" frame is undefined behaviour, so a panic is
    // caught here, the transfer cancelled, and the panic resumed afterwards.
    match catch_unwind(AssertUnwindSafe(|| (bridge.callback)(done, total))) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(payload) => {
            bridge.panic = Some(payload);
            0
        }
    }
}

// ============================================================================
// Context
// ============================================================================

/// The library context: the entry point for finding and opening dongles.
///
/// Thread-safe, per the C ABI's contract. Dropping it releases the library's
/// resources; the borrow checker guarantees no [`Dongle`] outlives it.
pub struct Context {
    ptr: NonNull<sys::licd_ctx>,
}

// The C ABI documents licd_ctx as thread-safe.
unsafe impl Send for Context {}
unsafe impl Sync for Context {}

impl Context {
    /// Creates a context.
    pub fn new() -> Result<Self> {
        let mut ptr: *mut sys::licd_ctx = core::ptr::null_mut();
        let rc = unsafe { sys::licd_init(&mut ptr) };
        if rc != sys::LICD_OK {
            return Err(Error::new(rc, "licd_init", String::new()));
        }
        NonNull::new(ptr).map(|ptr| Context { ptr }).ok_or_else(|| {
            Error::new(sys::LICD_E_INTERNAL, "licd_init", String::new())
        })
    }

    /// The native core library's version.
    pub fn library_version() -> Version {
        let (mut major, mut minor, mut patch) = (0, 0, 0);
        unsafe { sys::licd_version(&mut major, &mut minor, &mut patch) };
        Version {
            major,
            minor,
            patch,
        }
    }

    fn detail(&self) -> String {
        unsafe { cstr_to_string(sys::licd_error_detail(self.ptr.as_ptr())) }
    }

    fn check(&self, rc: c_int, operation: &'static str) -> Result<()> {
        if rc == sys::LICD_OK {
            Ok(())
        } else {
            Err(Error::new(rc, operation, self.detail()))
        }
    }

    /// The diagnostic detail for the most recent failure on this thread.
    pub fn last_error_detail(&self) -> String {
        self.detail()
    }

    /// The raw handle, for mixing this crate with direct FFI calls.
    ///
    /// # Safety
    /// The pointer is valid only while `self` is alive, and the C ABI's threading
    /// rules apply to anything done with it.
    pub unsafe fn as_raw(&self) -> *mut sys::licd_ctx {
        self.ptr.as_ptr()
    }

    /// Overrides the CA root that [`Dongle::verify_genuine`] checks against.
    ///
    /// Applications do not need this: a release build embeds the KeyNub
    /// production root. It exists for dongles provisioned against a development
    /// CA, and for vendor tooling.
    pub fn set_trust_root(&self, der: &[u8]) -> Result<()> {
        let rc =
            unsafe { sys::licd_set_trust_root(self.ptr.as_ptr(), der.as_ptr(), der.len()) };
        self.check(rc, "licd_set_trust_root")
    }

    /// Lists the connected dongles. Empty when none are attached.
    pub fn enumerate(&self) -> Result<Vec<DeviceInfo>> {
        let mut list: *mut sys::licd_device_info = core::ptr::null_mut();
        let mut count: usize = 0;
        let rc = unsafe { sys::licd_enumerate(self.ptr.as_ptr(), &mut list, &mut count) };
        self.check(rc, "licd_enumerate")?;

        let mut out = Vec::with_capacity(count);
        if !list.is_null() {
            for i in 0..count {
                let entry = unsafe { &*list.add(i) };
                out.push(DeviceInfo {
                    serial: fixed_to_string(&entry.serial),
                    path: fixed_to_string(&entry.path),
                    vendor_id: entry.vendor_id,
                    product_id: entry.product_id,
                });
            }
            unsafe { sys::licd_free_device_list(list, count) };
        }
        Ok(out)
    }

    /// Opens the dongle with this serial, or the first one found when `None`.
    pub fn open(&self, serial: Option<&str>) -> Result<Dongle<'_>> {
        let c_serial = match serial {
            Some(s) => Some(c_name(s, "licd_open")?),
            None => None,
        };
        let ptr_arg = c_serial
            .as_ref()
            .map_or(core::ptr::null(), |s| s.as_ptr());
        let mut dev: *mut sys::licd_device = core::ptr::null_mut();
        let rc = unsafe { sys::licd_open(self.ptr.as_ptr(), ptr_arg, &mut dev) };
        self.check(rc, "licd_open")?;
        Ok(unsafe { Dongle::from_raw(self, dev) })
    }

    /// Opens a specific dongle by the path from [`Context::enumerate`].
    pub fn open_path(&self, path: &str) -> Result<Dongle<'_>> {
        let c_path = c_name(path, "licd_open_path")?;
        let mut dev: *mut sys::licd_device = core::ptr::null_mut();
        let rc = unsafe { sys::licd_open_path(self.ptr.as_ptr(), c_path.as_ptr(), &mut dev) };
        self.check(rc, "licd_open_path")?;
        Ok(unsafe { Dongle::from_raw(self, dev) })
    }

    /// Adopts a device opened through the C ABI directly.
    ///
    /// Lets an existing codebase move to this crate a function at a time, and is
    /// how a test harness wraps a simulated device.
    ///
    /// # Safety
    /// `dev` must be a live `licd_device` belonging to this context, and must not
    /// be closed by anyone else: the returned [`Dongle`] owns it.
    pub unsafe fn adopt(&self, dev: *mut sys::licd_device) -> Dongle<'_> {
        Dongle::from_raw(self, dev)
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        unsafe { sys::licd_free(self.ptr.as_ptr()) };
    }
}

// ============================================================================
// Dongle
// ============================================================================

/// An open connection to a dongle.
///
/// Borrows the [`Context`] it came from, so it cannot outlive it.
pub struct Dongle<'ctx> {
    ptr: NonNull<sys::licd_device>,
    ctx: &'ctx Context,
    _marker: PhantomData<&'ctx ()>,
}

// A licd_device must be used by one thread at a time: movable between threads,
// not shareable across them.
unsafe impl Send for Dongle<'_> {}

impl<'ctx> Dongle<'ctx> {
    unsafe fn from_raw(ctx: &'ctx Context, dev: *mut sys::licd_device) -> Self {
        Dongle {
            ptr: NonNull::new_unchecked(dev),
            ctx,
            _marker: PhantomData,
        }
    }

    /// The raw handle, for mixing this crate with direct FFI calls.
    ///
    /// # Safety
    /// Valid only while `self` is alive, and it must not be closed by the caller.
    pub unsafe fn as_raw(&self) -> *mut sys::licd_device {
        self.ptr.as_ptr()
    }

    /// Reads the plaintext device info.
    pub fn info(&self) -> Result<Info> {
        let mut raw = sys::licd_info::default();
        let rc = unsafe { sys::licd_get_info(self.ptr.as_ptr(), &mut raw) };
        self.ctx.check(rc, "licd_get_info")?;
        Ok(Info {
            protocol_version: (raw.proto_version_major, raw.proto_version_minor),
            firmware_version: (
                raw.fw_version_major,
                raw.fw_version_minor,
                raw.fw_version_patch,
            ),
            se_ready: raw.se_ready != 0,
            provisioned: raw.provisioned != 0,
            data_capacity: raw.data_capacity,
            data_free: raw.data_free,
            watchdog_reboot: raw.watchdog_reboot != 0,
            isolated: raw.isolated != 0,
            writeauth_rotated: raw.writeauth_rotated != 0,
        })
    }

    /// Reads the dongle serial as hex.
    pub fn serial(&self) -> Result<String> {
        let mut buf = [0 as c_char; sys::LICD_SERIAL_HEX_LEN + 1];
        let rc =
            unsafe { sys::licd_get_serial(self.ptr.as_ptr(), buf.as_mut_ptr(), buf.len()) };
        self.ctx.check(rc, "licd_get_serial")?;
        Ok(fixed_to_string(&buf))
    }

    /// Proves authenticity: certificate chain to the trusted root, plus a live
    /// ECDSA challenge-response. Errors unless the dongle is genuine.
    pub fn verify_genuine(&self) -> Result<GenuineResult> {
        let mut raw = sys::licd_genuine_result::default();
        let rc = unsafe { sys::licd_verify_genuine(self.ptr.as_ptr(), &mut raw) };
        self.ctx.check(rc, "licd_verify_genuine")?;
        Ok(GenuineResult {
            genuine: raw.genuine != 0,
            serial: fixed_to_string(&raw.serial),
            provisioned_date: fixed_to_string(&raw.provisioned_date),
        })
    }

    /// The non-erroring form, for a licence gate. Fails closed: a missing dongle,
    /// an I/O error and an invalid certificate all report `false`.
    pub fn is_genuine(&self) -> bool {
        self.verify_genuine().map(|r| r.genuine).unwrap_or(false)
    }

    /// Opens an encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM).
    pub fn open_session(&self) -> Result<Session<'_, 'ctx>> {
        let rc = unsafe { sys::licd_session_open(self.ptr.as_ptr()) };
        self.ctx.check(rc, "licd_session_open")?;
        Ok(Session {
            dongle: self,
            open: true,
        })
    }
}

impl Drop for Dongle<'_> {
    fn drop(&mut self) {
        unsafe { sys::licd_close(self.ptr.as_ptr()) };
    }
}

// ============================================================================
// Session
// ============================================================================

/// An open encrypted session: records, counters and app-crypto.
///
/// Borrows its [`Dongle`]. The consequence is worth stating plainly: the
/// use-after-free that a C++ or C# wrapper has to defend against — a session
/// destroyed after the device it belongs to — will not compile here.
pub struct Session<'dev, 'ctx> {
    dongle: &'dev Dongle<'ctx>,
    open: bool,
}

impl Session<'_, '_> {
    fn dev(&self) -> *mut sys::licd_device {
        self.dongle.ptr.as_ptr()
    }

    fn check(&self, rc: c_int, operation: &'static str) -> Result<()> {
        self.dongle.ctx.check(rc, operation)
    }

    /// Ends the session early, zeroizing the session keys on the dongle. The
    /// [`Drop`] impl does this too; call it when you want the timing.
    pub fn close(&mut self) {
        if self.open {
            self.open = false;
            unsafe { sys::licd_session_close(self.dev()) };
        }
    }

    /// Elevates to the write role with the developer master key (a DER EC private
    /// key). This belongs in your licence-issuing tooling; never ship
    /// that key in the application your users run.
    pub fn authorize_write(&self, master_key_der: &[u8]) -> Result<()> {
        let rc = unsafe {
            sys::licd_write_auth(self.dev(), master_key_der.as_ptr(), master_key_der.len())
        };
        self.check(rc, "licd_write_auth")
    }

    /// Replaces the dongle's write-auth key with your own (a DER EC private key).
    ///
    /// Call [`Session::authorize_write`] with the current key first. From the
    /// next session on, only the new key elevates.
    pub fn rotate_write_key(&self, new_key_der: &[u8]) -> Result<()> {
        let rc = unsafe {
            sys::licd_write_auth_rotate(self.dev(), new_key_der.as_ptr(), new_key_der.len())
        };
        self.check(rc, "licd_write_auth_rotate")
    }

    /// Lists the records stored on the dongle.
    pub fn list_records(&self) -> Result<Vec<RecordInfo>> {
        let mut names: *mut *mut c_char = core::ptr::null_mut();
        let mut sizes: *mut u32 = core::ptr::null_mut();
        let mut count: usize = 0;
        let rc =
            unsafe { sys::licd_record_list(self.dev(), &mut names, &mut sizes, &mut count) };
        self.check(rc, "licd_record_list")?;

        let mut out = Vec::with_capacity(count);
        if !names.is_null() {
            for i in 0..count {
                out.push(RecordInfo {
                    name: unsafe { cstr_to_string(*names.add(i)) },
                    size: unsafe { *sizes.add(i) },
                });
            }
            unsafe { sys::licd_free_record_list(names, sizes, count) };
        }
        Ok(out)
    }

    /// Reads a record.
    pub fn read_record(&self, name: &str) -> Result<Vec<u8>> {
        self.read_record_with_progress(name, |_, _| true)
    }

    /// Reads a record, reporting progress. Return `false` from `progress` to
    /// cancel, which surfaces as [`Status::Cancelled`].
    pub fn read_record_with_progress<F>(&self, name: &str, mut progress: F) -> Result<Vec<u8>>
    where
        F: FnMut(u32, u32) -> bool,
    {
        let c_name = c_name(name, "licd_record_read")?;
        if name.is_empty() {
            return Err(Error {
                status: Status::InvalidArgument,
                operation: "licd_record_read",
                detail: String::new(),
                message: "the record name must not be empty".to_string(),
            });
        }

        // Probe for the size first, so progress runs monotonically from 0 to total.
        let mut probe = [0u8; 1];
        let (mut got, mut total) = (0u32, 0u32);
        let rc = unsafe {
            sys::licd_record_read(
                self.dev(),
                c_name.as_ptr(),
                0,
                probe.as_mut_ptr() as *mut c_void,
                1,
                &mut got,
                &mut total,
                None,
                core::ptr::null_mut(),
            )
        };
        self.check(rc, "licd_record_read")?;
        if total == 0 {
            return Ok(Vec::new());
        }

        let mut buf = vec![0u8; total as usize];
        let mut bridge = ProgressBridge {
            callback: &mut progress,
            panic: None,
        };
        let rc = unsafe {
            sys::licd_record_read(
                self.dev(),
                c_name.as_ptr(),
                0,
                buf.as_mut_ptr() as *mut c_void,
                total,
                &mut got,
                &mut total,
                Some(progress_trampoline),
                &mut bridge as *mut _ as *mut c_void,
            )
        };
        if let Some(payload) = bridge.panic.take() {
            std::panic::resume_unwind(payload);
        }
        self.check(rc, "licd_record_read")?;
        buf.truncate(got as usize);
        Ok(buf)
    }

    /// Atomically replaces a record. Requires the write role.
    pub fn write_record(&self, name: &str, data: &[u8]) -> Result<()> {
        self.write_record_with_progress(name, data, |_, _| true)
    }

    /// Writes a record, reporting progress. Requires the write role.
    pub fn write_record_with_progress<F>(
        &self,
        name: &str,
        data: &[u8],
        mut progress: F,
    ) -> Result<()>
    where
        F: FnMut(u32, u32) -> bool,
    {
        if name.is_empty() {
            return Err(Error {
                status: Status::InvalidArgument,
                operation: "licd_record_write",
                detail: String::new(),
                message: "the record name must not be empty".to_string(),
            });
        }
        let c_name = c_name(name, "licd_record_write")?;
        let mut bridge = ProgressBridge {
            callback: &mut progress,
            panic: None,
        };
        let rc = unsafe {
            sys::licd_record_write(
                self.dev(),
                c_name.as_ptr(),
                data.as_ptr() as *const c_void,
                data.len() as u32,
                Some(progress_trampoline),
                &mut bridge as *mut _ as *mut c_void,
            )
        };
        if let Some(payload) = bridge.panic.take() {
            std::panic::resume_unwind(payload);
        }
        self.check(rc, "licd_record_write")
    }

    /// Erases one record. Requires the write role.
    pub fn erase_record(&self, name: &str) -> Result<()> {
        if name.is_empty() {
            // A null name means "erase everything" to the C API; that is a
            // separate method here so an empty variable cannot wipe the dongle.
            return Err(Error {
                status: Status::InvalidArgument,
                operation: "licd_record_erase",
                detail: String::new(),
                message: "the record name must not be empty; use erase_all_records".to_string(),
            });
        }
        let c_name = c_name(name, "licd_record_erase")?;
        let rc = unsafe { sys::licd_record_erase(self.dev(), c_name.as_ptr()) };
        self.check(rc, "licd_record_erase")
    }

    /// Erases every record. Requires the write role.
    pub fn erase_all_records(&self) -> Result<()> {
        let rc = unsafe { sys::licd_record_erase(self.dev(), core::ptr::null()) };
        self.check(rc, "licd_record_erase")
    }

    /// Reads a hardware monotonic counter.
    pub fn read_counter(&self, counter_id: u8) -> Result<u32> {
        let mut value = 0u32;
        let rc = unsafe { sys::licd_counter_read(self.dev(), counter_id, &mut value) };
        self.check(rc, "licd_counter_read")?;
        Ok(value)
    }

    /// Increments a counter and returns the new value. Irreversible: the counter
    /// is monotonic in hardware. Requires the write role.
    pub fn increment_counter(&self, counter_id: u8) -> Result<u32> {
        let mut value = 0u32;
        let rc = unsafe { sys::licd_counter_increment(self.dev(), counter_id, &mut value) };
        self.check(rc, "licd_counter_increment")?;
        Ok(value)
    }

    /// Encrypts so that only a dongle of `scope` can decrypt.
    ///
    /// This is the pair to build a licence check on: put something the program
    /// genuinely needs through it, so removing the check removes the data.
    pub fn app_encrypt(&self, scope: Scope, plaintext: &[u8]) -> Result<Vec<u8>> {
        let raw_scope = match scope {
            Scope::Device => 0,
            Scope::Developer => 1,
        };
        let mut out: *mut u8 = core::ptr::null_mut();
        let mut out_len = 0u32;
        let rc = unsafe {
            sys::licd_app_encrypt(
                self.dev(),
                raw_scope,
                plaintext.as_ptr() as *const c_void,
                plaintext.len() as u32,
                &mut out,
                &mut out_len,
            )
        };
        self.check(rc, "licd_app_encrypt")?;
        Ok(take_buffer(out, out_len))
    }

    /// Decrypts a blob produced by [`Session::app_encrypt`], using the dongle.
    pub fn app_decrypt(&self, packed: &[u8]) -> Result<Vec<u8>> {
        let mut out: *mut u8 = core::ptr::null_mut();
        let mut out_len = 0u32;
        let rc = unsafe {
            sys::licd_app_decrypt(
                self.dev(),
                packed.as_ptr() as *const c_void,
                packed.len() as u32,
                &mut out,
                &mut out_len,
            )
        };
        self.check(rc, "licd_app_decrypt")?;
        Ok(take_buffer(out, out_len))
    }
}

fn take_buffer(ptr: *mut u8, len: u32) -> Vec<u8> {
    if ptr.is_null() || len == 0 {
        if !ptr.is_null() {
            unsafe { sys::licd_free_buffer(ptr) };
        }
        return Vec::new();
    }
    let out = unsafe { core::slice::from_raw_parts(ptr, len as usize) }.to_vec();
    unsafe { sys::licd_free_buffer(ptr) };
    out
}

impl Drop for Session<'_, '_> {
    fn drop(&mut self) {
        self.close();
    }
}
