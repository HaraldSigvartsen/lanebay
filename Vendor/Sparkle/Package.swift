// swift-tools-version: 5.5
import PackageDescription

// Keep aligned with Sparkle 2.10.0's upstream SPM manifest. The checksum
// verifies the exact upstream release archive fetched from its SourceForge mirror.
let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "Sparkle", targets: ["Sparkle"]),
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            url: "https://downloads.sourceforge.net/project/sparkle-2.mirror/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
        ),
    ]
)
