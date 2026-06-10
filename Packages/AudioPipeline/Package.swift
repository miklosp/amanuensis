// swift-tools-version: 6.2
import PackageDescription

let mainActorSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let nonisolatedSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "AudioPipeline",
    platforms: [.macOS("26.3")],
    products: [
        .library(name: "AppSettings",      targets: ["AppSettings"]),
        .library(name: "RecordingStorage", targets: ["RecordingStorage"]),
        .library(name: "RecordingCore",    targets: ["RecordingCore"]),
        .library(name: "AudioPipelineJobs", targets: ["AudioPipelineJobs"]),
        .library(name: "AppLog",            targets: ["AppLog"]),
    ],
    targets: [
        .target(name: "AppSettings",      swiftSettings: mainActorSettings),
        .target(name: "RecordingStorage", swiftSettings: mainActorSettings),
        .target(
            name: "RecordingCore",
            dependencies: ["RecordingStorage"],
            swiftSettings: nonisolatedSettings
        ),
        .target(
            name: "AudioPipelineJobs",
            resources: [.process("Resources")],
            swiftSettings: nonisolatedSettings
        ),
        .target(name: "AppLog", swiftSettings: mainActorSettings),
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
        .testTarget(
            name: "RecordingCoreTests",
            dependencies: ["RecordingCore"],
            swiftSettings: nonisolatedSettings
        ),
        .testTarget(
            name: "AudioPipelineJobsTests",
            dependencies: ["AudioPipelineJobs"],
            swiftSettings: nonisolatedSettings
        ),
        .testTarget(
            name: "AppLogTests",
            dependencies: ["AppLog"],
            swiftSettings: nonisolatedSettings
        ),
    ]
)
