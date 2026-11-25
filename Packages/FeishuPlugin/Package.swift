// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FeishuPlugin",
    platforms: [.macOS("26.0")],
    products: [.library(name: "FeishuPlugin", targets: ["FeishuPlugin"])],
    dependencies: [.package(path: "../IronBowlKit")],
    targets: [
        .target(
            name: "FeishuPlugin",
            dependencies: ["IronBowlKit"],
            swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .testTarget(name: "FeishuPluginTests", dependencies: ["FeishuPlugin"]),
    ]
)
