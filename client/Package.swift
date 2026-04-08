// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "koom",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "koom",
            targets: ["koom"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "koom",
            path: "Sources/koom",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
