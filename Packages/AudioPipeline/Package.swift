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
        .library(name: "AppSettings",        targets: ["AppSettings"]),
        .library(name: "RecordingStorage",   targets: ["RecordingStorage"]),
        .library(name: "RecordingCore",      targets: ["RecordingCore"]),
        .library(name: "AudioPipelineJobs",  targets: ["AudioPipelineJobs"]),
        .library(name: "AppLog",             targets: ["AppLog"]),
        .library(name: "DictationCore",      targets: ["DictationCore"]),
        .library(name: "LocalTranscription", targets: ["LocalTranscription"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.15.4")),
    ],
    targets: [
        .target(name: "AppSettings", dependencies: ["DictationCore"], swiftSettings: mainActorSettings),
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
        .target(name: "DictationCore", swiftSettings: nonisolatedSettings),
        .target(
            name: "LocalTranscription",
            dependencies: [
                "AudioPipelineJobs", "AppLog",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: nonisolatedSettings
        ),
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
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"],
            swiftSettings: nonisolatedSettings
        ),
        .testTarget(
            name: "LocalTranscriptionTests",
            dependencies: ["LocalTranscription"],
            swiftSettings: nonisolatedSettings
        ),
    ]
)
