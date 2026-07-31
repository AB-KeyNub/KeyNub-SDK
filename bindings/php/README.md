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

> Read [`../../docs/integration-security.md`](../../docs/integration-security.md)
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
   (which the test suite has to do for the simulator entry points).

Static `FFI::new()` is also deprecated as of PHP 8.3; allocate through the
instance.

## Testing

```
KEYNUB_SIM_PATH=../../build/keynub_licdongle_sim.dll php test/test_end_to_end.php
```

47 assertions against an in-process software dongle — **no hardware** — with a
plain assertion harness rather than PHPUnit, so it needs no Composer install
either. The harness prints each section to STDERR unbuffered: a mistake in an FFI
binding is an access violation rather than an exception, and PHP's buffered stdout
is lost when the process dies, so without that a crash tells you nothing about
where it happened.
