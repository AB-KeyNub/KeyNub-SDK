// Tells cargo where the KeyNub native library is and what to link.
//
//   KEYNUB_LIB_DIR   directory holding the library (required unless it is already
//                    on the linker's default search path)
//   KEYNUB_LIB_NAME  override the library name; defaults to keynub_licdongle
//   KEYNUB_STATIC    set to 1 to link the static library instead of the shared one
//
// A build script rather than a vendored copy of the C sources: the core is built
// by CMake with its own submodules (Mbed TLS, hidapi), and duplicating that in
// cargo would create a second thing to keep correct.

use std::env;

fn main() {
    println!("cargo:rerun-if-env-changed=KEYNUB_LIB_DIR");
    println!("cargo:rerun-if-env-changed=KEYNUB_LIB_NAME");
    println!("cargo:rerun-if-env-changed=KEYNUB_STATIC");

    // Say so when the variable is absent, rather than leaving the linker to fail.
    //
    // The crate carries no native library: it is not open source and cannot be
    // vendored, so a developer who runs `cargo add keynub_licdongle` and builds hits
    // a linker error naming a symbol, with nothing pointing at the cause. On
    // crates.io that is the first experience of the package, so the build script has
    // to name the variable itself.
    match env::var("KEYNUB_LIB_DIR").ok().or_else(repo_natives_dir) {
        Some(dir) => println!("cargo:rustc-link-search=native={dir}"),
        None => println!(
            "cargo:warning=KEYNUB_LIB_DIR is not set, so the linker will look for the \
             KeyNub native library on its default search path only. Download the SDK \
             archive for your platform and set KEYNUB_LIB_DIR to the directory holding \
             it (the lib/ folder on Linux and macOS, the architecture folder on \
             Windows). See https://github.com/AB-KeyNub/KeyNub-SDK"
        ),
    }

    let name = env::var("KEYNUB_LIB_NAME").unwrap_or_else(|_| "keynub_licdongle".to_string());

    let static_link = env::var("KEYNUB_STATIC").map(|v| v == "1").unwrap_or(false);
    if static_link {
        println!("cargo:rustc-link-lib=static={name}");
        // A static core does not carry its own dependencies, so name them here.
        // With the shared library these are already resolved inside it.
        let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
        match target_os.as_str() {
            "windows" => {
                for lib in ["setupapi", "hid", "advapi32", "bcrypt"] {
                    println!("cargo:rustc-link-lib=dylib={lib}");
                }
            }
            "macos" => {
                println!("cargo:rustc-link-lib=framework=IOKit");
                println!("cargo:rustc-link-lib=framework=CoreFoundation");
            }
            _ => {
                println!("cargo:rustc-link-lib=dylib=udev");
                println!("cargo:rustc-link-lib=dylib=pthread");
            }
        }
        // mbedcrypto/mbedx509 are separate archives in the CMake build tree.
        for lib in ["mbedx509", "mbedcrypto"] {
            println!("cargo:rustc-link-lib=static={lib}");
        }
    } else {
        println!("cargo:rustc-link-lib=dylib={name}");
    }
}

/// The prebuilt library a checkout of the SDK carries, per platform.
///
/// Building this crate from inside the repository needs no environment variable:
/// `natives/<rid>/` is beside it. A crate installed from crates.io has no such
/// directory, so this returns `None` there and `KEYNUB_LIB_DIR` is the answer.
fn repo_natives_dir() -> Option<String> {
    let os = match env::var("CARGO_CFG_TARGET_OS").ok()?.as_str() {
        "windows" => "win",
        "macos" => "osx",
        "linux" => "linux",
        _ => return None,
    };
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").ok()?.as_str() {
        "x86_64" => "x64",
        "x86" => "x86",
        "aarch64" => "arm64",
        _ => return None,
    };
    let manifest = env::var("CARGO_MANIFEST_DIR").ok()?;
    let dir = std::path::Path::new(&manifest)
        .join("..")
        .join("..")
        .join("natives")
        .join(format!("{os}-{arch}"));
    if dir.is_dir() {
        println!("cargo:rerun-if-changed={}", dir.display());
        Some(dir.to_string_lossy().into_owned())
    } else {
        None
    }
}
