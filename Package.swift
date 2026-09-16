// swift-tools-version:5.9
// KeyNub License Dongle: the Swift package. It sits at the repository root so
// that Swift Package Manager and the Swift Package Index find it; the sources
// live under bindings/swift. The native library is loaded at run time from the
// natives/ folder of this repository (a package dependency is a clone of it),
// so nothing is linked and no build flags are needed.
import PackageDescription

let package = Package(
    name: "KeyNubLicDongle",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "KeyNubLicDongle", targets: ["KeyNubLicDongle"]),
    ],
    targets: [
        // The SDK's C header as a module, for the structure layouts.
        .target(
            name: "CLicDongle",
            path: "bindings/swift/Sources/CLicDongle"
        ),
        .target(
            name: "KeyNubLicDongle",
            dependencies: ["CLicDongle"],
            path: "bindings/swift/Sources/KeyNubLicDongle"
        ),
        .testTarget(
            name: "KeyNubLicDongleTests",
            dependencies: ["KeyNubLicDongle"],
            path: "bindings/swift/Tests/KeyNubLicDongleTests"
        ),
    ]
)
