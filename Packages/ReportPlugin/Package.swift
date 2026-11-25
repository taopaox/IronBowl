// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReportPlugin",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ReportPlugin", targets: ["ReportPlugin"])],
    dependencies: [
        .package(path: "../IronBowlKit"),
        .package(path: "../ZentaoLogPlugin"),
    ],
    targets: [
        .target(
            name: "ReportPlugin",
            dependencies: ["IronBowlKit", "ZentaoLogPlugin"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "ReportPluginTests",
            dependencies: ["ReportPlugin", "IronBowlKit", "ZentaoLogPlugin"]
        ),
    ]
)
