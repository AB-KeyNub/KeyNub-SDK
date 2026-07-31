"""ctypes bindings to the native ``keynub_licdongle`` core.

This is the equivalent of the .NET binding's P/Invoke layer: it locates and loads
the shared library and declares the C ABI (argument/return types). Everything
above this module works in terms of the loaded ``lib`` handle.
"""

from __future__ import annotations

import ctypes
import os
import sys
from ctypes import POINTER, c_char, c_char_p, c_int, c_size_t, c_uint8, c_uint16, c_uint32, c_void_p

# --- Library discovery -------------------------------------------------------

_LIB_BASENAMES = {
    "win32": "keynub_licdongle.dll",
    "darwin": "libkeynub_licdongle.dylib",
}
_DEFAULT_LIB = _LIB_BASENAMES.get(sys.platform, "libkeynub_licdongle.so")


def _candidate_paths() -> list[str]:
    # 1) explicit override (tests point this at the simulator library)
    override = os.environ.get("KEYNUB_LICDONGLE_LIBRARY")
    if override:
        return [override]
    candidates = []
    # 2) native bundled inside the installed package (wheel layout)
    here = os.path.dirname(os.path.abspath(__file__))
    candidates.append(os.path.join(here, "_libs", _DEFAULT_LIB))
    # 3) alongside the package
    candidates.append(os.path.join(here, _DEFAULT_LIB))
    # 4) system search
    candidates.append(_DEFAULT_LIB)
    return candidates


def _load() -> ctypes.CDLL:
    errors = []
    for path in _candidate_paths():
        try:
            return ctypes.CDLL(path)
        except OSError as exc:  # not found / not loadable here; try the next
            errors.append(f"{path}: {exc}")
    raise OSError(
        "could not load the keynub_licdongle native library; tried:\n  " + "\n  ".join(errors)
    )


lib = _load()


# --- Structures (mirror licdongle.h) ----------------------------------------

class LicdInfo(ctypes.Structure):
    _fields_ = [
        ("proto_version_major", c_uint8),
        ("proto_version_minor", c_uint8),
        ("fw_version_major", c_uint8),
        ("fw_version_minor", c_uint8),
        ("fw_version_patch", c_uint8),
        ("se_ready", c_int),
        ("provisioned", c_int),
        ("data_capacity", c_uint32),
        ("data_free", c_uint32),
        ("watchdog_reboot", c_int),
        ("isolated", c_int),
    ]


class LicdGenuineResult(ctypes.Structure):
    _fields_ = [
        ("genuine", c_int),
        ("serial", c_char * 19),
        ("batch", c_char * 64),
        ("provisioned_date", c_char * 11),
    ]


class LicdDeviceInfo(ctypes.Structure):
    _fields_ = [
        ("serial", c_char * 19),
        ("path", c_char * 512),
        ("vendor_id", c_uint16),
        ("product_id", c_uint16),
    ]


# Callback types. CFUNCTYPE = cdecl, matching the C ABI (not WINFUNCTYPE/stdcall).
PROGRESS_CB = ctypes.CFUNCTYPE(c_int, c_uint32, c_uint32, c_void_p)
LOG_CB = ctypes.CFUNCTYPE(None, c_int, c_char_p, c_void_p)


def _decl(name, restype, argtypes):
    fn = getattr(lib, name)
    fn.restype = restype
    fn.argtypes = argtypes
    return fn


# --- Prototypes --------------------------------------------------------------

licd_version = _decl("licd_version", None, [POINTER(c_int), POINTER(c_int), POINTER(c_int)])
licd_init = _decl("licd_init", c_int, [POINTER(c_void_p)])
licd_free = _decl("licd_free", None, [c_void_p])
licd_set_log_callback = _decl("licd_set_log_callback", None, [c_void_p, LOG_CB, c_void_p])
licd_set_trust_root = _decl("licd_set_trust_root", c_int, [c_void_p, c_char_p, c_size_t])

licd_enumerate = _decl("licd_enumerate", c_int, [c_void_p, POINTER(c_void_p), POINTER(c_size_t)])
licd_free_device_list = _decl("licd_free_device_list", None, [c_void_p, c_size_t])
licd_open = _decl("licd_open", c_int, [c_void_p, c_char_p, POINTER(c_void_p)])
licd_open_path = _decl("licd_open_path", c_int, [c_void_p, c_char_p, POINTER(c_void_p)])
licd_close = _decl("licd_close", None, [c_void_p])

licd_get_info = _decl("licd_get_info", c_int, [c_void_p, POINTER(LicdInfo)])
licd_get_serial = _decl("licd_get_serial", c_int, [c_void_p, c_char_p, c_size_t])

licd_verify_genuine = _decl("licd_verify_genuine", c_int, [c_void_p, POINTER(LicdGenuineResult)])
licd_session_open = _decl("licd_session_open", c_int, [c_void_p])
licd_session_close = _decl("licd_session_close", c_int, [c_void_p])
licd_write_auth = _decl("licd_write_auth", c_int, [c_void_p, c_char_p, c_size_t])

licd_record_list = _decl(
    "licd_record_list", c_int, [c_void_p, POINTER(c_void_p), POINTER(c_void_p), POINTER(c_size_t)]
)
licd_free_record_list = _decl("licd_free_record_list", None, [c_void_p, c_void_p, c_size_t])
licd_record_read = _decl(
    "licd_record_read",
    c_int,
    [c_void_p, c_char_p, c_uint32, c_void_p, c_uint32, POINTER(c_uint32), POINTER(c_uint32),
     PROGRESS_CB, c_void_p],
)
licd_record_write = _decl(
    "licd_record_write", c_int, [c_void_p, c_char_p, c_char_p, c_uint32, PROGRESS_CB, c_void_p]
)
licd_record_erase = _decl("licd_record_erase", c_int, [c_void_p, c_char_p])

licd_counter_read = _decl("licd_counter_read", c_int, [c_void_p, c_uint8, POINTER(c_uint32)])
licd_counter_increment = _decl("licd_counter_increment", c_int, [c_void_p, c_uint8, POINTER(c_uint32)])

licd_app_encrypt = _decl(
    "licd_app_encrypt", c_int, [c_void_p, c_int, c_char_p, c_uint32, POINTER(c_void_p), POINTER(c_uint32)]
)
licd_app_decrypt = _decl(
    "licd_app_decrypt", c_int, [c_void_p, c_char_p, c_uint32, POINTER(c_void_p), POINTER(c_uint32)]
)
licd_free_buffer = _decl("licd_free_buffer", None, [c_void_p])

licd_strerror = _decl("licd_strerror", c_char_p, [c_int])
licd_error_detail = _decl("licd_error_detail", c_char_p, [c_void_p])
