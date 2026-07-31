# frozen_string_literal: true

module KeyNubLicDongle
  # Native status codes (mirrors licd_status). OK is 0; errors are negative.
  module Status
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
  end

  # Raised when a native operation fails. +status+ carries the specific code and
  # +detail+ the SDK's diagnostic text — log it, do not parse it.
  class Error < StandardError
    attr_reader :status, :operation, :detail

    def initialize(status, message, operation: nil, detail: nil)
      super(message)
      @status = status
      @operation = operation
      @detail = detail.to_s
    end
  end

  # The dongle failed its authenticity (challenge-response) check.
  class NotGenuineError < Error; end
  # The device certificate, or its chain to the trusted root, was invalid.
  class CertificateInvalidError < Error; end
  # The operation needs the write role (see Session#authorize_write).
  class WriteAuthorizationRequiredError < Error; end
  # No session for an operation that requires one, or it expired.
  class SessionExpiredError < Error; end
  # No matching dongle was found or present.
  class DeviceNotFoundError < Error; end
  # The named record does not exist on the dongle.
  class RecordNotFoundError < Error; end
  # A transfer was cancelled from its progress callback.
  class OperationCancelledError < Error; end

  SUBCLASS = {
    Status::NOT_GENUINE => NotGenuineError,
    Status::CERTIFICATE_INVALID => CertificateInvalidError,
    Status::AUTH_REQUIRED => WriteAuthorizationRequiredError,
    Status::SESSION_EXPIRED => SessionExpiredError,
    Status::NO_DEVICE => DeviceNotFoundError,
    Status::NOT_FOUND => RecordNotFoundError,
    Status::CANCELLED => OperationCancelledError
  }.freeze
  private_constant :SUBCLASS

  module_function

  # Builds the error type that goes with +status+ without raising it.
  def build_error(status, operation, detail = '')
    text = Native.read_c_string(Native.call(:licd_strerror, status))
    message = "#{operation}: #{text}"
    message += " (#{detail})" unless detail.to_s.empty?
    (SUBCLASS[status] || Error).new(status, message, operation: operation, detail: detail)
  end

  # Raises the mapped error unless +status+ is OK.
  def check(status, operation, ctx_handle = nil)
    return if status == Status::OK

    detail = ctx_handle ? Native.read_c_string(Native.call(:licd_error_detail, ctx_handle)) : ''
    raise build_error(status, operation, detail)
  end
end
