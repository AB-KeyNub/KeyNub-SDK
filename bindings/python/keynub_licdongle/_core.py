"""The public object model: :class:`LicenseDongleContext`, :class:`Dongle`, :class:`Session`."""

from __future__ import annotations

import ctypes
from ctypes import byref, c_char_p, c_size_t, c_uint32, c_void_p
from typing import Callable, List, Optional

from . import _native
from ._errors import OperationCancelledError, Status, check
from ._models import DeviceInfo, DongleInfo, GenuineResult, RecordInfo, Scope, TransferProgress

# A progress callback receives a TransferProgress; return False to cancel.
ProgressCallback = Callable[[TransferProgress], Optional[bool]]


def _u8(s: str) -> bytes:
    return s.encode("utf-8")


# A typed NULL callback: ctypes rejects None for a CFUNCTYPE argument, so pass this
# to mean "no callback" (the native side checks for a null pointer).
_NULL_PROGRESS = ctypes.cast(None, _native.PROGRESS_CB)


def _make_progress_cb(progress: Optional[ProgressCallback]):
    """Wrap a Python progress callable as a native PROGRESS_CB, or a NULL cb for none."""
    if progress is None:
        return _NULL_PROGRESS

    def _cb(done, total, _user):
        try:
            result = progress(TransferProgress(done, total))
        except Exception:
            return 0  # cancel on any callback error
        return 0 if result is False else 1

    return _native.PROGRESS_CB(_cb)


class LicenseDongleContext:
    """Library context: the entry point for enumerating and opening dongles.

    Use as a context manager, or call :meth:`close` when done (after the dongles it opened).
    """

    def __init__(self) -> None:
        handle = c_void_p()
        rc = _native.licd_init(byref(handle))
        check(rc, handle if handle.value else None, "licd_init")
        self._handle: Optional[c_void_p] = handle
        self._log_cb = None  # kept alive while registered

    # -- lifecycle --
    def __enter__(self) -> "LicenseDongleContext":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        if self._handle is not None:
            _native.licd_free(self._handle)
            self._handle = None
            self._log_cb = None

    @property
    def _h(self) -> c_void_p:
        if self._handle is None:
            raise RuntimeError("the context has been closed")
        return self._handle

    @staticmethod
    def library_version() -> tuple[int, int, int]:
        """The native core library version (semantic)."""
        major, minor, patch = ctypes.c_int(), ctypes.c_int(), ctypes.c_int()
        _native.licd_version(byref(major), byref(minor), byref(patch))
        return (major.value, minor.value, patch.value)

    def set_log_callback(self, callback: Optional[Callable[[int, str], None]]) -> None:
        """Set (or clear, with ``None``) a diagnostic log callback ``(level, message)``."""
        if callback is None:
            self._log_cb = None
            _native.licd_set_log_callback(self._h, ctypes.cast(None, _native.LOG_CB), None)
            return

        def _cb(level, msg, _user):
            callback(level, (msg or b"").decode("utf-8", "replace"))

        self._log_cb = _native.LOG_CB(_cb)
        _native.licd_set_log_callback(self._h, self._log_cb, None)

    def set_trust_root(self, der: bytes) -> None:
        """Override the CA root that :meth:`Dongle.verify_genuine` checks against.

        Applications do not need this — a release build embeds the KeyNub
        production root. It exists for dongles provisioned against a *development*
        CA and for vendor tooling and hardware tests. ``der`` is
        a DER-encoded X.509 CA certificate.
        """
        rc = _native.licd_set_trust_root(self._h, bytes(der), len(der))
        check(rc, self._h, "licd_set_trust_root")

    def enumerate(self) -> List[DeviceInfo]:
        """Enumerate the connected dongles (empty list when none are present)."""
        lst = c_void_p()
        count = c_size_t()
        rc = _native.licd_enumerate(self._h, byref(lst), byref(count))
        check(rc, self._h, "licd_enumerate")
        result: List[DeviceInfo] = []
        n = count.value
        if n and lst.value:
            arr = ctypes.cast(lst, ctypes.POINTER(_native.LicdDeviceInfo))
            for i in range(n):
                e = arr[i]
                result.append(DeviceInfo(
                    e.serial.decode("utf-8", "replace"),
                    e.path.decode("utf-8", "replace"),
                    e.vendor_id, e.product_id))
            _native.licd_free_device_list(lst, count)
        return result

    def open(self, serial: Optional[str] = None) -> "Dongle":
        """Open the dongle with ``serial``, or the first one if ``serial`` is None."""
        handle = c_void_p()
        rc = _native.licd_open(self._h, _u8(serial) if serial is not None else None, byref(handle))
        check(rc, self._h, "licd_open")
        return Dongle(self, handle)

    def open_path(self, path: str) -> "Dongle":
        """Open a specific dongle by the ``path`` from :meth:`enumerate`."""
        handle = c_void_p()
        rc = _native.licd_open_path(self._h, _u8(path), byref(handle))
        check(rc, self._h, "licd_open_path")
        return Dongle(self, handle)

    @property
    def last_error_detail(self) -> str:
        """The thread-local diagnostic detail for the most recent failure on this thread."""
        raw = _native.licd_error_detail(self._h)
        return (raw or b"").decode("utf-8", "replace")


