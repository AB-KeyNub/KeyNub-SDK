# KeyNub License Dongle — Fortran binding

Standard **Fortran 2003 `iso_c_binding`** interfaces to the SDK's
[flat companion API](../flat/README.md), plus helpers for the two things that are
awkward from Fortran: NUL-terminated strings and caller-allocated output buffers.
One module file, no build system of its own.

Aimed at where Fortran still ships commercial software: aerospace and structural
analysis, CFD, computational physics, reservoir and process simulation.

```fortran
use keynub_licdongle
integer(c_int32_t) :: handle, status
logical :: genuine
integer(c_int8_t), allocatable :: coefficients(:)

handle = keynub_open()                        ! > 0, or a negative status
if (handle < 0) error stop 'no KeyNub dongle attached'

status = keynub_verify_genuine(handle, genuine)
status = licdf_session_open(handle)
status = keynub_app_decrypt(handle, blob, coefficients)   ! the licence check
status = licdf_session_close(handle)
status = licdf_close(handle)
```

Compile the module alongside your program and link
`keynub_licdongle_flat`, which is self-contained — the core, Mbed TLS and hidapi
are compiled into it:

```
gfortran -c keynub_licdongle.f90
gfortran myprogram.f90 keynub_licdongle.o -L/path/to/native/ -lkeynub_licdongle_flat
```

Tested with **gfortran**. Any Fortran 2003 compiler should work — `iso_c_binding`
is standard — but Intel `ifx`, NAG and Cray have not been tried here.

## Conventions

- Every function returns `0` (`LICD_OK`) on success, otherwise a negative status.
  `keynub_open` is the exception and returns a **positive handle**.
  `keynub_status_text(status)` turns one into a message; `keynub_last_error(handle)`
  gives the SDK's diagnostic detail for the last failure.
- Bytes are `integer(c_int8_t)`, so values above 127 read as negative — Fortran
  has no unsigned integer type. Values round-trip exactly; use `transfer()` to
  move your own data in and out:

  ```fortran
  integer(c_int8_t), allocatable :: raw(:)
  real(c_double) :: coeffs(12)
  status = keynub_app_decrypt(handle, blob, raw)
  coeffs = transfer(raw, coeffs)
  ```

- The `licdf_*` interfaces are public, so you can call the C API directly. The
  `keynub_*` helpers exist for the calls where you would otherwise be building
  character arrays and sizing buffers by hand — `keynub_record_read`,
  `keynub_app_encrypt` and `keynub_app_decrypt` allocate their output for you.
- `keynub_record_erase` refuses an empty name. Erasing everything is
  `licdf_record_erase_all`, deliberately a different call: in Fortran an
  uninitialised `character` variable is blank, and that must not wipe a
  customer's dongle.

## Where the licence check goes

A Fortran program that does

```fortran
if (.not. genuine) error stop 'unlicensed'    ! <- one line to delete
```

is not protected, whatever the dongle proves. Solvers are also the easiest case
to protect properly, because they are full of data that is expensive to
reproduce: material models, empirical correlations, turbulence constants,
certified reference results. Encrypt those once with `keynub_app_encrypt`
(`KEYNUB_SCOPE_DEVELOPER`, so one file serves every customer) and decrypt at run
time. Without a dongle the solver has no coefficients, and there is nothing left
to delete.

See [`../../docs/integration-security.md`](../../docs/integration-security.md).

## License

Apache-2.0, like the rest of the SDK — see [`../../LICENSE`](../../LICENSE) and
[`../../THIRD-PARTY-NOTICES.txt`](../../THIRD-PARTY-NOTICES.txt).
