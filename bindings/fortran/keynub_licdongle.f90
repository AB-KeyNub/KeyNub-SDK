!> KeyNub License Dongle SDK — Fortran binding.
!!
!! Standard Fortran 2003 `iso_c_binding` interfaces to the SDK's flat companion
!! API (`bindings/flat/licd_flat.h`), plus a few helpers for the two things that
!! are awkward across the C boundary from Fortran: NUL-terminated strings, and
!! caller-allocated output buffers.
!!
!! Link against `keynub_licdongle_flat`, which is self-contained — the core,
!! Mbed TLS and hidapi are compiled into it.
!!
!!     use keynub_licdongle
!!     integer(c_int32_t) :: handle, status
!!     handle = keynub_open()                     ! > 0, or a negative status
!!     status = keynub_verify_genuine(handle, genuine, serial)
!!     status = licdf_session_open(handle)
!!     status = keynub_app_decrypt(handle, blob, plaintext, n)
!!     status = licdf_close(handle)
!!
!! Every function returns 0 (`LICD_OK`) on success or a negative status;
!! `keynub_open` is the exception and returns a positive handle. `keynub_status_text`
!! turns a status into a message.
!!
!! Bytes are `integer(c_int8_t)`, so values above 127 appear negative — Fortran
!! has no unsigned integer. Use `transfer()` to move your own data in and out of
!! byte arrays; the values round-trip exactly.
!!
!! Read docs/integration-security.md before deciding where the check goes. A
!! Fortran program that branches on `genuine` is one line away from not checking
!! at all. Put something the program needs — coefficients, a material database,
!! reference data — through `keynub_app_encrypt` when you issue the licence and
!! `keynub_app_decrypt` at run time, so removing the check removes the data.

