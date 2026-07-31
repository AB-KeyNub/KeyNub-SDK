//! KeyNub dongle check from Rust: enumerate -> open -> verify -> session ->
//! read a record -> app-crypto round trip.
//!
//! ```text
//! KEYNUB_LIB_DIR=../../../build cargo run
//! ```
//!
//! Targets real hardware: with no dongle attached it prints guidance and exits 0.
//!
//! READ FIRST: docs/integration-security.md. This sample prints whether the dongle
//! is genuine, which is the one thing a real licence check must not do — a printed
//! boolean is a deleted line away from nothing. `protect_something` shows the shape
//! that actually protects something.
//!
//! Two things the Rust binding gives you that the C ABI cannot. `Session` borrows
//! its `Dongle`, so "session outlived the dongle it came from" is a compile error
//! rather than a use-after-free. And `Drop` closes both, so there is no cleanup
//! path to forget — including on the `?` early returns below.

use keynub_licdongle::{Context, Dongle, Error, RecordInfo, Scope, Session};

fn report(dongle: &Dongle) -> Result<(), Error> {
    let info = dongle.info()?;
    let (pmaj, pmin) = info.protocol_version;
    let (fmaj, fmin, fpatch) = info.firmware_version;
    println!(
        "Protocol v{pmaj}.{pmin}, firmware v{fmaj}.{fmin}.{fpatch}, {} of {} bytes free.",
        info.data_free, info.data_capacity
    );

    if info.watchdog_reboot {
        // The only trace a firmware hang leaves behind. Worth reporting to support.
        println!("WARNING: this dongle's previous boot ended in a watchdog reset.");
    }

    let result = dongle.verify_genuine()?;
    println!(
        "Genuine: {} (serial {}, batch {}, provisioned {})",
        result.genuine, result.serial, result.batch, result.provisioned_date
    );
    Ok(())
}

fn read_records(session: &Session) -> Result<(), Error> {
    let records: Vec<RecordInfo> = session.list_records()?;
    println!("{} record(s) on the dongle:", records.len());
    for record in &records {
        println!("  {:<16} {:>6} bytes", record.name, record.size);
    }

    // A missing record is a normal state, not an error, so this is an Option rather
    // than a lookup that can fail.
    if records.iter().any(|r| r.name == "license") {
        let data = session.read_record("license")?;
        println!("Read {} bytes from the license record.", data.len());
    }
    Ok(())
}

/// The part that actually protects something. At licence-issue time you would call
/// `app_encrypt` once, with a developer dongle, and ship only the blob; the
/// application then cannot proceed without a dongle, because it holds no other copy
/// of the data. `Scope::Developer` lets any dongle from your batch decrypt it, so one
/// file serves every customer; `Scope::Device` locks it to one dongle.
fn protect_something(session: &Session) -> Result<(), Error> {
    let needed = b"the data this program cannot run without";

    let sealed = session.app_encrypt(Scope::Developer, needed)?;
    let recovered = session.app_decrypt(&sealed)?;

    let outcome = if recovered == needed {
        "recovered intact"
    } else {
        "MISMATCH"
    };
    println!(
        "App-crypto round trip: {} bytes -> {} sealed -> {outcome}",
        needed.len(),
        sealed.len()
    );
    Ok(())
}

fn run() -> Result<(), Error> {
    let ctx = Context::new()?;

    let devices = ctx.enumerate()?;
    println!("Found {} KeyNub dongle(s).", devices.len());
    for (i, d) in devices.iter().enumerate() {
        println!(
            "  [{i}] serial {} (VID {:04X} PID {:04X})",
            d.serial, d.vendor_id, d.product_id
        );
    }
    if devices.is_empty() {
        println!("No dongle attached; nothing to do.");
        return Ok(());
    }

    // None = first dongle found; pass Some(serial) to pick a specific one.
    let dongle = ctx.open(None)?;
    report(&dongle)?;

    let session = dongle.open_session()?;
    read_records(&session)?;
    protect_something(&session)?;
    Ok(())
}

fn main() -> std::process::ExitCode {
    let v = Context::library_version();
    println!("KeyNub SDK {}.{}.{}", v.major, v.minor, v.patch);

    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(err) => {
            // Match on `status` rather than on the message; `detail` carries the
            // SDK's own diagnostic text, which is what tells "no dongle" from
            // "certificate rejected".
            eprintln!("KeyNub error ({:?}) in {}: {err}", err.status, err.operation);
            if !err.detail.is_empty() {
                eprintln!("  detail: {}", err.detail);
            }
            std::process::ExitCode::FAILURE
        }
    }
}
