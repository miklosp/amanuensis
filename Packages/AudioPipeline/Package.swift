// swift-tools-version: 6.2
import PackageDescription

let mainActorSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "AudioPipeline",
    platforms: [.macOS("26.3")],
    products: [
        .library(name: "AppSettings",      targets: ["AppSettings"]),
        .library(name: "RecordingStorage", targets: ["RecordingStorage"]),
    ],
    targets: [
        .target(name: "AppSettings",      swiftSettings: mainActorSettings),
        .target(name: "RecordingStorage", swiftSettings: mainActorSettings),
        .testTarget(
            name: "AppSettingsTests",
            dependencies: ["AppSettings"],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "RecordingStorageTests",
            dependencies: ["RecordingStorage"],
            swiftSettings: mainActorSettings
        ),
    ]
)
