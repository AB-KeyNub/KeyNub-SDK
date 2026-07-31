! KeyNub dongle check from Fortran: enumerate -> open -> verify -> session ->
! read a record -> app-crypto round trip.
!
!   gfortran -c ../../../bindings/fortran/keynub_licdongle.f90
!   gfortran verify_and_read.f90 keynub_licdongle.o -L<native dir> \
!            -lkeynub_licdongle_flat -o verify_and_read
!
! The binding is standard Fortran 2003 ISO_C_BINDING over the flat companion API,
! so it works with gfortran, Intel and NAG without anything vendor-specific.
!
! Targets real hardware: with no dongle attached it prints guidance and stops.
!
! READ FIRST: docs/integration-security.md. This sample prints whether the dongle
! is genuine, which is the one thing a real licence check must not do -- a printed
! logical is a deleted line away from nothing. protect_something shows the shape
! that actually protects something, and for a Fortran solver it is usually the
! natural one: the valuable part is already data, not code.

program verify_and_read
    use iso_c_binding
    use keynub_licdongle
    implicit none

    integer(c_int32_t) :: handle, status, count, i, vmaj, vmin, vpat
    character(kind=c_char) :: serial_buf(KEYNUB_SERIAL_LEN + 1)

    status = licdf_version(vmaj, vmin, vpat)
    write (*, '(A,I0,A,I0,A,I0)') 'KeyNub SDK ', vmaj, '.', vmin, '.', vpat

    status = licdf_device_count(count)
    write (*, '(A,I0,A)') 'Found ', count, ' KeyNub dongle(s).'
    do i = 0, count - 1
        status = licdf_device_serial(i, serial_buf, int(size(serial_buf), c_int32_t))
        if (status == LICD_OK) then
            write (*, '(A,I0,A,A)') '  [', i, '] serial ', trim(keynub_f_string(serial_buf))
        end if
    end do
    if (count == 0) then
        write (*, '(A)') 'No dongle attached; nothing to do.'
        stop
    end if

    ! No argument = first dongle found; pass a serial to pick a specific dongle.
    handle = keynub_open()
    if (handle < 0) then
        write (*, '(A,A)') 'Could not open a dongle: ', trim(keynub_status_text(handle))
        error stop 1
    end if

    call report(handle)

    status = licdf_session_open(handle)
    if (status /= LICD_OK) then
        call fail(handle, 'session_open', status)
    else
        call read_records(handle)
        call protect_something(handle)
        status = licdf_session_close(handle)
    end if

    status = licdf_close(handle)

contains

    subroutine report(h)
        integer(c_int32_t), intent(in) :: h
        integer(c_int32_t) :: st
        logical :: genuine
        character(len=KEYNUB_SERIAL_LEN) :: dev_serial
        character(len=KEYNUB_BATCH_LEN)  :: batch

        st = keynub_verify_genuine(h, genuine, dev_serial, batch)
        if (st /= LICD_OK) then
            call fail(h, 'verify_genuine', st)
            return
        end if
        write (*, '(A,L1,A,A,A,A,A)') 'Genuine: ', genuine, &
            ' (serial ', trim(dev_serial), ', batch ', trim(batch), ')'
    end subroutine report

    subroutine read_records(h)
        integer(c_int32_t), intent(in) :: h
        integer(c_int32_t) :: n, k, st, rec_size
        character(len=64) :: name
        integer(c_int8_t), allocatable :: data(:)

        st = licdf_record_count(h, n)
        write (*, '(I0,A)') n, ' record(s) on the dongle:'
        do k = 0, n - 1
            st = keynub_record_name(h, k, name, rec_size)
            if (st == LICD_OK) then
                write (*, '(A,A16,I8,A)') '  ', name, rec_size, ' bytes'
            end if
        end do

        ! A missing record is a normal state, not an error, so a non-OK status here
        ! is not worth reporting as a failure.
        st = keynub_record_read(h, 'license', data)
        if (st == LICD_OK) then
            write (*, '(A,I0,A)') 'Read ', size(data), ' bytes from the license record.'
        end if
    end subroutine read_records

    ! The part that actually protects something. At licence-issue time you would
    ! call app_encrypt once, with a developer dongle, and ship only the blob; the
    ! solver then cannot run without a dongle, because it holds no other copy of
    ! the data. For a Fortran code that data is usually the material properties,
    ! empirical coefficients or validated constants read at start-up -- the part a
    ! competitor cannot regenerate. Scope 1 (developer) lets any dongle from your
    ! batch decrypt it; scope 0 locks it to one physical dongle.
    subroutine protect_something(h)
        integer(c_int32_t), intent(in) :: h
        integer(c_int8_t), allocatable :: needed(:), blob(:), recovered(:)
        character(len=*), parameter :: text = 'the data this program cannot run without'
        integer(c_int32_t) :: st
        integer :: k
        logical :: intact

        allocate (needed(len(text)))
        do k = 1, len(text)
            needed(k) = int(iachar(text(k:k)), c_int8_t)
        end do

        st = keynub_app_encrypt(h, 1_c_int32_t, needed, blob)
        if (st /= LICD_OK) then
            call fail(h, 'app_encrypt', st)
            return
        end if
        st = keynub_app_decrypt(h, blob, recovered)
        if (st /= LICD_OK) then
            call fail(h, 'app_decrypt', st)
            return
        end if

        intact = size(recovered) == size(needed)
        if (intact) intact = all(recovered == needed)
        if (intact) then
            write (*, '(A,I0,A,I0,A)') 'App-crypto round trip: ', size(needed), &
                ' bytes -> ', size(blob), ' sealed -> recovered intact'
        else
            write (*, '(A)') 'App-crypto round trip: MISMATCH'
        end if
    end subroutine protect_something

    ! last_error carries the SDK's diagnostic text, which is what tells
    ! "no dongle" from "certificate rejected".
    subroutine fail(h, operation, status)
        integer(c_int32_t), intent(in) :: h, status
        character(len=*),   intent(in) :: operation
        write (*, '(A,A,A,A)') 'KeyNub error in ', operation, ': ', &
            trim(keynub_status_text(status))
        write (*, '(A,A)') '  detail: ', trim(keynub_last_error(h))
    end subroutine fail

end program verify_and_read
