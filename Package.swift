// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lanebay",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LanebayCore", targets: ["LanebayCore"]),
        .library(name: "LanebayUI", targets: ["LanebayUI"]),
        .executable(name: "Lanebay", targets: ["Lanebay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(path: "Vendor/Sparkle"),
    ],
    targets: [
        .target(name: "LanebayCore"),
        .target(name: "LanebayUI", dependencies: [
            "LanebayCore",
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
        .testTarget(name: "LanebayCoreTests", dependencies: ["LanebayCore"]),
        .testTarget(name: "LanebayUITests", dependencies: ["LanebayUI"]),
    ]
)
