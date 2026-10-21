// swift-tools-version: 6.0
import PackageDescription

// No package dependencies: the curve arithmetic is the in-tree
// NativeSecp256k1 module, and the test suite checks it against recorded
// libsecp256k1 answers (Tests/BitcoinCoreTests/Vectors/native-secp256k1).
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
        .executable(name: "winnow-checker", targets: ["WinnowChecker"]),
    ],
    targets: [
        // Pure-Swift secp256k1 for the single-key BIP86 path (variable-time;
        // see Sources/NativeSecp256k1/README.md). Foundation and CryptoKit only.
        .target(
            name: "NativeSecp256k1",
            exclude: ["README.md"]
        ),
        .target(
            name: "WalletCore",
            dependencies: ["NativeSecp256k1"],
            exclude: [
                "Crypto/README.md",
                "Descriptors/README.md",
                "Script/README.md",
                "Keys/README.md",
                "Ledger/README.md",
                "Network/Broadcast/README.md",
                "Network/Filters/README.md",
                "Network/Headers/README.md",
                "Network/Mempool/README.md",
                "Network/Peers/README.md",
                "Network/Protocol/README.md",
                "Network/Transport/README.md",
                "PSBT/README.md",
                "Satochip/README.md",
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
        // The Satochip checker for a trusted Mac: shows each spend from the
        // PSBT alone and approves what the card may sign (Tools/Checker).
        .executableTarget(
            name: "WinnowChecker",
            dependencies: ["WalletCore"],
            path: "Tools/Checker/Sources/WinnowChecker"
        ),
        // The native-secp256k1 target checks the module's own algebra on
        // every input; byte agreement with libsecp256k1 is the vector suite's.
        .target(
            name: "WinnowFuzzCore",
            dependencies: ["WalletCore", "NativeSecp256k1"],
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
        // implementation. The signet miner has the node's wallet sign block
        // challenges over RPC, so it needs no curve code of its own.
        .target(
            name: "TestSupport",
            dependencies: ["WalletCore"],
            path: "Tests/Support",
            exclude: ["Node/README.md", "P2P/README.md", "README.md"]
        ),
        .executableTarget(
            name: "WinnowFixture",
            dependencies: ["TestSupport"],
            path: "Tools/Fixture",
            exclude: ["README.md"]
        ),
        // The native curve code is checked layer by layer against the
        // recorded fixtures, the official BIP vectors, and the fuzz core's
        // independent reference implementation.
        .testTarget(
            name: "BitcoinCoreTests",
            dependencies: ["WalletCore", "TestSupport", "NativeSecp256k1", "WinnowFuzzCore"],
            exclude: ["README.md"],
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "WalletCoreTests",
            dependencies: ["WalletCore", "TestSupport", "NativeSecp256k1"],
            exclude: ["Network/README.md", "README.md"],
            resources: [.copy("Vectors")]
        ),
        // The development tools, tested together: the debugging commands, the
        // release-path generators, and the fuzz crash corpus replayed out of
        // `Cases`. One target, so a tool suite costs no more manifest than a
        // library one and `swift test` links the tools once.
        .testTarget(
            name: "ToolsTests",
            dependencies: ["WinnowDebug", "WinnowFuzzCore", "WinnowChecker", "TestSupport"],
            exclude: ["README.md"],
            resources: [.copy("Cases")]
        ),
    ]
)
