// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Upgrady",
    platforms: [.macOS(.v14)],
    targets: [
        // Sparkle 2, downloaded and verified by build_app.sh into Vendor/ (see SPARKLE_VERSION there).
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle.xcframework"),
        .target(name: "UpgradyCore", path: "Sources/UpgradyCore"),
        .executableTarget(
            name: "Upgrady",
            dependencies: ["UpgradyCore", "Sparkle"],
            path: "Sources/Upgrady"
        ),
        .testTarget(
            name: "UpgradyCoreTests",
            dependencies: ["UpgradyCore"],
            path: "Tests/UpgradyCoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
