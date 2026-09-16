# KeyNub License Dongle — R package

```r
library(KeyNubLicDongle)

ctx <- licd_context()
dongle <- licd_open(ctx)                     # first dongle, or licd_open(ctx, serial)
licd_verify_genuine(dongle)                  # signals an error unless genuine
data <- licd_with_session(dongle,
  licd_app_decrypt(dongle, sealed))          # <- build the licence check on this
licd_close(dongle)
licd_close(ctx)
```

**No packages.** The R code reaches the SDK's C library through a small C
layer that R compiles when the package is installed, so nothing sits in the
path of the check that a customer could substitute.

R is the closest neighbour to the MATLAB and Julia bindings, and sells to the
same kind of buyer. If you sell an R package, the thing worth protecting is
usually not the code but the data: fitted parameters, a validated correlation
set, a proprietary model's coefficients. That is what
`licd_app_encrypt()`/`licd_app_decrypt()` is for.

## Setup

```r
install.packages("KeyNubLicDongle")
```

CRAN ships the package compiled for Windows and macOS; on Linux, R compiles the
C layer with the system compiler, as for any source package. Straight from the
repository instead:

```r
install.packages("remotes")
remotes::install_github("AB-KeyNub/KeyNub-SDK", subdir = "bindings/r")
```

The package loads the native library at run time and does not carry it. Take
`keynub_licdongle` for your platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and either put it where the operating system finds libraries (`PATH`,
`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`) or name it before the first call:

```r
licd_library("/opt/keynub/libkeynub_licdongle.so")
```

`KEYNUB_LICDONGLE_LIBRARY` in the environment does the same. In a clone of the
repository the package finds `natives/<platform>/` on its own, from the working
directory upwards, so the samples run with nothing set. A process loads the
library once; `licd_library()` tells which. On Linux, install the udev rule
described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Results are plain R values: `licd_info()` a list, `licd_enumerate()` and
  `licd_record_list()` data frames, records and sealed data raw vectors
  (`rawToChar()` for text). Counters are unsigned 32-bit and come back as
  doubles.
- Failures signal a condition of class `licd_error` carrying `status`,
  `operation` and `detail`. The ones a program branches on carry a more
  specific class in front: `licd_no_device`, `licd_not_genuine`,
  `licd_certificate_invalid`, `licd_session_expired`, `licd_not_found`,
  `licd_auth_required`, `licd_cancelled`. So
  `tryCatch(licd_open(ctx), licd_no_device = function(e) NULL)`.
- `licd_is_genuine(dongle)` is the non-signalling form for a gate and **fails
  closed**.
- `licd_with_session(dongle, expr)` closes the session afterwards, whatever
  happens inside `expr`.
- `licd_record_read()` and `licd_record_write()` take
  `progress = function(done, total)`; returning `FALSE` cancels. An error inside
  the function cancels the transfer rather than unwinding through the C frames,
  which would strand the device.
- `licd_record_erase_all()` is deliberately separate from `licd_record_erase()`:
  to the C library a missing name means "erase every record", and an
  accidentally empty variable must not do that.
- `licd_close()` releases a dongle or a context, and the garbage collector
  releases what is forgotten: a context reclaimed with dongles still open closes
  them first.
- The SDK's C header is installed with the package,
  `system.file("include", "licdongle.h", package = "KeyNubLicDongle")`, for code
  that talks to the library directly.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if (!licd_is_genuine(dongle)) stop()` is one line to
> delete, and R ships as source. What cannot be deleted is data the program
> needs and only the dongle can decrypt.

## Tests

`tests/stub.R` runs without a dongle: it compiles a stand-in for the C ABI from
`tests/licd_stub.c` with R's own toolchain (`R CMD SHLIB`) and exercises every
call against it, which is what `R CMD check` runs.

## Links

- [KeyNub License Dongle for R](https://www.keynub.com/developers/r/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
