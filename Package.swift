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
            path: "Sources/AlembicRewrite",
            resources: [
                // Bundled app + menu-bar icons, reached at runtime via
                // Bundle.module. .copy keeps the files verbatim (no asset-catalog
                // processing, which a bare SPM executable has no Info.plist for).
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/MenuBarIcon.png"),
                .copy("Resources/MenuBarIcon@2x.png")
            ]
        ),
        .testTarget(
            name: "AlembicRewriteTests",
            dependencies: ["AlembicRewrite"],
            path: "Tests/AlembicRewriteTests"
        )
    ]
)
