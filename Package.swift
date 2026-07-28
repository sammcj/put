// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Put",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Put", targets: ["Put"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.3.0")
    ],
    targets: [
        .target(
            name: "PutCore",
            path: "Sources/PutCore"),
        .target(
            name: "PutStorage",
            dependencies: ["PutCore"],
            path: "Sources/PutStorage"),
        .target(
            name: "PutDisplay",
            dependencies: ["PutCore"],
            path: "Sources/PutDisplay"),
        .target(
            name: "PutWindows",
            dependencies: ["PutCore"],
            path: "Sources/PutWindows"),
        .target(
            name: "PutPlacement",
            dependencies: ["PutCore", "PutDisplay", "PutWindows"],
            path: "Sources/PutPlacement"),
        .target(
            name: "PutHotkeys",
            dependencies: [
                "PutCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/PutHotkeys"),
        .target(
            name: "PutAutomation",
            dependencies: ["PutCore", "PutDisplay", "PutWindows", "PutPlacement"],
            path: "Sources/PutAutomation"),
        .target(
            name: "PutUI",
            dependencies: [
                "PutCore",
                "PutStorage",
                "PutDisplay",
                "PutWindows",
                "PutPlacement",
                "PutHotkeys",
                "PutAutomation",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/PutUI"),
        .executableTarget(
            name: "Put",
            dependencies: [
                "PutCore",
                "PutStorage",
                "PutDisplay",
                "PutWindows",
                "PutPlacement",
                "PutHotkeys",
                "PutAutomation",
                "PutUI"
            ],
            path: "Sources/Put"),
        // Dev-only Phase 0 probe for Space-fingerprint signals. Not part of the
        // shipped .app; run with `swift run PutSpaceProbe`.
        .executableTarget(
            name: "PutSpaceProbe",
            path: "Sources/PutSpaceProbe"),
        // Test-only shared fixture builders. Plain library target (not a
        // product) consumed by the test targets below; never linked into the app.
        .target(
            name: "PutTestSupport",
            dependencies: ["PutCore", "PutStorage", "PutWindows"],
            path: "Tests/PutTestSupport"),
        .testTarget(
            name: "PutCoreTests",
            dependencies: ["PutCore", "PutTestSupport"],
            path: "Tests/PutCoreTests"),
        .testTarget(
            name: "PutStorageTests",
            dependencies: ["PutCore", "PutStorage", "PutTestSupport"],
            path: "Tests/PutStorageTests"),
        .testTarget(
            name: "PutPlacementTests",
            dependencies: ["PutCore", "PutPlacement", "PutWindows", "PutDisplay"],
            path: "Tests/PutPlacementTests"),
        .testTarget(
            name: "PutDisplayTests",
            dependencies: ["PutCore", "PutDisplay", "PutTestSupport"],
            path: "Tests/PutDisplayTests"),
        .testTarget(
            name: "PutWindowsTests",
            dependencies: ["PutCore", "PutWindows"],
            path: "Tests/PutWindowsTests"),
        .testTarget(
            name: "PutAutomationTests",
            dependencies: ["PutCore", "PutAutomation", "PutStorage", "PutWindows", "PutTestSupport"],
            path: "Tests/PutAutomationTests"),
        .testTarget(
            name: "PutHotkeysTests",
            dependencies: [
                "PutCore",
                "PutHotkeys",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Tests/PutHotkeysTests"),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "PutCore",
                "PutDisplay",
                "PutWindows",
                "PutPlacement"
            ],
            path: "Tests/IntegrationTests"),
        .testTarget(
            name: "PutUITests",
            dependencies: ["PutCore", "PutUI", "PutTestSupport"],
            path: "Tests/PutUITests")
    ],
    swiftLanguageModes: [.v6])
