// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DevToolsPlugin",
    platforms: [.macOS("26.0")],
    products: [.library(name: "DevToolsPlugin", targets: ["DevToolsPlugin"])],
    dependencies: [
        .package(path: "../IronBowlKit"),
        .package(path: "../ZentaoLogPlugin"),
    ],
    targets: [
        .target(
            name: "DevToolsPlugin",
            dependencies: ["IronBowlKit", "ZentaoLogPlugin"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "DevToolsPluginTests",
            dependencies: ["DevToolsPlugin", "IronBowlKit", "ZentaoLogPlugin"]
        ),
    ]
)
