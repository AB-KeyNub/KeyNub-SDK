// Tells cargo where the KeyNub native library is and what to link.
//
//   KEYNUB_LIB_DIR   directory holding the library (required unless it is already
//                    on the linker's default search path)
//   KEYNUB_LIB_NAME  override the library name; defaults to keynub_licdongle, or
//                    keynub_licdongle_sim with the `simulator` feature
//   KEYNUB_STATIC    set to 1 to link the static library instead of the shared one
//
// A build script rather than a vendored copy of the C sources: the core is built
// by the native build with its own submodules (Mbed TLS, hidapi), and duplicating that in
// cargo would create a second thing to keep correct.

use std::env;

fn main() {
    println!("cargo:rerun-if-env-changed=KEYNUB_LIB_DIR");
    println!("cargo:rerun-if-env-changed=KEYNUB_LIB_NAME");
    println!("cargo:rerun-if-env-changed=KEYNUB_STATIC");

    if let Ok(dir) = env::var("KEYNUB_LIB_DIR") {
        println!("cargo:rustc-link-search=native={dir}");
    }

    let default_name = if cfg!(feature = "simulator") {
        "keynub_licdongle_sim"
    } else {
        "keynub_licdongle"
    };
    let name = env::var("KEYNUB_LIB_NAME").unwrap_or_else(|_| default_name.to_string());

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
        // mbedcrypto/mbedx509 are separate archives in the native directory.
        for lib in ["mbedx509", "mbedcrypto"] {
            println!("cargo:rustc-link-lib=static={lib}");
        }
    } else {
        println!("cargo:rustc-link-lib=dylib={name}");
    }
}
