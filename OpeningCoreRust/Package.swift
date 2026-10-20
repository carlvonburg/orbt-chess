// swift-tools-version: 6.2
// The Rust core (core/) as a Swift package. Run core/scripts/build-apple.sh first: it builds
// OpeningCoreFFI.xcframework and regenerates the Swift bindings in Sources/OpeningCoreRust.
import PackageDescription

let package = Package(
    name: "OpeningCoreRust",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "OpeningCoreRust", targets: ["OpeningCoreRust"]),
    ],
    targets: [
        .binaryTarget(name: "OpeningCoreFFI", path: "OpeningCoreFFI.xcframework"),
        .target(
            name: "OpeningCoreRust",
            dependencies: ["OpeningCoreFFI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OpeningCoreRustTests", dependencies: ["OpeningCoreRust"]),
    ]
)
