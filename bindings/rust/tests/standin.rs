//! Every call of the binding against the C ABI stand-in:
//! `bindings/julia/test/stub/licd_stub.c`, one imaginary dongle held in memory,
//! compiled into a shared library named `keynub_licdongle_standin` that the
//! crate links through `KEYNUB_LIB_DIR` and `KEYNUB_LIB_NAME`. The tests are
//! ignored unless asked for, since a normal build links the real library.
//! From this directory, on Windows (PowerShell; `zig cc` or MinGW-w64 `gcc`
//! compiles the stand-in):
//!
//! ```text
//! mkdir -Force $env:TEMP\kn-rust > $null
//! zig cc -shared -O1 -DLICD_BUILD_SHARED -I../../include ../julia/test/stub/licd_stub.c -o $env:TEMP\kn-rust\keynub_licdongle_standin.dll "-Wl,--out-implib,$env:TEMP\kn-rust\keynub_licdongle_standin.lib"
//! $env:KEYNUB_LIB_DIR = "$env:TEMP\kn-rust"; $env:KEYNUB_LIB_NAME = "keynub_licdongle_standin"
//! $env:PATH = "$env:TEMP\kn-rust;$env:PATH"
//! cargo test --test standin -- --ignored
//! ```
//!
//! On Linux:
//!
//! ```text
//! mkdir -p /tmp/kn-rust
//! cc -shared -fPIC -O1 -DLICD_BUILD_SHARED -I../../include ../julia/test/stub/licd_stub.c -o /tmp/kn-rust/libkeynub_licdongle_standin.so
//! KEYNUB_LIB_DIR=/tmp/kn-rust KEYNUB_LIB_NAME=keynub_licdongle_standin LD_LIBRARY_PATH=/tmp/kn-rust cargo test --test standin -- --ignored
//! ```
//!
//! The stand-in keeps records, counters and the write key per opened device, so
//! each test starts from a fresh dongle.

use keynub_licdongle::{
    Context, DeviceInfo, GenuineResult, Info, RecordInfo, Scope, Status, Version,
};

const SERIAL: &str = "04A1B2C3D4E5F6";
const FACTORY_KEY: &[u8] = &[0x30, 0x10, 0x01, 0x02, 0x03];
const REPLACEMENT_KEY: &[u8] = &[0x30, 0x11, 0x09, 0x08, 0x07, 0x06];

fn status<T: std::fmt::Debug>(result: keynub_licdongle::Result<T>) -> Status {
    result.expect_err("no failure").status
}

#[test]
#[ignore = "links the ABI stand-in (see the top of tests/standin.rs)"]
fn version_devices_and_open() {
    assert_eq!(Context::library_version(), Version { major: 9, minor: 8, patch: 7 });
    assert_eq!(Context::library_version().to_string(), "9.8.7");

    let ctx = Context::new().unwrap();
    assert_eq!(
        ctx.enumerate().unwrap(),
        vec![DeviceInfo {
            serial: SERIAL.into(),
            path: "stub:0".into(),
            vendor_id: 0x1234,
            product_id: 0xABCD,
        }]
    );

    let e = ctx.open(Some("nope")).err().expect("no failure");
    assert_eq!(e.status, Status::NoDevice);
    assert_eq!(e.operation, "licd_open");
    assert_eq!(e.detail, "no dongle with that serial");
    assert_eq!(e.to_string(), "licd_open: no device (no dongle with that serial)");
    assert_eq!(ctx.last_error_detail(), "no dongle with that serial");
    assert_eq!(ctx.open_path("stub:9").err().expect("no failure").status, Status::NoDevice);
    assert_eq!(ctx.open(Some("a\0b")).err().expect("no failure").status, Status::InvalidArgument);

    assert_eq!(ctx.open(None).unwrap().serial().unwrap(), SERIAL);
    assert_eq!(ctx.open(Some(SERIAL)).unwrap().serial().unwrap(), SERIAL);
    assert_eq!(ctx.open_path("stub:0").unwrap().serial().unwrap(), SERIAL);
}