module keynub_licdongle
    use, intrinsic :: iso_c_binding
    implicit none
    public

    ! --- status codes ------------------------------------------------------
    integer(c_int32_t), parameter :: LICD_OK = 0
    integer(c_int32_t), parameter :: LICD_E_INVALID_ARG = -1
    integer(c_int32_t), parameter :: LICD_E_NO_DEVICE = -2
    integer(c_int32_t), parameter :: LICD_E_ACCESS_DENIED = -3
    integer(c_int32_t), parameter :: LICD_E_IO = -4
    integer(c_int32_t), parameter :: LICD_E_TIMEOUT = -5
    integer(c_int32_t), parameter :: LICD_E_PROTOCOL = -6
    integer(c_int32_t), parameter :: LICD_E_NOT_GENUINE = -7
    integer(c_int32_t), parameter :: LICD_E_CERT_INVALID = -8
    integer(c_int32_t), parameter :: LICD_E_SESSION_EXPIRED = -9
    integer(c_int32_t), parameter :: LICD_E_TAG_MISMATCH = -10
    integer(c_int32_t), parameter :: LICD_E_RANGE = -11
    integer(c_int32_t), parameter :: LICD_E_STORAGE_FULL = -12
    integer(c_int32_t), parameter :: LICD_E_BUSY = -13
    integer(c_int32_t), parameter :: LICD_E_NOT_FOUND = -14
    integer(c_int32_t), parameter :: LICD_E_AUTH_REQUIRED = -15
    integer(c_int32_t), parameter :: LICD_E_FW_INCOMPATIBLE = -16
    integer(c_int32_t), parameter :: LICD_E_SDK_TOO_OLD = -17
    integer(c_int32_t), parameter :: LICD_E_CANCELLED = -18
    integer(c_int32_t), parameter :: LICD_E_NOT_IMPLEMENTED = -19
    integer(c_int32_t), parameter :: LICD_E_INTERNAL = -20

    ! --- flags in the licdf_get_info bitmask -------------------------------
    integer(c_int32_t), parameter :: LICDF_FLAG_SE_READY = 1
    integer(c_int32_t), parameter :: LICDF_FLAG_PROVISIONED = 2
    integer(c_int32_t), parameter :: LICDF_FLAG_WATCHDOG_REBOOT = 4
    integer(c_int32_t), parameter :: LICDF_FLAG_ISOLATED = 8
    !> The write-auth key has been rotated away from the factory one, which is
    !! public: a dongle without this bit takes writes from anyone holding it.
    integer(c_int32_t), parameter :: LICDF_FLAG_WRITEAUTH_ROTATED = 16

    ! --- app-crypto scopes -------------------------------------------------
    integer(c_int32_t), parameter :: KEYNUB_SCOPE_DEVICE = 0    !< this dongle only
    integer(c_int32_t), parameter :: KEYNUB_SCOPE_DEVELOPER = 1 !< any dongle you issued

    ! --- buffer sizes ------------------------------------------------------
    integer, parameter :: KEYNUB_SERIAL_LEN = 14
    !> Length of a personalisation date, "YYYY-MM-DD".
    integer, parameter :: KEYNUB_DATE_LEN = 10
    integer, parameter :: KEYNUB_ERROR_LEN = 255

    ! =======================================================================
    ! Raw interfaces to the flat C API. Usable directly; the helpers below
    ! wrap the string and buffer handling.
    ! =======================================================================
    interface
        integer(c_int32_t) function licdf_version(major, minor, patch) &
                bind(C, name="licdf_version")
            import :: c_int32_t
            integer(c_int32_t), intent(out) :: major, minor, patch
        end function licdf_version

        integer(c_int32_t) function licdf_strerror(status, out, out_size) &
                bind(C, name="licdf_strerror")
            import :: c_int32_t, c_char
            integer(c_int32_t), value :: status
            character(kind=c_char), intent(out) :: out(*)
            integer(c_int32_t), value :: out_size
        end function licdf_strerror

        integer(c_int32_t) function licdf_device_count(count) &
                bind(C, name="licdf_device_count")
            import :: c_int32_t
            integer(c_int32_t), intent(out) :: count
        end function licdf_device_count

        integer(c_int32_t) function licdf_device_serial(index, out, out_size) &
                bind(C, name="licdf_device_serial")
            import :: c_int32_t, c_char
            integer(c_int32_t), value :: index
            character(kind=c_char), intent(out) :: out(*)
            integer(c_int32_t), value :: out_size
        end function licdf_device_serial

        integer(c_int32_t) function licdf_open_c(serial) bind(C, name="licdf_open")
            import :: c_int32_t, c_char
            character(kind=c_char), intent(in) :: serial(*)
        end function licdf_open_c

        integer(c_int32_t) function licdf_close(handle) bind(C, name="licdf_close")
            import :: c_int32_t
            integer(c_int32_t), value :: handle
        end function licdf_close

        integer(c_int32_t) function licdf_set_trust_root(handle, der, der_len) &
                bind(C, name="licdf_set_trust_root")
            import :: c_int32_t, c_int8_t
            integer(c_int32_t), value :: handle
            integer(c_int8_t), intent(in) :: der(*)
            integer(c_int32_t), value :: der_len
        end function licdf_set_trust_root

        integer(c_int32_t) function licdf_get_serial(handle, out, out_size) &
                bind(C, name="licdf_get_serial")
            import :: c_int32_t, c_char
            integer(c_int32_t), value :: handle
            character(kind=c_char), intent(out) :: out(*)
            integer(c_int32_t), value :: out_size
        end function licdf_get_serial

        integer(c_int32_t) function licdf_get_info(handle, proto_major, proto_minor, &
                fw_major, fw_minor, fw_patch, flags, capacity, free_bytes) &
                bind(C, name="licdf_get_info")
            import :: c_int32_t
            integer(c_int32_t), value :: handle
            integer(c_int32_t), intent(out) :: proto_major, proto_minor
            integer(c_int32_t), intent(out) :: fw_major, fw_minor, fw_patch
            integer(c_int32_t), intent(out) :: flags, capacity, free_bytes
        end function licdf_get_info

        integer(c_int32_t) function licdf_verify_genuine_c(handle, genuine, serial, &
                serial_size, prov_date, date_size) bind(C, name="licdf_verify_genuine")
            import :: c_int32_t, c_char
            integer(c_int32_t), value :: handle
            integer(c_int32_t), intent(out) :: genuine
            character(kind=c_char), intent(out) :: serial(*)
            integer(c_int32_t), value :: serial_size
            character(kind=c_char), intent(out) :: prov_date(*)
            integer(c_int32_t), value :: date_size
        end function licdf_verify_genuine_c

        integer(c_int32_t) function licdf_session_open(handle) &
                bind(C, name="licdf_session_open")
            import :: c_int32_t
            integer(c_int32_t), value :: handle
        end function licdf_session_open

        integer(c_int32_t) function licdf_session_close(handle) &
                bind(C, name="licdf_session_close")
            import :: c_int32_t
            integer(c_int32_t), value :: handle
        end function licdf_session_close

        integer(c_int32_t) function licdf_write_auth(handle, der, der_len) &
                bind(C, name="licdf_write_auth")
            import :: c_int32_t, c_int8_t
            integer(c_int32_t), value :: handle
            integer(c_int8_t), intent(in) :: der(*)
            integer(c_int32_t), value :: der_len
        end function licdf_write_auth

        integer(c_int32_t) function licdf_write_auth_rotate(handle, der, der_len) &
                bind(C, name="licdf_write_auth_rotate")
            import :: c_int32_t, c_int8_t
            integer(c_int32_t), value :: handle
            integer(c_int8_t), intent(in) :: der(*)
            integer(c_int32_t), value :: der_len
        end function licdf_write_auth_rotate

        integer(c_int32_t) function licdf_record_count(handle, count) &
                bind(C, name="licdf_record_count")
            import :: c_int32_t
            integer(c_int32_t), value :: handle
            integer(c_int32_t), intent(out) :: count
        end function licdf_record_count

        integer(c_int32_t) function licdf_record_name_c(handle, index, out, out_size, &
                record_size) bind(C, name="licdf_record_name")
            import :: c_int32_t, c_char
            integer(c_int32_t), value :: handle, index
            character(kind=c_char), intent(out) :: out(*)
            integer(c_int32_t), value :: out_size
            integer(c_int32_t), intent(out) :: record_size
        end function licdf_record_name_c

        integer(c_int32_t) function licdf_record_size_c(handle, name, size) &
                bind(C, name="licdf_record_size")
            import :: c_int32_t, c_char
            integer(c_int32_t), value :: handle
            character(kind=c_char), intent(in) :: name(*)
            integer(c_int32_t), intent(out) :: size
        end function licdf_record_size_c

        integer(c_int32_t) function licdf_record_read_c(handle, name, out, out_cap, &
                out_len) bind(C, name="licdf_record_read")
            import :: c_int32_t, c_char, c_int8_t
            integer(c_int32_t), value :: handle
            character(kind=c_char), intent(in) :: name(*)
            integer(c_int8_t), intent(out) :: out(*)
            integer(c_int32_t), value :: out_cap
            integer(c_int32_t), intent(out) :: out_len
        end function licdf_record_read_c

        integer(c_int32_t) function licdf_record_write_c(handle, name, data, data_len) &
                bind(C, name="licdf_record_write")
            import :: c_int32_t, c_char, c_int8_t
            integer(c_int32_t), value :: handle
            character(kind=c_char), intent(in) :: name(*)
            integer(c_int8_t), intent(in) :: data(*)
            integer(c_int32_t), value :: data_len
        end function licdf_record_write_c

        integer(c_int32_t) function licdf_record_erase_c(handle, name) &
                bind(C, name="licdf_record_erase")
            import :: c_int32_t, c_char
            integer(c_int32_t), value :: handle
            character(kind=c_char), intent(in) :: name(*)
        end function licdf_record_erase_c

        integer(c_int32_t) function licdf_record_erase_all(handle) &
                bind(C, name="licdf_record_erase_all")
            import :: c_int32_t
            integer(c_int32_t), value :: handle
        end function licdf_record_erase_all

        integer(c_int32_t) function licdf_counter_read(handle, counter_id, value) &
                bind(C, name="licdf_counter_read")
            import :: c_int32_t
            integer(c_int32_t), value :: handle, counter_id
            integer(c_int32_t), intent(out) :: value
        end function licdf_counter_read

        integer(c_int32_t) function licdf_counter_increment(handle, counter_id, value) &
                bind(C, name="licdf_counter_increment")
            import :: c_int32_t
            integer(c_int32_t), value :: handle, counter_id
            integer(c_int32_t), intent(out) :: value
        end function licdf_counter_increment

        integer(c_int32_t) function licdf_app_encrypt(handle, scope, plaintext, &
                plaintext_len, out, out_cap, out_len) bind(C, name="licdf_app_encrypt")
            import :: c_int32_t, c_int8_t
            integer(c_int32_t), value :: handle, scope
            integer(c_int8_t), intent(in) :: plaintext(*)
            integer(c_int32_t), value :: plaintext_len
            integer(c_int8_t), intent(out) :: out(*)
            integer(c_int32_t), value :: out_cap
            integer(c_int32_t), intent(out) :: out_len
        end function licdf_app_encrypt

        integer(c_int32_t) function licdf_app_decrypt(handle, packed, packed_len, out, &
                out_cap, out_len) bind(C, name="licdf_app_decrypt")
            import :: c_int32_t, c_int8_t
            integer(c_int32_t), value :: handle
            integer(c_int8_t), intent(in) :: packed(*)
            integer(c_int32_t), value :: packed_len
            integer(c_int8_t), intent(out) :: out(*)
            integer(c_int32_t), value :: out_cap
            integer(c_int32_t), intent(out) :: out_len
        end function licdf_app_decrypt

        integer(c_int32_t) function licdf_last_error(handle, out, out_size) &
                bind(C, name="licdf_last_error")
            import :: c_int32_t, c_char
            integer(c_int32_t), value :: handle
            character(kind=c_char), intent(out) :: out(*)
            integer(c_int32_t), value :: out_size
        end function licdf_last_error
    end interface

