// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IronBowlKit",
    platforms: [.macOS("26.0")],
    products: [.library(name: "IronBowlKit", targets: ["IronBowlKit"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "IronBowlKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .testTarget(name: "IronBowlKitTests", dependencies: ["IronBowlKit"]),
    ]
)
