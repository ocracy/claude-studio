// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeStudio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeStudio",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/ClaudeStudio"
        ),
        // The project bridge: an MCP server shipped inside the app bundle. No
        // SwiftTerm, no SwiftUI — it must stay a small headless binary.
        .executableTarget(
            name: "StudioBridge",
            path: "Sources/StudioBridge"
        ),
    ]
)
