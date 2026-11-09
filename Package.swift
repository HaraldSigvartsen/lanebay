// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lanebay",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LanebayCore", targets: ["LanebayCore"]),
        .library(name: "LanebayUI", targets: ["LanebayUI"]),
        .library(name: "LanebayDesign", targets: ["LanebayDesign"]),
        .executable(name: "Lanebay", targets: ["Lanebay"]),
        // Installed as `lanebay` (a different name than the app binary on case-insensitive disks).
        .executable(name: "lanebayctl", targets: ["LanebayCtl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(path: "Vendor/Sparkle"),
    ],
    targets: [
        .target(name: "LanebayCore"),
        .target(name: "LanebayDesign"),
        .target(name: "LanebayUI", dependencies: [
            "LanebayCore",
            "LanebayDesign",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .executableTarget(
            name: "Lanebay",
            dependencies: [
                "LanebayCore",
                "LanebayUI",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(name: "LanebayCtl", dependencies: ["LanebayCore"]),
        .testTarget(name: "LanebayCoreTests", dependencies: ["LanebayCore"]),
        .testTarget(name: "LanebayUITests", dependencies: ["LanebayUI"]),
        .testTarget(name: "LanebayDesignTests", dependencies: ["LanebayDesign"]),
    ]
)
