// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LodgeKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LodgeKit", targets: ["LodgeKit"])
    ],
    targets: [
        .target(name: "LodgeKit"),
        .testTarget(name: "LodgeKitTests", dependencies: ["LodgeKit"]),
    ]
)
