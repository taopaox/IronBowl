// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CalendarPlugin",
    platforms: [.macOS("26.0")],
    products: [.library(name: "CalendarPlugin", targets: ["CalendarPlugin"])],
    dependencies: [.package(path: "../IronBowlKit")],
    targets: [
        .target(
            name: "CalendarPlugin",
            dependencies: ["IronBowlKit"],
            swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .testTarget(name: "CalendarPluginTests", dependencies: ["CalendarPlugin"]),
    ]
)