contains

    !> A NUL-terminated copy of a Fortran string, for passing to C.
    pure function keynub_c_string(text) result(buffer)
        character(len=*), intent(in) :: text
        character(kind=c_char) :: buffer(len_trim(text) + 1)
        integer :: i
        do i = 1, len_trim(text)
            buffer(i) = text(i:i)
        end do
        buffer(len_trim(text) + 1) = c_null_char
    end function keynub_c_string

    !> A Fortran string from a NUL-terminated C character buffer.
    pure function keynub_f_string(buffer) result(text)
        character(kind=c_char), intent(in) :: buffer(:)
        character(len=size(buffer)) :: text
        integer :: i
        text = ''
        do i = 1, size(buffer)
            if (buffer(i) == c_null_char) exit
            text(i:i) = buffer(i)
        end do
    end function keynub_f_string

    !> Opens the dongle with this serial, or the first one found when SERIAL is
    !! absent or blank. Returns a positive handle, or a negative status.
    function keynub_open(serial) result(handle)
        character(len=*), intent(in), optional :: serial
        integer(c_int32_t) :: handle
        if (present(serial)) then
            handle = licdf_open_c(keynub_c_string(serial))
        else
            handle = licdf_open_c(keynub_c_string(''))
        end if
    end function keynub_open

    !> Human-readable text for a status code. Needs no handle.
    function keynub_status_text(status) result(text)
        integer(c_int32_t), intent(in) :: status
        character(len=KEYNUB_ERROR_LEN) :: text
        character(kind=c_char) :: buffer(KEYNUB_ERROR_LEN + 1)
        if (licdf_strerror(status, buffer, int(size(buffer), c_int32_t)) == LICD_OK) then
            text = keynub_f_string(buffer)
        else
            write (text, '(A,I0)') 'status ', status
        end if
    end function keynub_status_text

    !> The SDK's diagnostic detail for the most recent failure on this handle.
    function keynub_last_error(handle) result(text)
        integer(c_int32_t), intent(in) :: handle
        character(len=KEYNUB_ERROR_LEN) :: text
        character(kind=c_char) :: buffer(KEYNUB_ERROR_LEN + 1)
        text = ''
        if (licdf_last_error(handle, buffer, int(size(buffer), c_int32_t)) == LICD_OK) then
            text = keynub_f_string(buffer)
        end if
    end function keynub_last_error

    !> Reads the dongle serial as hex.
    function keynub_serial(handle, serial) result(status)
        integer(c_int32_t), intent(in) :: handle
        character(len=KEYNUB_SERIAL_LEN), intent(out) :: serial
        integer(c_int32_t) :: status
        character(kind=c_char) :: buffer(KEYNUB_SERIAL_LEN + 1)
        serial = ''
        status = licdf_get_serial(handle, buffer, int(size(buffer), c_int32_t))
        if (status == LICD_OK) serial = keynub_f_string(buffer)
    end function keynub_serial

    !> Proves authenticity and returns the identity from the certificate.
    !! Returns LICD_OK only when the dongle is genuine.
    function keynub_verify_genuine(handle, genuine, serial, prov_date) result(status)
        integer(c_int32_t), intent(in) :: handle
        logical, intent(out) :: genuine
        character(len=KEYNUB_SERIAL_LEN), intent(out), optional :: serial
        !> "YYYY-MM-DD", or blank when the dongle reports no date.
        character(len=KEYNUB_DATE_LEN), intent(out), optional :: prov_date
        integer(c_int32_t) :: status
        integer(c_int32_t) :: is_genuine
        character(kind=c_char) :: serial_buf(KEYNUB_SERIAL_LEN + 1)
        character(kind=c_char) :: date_buf(KEYNUB_DATE_LEN + 1)

        genuine = .false.
        if (present(serial)) serial = ''
        if (present(prov_date)) prov_date = ''
        status = licdf_verify_genuine_c(handle, is_genuine, serial_buf, &
                                        int(size(serial_buf), c_int32_t), date_buf, &
                                        int(size(date_buf), c_int32_t))
        if (status /= LICD_OK) return
        genuine = (is_genuine /= 0)
        if (present(serial)) serial = keynub_f_string(serial_buf)
        if (present(prov_date)) prov_date = keynub_f_string(date_buf)
    end function keynub_verify_genuine

    !> Size in bytes of a named record.
    function keynub_record_size(handle, name, size_out) result(status)
        integer(c_int32_t), intent(in) :: handle
        character(len=*), intent(in) :: name
        integer(c_int32_t), intent(out) :: size_out
        integer(c_int32_t) :: status
        status = licdf_record_size_c(handle, keynub_c_string(name), size_out)
    end function keynub_record_size

    !> Reads a record into an allocatable byte array, sized automatically.
    function keynub_record_read(handle, name, data) result(status)
        integer(c_int32_t), intent(in) :: handle
        character(len=*), intent(in) :: name
        integer(c_int8_t), allocatable, intent(out) :: data(:)
        integer(c_int32_t) :: status, needed, got
        integer(c_int8_t) :: probe(1)

        ! Ask for the size first: the flat API answers a zero-capacity call with
        ! LICD_E_RANGE and the size required.
        status = licdf_record_read_c(handle, keynub_c_string(name), probe, 0_c_int32_t, needed)
        if (status /= LICD_OK .and. status /= LICD_E_RANGE) then
            allocate (data(0))
            return
        end if
        if (needed <= 0) then
            allocate (data(0))
            status = LICD_OK
            return
        end if
        allocate (data(needed))
        status = licdf_record_read_c(handle, keynub_c_string(name), data, needed, got)
        if (status /= LICD_OK) then
            deallocate (data)
            allocate (data(0))
        end if
    end function keynub_record_read

    !> Atomically replaces a record. Requires the write role.
    function keynub_record_write(handle, name, data) result(status)
        integer(c_int32_t), intent(in) :: handle
        character(len=*), intent(in) :: name
        integer(c_int8_t), intent(in) :: data(:)
        integer(c_int32_t) :: status
        integer(c_int8_t) :: empty(1)
        if (size(data) == 0) then
            status = licdf_record_write_c(handle, keynub_c_string(name), empty, 0_c_int32_t)
        else
            status = licdf_record_write_c(handle, keynub_c_string(name), data, &
                                          int(size(data), c_int32_t))
        end if
    end function keynub_record_write

    !> Erases one record. Requires the write role. An empty name is refused —
    !! use LICDF_RECORD_ERASE_ALL to erase everything.
    function keynub_record_erase(handle, name) result(status)
        integer(c_int32_t), intent(in) :: handle
        character(len=*), intent(in) :: name
        integer(c_int32_t) :: status
        status = licdf_record_erase_c(handle, keynub_c_string(name))
    end function keynub_record_erase

    !> The name and size of the record at INDEX (0-based).
    function keynub_record_name(handle, index, name, record_size) result(status)
        integer(c_int32_t), intent(in) :: handle, index
        character(len=*), intent(out) :: name
        integer(c_int32_t), intent(out) :: record_size
        integer(c_int32_t) :: status
        character(kind=c_char) :: buffer(256)
        name = ''
        status = licdf_record_name_c(handle, index, buffer, int(size(buffer), c_int32_t), &
                                     record_size)
        if (status == LICD_OK) name = keynub_f_string(buffer)
    end function keynub_record_name

    !> Encrypts so that only a dongle of SCOPE can decrypt. The output array is
    !! allocated to the exact size.
    function keynub_app_encrypt(handle, scope, plaintext, blob) result(status)
        integer(c_int32_t), intent(in) :: handle, scope
        integer(c_int8_t), intent(in) :: plaintext(:)
        integer(c_int8_t), allocatable, intent(out) :: blob(:)
        integer(c_int32_t) :: status, needed, got
        integer(c_int8_t) :: probe(1)

        status = licdf_app_encrypt(handle, scope, plaintext, int(size(plaintext), c_int32_t), &
                                   probe, 0_c_int32_t, needed)
        if (status /= LICD_OK .and. status /= LICD_E_RANGE) then
            allocate (blob(0))
            return
        end if
        allocate (blob(max(needed, 1)))
        status = licdf_app_encrypt(handle, scope, plaintext, int(size(plaintext), c_int32_t), &
                                   blob, needed, got)
        if (status /= LICD_OK) then
            deallocate (blob)
            allocate (blob(0))
        end if
    end function keynub_app_encrypt

    !> Decrypts a blob produced by KEYNUB_APP_ENCRYPT, using the dongle.
    !!
    !! This is the pair to build a licence check on: put something the program
    !! genuinely needs through it, so removing the check removes the data.
    function keynub_app_decrypt(handle, blob, plaintext) result(status)
        integer(c_int32_t), intent(in) :: handle
        integer(c_int8_t), intent(in) :: blob(:)
        integer(c_int8_t), allocatable, intent(out) :: plaintext(:)
        integer(c_int32_t) :: status, needed, got
        integer(c_int8_t) :: probe(1)

        status = licdf_app_decrypt(handle, blob, int(size(blob), c_int32_t), probe, &
                                   0_c_int32_t, needed)
        if (status /= LICD_OK .and. status /= LICD_E_RANGE) then
            allocate (plaintext(0))
            return
        end if
        if (needed <= 0) then
            allocate (plaintext(0))
            status = LICD_OK
            return
        end if
        allocate (plaintext(needed))
        status = licdf_app_decrypt(handle, blob, int(size(blob), c_int32_t), plaintext, &
                                   needed, got)
        if (status /= LICD_OK) then
            deallocate (plaintext)
            allocate (plaintext(0))
        end if
    end function keynub_app_decrypt

end module keynub_licdongle
