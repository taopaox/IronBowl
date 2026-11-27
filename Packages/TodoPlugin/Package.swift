// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TodoPlugin",
    platforms: [.macOS("26.0")],
    products: [.library(name: "TodoPlugin", targets: ["TodoPlugin"])],
    dependencies: [
        .package(path: "../IronBowlKit"),
        .package(path: "../ZentaoLogPlugin"),
    ],
    targets: [
        .target(
            name: "TodoPlugin",
            dependencies: ["IronBowlKit", "ZentaoLogPlugin"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "TodoPluginTests",
            dependencies: ["TodoPlugin", "IronBowlKit", "ZentaoLogPlugin"]
        ),
    ]
)
