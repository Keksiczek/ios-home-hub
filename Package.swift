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
// ---------------------------------------------------------------------

let package = Package(
    name: "HomeHub",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HomeHub", targets: ["HomeHub"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.9.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.10.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        // Explicitly declaring swift-transformers (was transitive via WhisperKit).
        // Required for Phase 4A: Hub.HubApi (real download progress) + Tokenizers.AutoTokenizer
        // (tokenizer loading from local cache directory) used in HubIntegration.swift.
        .package(url: "https://github.com/huggingface/swift-transformers", branch: "main")
    ],
    targets: [
        .target(
            name: "HomeHub",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // Hub (HubApi downloader) + Tokenizers (AutoTokenizer bridge)
                // are the two products actually used by HubIntegration.swift.
                // The umbrella `Transformers` product is not needed here.
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers")
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