#[test]
#[ignore = "links the ABI stand-in (see the top of tests/standin.rs)"]
fn info_and_genuine() {
    let ctx = Context::new().unwrap();
    let d = ctx.open(None).unwrap();
    assert_eq!(
        d.info().unwrap(),
        Info {
            protocol_version: (1, 0),
            firmware_version: (2, 3, 4),
            se_ready: true,
            provisioned: true,
            data_capacity: 1024 * 1024,
            data_free: 1_000_000,
            watchdog_reboot: false,
            isolated: true,
            writeauth_rotated: false,
        }
    );
    assert_eq!(
        d.verify_genuine().unwrap(),
        GenuineResult {
            genuine: true,
            serial: SERIAL.into(),
            provisioned_date: "2026-08-15".into(),
        }
    );
    assert!(d.is_genuine());
}

#[test]
#[ignore = "links the ABI stand-in (see the top of tests/standin.rs)"]
fn trust_root() {
    let ctx = Context::new().unwrap();
    let d = ctx.open(None).unwrap();
    assert_eq!(status(ctx.set_trust_root(&[0x02, 0x01, 0x00])), Status::CertificateInvalid);
    assert_eq!(status(ctx.set_trust_root(&[])), Status::InvalidArgument);

    let mut root = vec![0x30, 0x82, 0x01, 0x00];
    root.extend([0xAB; 128]);
    ctx.set_trust_root(&root).unwrap();
    assert_eq!(status(d.verify_genuine()), Status::CertificateInvalid);
    assert!(!d.is_genuine(), "is_genuine fails closed");

    root[4..].fill(0x01);
    ctx.set_trust_root(&root).unwrap();
    assert!(d.is_genuine());
}

#[test]
#[ignore = "links the ABI stand-in (see the top of tests/standin.rs)"]
fn records_and_write_role() {
    let ctx = Context::new().unwrap();
    let d = ctx.open(None).unwrap();
    let s = d.open_session().unwrap();

    let payload = b"license-blob-0123456789";
    assert_eq!(status(s.write_record("lic", payload)), Status::AuthRequired);
    assert_eq!(status(s.erase_record("lic")), Status::AuthRequired);
    assert_eq!(status(s.erase_all_records()), Status::AuthRequired);
    assert_eq!(status(s.increment_counter(0)), Status::AuthRequired);
    assert_eq!(status(s.authorize_write(&[0x30, 0x00])), Status::NotGenuine);

    s.authorize_write(FACTORY_KEY).unwrap();
    s.write_record("lic", payload).unwrap();
    assert_eq!(s.read_record("lic").unwrap(), payload);
    s.write_record("cfg", b"cfgdata").unwrap();
    let records = s.list_records().unwrap();
    let mut names: Vec<_> = records.iter().map(|r| r.name.as_str()).collect();
    names.sort();
    assert_eq!(names, ["cfg", "lic"]);
    let lic = RecordInfo { name: "lic".into(), size: payload.len() as u32 };
    assert!(records.contains(&lic));
    assert_eq!(s.read_record("cfg").unwrap(), b"cfgdata");
    assert_eq!(status(s.read_record("nope")), Status::NotFound);
    assert_eq!(status(s.erase_record("nope")), Status::NotFound);

    // An empty name is refused by the binding, never passed on as "erase everything".
    assert_eq!(status(s.erase_record("")), Status::InvalidArgument);
    assert_eq!(status(s.read_record("")), Status::InvalidArgument);
    assert_eq!(status(s.write_record("", payload)), Status::InvalidArgument);
    assert_eq!(status(s.read_record("a\0b")), Status::InvalidArgument);
    assert_eq!(s.list_records().unwrap().len(), 2);
    s.erase_record("cfg").unwrap();
    assert_eq!(s.list_records().unwrap(), vec![lic]);

    s.write_record("empty", &[]).unwrap();
    assert!(s.read_record("empty").unwrap().is_empty());

    // Bigger than one transfer chunk, with progress, cancellation and a panicking callback.
    let big: Vec<u8> = (0..3000u32).map(|k| (k * 31 + 5) as u8).collect();
    let mut last = 0;
    s.write_record_with_progress("big", &big, |done, _| {
        last = done;
        true
    })
    .unwrap();
    assert_eq!(last, 3000, "write progress");
    last = 0;
    let read = s
        .read_record_with_progress("big", |done, _| {
            last = done;
            true
        })
        .unwrap();
    assert_eq!(read, big);
    assert_eq!(last, 3000, "read progress");
    assert_eq!(status(s.read_record_with_progress("big", |_, _| false)), Status::Cancelled);
    let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = s.read_record_with_progress("big", |_, _| panic!("from the callback"));
    }));
    let caught = panicked.expect_err("the panic is resumed");
    assert_eq!(*caught.downcast::<&str>().unwrap(), "from the callback");
    assert_eq!(s.read_record("big").unwrap(), big);

    s.erase_all_records().unwrap();
    assert!(s.list_records().unwrap().is_empty());
}