class Dongle:
    """An open connection to a dongle. Plaintext ops here; session ops on :class:`Session`."""

    def __init__(self, context: LicenseDongleContext, handle: c_void_p) -> None:
        self._ctx = context
        self._handle: Optional[c_void_p] = handle

    def __enter__(self) -> "Dongle":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        if self._handle is not None:
            _native.licd_close(self._handle)
            self._handle = None

    @property
    def _h(self) -> c_void_p:
        if self._handle is None:
            raise RuntimeError("the dongle has been closed")
        return self._handle

    @property
    def _ch(self) -> c_void_p:
        return self._ctx._h

    def get_info(self) -> DongleInfo:
        """Read the plaintext device info (protocol/firmware version, flags, capacity)."""
        info = _native.LicdInfo()
        check(_native.licd_get_info(self._h, byref(info)), self._ch, "licd_get_info")
        return DongleInfo(
            (info.proto_version_major, info.proto_version_minor),
            (info.fw_version_major, info.fw_version_minor, info.fw_version_patch),
            bool(info.se_ready), bool(info.provisioned),
            info.data_capacity, info.data_free, bool(info.watchdog_reboot),
            bool(info.isolated), bool(info.writeauth_rotated))

    def get_serial(self) -> str:
        """Read the dongle serial as hex (e.g. ``04A1B2C3D4E5F6``)."""
        buf = ctypes.create_string_buffer(15)  # LICD_SERIAL_HEX_LEN + 1
        check(_native.licd_get_serial(self._h, buf, 15), self._ch, "licd_get_serial")
        return buf.value.decode("utf-8", "replace")

    def verify_genuine(self) -> GenuineResult:
        """Verify authenticity (cert chain + live challenge-response); return the cert identity."""
        res = _native.LicdGenuineResult()
        check(_native.licd_verify_genuine(self._h, byref(res)), self._ch, "licd_verify_genuine")
        return GenuineResult(
            bool(res.genuine),
            res.serial.decode("utf-8", "replace"),
            res.provisioned_date.decode("utf-8", "replace"))

    def open_session(self) -> "Session":
        """Open an encrypted session (verify + P-256 ECDH / HKDF / AES-256-GCM handshake)."""
        check(_native.licd_session_open(self._h), self._ch, "licd_session_open")
        return Session(self)


