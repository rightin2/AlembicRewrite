// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PromptRewriter",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Menu-bar executable. No external dependencies: Foundation, AppKit,
        // SwiftUI, Carbon, and Security are all provided by the macOS SDK.
        .executableTarget(
            name: "PromptRewriter",
            path: "Sources/PromptRewriter"
        ),
        .testTarget(
            name: "PromptRewriterTests",
            dependencies: ["PromptRewriter"],
            path: "Tests/PromptRewriterTests"
        )
    ]
)
