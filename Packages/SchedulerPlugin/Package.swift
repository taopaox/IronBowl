// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SchedulerPlugin",
    platforms: [.macOS("26.0")],
    products: [.library(name: "SchedulerPlugin", targets: ["SchedulerPlugin"])],
    dependencies: [.package(path: "../IronBowlKit")],
    targets: [
        .target(
            name: "SchedulerPlugin",
            dependencies: ["IronBowlKit"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(name: "SchedulerPluginTests", dependencies: ["SchedulerPlugin"]),
    ]
)
