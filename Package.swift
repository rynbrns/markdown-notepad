// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkdownCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MarkdownCore", targets: ["MarkdownCore"]),
        .library(name: "MarkdownPreview", targets: ["MarkdownPreview"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", exact: "0.6.0")
    ],
    targets: [
        .target(name: "MarkdownCore"),
        .target(
            name: "MarkdownPreview",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .testTarget(
            name: "MarkdownCoreTests",
            dependencies: ["MarkdownCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MarkdownPreviewTests",
            dependencies: ["MarkdownPreview"],
            resources: [.copy("Fixtures")]
        )
    ]
)
