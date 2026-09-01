// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "web-to-markdown-apple",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
        .macCatalyst(.v16),
    ],
    products: [
        .library(
            name: "WebToMarkdown",
            targets: ["WebToMarkdown"]
        ),
        .executable(
            name: "web-to-markdown",
            targets: ["WebToMarkdownCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.5"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        .package(url: "https://github.com/shareup/synchronized.git", from: "4.0.2"),
    ],
    targets: [
        .target(
            name: "WebToMarkdown",
            dependencies: [
                "SwiftSoup",
                .product(name: "Synchronized", package: "synchronized"),
            ]
        ),
        .executableTarget(
            name: "WebToMarkdownCLI",
            dependencies: [
                "WebToMarkdown",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "WebToMarkdownTests",
            dependencies: ["WebToMarkdown"]
        ),
    ]
)