#[test]
#[ignore = "links the ABI stand-in (see the top of tests/standin.rs)"]
fn counters() {
    let ctx = Context::new().unwrap();
    let d = ctx.open(None).unwrap();
    let s = d.open_session().unwrap();
    s.authorize_write(FACTORY_KEY).unwrap();

    let before = s.read_counter(0).unwrap();
    assert_eq!(s.increment_counter(0).unwrap(), before + 1);
    assert_eq!(s.read_counter(0).unwrap(), before + 1);
    assert_eq!(s.read_counter(1).unwrap(), 0);
    assert_eq!(status(s.read_counter(7)), Status::Range);
    assert_eq!(status(s.increment_counter(7)), Status::Range);
}

#[test]
#[ignore = "links the ABI stand-in (see the top of tests/standin.rs)"]
fn app_encrypt_and_decrypt() {
    let ctx = Context::new().unwrap();
    let d = ctx.open(None).unwrap();
    let s = d.open_session().unwrap();

    let secret: Vec<u8> = (0..100u32).map(|k| ((3 * k + 7) % 256) as u8).collect();
    for (scope, byte) in [(Scope::Device, 0u8), (Scope::Developer, 1u8)] {
        let blob = s.app_encrypt(scope, &secret).unwrap();
        assert!(blob.len() > secret.len(), "sealed data is longer, {scope:?}");
        assert_eq!(blob[0], byte, "scope byte, {scope:?}");
        assert_eq!(s.app_decrypt(&blob).unwrap(), secret, "round trip, {scope:?}");
        let mut tampered = blob.clone();
        *tampered.last_mut().unwrap() ^= 1;
        let what = format!("tampered blob, {scope:?}");
        assert_eq!(status(s.app_decrypt(&tampered)), Status::TagMismatch, "{what}");
    }
    assert!(s.app_decrypt(&s.app_encrypt(Scope::Device, &[]).unwrap()).unwrap().is_empty());
}

#[test]
#[ignore = "links the ABI stand-in (see the top of tests/standin.rs)"]
fn write_key_rotation() {
    let ctx = Context::new().unwrap();
    let d = ctx.open(None).unwrap();
    {
        let s = d.open_session().unwrap();
        assert_eq!(status(s.rotate_write_key(REPLACEMENT_KEY)), Status::AuthRequired);
        s.authorize_write(FACTORY_KEY).unwrap();
        s.rotate_write_key(REPLACEMENT_KEY).unwrap();
        s.write_record("lic", b"still-writable").unwrap(); // the session keeps its role
    }
    assert!(d.info().unwrap().writeauth_rotated);

    let s = d.open_session().unwrap();
    assert_eq!(status(s.authorize_write(FACTORY_KEY)), Status::NotGenuine);
    s.authorize_write(REPLACEMENT_KEY).unwrap();
    s.write_record("lic", b"new-key-writes").unwrap();
    assert_eq!(s.read_record("lic").unwrap(), b"new-key-writes");
}

#[test]
#[ignore = "links the ABI stand-in (see the top of tests/standin.rs)"]
fn session_and_close_semantics() {
    let ctx = Context::new().unwrap();
    let d = ctx.open(None).unwrap();

    let mut s = d.open_session().unwrap();
    s.list_records().unwrap();
    s.close();
    s.close(); // idempotent
    assert_eq!(status(s.list_records()), Status::SessionExpired);
    assert_eq!(status(s.read_counter(0)), Status::SessionExpired);
    drop(s);

    // Dropping a session ends it on the device.
    {
        let s = d.open_session().unwrap();
        s.read_counter(0).unwrap();
    }
    let mut again = d.open_session().unwrap();
    again.close();
    assert_eq!(status(again.read_counter(0)), Status::SessionExpired);
    drop(again);

    // adopt takes over a raw handle; the adopting Dongle closes it.
    let raw = unsafe { d.as_raw() };
    assert!(!unsafe { ctx.as_raw() }.is_null());
    std::mem::forget(d);
    let adopted = unsafe { ctx.adopt(raw) };
    assert_eq!(adopted.serial().unwrap(), SERIAL);
    drop(adopted);
    drop(ctx);
}
