// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ZentaoLogPlugin",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ZentaoLogPlugin", targets: ["ZentaoLogPlugin"])],
    dependencies: [.package(path: "../IronBowlKit")],
    targets: [
        .target(
            name: "ZentaoLogPlugin",
            dependencies: ["IronBowlKit"],
            swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .testTarget(name: "ZentaoLogPluginTests", dependencies: ["ZentaoLogPlugin"]),
    ]
)
