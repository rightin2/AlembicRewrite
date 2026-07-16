// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AlembicRewrite",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Menu-bar executable. No external dependencies: Foundation, AppKit,
        // SwiftUI, Carbon, and Security are all provided by the macOS SDK.
        .executableTarget(
            name: "AlembicRewrite",
            path: "Sources/AlembicRewrite"
        ),
        .testTarget(
            name: "AlembicRewriteTests",
            dependencies: ["AlembicRewrite"],
            path: "Tests/AlembicRewriteTests"
        )
    ]
)
