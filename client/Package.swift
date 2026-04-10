// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "koom",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(
            name: "koom",
            targets: ["koom"]
        )
    ],
    dependencies: [
        // Local transcription via OpenAI Whisper weights, run in-process
        // through CoreML / the Neural Engine on Apple Silicon. Powers
        // the auto-titling pipeline that runs after each recording.
        .package(
            url: "https://github.com/argmaxinc/WhisperKit",
            .upToNextMajor(from: "0.9.0")
        )
    ],
    targets: [
        .executableTarget(
            name: "koom",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/koom",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "koomTests",
            dependencies: ["koom"],
            path: "Tests/koomTests"
        )
    ]
)
