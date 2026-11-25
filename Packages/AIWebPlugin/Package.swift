// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIWebPlugin",
    platforms: [.macOS("26.0")],
    products: [.library(name: "AIWebPlugin", targets: ["AIWebPlugin"])],
    dependencies: [.package(path: "../IronBowlKit")],
    targets: [
        .target(
            name: "AIWebPlugin",
            dependencies: ["IronBowlKit"],
            resources: [.copy("Resources/Logos")],
            swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .testTarget(name: "AIWebPluginTests", dependencies: ["AIWebPlugin"]),
    ]
)
