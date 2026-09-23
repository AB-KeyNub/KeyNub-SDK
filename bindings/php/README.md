# KeyNub License Dongle — PHP binding

```php
require 'src/KeyNub.php';
use KeyNub\LicDongle\Context;

$ctx = new Context();
$dongle = $ctx->open();                    // first dongle, or open('serial')
$dongle->verifyGenuine();                  // throws unless genuine
$session = $dongle->openSession();
$data = $session->appDecrypt($blob);       // <- build the licence check on this
```

PHP **8.0+**, using the bundled **FFI extension** — no PECL module, no Composer
package, no compiler. Enable it in `php.ini`:

```ini
extension=ffi
ffi.enable=true
```

The C declarations in `src/Native.php` are the header's own text, pasted:
`FFI::cdef` parses real C, so there is one less transformation to get wrong than
in a binding that restates the ABI in another notation.

## Notes

- Results are arrays (`$info['dataFree']`, `$result['genuine']`), which is what
  PHP code expects; byte data is a plain `string`.
- Failures throw `LicenseDongleException` or a subclass, each carrying `$status`,
  `$operation` and `$detail`.
- `$dongle->isGenuine()` is the non-throwing form for a gate and **fails closed**.
- `readRecord`/`writeRecord` accept a `callable(int $done, int $total)`; returning
  `false` cancels. An exception from it is held and re-thrown once the SDK has
  unwound its own transfer.

> Read [`../../docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> first. `if (!$licensed) die();` is one line to delete, and PHP ships as source.
> What cannot be deleted is data the application needs and only the dongle can
> decrypt — a rate table, a licensed data set, the parameters of a calculation.

## Three PHP FFI traps, since they cost real time here

1. **A `CData` from `FFI::cast()` is a *view*, not a copy.** Casting a local
   pointer and returning it leaves the caller holding a pointer into storage PHP
   frees on return — an access violation on first use, with no exception and, if
   output is buffered, no output either. Allocate the destination in the scope that
   will keep it and let C write into that.
2. **An element of a temporary array can also be a view.** Prefer
   `$ffi->new('licd_ctx*')` plus `FFI::addr($handle)` over
   `$ffi->new('licd_ctx*[1]')` plus `FFI::addr($out[0])`.
3. **Types from two different `FFI::cdef` instances are distinct** even when the C
   text is identical, so handles must be `cast()` when they cross between them
   when mixing this binding with FFI declarations of your own.

Static `FFI::new()` is also deprecated as of PHP 8.3; allocate through the
instance.

## Tests

`php test/test_standin.php` runs without a dongle: it compiles a stand-in for
the C ABI (`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the
path and exercises every call against it. `KEYNUB_SDK_ROOT` names the SDK
sources when the package is not inside a clone; `KEYNUB_LICDONGLE_LIBRARY` names
a compiled stand-in instead.

## Links

- [KeyNub License Dongle for PHP](https://www.keynub.com/developers/php/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
