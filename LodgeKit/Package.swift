// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LodgeKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LodgeKit", targets: ["LodgeKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", .upToNextMajor(from: "2.7.0")),
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.0.0")),
        .package(url: "https://github.com/futamura/TLDExtractSwift.git", .upToNextMajor(from: "4.0.7")),
    ],
    targets: [
        .target(
            name: "LodgeKit",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TLDExtractSwift", package: "TLDExtractSwift"),
            ],
            resources: [.process("Resources")]),
        .testTarget(name: "LodgeKitTests", dependencies: ["LodgeKit"]),
    ]
)
