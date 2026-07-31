"""Status codes and the exception hierarchy raised on native failures."""

from __future__ import annotations

import enum
from typing import Optional

from . import _native


class Status(enum.IntEnum):
    """Native status codes (mirrors ``licd_status``). ``OK`` is 0; errors are negative."""

    OK = 0
    INVALID_ARGUMENT = -1
    NO_DEVICE = -2
    ACCESS_DENIED = -3
    IO = -4
    TIMEOUT = -5
    PROTOCOL = -6
    NOT_GENUINE = -7
    CERTIFICATE_INVALID = -8
    SESSION_EXPIRED = -9
    TAG_MISMATCH = -10
    RANGE = -11
    STORAGE_FULL = -12
    BUSY = -13
    NOT_FOUND = -14
    AUTH_REQUIRED = -15
    FIRMWARE_INCOMPATIBLE = -16
    SDK_TOO_OLD = -17
    CANCELLED = -18
    NOT_IMPLEMENTED = -19
    INTERNAL = -20


class LicenseDongleError(Exception):
    """Raised when a native operation fails. ``status`` carries the specific code."""

    def __init__(self, status: Status, message: str, detail: Optional[str] = None):
        super().__init__(message)
        self.status = status
        self.detail = detail


class NotGenuineError(LicenseDongleError):
    """The dongle failed its authenticity (challenge-response) check."""


class CertificateInvalidError(LicenseDongleError):
    """The device certificate or its chain to the trusted root was invalid."""


class WriteAuthorizationRequiredError(LicenseDongleError):
    """The operation needs the write role (grant it with :meth:`Session.authorize_write`)."""


class SessionExpiredError(LicenseDongleError):
    """No active session for an operation that requires one."""


class DeviceNotFoundError(LicenseDongleError):
    """No matching dongle was found or present."""


class RecordNotFoundError(LicenseDongleError):
    """The named record does not exist on the dongle."""


_SUBCLASS = {
    Status.NOT_GENUINE: NotGenuineError,
    Status.CERTIFICATE_INVALID: CertificateInvalidError,
    Status.AUTH_REQUIRED: WriteAuthorizationRequiredError,
    Status.SESSION_EXPIRED: SessionExpiredError,
    Status.NO_DEVICE: DeviceNotFoundError,
    Status.NOT_FOUND: RecordNotFoundError,
}


def check(rc: int, ctx_handle, operation: str) -> None:
    """Raise the appropriate exception when ``rc`` is not :attr:`Status.OK`."""
    if rc == Status.OK:
        return
    try:
        status = Status(rc)
    except ValueError:
        status = Status.INTERNAL

    if status == Status.CANCELLED:
        raise OperationCancelledError(f"{operation} was cancelled")

    detail = ""
    if ctx_handle is not None:
        raw = _native.licd_error_detail(ctx_handle)
        if raw:
            detail = raw.decode("utf-8", "replace")
    strerr = (_native.licd_strerror(rc) or b"").decode("utf-8", "replace")
    message = f"{operation}: {strerr}" + (f" - {detail}" if detail else "")
    raise _SUBCLASS.get(status, LicenseDongleError)(status, message, detail or None)


class OperationCancelledError(Exception):
    """Raised when a transfer is cancelled via its progress callback."""
