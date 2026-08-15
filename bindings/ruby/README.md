# KeyNub License Dongle — Ruby binding

`keynub_licdongle` — the KeyNub dongle from Ruby. **No gems, no compiler**: the
FFI layer is [Fiddle](https://docs.ruby-lang.org/en/master/Fiddle.html), which is
part of Ruby's standard library. Ruby 3.0+, Windows / Linux / macOS.

```ruby
require 'keynub_licdongle'

KeyNubLicDongle::Context.open do |ctx|
  dongle = ctx.open              # first dongle, or ctx.open(serial)
  dongle.verify_genuine!         # raises unless genuine

  dongle.session do |session|
    data = session.app_decrypt(blob)   # <- build your licence check on this
  end
end
```

> Read [`../../docs/integration-security.md`](../../docs/integration-security.md)
> first. `exit unless licensed?` is one line to delete, and Ruby ships as source —
> even a `.rbc` or an obfuscator only slows that down. What cannot be deleted is
> data the program needs and only the dongle can decrypt.

## Why no `ffi` gem

The `ffi` gem is the usual choice and it is a fine library. Fiddle wins here for
one reason that matters specifically to licensing: it is **already in the standard
library**, so the check has no third-party dependency that a customer could
replace with a stub of their own. Nothing to install, nothing to build, nothing in
the load path but Ruby itself.

The cost is that the C signatures live in
[`lib/keynub_licdongle/native.rb`](lib/keynub_licdongle/native.rb) as data no
compiler verifies — which is why every one of them is written out by hand. Struct
layouts go through `Fiddle::Importer`, so the padding is computed rather than
hand-maintained; a hand-written offset that is wrong reads a neighbouring field
and produces a plausible wrong value rather than a crash.

## Errors

Failures raise `KeyNubLicDongle::Error` or a subclass, each carrying `status`
(the numeric `licd_status`), `operation`, and `detail` (the SDK's diagnostic text).

```ruby
begin
  dongle.verify_genuine!
rescue KeyNubLicDongle::DeviceNotFoundError
  warn 'please insert your KeyNub dongle'
rescue KeyNubLicDongle::CertificateInvalidError => e
  warn "this dongle was rejected: #{e.detail}"
end
```

`dongle.genuine?` is the non-raising form for a gate and **fails closed**: a
missing dongle, an I/O error and an invalid certificate all return `false`.

Blocks close things for you — `Context.open`, `dongle.session` — and are the
recommended form; `#close` is there when the lifetime is not lexical.

## Progress callbacks

`read_record` and `write_record` take a block called as `(done, total)`. Return
`false` to cancel, which raises `OperationCancelledError`. An exception raised
inside the block is held until the SDK has unwound its own transfer and then
re-raised with its own identity — letting it escape through the C frames would
skip that cleanup and strand the device mid-transfer.

```ruby
data = session.read_record('license') do |done, total|
  print "\r#{done}/#{total}"
  true
end
```

## Shipping the native library

The binding looks for the core library, in order:

1. `KEYNUB_LICDONGLE_LIBRARY` — an absolute path to a specific library
2. `vendor/` inside the gem
3. beside `lib/keynub_licdongle/`
4. the system search path

## License

Apache-2.0, like the rest of the SDK — [`../../LICENSE`](../../LICENSE),
[`../../THIRD-PARTY-NOTICES.txt`](../../THIRD-PARTY-NOTICES.txt).
