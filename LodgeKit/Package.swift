// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LodgeKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LodgeKit", targets: ["LodgeKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", .upToNextMajor(from: "2.7.0"))
    ],
    targets: [
        .target(name: "LodgeKit", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]),
        .testTarget(name: "LodgeKitTests", dependencies: ["LodgeKit"]),
    ]
)
