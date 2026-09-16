// swift-tools-version:5.9
// The Swift samples: two executables that depend on the SDK package two
// directories up (the repository root).
//
//   swift run verify_and_read
//   swift run rotate_write_key ../../keys/keynub-shipping-writeauth.key.der my-key.der
import PackageDescription

let package = Package(
    name: "KeyNubSamples",
    platforms: [.macOS(.v12)],
    dependencies: [
        // Named, so the identity does not depend on what the checkout folder is called.
        .package(name: "KeyNubLicDongle", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "verify_and_read",
            dependencies: [.product(name: "KeyNubLicDongle", package: "KeyNubLicDongle")]
        ),
        .executableTarget(
            name: "rotate_write_key",
            dependencies: [.product(name: "KeyNubLicDongle", package: "KeyNubLicDongle")]
        ),
    ]
)
