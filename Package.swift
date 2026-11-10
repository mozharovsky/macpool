// swift-tools-version: 6.2

import PackageDescription

/// Compiler settings that every target shares.
///
/// The package builds in the Swift 6 language mode, which checks concurrency completely. The
/// upcoming features keep imports explicit and run nonisolated async functions on the caller's
/// actor unless they opt out.
let strictSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

/// The macpool libraries, command line, and their tests.
let package = Package(
    name: "macpool",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MacpoolVM", targets: ["MacpoolVM"]),
        .library(name: "MacpoolPool", targets: ["MacpoolPool"]),
        .executable(name: "macpool", targets: ["MacpoolCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-log", from: "1.17.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.2"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-certificates", exact: "1.21.1"),
        .package(url: "https://github.com/apple/swift-asn1", exact: "1.7.4"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", exact: "0.64.6"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.65.1"),
    ],
    targets: [
        .target(
            name: "MacpoolVM",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            swiftSettings: strictSwiftSettings,
        ),
        .target(
            name: "MacpoolPool",
            dependencies: [
                "MacpoolVM",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            swiftSettings: strictSwiftSettings,
        ),
        .executableTarget(
            name: "MacpoolCLI",
            dependencies: [
                "MacpoolVM",
                "MacpoolPool",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            swiftSettings: strictSwiftSettings,
        ),
        .testTarget(
            name: "MacpoolVMTests",
            dependencies: [
                "MacpoolVM",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSwiftSettings,
        ),
        .testTarget(
            name: "MacpoolPoolTests",
            dependencies: [
                "MacpoolPool",
                "MacpoolVM",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: strictSwiftSettings,
        ),
        .testTarget(
            name: "MacpoolCLITests",
            dependencies: [
                "MacpoolCLI",
                "MacpoolPool",
                "MacpoolVM",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            swiftSettings: strictSwiftSettings,
        ),
    ],
)
