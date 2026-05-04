// swift-tools-version: 5.10
import PackageDescription

// ---------------------------------------------------------------------
// HomeHub — SPM manifest
// ---------------------------------------------------------------------
//
// This Package.swift serves two purposes:
//
// 1. **Open in Xcode**: Double-click Package.swift to open the project.
//    Xcode will resolve targets, enable SwiftUI previews, and let you
//    run HomeHubTests on an iOS 17 simulator.
//
// 2. **CI / command-line builds** (macOS only — requires iOS SDK):
//    swift build -Xswiftc "-sdk" -Xswiftc "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
//                -Xswiftc "-target" -Xswiftc "arm64-apple-ios17.0-simulator"
//
// The @main entry point (HomeHubApp.swift) is excluded from the library
// target so the test runner doesn't conflict with it. When you build the
// real app, use the XcodeGen project.yml or a manual Xcode target that
// includes HomeHubApp.swift.
//
// ---------------------------------------------------------------------
// Dependency pinning policy
// ---------------------------------------------------------------------
//
// ALL packages are pinned to specific versions (not branch: main) to
// ensure reproducible CI builds. The only exception is mlx-swift-lm
// which has not yet adopted a stable release cycle — it is pinned to
// a known-good revision in Package.resolved.
//
// WhisperKit ≥ 0.11.0 is required. Earlier versions import TensorUtils
// as a standalone module from swift-transformers, which was restructured
// in swift-transformers 0.1.x. Using 0.9.x with swift-transformers ≥ 0.1.14
// produces "No such module 'TensorUtils'" at build time.
//
// swift-transformers exports one library product: Transformers
// (targets: ["Tokenizers", "Generation", "Models"]).
// Hub and Tokenizers are internal targets of that product — they are NOT
// exported as standalone library products. Depending on product: Transformers
// makes all three targets (and their deps, including Hub) available for import.
// ---------------------------------------------------------------------

let package = Package(
    name: "HomeHub",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HomeHub", targets: ["HomeHub"])
    ],
    dependencies: [
        // WhisperKit ≥ 0.11.0: first release with restructured swift-transformers
        // support that no longer requires TensorUtils as a standalone import.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.11.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
        // mlx-swift-lm has no stable tag series yet; pinned via Package.resolved.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        // Explicit direct dependency so Hub and Tokenizers resolve from a pinned
        // version rather than whatever mlx-swift-lm pulls transitively.
        // from: "0.1.14" is the first version after the TensorUtils restructure
        // that is compatible with WhisperKit 0.11.0 and mlx-swift-lm main.
        // from: "0.1.14" is the minimum version compatible with WhisperKit 0.11.0.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.14"),
    ],
    targets: [
        .target(
            name: "HomeHub",
            dependencies: [
                .product(name: "WhisperKit",    package: "WhisperKit"),
                .product(name: "MLX",           package: "mlx-swift"),
                .product(name: "MLXNN",         package: "mlx-swift"),
                .product(name: "MLXLLM",        package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon",   package: "mlx-swift-lm"),
                // Transformers is the only exported library product in swift-transformers.
                // Hub and Tokenizers are internal targets compiled as part of it.
                .product(name: "Transformers",  package: "swift-transformers"),
            ],
            path: "HomeHub",
            exclude: [
                "App/HomeHubApp.swift",
                "Runtime/Bridge/HomeHub-Bridging-Header.h"
            ],
            swiftSettings: []
        ),
        .testTarget(
            name: "HomeHubTests",
            dependencies: ["HomeHub"],
            path: "HomeHubTests"
        )
    ]
)
