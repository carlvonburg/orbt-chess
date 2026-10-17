// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpeningCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "OpeningCore", targets: ["OpeningCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/chesskit-app/chesskit-swift", from: "0.17.0"),
    ],
    targets: [
        .target(
            name: "OpeningCore",
            dependencies: [.product(name: "ChessKit", package: "chesskit-swift")]
        ),
        .testTarget(name: "OpeningCoreTests", dependencies: ["OpeningCore"]),
    ]
)
