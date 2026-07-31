"""KeyNub License Dongle SDK - Python binding.

A thin ctypes wrapper over the native ``keynub_licdongle`` core (no protocol or
crypto logic in Python). Driverless on Windows, Linux, and macOS.

    import keynub_licdongle as kn

    with kn.LicenseDongleContext() as ctx:
        dongle = ctx.open()                 # first attached dongle
        result = dongle.verify_genuine()    # cert chain + live challenge-response
        with dongle.open_session() as session:
            data = session.read_record("license")
"""

from __future__ import annotations

from ._core import Dongle, LicenseDongleContext, ProgressCallback, Session
from ._errors import (
    CertificateInvalidError,
    DeviceNotFoundError,
    LicenseDongleError,
    NotGenuineError,
    OperationCancelledError,
    RecordNotFoundError,
    SessionExpiredError,
    Status,
    WriteAuthorizationRequiredError,
)
from ._models import DeviceInfo, DongleInfo, GenuineResult, LogLevel, RecordInfo, Scope, TransferProgress

__version__ = "1.0.0"

__all__ = [
    "LicenseDongleContext",
    "Dongle",
    "Session",
    "ProgressCallback",
    "Scope",
    "LogLevel",
    "DeviceInfo",
    "DongleInfo",
    "GenuineResult",
    "RecordInfo",
    "TransferProgress",
    "Status",
    "LicenseDongleError",
    "NotGenuineError",
    "CertificateInvalidError",
    "WriteAuthorizationRequiredError",
    "SessionExpiredError",
    "DeviceNotFoundError",
    "RecordNotFoundError",
    "OperationCancelledError",
    "__version__",
]
