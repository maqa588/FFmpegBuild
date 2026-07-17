// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FFmpegBuild",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "FFmpegBuild",
            targets: ["FFmpegBuild"]
        ),
        // Individual libraries for consumers that want fine-grained control
        .library(name: "Libavcodec", targets: ["Libavcodec"]),
        .library(name: "Libavformat", targets: ["Libavformat"]),
        .library(name: "Libavutil", targets: ["Libavutil"]),
        .library(name: "Libswresample", targets: ["Libswresample"]),
        .library(name: "Libswscale", targets: ["Libswscale"]),
        .library(name: "Libdav1d", targets: ["Libdav1d"]),
    ],
    targets: [
        // Umbrella target that links all FFmpeg libraries + dav1d + system frameworks
        .target(
            name: "FFmpegBuild",
            dependencies: [
                "Libavcodec",
                "Libavformat",
                "Libavutil",
                "Libswresample",
                "Libswscale",
                "Libdav1d",
            ],
            path: "Sources/FFmpegBuild",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
            ]
        ),
        // Prebuilt xcframeworks (created by build.sh)
        .binaryTarget(name: "Libavcodec", path: "Sources/Libavcodec.xcframework"),
        .binaryTarget(name: "Libavformat", path: "Sources/Libavformat.xcframework"),
        .binaryTarget(name: "Libavutil", path: "Sources/Libavutil.xcframework"),
        .binaryTarget(name: "Libswresample", path: "Sources/Libswresample.xcframework"),
        .binaryTarget(name: "Libswscale", path: "Sources/Libswscale.xcframework"),
        .binaryTarget(name: "Libdav1d", path: "Sources/Libdav1d.xcframework"),
        .testTarget(
            name: "FFmpegBuildTests",
            dependencies: ["FFmpegBuild", "Libavcodec"],
            path: "Tests/FFmpegBuildTests",
            linkerSettings: [
                // SwiftPM materializes dynamic binary targets next to the
                // .xctest bundle but does not embed them inside it.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."]),
            ]
        ),
    ]
)
