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
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "HomeHub", targets: ["HomeHub"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.9.3")
    ],
    targets: [
        .target(
            name: "HomeHub",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "HomeHub",
            exclude: [
                "App/HomeHubApp.swift",
                "Runtime/Bridge/HomeHub-Bridging-Header.h"
            ],
            swiftSettings: [
                // Default: use MockLocalRuntime in live() builds.
                // When integrating the real llama.cpp xcframework, add
                // HOMEHUB_REAL_RUNTIME to Swift Active Compilation
                // Conditions in your Xcode build settings.
            ]
        ),
        .testTarget(
            name: "HomeHubTests",
            dependencies: ["HomeHub"],
            path: "HomeHubTests"
        )
    ]
)
