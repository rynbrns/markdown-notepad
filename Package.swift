// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkdownCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MarkdownCore", targets: ["MarkdownCore"])
    ],
    targets: [
        .target(name: "MarkdownCore"),
        .testTarget(
            name: "MarkdownCoreTests",
            dependencies: ["MarkdownCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