class Session:
    """An open encrypted session: records, counters, app-crypto, write-role elevation."""

    def __init__(self, dongle: Dongle) -> None:
        self._dongle = dongle
        self._closed = False

    def __enter__(self) -> "Session":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    @property
    def is_closed(self) -> bool:
        return self._closed

    def close(self) -> None:
        """End the session, zeroizing session keys on the dongle. Safe to call repeatedly."""
        if not self._closed:
            self._closed = True
            # Teardown is local state; ignore the status so close never raises.
            _native.licd_session_close(self._dongle._h)

    def _guard(self) -> None:
        if self._closed:
            raise RuntimeError("the session has been closed")

    @property
    def _h(self) -> c_void_p:
        return self._dongle._h

    @property
    def _ch(self) -> c_void_p:
        return self._dongle._ch

    @staticmethod
    def _require_name(name: str) -> bytes:
        if not name:
            raise ValueError("record name must be non-empty")
        return _u8(name)

    def authorize_write(self, master_key_der: bytes) -> None:
        """Elevate to the write role by proving the developer master key (DER EC private key)."""
        self._guard()
        check(_native.licd_write_auth(self._h, bytes(master_key_der), len(master_key_der)),
              self._ch, "licd_write_auth")

    def rotate_write_key(self, new_key_der: bytes) -> None:
        """Replace the dongle's write-auth key with your own (DER EC private key).

        Call authorize_write with the current key first. From the next session on,
        only the new key elevates.
        """
        self._guard()
        check(_native.licd_write_auth_rotate(self._h, bytes(new_key_der), len(new_key_der)),
              self._ch, "licd_write_auth_rotate")

    def list_records(self) -> List[RecordInfo]:
        """List the record names and sizes stored on the dongle."""
        self._guard()
        names = c_void_p()
        sizes = c_void_p()
        count = c_size_t()
        check(_native.licd_record_list(self._h, byref(names), byref(sizes), byref(count)),
              self._ch, "licd_record_list")
        result: List[RecordInfo] = []
        n = count.value
        try:
            if n:
                name_arr = ctypes.cast(names, ctypes.POINTER(c_char_p))
                size_arr = ctypes.cast(sizes, ctypes.POINTER(c_uint32))
                for i in range(n):
                    result.append(RecordInfo(
                        (name_arr[i] or b"").decode("utf-8", "replace"), size_arr[i]))
        finally:
            _native.licd_free_record_list(names, sizes, count)
        return result

    def read_record(self, name: str, progress: Optional[ProgressCallback] = None) -> bytes:
        """Read the entire named record. ``progress`` may cancel by returning ``False``."""
        self._guard()
        name_b = self._require_name(name)

        # Learn the total size (no progress on the tiny probe), then read the whole record so
        # progress is monotonic from 0 to total.
        out_len = c_uint32()
        total = c_uint32()
        probe = ctypes.create_string_buffer(1)
        check(_native.licd_record_read(self._h, name_b, 0, ctypes.cast(probe, c_void_p), 1,
                                       byref(out_len), byref(total), _NULL_PROGRESS, None),
              self._ch, "licd_record_read")
        if total.value == 0:
            if progress:
                progress(TransferProgress(0, 0))
            return b""

        buf = ctypes.create_string_buffer(total.value)
        cb = _make_progress_cb(progress)
        rc = _native.licd_record_read(self._h, name_b, 0, ctypes.cast(buf, c_void_p),
                                      total.value, byref(out_len), byref(total), cb, None)
        self._check_cancel(rc, "licd_record_read")
        return buf.raw[:out_len.value]

    def write_record(self, name: str, data: bytes,
                     progress: Optional[ProgressCallback] = None) -> None:
        """Write (atomically replace) the named record. Requires the write role."""
        self._guard()
        name_b = self._require_name(name)
        data_b = bytes(data)
        cb = _make_progress_cb(progress)
        rc = _native.licd_record_write(self._h, name_b, data_b, len(data_b), cb, None)
        self._check_cancel(rc, "licd_record_write")

    def erase_record(self, name: str) -> None:
        """Erase the named record. Requires the write role."""
        self._guard()
        check(_native.licd_record_erase(self._h, self._require_name(name)),
              self._ch, "licd_record_erase")

    def erase_all_records(self) -> None:
        """Erase all records. Requires the write role."""
        self._guard()
        check(_native.licd_record_erase(self._h, None), self._ch, "licd_record_erase")

    def read_counter(self, counter_id: int) -> int:
        """Read a hardware monotonic counter."""
        self._guard()
        value = c_uint32()
        check(_native.licd_counter_read(self._h, counter_id, byref(value)),
              self._ch, "licd_counter_read")
        return value.value

    def increment_counter(self, counter_id: int) -> int:
        """Increment a monotonic counter, returning the new value. Requires the write role."""
        self._guard()
        value = c_uint32()
        check(_native.licd_counter_increment(self._h, counter_id, byref(value)),
              self._ch, "licd_counter_increment")
        return value.value

    def app_encrypt(self, scope: Scope, plaintext: bytes) -> bytes:
        """Encrypt ``plaintext`` so only a dongle of ``scope`` can decrypt it."""
        self._guard()
        data_b = bytes(plaintext)
        out = c_void_p()
        out_len = c_uint32()
        check(_native.licd_app_encrypt(self._h, int(scope), data_b, len(data_b),
                                       byref(out), byref(out_len)),
              self._ch, "licd_app_encrypt")
        return self._take_buffer(out, out_len)

    def app_decrypt(self, packed: bytes) -> bytes:
        """Decrypt a blob produced by :meth:`app_encrypt` using the dongle."""
        self._guard()
        data_b = bytes(packed)
        out = c_void_p()
        out_len = c_uint32()
        check(_native.licd_app_decrypt(self._h, data_b, len(data_b), byref(out), byref(out_len)),
              self._ch, "licd_app_decrypt")
        return self._take_buffer(out, out_len)

    def _check_cancel(self, rc: int, operation: str) -> None:
        if rc == Status.CANCELLED:
            raise OperationCancelledError(f"{operation} was cancelled")
        check(rc, self._ch, operation)

    @staticmethod
    def _take_buffer(out: c_void_p, out_len: c_uint32) -> bytes:
        try:
            if not out.value or out_len.value == 0:
                return b""
            return ctypes.string_at(out, out_len.value)
        finally:
            if out.value:
                _native.licd_free_buffer(out)
