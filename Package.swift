// swift-tools-version: 6.0
// Albumist – platform-independent core.
// The iOS app (App/) links these libraries. Everything in here builds and tests on
// macOS, iOS and Linux so the business logic is verifiable without a Mac.
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "SortlyKit",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SortlyCore", targets: ["SortlyCore"]),
        .library(name: "SortlyStore", targets: ["SortlyStore"]),
        .library(name: "SortlyWorldMap", targets: ["SortlyWorldMap"]),
        .library(name: "SortlyEngine", targets: ["SortlyEngine"]),
        .library(name: "SortlyMap", targets: ["SortlyMap"]),
        .library(name: "SortlyTestSupport", targets: ["SortlyTestSupport"]),
    ],
    targets: [
        // Apple platforms ship SQLite as the `SQLite3` module; Linux needs a module map.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "SortlyCore",
            swiftSettings: strictSettings
        ),
        .target(
            name: "SortlyStore",
            dependencies: [
                "SortlyCore",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "SortlyWorldMap",
            dependencies: ["SortlyCore"],
            resources: [.copy("Resources/world.sortlymap"), .copy("Resources/LICENSE-NaturalEarth.txt")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "SortlyEngine",
            dependencies: ["SortlyCore", "SortlyStore"],
            swiftSettings: strictSettings
        ),
        // "Deine Welt" (map concept 2.0, approved 20.11.2026): the map summary, its numbers and
        // the data of the share images. Its own module, so the map builds and tests on its own.
        .target(
            name: "SortlyMap",
            dependencies: ["SortlyCore"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "SortlyTestSupport",
            dependencies: ["SortlyCore"],
            swiftSettings: strictSettings
        ),
        // Files of the UI tests built here as well so Linux tests them: test12's pause check,
        // and which app process the end of the app is about (UITestLaunchRecord).
        .target(
            name: "SortlyUITestLogic",
            path: "App/SortlyUITests",
            sources: ["PauseCountCheck.swift", "UITestLaunchRecord.swift"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SortlyUITestLogicTests",
            dependencies: ["SortlyUITestLogic"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SortlyCoreTests",
            dependencies: ["SortlyCore", "SortlyWorldMap", "SortlyTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SortlyMapTests",
            dependencies: ["SortlyMap", "SortlyCore", "SortlyWorldMap", "SortlyTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SortlyStoreTests",
            dependencies: ["SortlyStore", "SortlyCore", "SortlyTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SortlyEngineTests",
            dependencies: ["SortlyEngine", "SortlyStore", "SortlyCore", "SortlyWorldMap", "SortlyTestSupport"],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
