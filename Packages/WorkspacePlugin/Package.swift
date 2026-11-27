// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WorkspacePlugin",
    platforms: [.macOS("26.0")],
    products: [.library(name: "WorkspacePlugin", targets: ["WorkspacePlugin"])],
    dependencies: [
        .package(path: "../IronBowlKit"),
        .package(path: "../ZentaoLogPlugin"),
    ],
    targets: [
        .target(
            name: "WorkspacePlugin",
            dependencies: ["IronBowlKit", "ZentaoLogPlugin"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "WorkspacePluginTests",
            dependencies: ["WorkspacePlugin", "IronBowlKit", "ZentaoLogPlugin"]
        ),
    ]
)
