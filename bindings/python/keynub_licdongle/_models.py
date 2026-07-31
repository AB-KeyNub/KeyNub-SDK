"""Public enums and immutable data models returned by the API."""

from __future__ import annotations

import enum
from dataclasses import dataclass


class Scope(enum.IntEnum):
    """Scope for app-data envelope encryption (:meth:`Session.app_encrypt`)."""

    DEVICE = 0     #: Only this physical dongle can decrypt (node-locking).
    DEVELOPER = 1  #: Any dongle from the same developer batch can decrypt.


class LogLevel(enum.IntEnum):
    """Severity of a diagnostic log message."""

    ERROR = 0
    WARN = 1
    INFO = 2
    DEBUG = 3


@dataclass(frozen=True)
class DeviceInfo:
    """A dongle discovered by :meth:`LicenseDongleContext.enumerate`."""

    serial: str
    path: str
    vendor_id: int
    product_id: int


@dataclass(frozen=True)
class DongleInfo:
    """Plaintext device info from :meth:`Dongle.get_info`."""

    protocol_version: tuple[int, int]
    firmware_version: tuple[int, int, int]
    se_ready: bool
    provisioned: bool
    data_capacity: int
    data_free: int
    #: Whether the dongle's *previous* boot ended in a watchdog timeout -- the
    #: firmware hung and reset itself. Normal operation and a requested reboot both
    #: leave this false, so a true value is worth logging: it is the only trace a
    #: field hang leaves behind. Cleared by a power cycle.
    watchdog_reboot: bool = False
    #: Whether the dongle confirmed at boot that its USB and parsing code is fenced off
    #: from keys and storage. The software simulator reports false.
    isolated: bool = False


@dataclass(frozen=True)
class GenuineResult:
    """The verified identity from :meth:`Dongle.verify_genuine`."""

    is_genuine: bool
    serial: str
    batch: str
    provisioned_date: str


@dataclass(frozen=True)
class RecordInfo:
    """A record name and size, from :meth:`Session.list_records`."""

    name: str
    size: int


@dataclass(frozen=True)
class TransferProgress:
    """Progress of a record transfer, passed to a progress callback."""

    bytes_transferred: int
    total_bytes: int

    @property
    def fraction(self) -> float:
        """Fraction complete in ``[0, 1]`` (1.0 when :attr:`total_bytes` is 0)."""
        return 1.0 if self.total_bytes == 0 else self.bytes_transferred / self.total_bytes
