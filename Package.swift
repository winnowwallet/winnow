// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Winnow",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WalletCore", targets: ["WalletCore"]),
        // Test fixtures shared by every test target, SwiftPM and Xcode alike.
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .executable(name: "winnow-debug", targets: ["WinnowDebug"]),
        .executable(name: "WinnowFuzz", targets: ["WinnowFuzz"]),
        .executable(name: "winnow-fixture", targets: ["WinnowFixture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
    ],
    targets: [
        // Pure-Swift secp256k1 for the single-key BIP86 path (variable-time;
        // see Sources/NativeSecp256k1/README.md). Foundation and CryptoKit only.
        .target(
            name: "NativeSecp256k1",
            exclude: ["README.md"]
        ),
        // P256K remains only for the vault code (MuSig2 point arithmetic);
        // the single-key path uses NativeSecp256k1.
        .target(
            name: "WalletCore",
            dependencies: ["NativeSecp256k1", .product(name: "P256K", package: "swift-secp256k1")],
            exclude: [
                "Crypto/README.md",
                "Descriptors/README.md",
                "Script/README.md",
                "Keys/README.md",
                "Network/Broadcast/README.md",
                "Network/Filters/README.md",
                "Network/Headers/README.md",
                "Network/Mempool/README.md",
                "Network/Peers/README.md",
                "Network/Protocol/README.md",
                "Network/Transport/README.md",
                "PSBT/README.md",
                "Transactions/README.md",
                "Wallet/README.md",
            ]
        ),
        .executableTarget(
            name: "WinnowDebug",
            dependencies: ["WalletCore"],
            path: "Tools/Debug/Sources/WinnowDebug",
            exclude: ["README.md"]
        ),
        // P256K: the native-secp256k1 target compares both backends.
        .target(
            name: "WinnowFuzzCore",
            dependencies: ["WalletCore", "NativeSecp256k1",
                           .product(name: "P256K", package: "swift-secp256k1")],
            path: "Tools/Fuzz/Sources/WinnowFuzzCore",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "WinnowFuzz",
            dependencies: ["WalletCore", "WinnowFuzzCore"],
            path: "Tools/Fuzz/Sources/WinnowFuzz",
            exclude: ["README.md"]
        ),
        // Framework-agnostic fixtures (no Testing, no XCTest) so the
        // swift-testing targets below and the Xcode app test bundles share one
        // implementation. P256K: the signet miner signs block challenges.
        .target(
            name: "TestSupport",
            dependencies: ["WalletCore",
                           .product(name: "P256K", package: "swift-secp256k1")],
            path: "Tests/Support",
            exclude: ["Node/README.md", "P2P/README.md", "README.md"]
        ),
        .executableTarget(
            name: "WinnowFixture",
            dependencies: ["TestSupport"],
            path: "Tools/Fixture",
            exclude: ["README.md"]
        ),
        // P256K: the native curve code is differential-tested against it.
        .testTarget(
            name: "BitcoinCoreTests",
            dependencies: ["WalletCore", "TestSupport", "NativeSecp256k1",
                           .product(name: "P256K", package: "swift-secp256k1")],
            exclude: ["README.md"],
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "WalletCoreTests",
            dependencies: ["WalletCore", "TestSupport", "NativeSecp256k1",
                           .product(name: "P256K", package: "swift-secp256k1")],
            exclude: ["Network/README.md", "README.md"],
            resources: [.copy("Vectors")]
        ),
        // The development tools, tested together: the debugging commands, the
        // release-path generators, and the fuzz crash corpus replayed out of
        // `Cases`. One target, so a tool suite costs no more manifest than a
        // library one and `swift test` links the tools once.
        .testTarget(
            name: "ToolsTests",
            dependencies: ["WinnowDebug", "WinnowFuzzCore"],
            exclude: ["README.md"],
            resources: [.copy("Cases")]
        ),
    ]
)
