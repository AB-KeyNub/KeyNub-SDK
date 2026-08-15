! KeyNub SDK - Fortran sample: take ownership of a new dongle.
!
! A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
! that from the next session onward only your key can write records, erase them or
! increment counters. Run it once per dongle, when it arrives.
!
! Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
!
!   openssl ecparam -name prime256v1 -genkey -noout | \
!     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
!
!   gfortran -c ../../../bindings/fortran/keynub_licdongle.f90
!   gfortran rotate_write_key.f90 keynub_licdongle.o -L<native dir> \
!            -lkeynub_licdongle_flat -o rotate_write_key
!   ./rotate_write_key ../../../keys/keynub-shipping-writeauth.key.der my-key.der
!
! Targets real hardware: with no dongle attached it prints guidance and stops.
!
! The replacement key is worth what your licence-signing key is worth. It cannot be
! recovered from the dongle, and a unit rotated to a key you have lost has to come
! back to be re-provisioned.

program rotate_write_key
    use iso_c_binding
    use keynub_licdongle
    implicit none

    integer(c_int32_t) :: handle, status, count
    integer(c_int8_t), allocatable :: current(:), replacement(:)
    character(len=256) :: current_path, new_path
    character(len=KEYNUB_SERIAL_LEN) :: serial

    if (command_argument_count() /= 2) then
        write (*, '(A)') 'usage: rotate_write_key <current-key.der> <new-key.der>'
        stop 2
    end if
    call get_command_argument(1, current_path)
    call get_command_argument(2, new_path)
    call read_key(trim(current_path), current)
    call read_key(trim(new_path), replacement)

    status = licdf_device_count(count)
    if (status /= LICD_OK) then
        call fail(0_c_int32_t, 'licdf_device_count', status)
    end if
    if (count == 0) then
        write (*, '(A)') 'Connect a KeyNub dongle and re-run.'
        stop
    end if

    handle = keynub_open()   ! first dongle; keynub_open(serial) picks a specific one
    if (handle <= 0) then
        call fail(0_c_int32_t, 'keynub_open', handle)
    end if

    if (keynub_serial(handle, serial) == LICD_OK) then
        write (*, '(A,A)') 'dongle ', trim(serial)
    end if

    status = licdf_session_open(handle)
    if (status /= LICD_OK) call fail(handle, 'licdf_session_open', status)
    status = licdf_write_auth(handle, current, int(size(current), c_int32_t))
    if (status /= LICD_OK) call fail(handle, 'licdf_write_auth', status)
    status = licdf_write_auth_rotate(handle, replacement, int(size(replacement), c_int32_t))
    if (status /= LICD_OK) call fail(handle, 'licdf_write_auth_rotate', status)
    write (*, '(A)') 'rotated: this dongle now answers only to your key'
    status = licdf_session_close(handle)

    ! A fresh session is the only place the change is observable: the session above
    ! keeps the role it was already granted.
    status = licdf_session_open(handle)
    if (status /= LICD_OK) call fail(handle, 'licdf_session_open', status)
    status = licdf_write_auth(handle, current, int(size(current), c_int32_t))
    if (status == LICD_OK) then
        write (*, '(A)') 'WARNING: the old key still works -- do not ship this unit'
        status = licdf_close(handle)
        stop 1
    end if
    write (*, '(A)') 'confirmed: the old key no longer elevates'
    status = licdf_write_auth(handle, replacement, int(size(replacement), c_int32_t))
    if (status /= LICD_OK) call fail(handle, 'licdf_write_auth', status)
    write (*, '(A)') 'confirmed: your key elevates'
    status = licdf_session_close(handle)
    status = licdf_close(handle)

    write (*, '(A)') ''
    write (*, '(A)') 'Keep the replacement key safe. Every future write to this dongle needs it.'

contains

    !> The DER file as a byte array, which is what the flat API takes.
    subroutine read_key(path, key)
        character(len=*), intent(in) :: path
        integer(c_int8_t), allocatable, intent(out) :: key(:)
        integer :: unit, length, ios
        open (newunit=unit, file=path, access='stream', form='unformatted', &
              status='old', action='read', iostat=ios)
        if (ios /= 0) then
            write (*, '(A,A)') 'cannot open ', path
            stop 2
        end if
        inquire (unit=unit, size=length)
        allocate (key(length))
        read (unit) key
        close (unit)
    end subroutine read_key

    subroutine fail(handle, what, status)
        integer(c_int32_t), intent(in) :: handle, status
        character(len=*), intent(in) :: what
        integer(c_int32_t) :: ignored
        write (*, '(A,A,A,A)') 'KeyNub error in ', what, ': ', trim(keynub_status_text(status))
        if (handle > 0) then
            write (*, '(A,A)') '  detail: ', trim(keynub_last_error(handle))
            ignored = licdf_close(handle)
        end if
        stop 1
    end subroutine fail

end program rotate_write_key
