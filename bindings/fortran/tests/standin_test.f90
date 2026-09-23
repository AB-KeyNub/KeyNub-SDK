!> Every call of the Fortran binding (keynub_licdongle module) against a
!! stand-in for the C ABI: bindings/flat/licd_flat.c over
!! bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory,
!! linked into the same program. Exit status 0 when every check passed.
!!
!!     cmake -S bindings/fortran/tests -B build-fortran-standin
!!     cmake --build build-fortran-standin
!!     ctest --test-dir build-fortran-standin
program standin_test
    use, intrinsic :: iso_c_binding
    use keynub_licdongle
    implicit none

    character(len=*), parameter :: SERIAL = '04A1B2C3D4E5F6'
    integer(c_int8_t), parameter :: FACTORY_KEY(5) = [int(z'30', c_int8_t), int(z'10', c_int8_t), &
        1_c_int8_t, 2_c_int8_t, 3_c_int8_t]
    integer(c_int8_t), parameter :: REPLACEMENT_KEY(6) = [int(z'30', c_int8_t), int(z'11', c_int8_t), &
        9_c_int8_t, 8_c_int8_t, 7_c_int8_t, 6_c_int8_t]

    integer :: failures = 0
    integer(c_int32_t) :: h, rc, major, minor, patch, count, pa, pb, fa, fb, fc, flags, capacity, free_bytes
    integer(c_int32_t) :: size_out, before, value, scope, i
    character(len=KEYNUB_SERIAL_LEN) :: serial_text
    character(len=KEYNUB_DATE_LEN) :: date_text
    character(len=64) :: name
    logical :: genuine, seen_lic, seen_cfg
    integer(c_int8_t), allocatable :: data(:), blob(:), plain(:)
    integer(c_int8_t) :: root(132), secret(100), nothing(0)

    rc = licdf_version(major, minor, patch)
    call check(rc == LICD_OK .and. major == 9 .and. minor == 8 .and. patch == 7, 'library version')
    call check(keynub_status_text(LICD_E_NO_DEVICE) == 'no device', 'status text')

    rc = licdf_device_count(count)
    call check(rc == LICD_OK .and. count == 1, 'one device')
    call expect(keynub_open('nope'), LICD_E_NO_DEVICE, 'open by unknown serial')

    h = keynub_open()
    call check(h > 0, 'open')
    call expect(keynub_serial(h, serial_text), LICD_OK, 'serial call')
    call check(serial_text == SERIAL, 'serial')
    call expect(licdf_get_info(h, pa, pb, fa, fb, fc, flags, capacity, free_bytes), LICD_OK, 'get_info')
    call check(pa == 1 .and. pb == 0, 'protocol version')
    call check(fa == 2 .and. fb == 3 .and. fc == 4, 'firmware version')
    call check(iand(flags, LICDF_FLAG_SE_READY) /= 0 .and. iand(flags, LICDF_FLAG_PROVISIONED) /= 0 .and. &
               iand(flags, LICDF_FLAG_ISOLATED) /= 0, 'flags set')
    call check(iand(flags, LICDF_FLAG_WATCHDOG_REBOOT) == 0 .and. iand(flags, LICDF_FLAG_WRITEAUTH_ROTATED) == 0, &
               'flags clear')
    call check(capacity == 1048576 .and. free_bytes == 1000000, 'capacity')
    call expect(keynub_verify_genuine(h, genuine, serial_text, date_text), LICD_OK, 'verify_genuine')
    call check(genuine .and. serial_text == SERIAL .and. date_text == '2026-08-15', 'genuine')

    call expect(licdf_set_trust_root(h, [2_c_int8_t, 1_c_int8_t, 0_c_int8_t], 3_c_int32_t), LICD_E_CERT_INVALID, &
                'malformed trust root')
    root = -85_c_int8_t  ! 0xAB
    root(1:4) = [48_c_int8_t, -126_c_int8_t, 1_c_int8_t, 0_c_int8_t]  ! 30 82 01 00
    call expect(licdf_set_trust_root(h, root, 132_c_int32_t), LICD_OK, 'foreign trust root')
    call expect(keynub_verify_genuine(h, genuine), LICD_E_CERT_INVALID, 'verify against a foreign root')
    root(5:) = 1_c_int8_t
    call expect(licdf_set_trust_root(h, root, 132_c_int32_t), LICD_OK, 'right trust root')
    call expect(keynub_verify_genuine(h, genuine), LICD_OK, 'verify after the right root')
    call check(genuine, 'genuine after the right root')

    call expect(licdf_record_count(h, count), LICD_E_SESSION_EXPIRED, 'records without a session')
    call expect(licdf_session_open(h), LICD_OK, 'session_open')
    call expect(keynub_record_write(h, 'lic', bytes('license-blob-0123456789')), LICD_E_AUTH_REQUIRED, &
                'write before the write role')
    call expect(licdf_write_auth(h, [int(z'30', c_int8_t), 0_c_int8_t], 2_c_int32_t), LICD_E_NOT_GENUINE, &
                'write role with a bad key')
    call expect(licdf_write_auth(h, FACTORY_KEY, 5_c_int32_t), LICD_OK, 'write_auth')
    call expect(keynub_record_write(h, 'lic', bytes('license-blob-0123456789')), LICD_OK, 'record_write')
    call expect(keynub_record_read(h, 'lic', data), LICD_OK, 'record_read')
    call check(same(data, bytes('license-blob-0123456789')), 'read back')
    call expect(keynub_record_size(h, 'lic', size_out), LICD_OK, 'record_size')
    call check(size_out == 23, 'record size')
    call expect(keynub_record_write(h, 'cfg', bytes('cfgdata')), LICD_OK, 'second record')
    call expect(licdf_record_count(h, count), LICD_OK, 'record_count')
    call check(count == 2, 'two records')
    seen_lic = .false.
    seen_cfg = .false.
    do i = 0, count - 1
        call expect(keynub_record_name(h, i, name, size_out), LICD_OK, 'record_name')
        if (trim(name) == 'lic' .and. size_out == 23) seen_lic = .true.
        if (trim(name) == 'cfg' .and. size_out == 7) seen_cfg = .true.
    end do
    call check(seen_lic .and. seen_cfg, 'record names and sizes')
    call expect(keynub_record_read(h, 'nope', data), LICD_E_NOT_FOUND, 'read a missing record')
    call check(trim(keynub_last_error(h)) == 'no such record', 'error detail')
    call expect(keynub_record_erase(h, ''), LICD_E_INVALID_ARG, 'erase with an empty name')
    call expect(keynub_record_erase(h, 'cfg'), LICD_OK, 'record_erase')
    call expect(licdf_record_count(h, count), LICD_OK, 'record_count')
    call check(count == 1, 'one record left')
    call expect(keynub_record_write(h, 'empty', nothing), LICD_OK, 'empty record')
    call expect(keynub_record_read(h, 'empty', data), LICD_OK, 'read the empty record')
    call check(size(data) == 0, 'empty record length')

    call expect(licdf_counter_read(h, 0_c_int32_t, before), LICD_OK, 'counter_read')
    call expect(licdf_counter_increment(h, 0_c_int32_t, value), LICD_OK, 'counter_increment')
    call check(value == before + 1, 'increment')
    call expect(licdf_counter_read(h, 1_c_int32_t, value), LICD_OK, 'second counter')
    call check(value == 0, 'counters')
    call expect(licdf_counter_read(h, 7_c_int32_t, value), LICD_E_RANGE, 'counter out of range')

    do i = 1, 100
        secret(i) = int(mod(3 * (i - 1) + 7, 256) - merge(256, 0, mod(3 * (i - 1) + 7, 256) > 127), c_int8_t)
    end do
    do scope = KEYNUB_SCOPE_DEVICE, KEYNUB_SCOPE_DEVELOPER
        call expect(keynub_app_encrypt(h, scope, secret, blob), LICD_OK, 'app_encrypt')
        call check(size(blob) > 100, 'sealed data is longer')
        call check(blob(1) == scope, 'scope byte')
        call expect(keynub_app_decrypt(h, blob, plain), LICD_OK, 'app_decrypt')
        call check(same(plain, secret), 'round trip')
        blob(size(blob)) = ieor(blob(size(blob)), 1_c_int8_t)
        call expect(keynub_app_decrypt(h, blob, plain), LICD_E_TAG_MISMATCH, 'tampered blob')
    end do

    call expect(licdf_record_erase_all(h), LICD_OK, 'record_erase_all')
    call expect(licdf_record_count(h, count), LICD_OK, 'record_count')
    call check(count == 0, 'erase all')

    call expect(licdf_write_auth_rotate(h, REPLACEMENT_KEY, 6_c_int32_t), LICD_OK, 'write_auth_rotate')
    call expect(keynub_record_write(h, 'lic', bytes('still-writable')), LICD_OK, 'still writable')
    call expect(licdf_session_close(h), LICD_OK, 'session_close')
    call expect(licdf_get_info(h, pa, pb, fa, fb, fc, flags, capacity, free_bytes), LICD_OK, 'get_info')
    call check(iand(flags, LICDF_FLAG_WRITEAUTH_ROTATED) /= 0, 'rotated flag')
    call expect(licdf_session_open(h), LICD_OK, 'second session')
    call expect(licdf_write_auth(h, FACTORY_KEY, 5_c_int32_t), LICD_E_NOT_GENUINE, 'factory key after rotation')
    call expect(licdf_write_auth(h, REPLACEMENT_KEY, 6_c_int32_t), LICD_OK, 'new key')
    call expect(keynub_record_write(h, 'lic', bytes('new-key-writes')), LICD_OK, 'write with the new key')
    call expect(keynub_record_read(h, 'lic', data), LICD_OK, 'read with the new key')
    call check(same(data, bytes('new-key-writes')), 'new key content')
    call expect(licdf_session_close(h), LICD_OK, 'session_close')

    call expect(licdf_close(h), LICD_OK, 'close')
    call expect(keynub_serial(h, serial_text), LICD_E_INVALID_ARG, 'serial after close')

    if (failures > 0) then
        print '(I0,A)', failures, ' check(s) failed'
        error stop 1
    end if
    print '(A)', 'keynub_licdongle: every call passed against the ABI stand-in'

contains

    subroutine check(condition, what)
        logical, intent(in) :: condition
        character(len=*), intent(in) :: what
        if (.not. condition) then
            failures = failures + 1
            print '(A,A)', '  FAIL  ', what
        end if
    end subroutine check

    subroutine expect(got, status, what)
        integer(c_int32_t), intent(in) :: got, status
        character(len=*), intent(in) :: what
        if (got /= status) then
            failures = failures + 1
            print '(A,A,A,I0,A,I0)', '  FAIL  ', what, ': ', got, ', expected ', status
        end if
    end subroutine expect

    function bytes(text) result(out)
        character(len=*), intent(in) :: text
        integer(c_int8_t) :: out(len(text))
        out = transfer(text, out)
    end function bytes

    logical function same(a, b)
        integer(c_int8_t), intent(in) :: a(:), b(:)
        same = size(a) == size(b)
        if (same) same = all(a == b)
    end function same

end program standin_test
