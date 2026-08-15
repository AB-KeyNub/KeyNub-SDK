//! KeyNub SDK - Rust sample: take ownership of a new dongle.
//!
//! A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
//! that from the next session onward only your key can write records, erase them or
//! increment counters. Run it once per dongle, when it arrives.
//!
//! Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//!
//! ```text
//! openssl ecparam -name prime256v1 -genkey -noout |
//!   openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//!
//! KEYNUB_LIB_DIR=../../../build cargo run -- ../../../keys/keynub-shipping-writeauth.key.der my-key.der
//! ```
//!
//! Targets real hardware: with no dongle attached it prints guidance and exits 0.
//!
//! The replacement key is worth what your licence-signing key is worth. It cannot
//! be recovered from the dongle, and a unit rotated to a key you have lost has to
//! come back to be re-provisioned.

use std::process::ExitCode;

use keynub_licdongle::{Context, Error};

fn rotate(current: &[u8], replacement: &[u8]) -> Result<bool, Error> {
    let ctx = Context::new()?;

    if ctx.enumerate()?.is_empty() {
        println!("Connect a KeyNub dongle and re-run.");
        return Ok(true);
    }

    // None = first dongle found; pass a serial to pick a specific one.
    let dongle = ctx.open(None)?;
    println!("dongle {}", dongle.serial()?);

    {
        let session = dongle.open_session()?;
        session.authorize_write(current)?;
        session.rotate_write_key(replacement)?;
        println!("rotated: this dongle now answers only to your key");
    }

    // A fresh session is the only place the change is observable: the session
    // above keeps the role it was already granted.
    let session = dongle.open_session()?;
    if session.authorize_write(current).is_ok() {
        eprintln!("WARNING: the old key still works -- do not ship this unit");
        return Ok(false);
    }
    println!("confirmed: the old key no longer elevates");
    session.authorize_write(replacement)?;
    println!("confirmed: your key elevates");

    println!("\nKeep the replacement key safe. Every future write to this dongle needs it.");
    Ok(true)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: {} <current-key.der> <new-key.der>", args[0]);
        return ExitCode::from(2);
    }
    let current = match std::fs::read(&args[1]) {
        Ok(bytes) => bytes,
        Err(err) => {
            eprintln!("{}: {err}", args[1]);
            return ExitCode::from(2);
        }
    };
    let replacement = match std::fs::read(&args[2]) {
        Ok(bytes) => bytes,
        Err(err) => {
            eprintln!("{}: {err}", args[2]);
            return ExitCode::from(2);
        }
    };

    match rotate(&current, &replacement) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(err) => {
            eprintln!("KeyNub error: {err}");
            ExitCode::FAILURE
        }
    }
}
